// Top-of-book engine for one stock: decoded ITCH events in, BBO updates out.
//
// Order table: 4-way set-associative in block RAM. Set = ref[11:0] (Nasdaq order
// references increase through the day, so low bits spread live orders evenly),
// tag = ref[43:12]. Each entry: {valid, side, tag, price index, shares} = 78 bits.
// An Add that finds its set full is counted as a collision and not booked.
//
// Price ladder: a window of 4,096 ticks per side starting at cfg_base_price
// (tick = $0.01 = 100 ITCH price units), level quantities in block RAM, and a
// bitmap of non-empty levels in flip-flops. The best level comes from a
// two-level priority encoder over the bitmap (64 words of 64 bits plus a
// 64-bit summary), so when the best level empties the next best is found in
// two cycles. Orders priced outside the window or off the tick grid are counted
// and not booked.
//
// Sequencing: one event at a time through a short state machine
//   IDLE -> LOOKUP -> LVL_RD -> LVL_WR -> BBO1 -> BBO2 -> BBO3      (7 cycles)
// A Replace runs the delete half, then the add half (U_RD re-reads the order set
// for the new reference, then LOOKUP again): 10 cycles.
// Because each step finishes before the next starts, no read-after-write
// forwarding is needed. 7 cycles per event at 156.25 MHz = 22 M events/s.
//
// Output: a BBO update (prices in ITCH units, quantities in shares, the event's
// sequence number) whenever the best bid or offer changes, same rule as the C++
// BookBuilder. An empty side reports price 0, quantity 0.

`default_nettype none

module book_engine #(
    parameter int SET_BITS = 12,      // 4,096 sets x 4 ways
    parameter int WIN_BITS = 12       // 4,096 price levels per side
) (
    input  wire         clk,
    input  wire         rst,
    input  wire  [31:0] cfg_base_price,   // price of level 0 (ITCH units, multiple of 100)

    input  wire         ev_valid,
    output logic        ev_ready,
    input  wire  [2:0]  ev_type,          // 1 Add 2 Exec 3 ExecPrice 4 Cancel 5 Delete 6 Replace 7 Trade
    input  wire  [63:0] ev_ref,
    input  wire  [63:0] ev_new_ref,
    input  wire  [31:0] ev_shares,
    input  wire  [31:0] ev_price,
    input  wire         ev_side_sell,
    input  wire  [63:0] ev_seq,

    output logic        bbo_valid,
    input  wire         bbo_ready,
    output logic [31:0] bbo_bid_px,
    output logic [47:0] bbo_bid_qty,
    output logic [31:0] bbo_ask_px,
    output logic [47:0] bbo_ask_qty,
    output logic [63:0] bbo_seq,

    output logic [31:0] cnt_events,
    output logic [31:0] cnt_bbo,
    output logic [31:0] cnt_out_of_window,
    output logic [31:0] cnt_collisions,
    output logic [31:0] cnt_unknown,
    output logic [31:0] cnt_duplicates,
    output logic [15:0] live_orders
);
    localparam int WAYS  = 4;
    localparam int NSETS = 1 << SET_BITS;
    localparam int NLVL  = 1 << WIN_BITS;
    localparam int TAGW  = 32;
    localparam int NW    = NLVL / 64;     // bitmap words per side

    typedef struct packed {
        logic                valid;
        logic                sell;
        logic [TAGW-1:0]     tag;
        logic [WIN_BITS-1:0] pidx;
        logic [31:0]         qty;
    } entry_t;

    typedef enum logic [3:0] {CLEAR, IDLE, LOOKUP, LVL_RD, LVL_WR, BBO1, BBO2, BBO3, U_RD} state_t;
    state_t state;

    // After reset the block RAMs still hold whatever they held before (FPGA memories
    // are not cleared by a reset), so CLEAR walks every address writing zeros:
    // 4,096 cycles (26 us) during which ev_ready stays low.
    localparam int CLR_BITS = (SET_BITS > WIN_BITS) ? SET_BITS : WIN_BITS;
    logic [CLR_BITS-1:0] clr_addr;

    // ---------------------------------------------------------------- current event
    logic [2:0]  e_type;
    logic [63:0] e_ref, e_new_ref, e_seq;
    logic [31:0] e_shares, e_price;
    logic        e_sell;
    logic        changed;            // a level changed during this event
    logic        u_add_pending;      // Replace: add half still to do

    // ---------------------------------------------------------------- order table
    entry_t      ways_q [WAYS][NSETS];
    entry_t      way_rd [WAYS];
    logic [SET_BITS-1:0] set_rd_addr;
    logic        way_we [WAYS];
    entry_t      way_wd;
    logic [SET_BITS-1:0] set_wr_addr;

    always_ff @(posedge clk) begin
        for (int w = 0; w < WAYS; w++) begin
            if (way_we[w]) ways_q[w][set_wr_addr] <= way_wd;
            way_rd[w] <= ways_q[w][set_rd_addr];
        end
    end

    // ---------------------------------------------------------------- level quantities
    logic [47:0] lvl_bid [NLVL];
    logic [47:0] lvl_ask [NLVL];
    logic [WIN_BITS-1:0] lvl_rd_bid_addr, lvl_rd_ask_addr, lvl_wr_addr;
    logic [47:0] lvl_rd_bid, lvl_rd_ask, lvl_wd;
    logic        lvl_we_bid, lvl_we_ask;

    always_ff @(posedge clk) begin
        if (lvl_we_bid) lvl_bid[lvl_wr_addr] <= lvl_wd;
        if (lvl_we_ask) lvl_ask[lvl_wr_addr] <= lvl_wd;
        lvl_rd_bid <= lvl_bid[lvl_rd_bid_addr];
        lvl_rd_ask <= lvl_ask[lvl_rd_ask_addr];
    end

    // ---------------------------------------------------------------- non-empty bitmaps
    logic [NLVL-1:0] bm_bid, bm_ask;
    logic [NW-1:0]   sum_bid, sum_ask;
    always_comb begin
        for (int w = 0; w < NW; w++) begin
            sum_bid[w] = |bm_bid[64*w +: 64];
            sum_ask[w] = |bm_ask[64*w +: 64];
        end
    end
    function automatic logic [5:0] highest(input logic [63:0] v);
        logic [5:0] r;
        r = '0;
        for (int i = 0; i < 64; i++) if (v[i]) r = 6'(i);
        return r;
    endfunction
    function automatic logic [5:0] lowest(input logic [63:0] v);
        logic [5:0] r;
        r = '0;
        for (int i = 63; i >= 0; i--) if (v[i]) r = 6'(i);
        return r;
    endfunction

    // ---------------------------------------------------------------- price -> level index
    // (price - base) / 100 by multiplication: exact for every multiple of 100 below
    // 4,096 x 100; anything else fails the round-trip check and is out of window.
    function automatic logic [WIN_BITS-1:0] price_index(input logic [31:0] price, input logic [31:0] base,
                                                      output logic ok);
        logic [31:0] diff;
        logic [44:0] prod;
        logic [25:0] q;
        diff = price - base;
        prod = 45'(diff) * 45'd5243;
        q = 26'(prod >> 19);
        ok = (price >= base) && (q < 26'(NLVL)) && (32'(q) * 32'd100 == diff);
        return q[WIN_BITS-1:0];
    endfunction

    // ---------------------------------------------------------------- lookup results (LOOKUP)
    wire [TAGW-1:0] tag_of_e = e_ref[SET_BITS +: TAGW];
    logic [WAYS-1:0] hit_v, free_v;
    always_comb begin
        for (int w = 0; w < WAYS; w++) begin
            hit_v[w]  = way_rd[w].valid && (way_rd[w].tag == tag_of_e);
            free_v[w] = !way_rd[w].valid;
        end
    end
    logic [1:0] hit_way, free_way;
    always_comb begin
        hit_way = '0;
        free_way = '0;
        for (int w = WAYS - 1; w >= 0; w--) begin
            if (hit_v[w])  hit_way  = 2'(w);
            if (free_v[w]) free_way = 2'(w);
        end
    end
    wire    hit      = |hit_v;
    wire    any_free = |free_v;
    entry_t hit_e;
    assign  hit_e = way_rd[hit_way];
    logic   pidx_ok;
    logic [WIN_BITS-1:0] pidx_full;
    always_comb pidx_full = price_index(e_price, cfg_base_price, pidx_ok);
    wire    ref_ok = (e_ref[63:SET_BITS + TAGW] == '0);   // refs below 2^44 (a day is ~2^30)

    // level operation decided in LOOKUP, applied in LVL_RD / LVL_WR
    logic                op_sell, op_add;
    logic [WIN_BITS-1:0] op_pidx;
    logic [31:0]         op_qty;

    // ---------------------------------------------------------------- best levels (BBO1/BBO2)
    logic [5:0]  bw_bid, bw_ask;                 // best word
    logic        has_bid, has_ask;
    logic [WIN_BITS-1:0] best_bid, best_ask;
    logic [31:0] last_bid_px, last_ask_px;
    logic [47:0] last_bid_qty, last_ask_qty;

    assign ev_ready = (state == IDLE);

    always_comb begin
        // defaults: no writes
        for (int w = 0; w < WAYS; w++) way_we[w] = 1'b0;
        way_wd = '0;
        set_wr_addr = e_ref[SET_BITS-1:0];
        set_rd_addr = (state == IDLE) ? ev_ref[SET_BITS-1:0] : e_ref[SET_BITS-1:0];
        lvl_we_bid = 1'b0;
        lvl_we_ask = 1'b0;
        lvl_wr_addr = op_pidx;
        lvl_wd = '0;
        lvl_rd_bid_addr = (state == BBO2) ? {bw_bid, highest(bm_bid[64*bw_bid +: 64])} : op_pidx;
        lvl_rd_ask_addr = (state == BBO2) ? {bw_ask, lowest(bm_ask[64*bw_ask +: 64])}  : op_pidx;

        if (state == CLEAR) begin
            for (int w = 0; w < WAYS; w++) way_we[w] = 1'b1;
            way_wd = '0;
            set_wr_addr = clr_addr[SET_BITS-1:0];
            lvl_we_bid = 1'b1;
            lvl_we_ask = 1'b1;
            lvl_wr_addr = clr_addr[WIN_BITS-1:0];
            lvl_wd = '0;
        end
        if (state == LOOKUP) begin
            unique case (e_type)
                3'd1: if (ref_ok && pidx_ok && !hit && any_free) begin       // Add
                    way_we[free_way] = 1'b1;
                    way_wd = '{valid: 1'b1, sell: e_sell, tag: tag_of_e,
                               pidx: pidx_full, qty: e_shares};
                end
                3'd2, 3'd3, 3'd4, 3'd5, 3'd6: if (ref_ok && hit) begin       // reduce / remove
                    way_we[hit_way] = 1'b1;
                    way_wd = hit_e;
                    if (e_type == 3'd5 || e_type == 3'd6 || e_shares >= hit_e.qty) begin
                        way_wd.valid = 1'b0;
                        way_wd.qty = '0;
                    end else begin
                        way_wd.qty = hit_e.qty - e_shares;
                    end
                end
                default: ;
            endcase
        end
        if (state == LVL_WR) begin
            lvl_wd = op_add ? (op_sell ? lvl_rd_ask : lvl_rd_bid) + 48'(op_qty)
                            : (op_sell ? lvl_rd_ask : lvl_rd_bid) - 48'(op_qty);
            lvl_we_bid = !op_sell;
            lvl_we_ask = op_sell;
        end
    end

    // ---------------------------------------------------------------- state machine
    always_ff @(posedge clk) begin
        if (rst) begin
            state <= CLEAR;
            clr_addr <= '0;
            bm_bid <= '0;
            bm_ask <= '0;
            bbo_valid <= 1'b0;
            {last_bid_px, last_ask_px} <= '0;
            {last_bid_qty, last_ask_qty} <= '0;
            {cnt_events, cnt_bbo, cnt_out_of_window, cnt_collisions, cnt_unknown, cnt_duplicates} <= '0;
            live_orders <= '0;
            changed <= 1'b0;
            u_add_pending <= 1'b0;
        end else begin
            if (bbo_valid && bbo_ready) bbo_valid <= 1'b0;
            unique case (state)
                CLEAR: begin
                    clr_addr <= clr_addr + 1'b1;
                    if (&clr_addr) state <= IDLE;
                end

                IDLE: if (ev_valid) begin
                    e_type <= ev_type;
                    e_ref <= ev_ref;
                    e_new_ref <= ev_new_ref;
                    e_seq <= ev_seq;
                    e_shares <= ev_shares;
                    e_price <= ev_price;
                    e_sell <= ev_side_sell;
                    changed <= 1'b0;
                    u_add_pending <= 1'b0;
                    cnt_events <= cnt_events + 1;
                    state <= (ev_type == 3'd7 || ev_type == 3'd0) ? IDLE : LOOKUP;  // trades: no book change
                end

                LOOKUP: begin
                    state <= (changed) ? BBO1 : IDLE;   // default: nothing to apply
                    unique case (e_type)
                        3'd1: begin                                  // Add
                            if (!ref_ok || !pidx_ok) cnt_out_of_window <= cnt_out_of_window + 1;
                            else if (hit) cnt_duplicates <= cnt_duplicates + 1;
                            else if (!any_free) cnt_collisions <= cnt_collisions + 1;
                            else begin
                                op_sell <= e_sell;
                                op_add  <= 1'b1;
                                op_pidx <= pidx_full;
                                op_qty  <= e_shares;
                                live_orders <= live_orders + 1;
                                state <= LVL_RD;
                            end
                        end
                        3'd2, 3'd3, 3'd4, 3'd5, 3'd6: begin           // E, C, X, D, U (delete half)
                            if (!ref_ok || !hit) begin
                                cnt_unknown <= cnt_unknown + 1;
                            end else begin
                                op_sell <= hit_e.sell;
                                op_add  <= 1'b0;
                                op_pidx <= hit_e.pidx;
                                op_qty  <= (e_type == 3'd5 || e_type == 3'd6 || e_shares >= hit_e.qty)
                                           ? hit_e.qty : e_shares;
                                if (e_type == 3'd5 || e_type == 3'd6 || e_shares >= hit_e.qty)
                                    live_orders <= live_orders - 1;
                                state <= LVL_RD;
                            end
                            if (e_type == 3'd6 && ref_ok && hit) begin
                                u_add_pending <= 1'b1;               // add half: same side
                                e_sell <= hit_e.sell;
                            end
                        end
                        default: ;
                    endcase
                end

                LVL_RD: state <= LVL_WR;                             // level read in flight

                U_RD: state <= LOOKUP;                               // order-set read in flight

                LVL_WR: begin
                    changed <= 1'b1;
                    if (op_sell) bm_ask[op_pidx] <= (lvl_wd != '0);
                    else         bm_bid[op_pidx] <= (lvl_wd != '0);
                    if (u_add_pending) begin                         // Replace: now the add half
                        u_add_pending <= 1'b0;
                        e_type <= 3'd1;
                        e_ref  <= e_new_ref;
                        state  <= U_RD;                         // read the new ref's set
                    end else begin
                        state <= BBO1;
                    end
                end

                BBO1: begin
                    has_bid <= |sum_bid;
                    has_ask <= |sum_ask;
                    bw_bid  <= highest(sum_bid);
                    bw_ask  <= lowest(sum_ask);
                    state   <= BBO2;
                end

                BBO2: begin                                          // level reads issued here
                    best_bid <= {bw_bid, highest(bm_bid[64*bw_bid +: 64])};
                    best_ask <= {bw_ask, lowest(bm_ask[64*bw_ask +: 64])};
                    state <= BBO3;
                end

                BBO3: if (!bbo_valid || bbo_ready) begin
                    automatic logic [31:0] bpx = has_bid ? cfg_base_price + 32'(best_bid) * 32'd100 : '0;
                    automatic logic [31:0] apx = has_ask ? cfg_base_price + 32'(best_ask) * 32'd100 : '0;
                    automatic logic [47:0] bq  = has_bid ? lvl_rd_bid : '0;
                    automatic logic [47:0] aq  = has_ask ? lvl_rd_ask : '0;
                    if (bpx != last_bid_px || apx != last_ask_px || bq != last_bid_qty || aq != last_ask_qty) begin
                        bbo_valid   <= 1'b1;
                        bbo_bid_px  <= bpx;
                        bbo_ask_px  <= apx;
                        bbo_bid_qty <= bq;
                        bbo_ask_qty <= aq;
                        bbo_seq     <= e_seq;
                        cnt_bbo     <= cnt_bbo + 1;
                        last_bid_px <= bpx;
                        last_ask_px <= apx;
                        last_bid_qty <= bq;
                        last_ask_qty <= aq;
                    end
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
