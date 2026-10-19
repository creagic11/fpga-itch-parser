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
// two-level priority encoder over the bitmap (a 64-bit summary, then the chosen
// 64-bit word). Orders priced outside the window or off the tick grid are
// counted and not booked.
//
// Pipelining for 156.25 MHz: every state does one simple step, and every RAM
// read comes out of the block RAM's output register (2-cycle latency):
//   IDLE  accept event; order-set read issued; price - base
//   RD1   price index: (diff x 5243) >> 19 in a DSP (= diff / 100)
//   RD2   price index: round-trip and window check
//   TAG   4 tag compares on the order set
//   DECIDE  pick hit / free way, register the entry
//   APPLY   write the order table; level read issued
//   LV1 LV2  level read in flight
//   LADD  level quantity +/- shares, non-zero flag
//   LWR   write level quantity and bitmap bit
//   B1..B8  best levels: word summary -> best word -> word -> best bit ->
//           level reads + price = base + 100 x index -> compare with last BBO
//   OUT   emit a BBO update if it changed
// An Add takes 19 cycles (about 8 M events/s at 156.25 MHz); a Replace runs the
// delete half, then URD re-reads the set for the new reference and runs the add
// half. Events are handled one at a time, so no read-after-write forwarding is
// needed.
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

    typedef enum logic [4:0] {
        CLEAR, IDLE, RD1, RD2, RD3, TAG, DECIDE, APPLY, LV1, LV2, LV3, LADD, LWR, LBM, URD,
        B1, B2, B3, B4, B5, B6, B7, B7B, B8, OUT
    } state_t;
    state_t state;

    // event types (E = 2, C = 3 and X = 4 all reduce an order, like the default case)
    localparam logic [2:0] T_ADD = 3'd1, T_DELETE = 3'd5, T_REPLACE = 3'd6, T_TRADE = 3'd7;

    // After reset the block RAMs still hold whatever they held before (FPGA memories
    // are not cleared by a reset), so CLEAR walks every address writing zeros:
    // 4,096 cycles (26 us) during which ev_ready stays low.
    localparam int CLR_BITS = (SET_BITS > WIN_BITS) ? SET_BITS : WIN_BITS;
    logic [CLR_BITS-1:0] clr_addr;

    // ---------------------------------------------------------------- current event
    logic [2:0]  e_type;
    logic [63:0] e_ref, e_new_ref, e_seq;
    logic [31:0] e_shares;
    logic        e_sell;
    logic        changed;            // a level changed during this event
    logic        u_add_pending;      // Replace: add half still to do

    // ---------------------------------------------------------------- order table RAMs
    entry_t              way_rd [WAYS];
    logic [SET_BITS-1:0] way_raddr;
    logic                way_we [WAYS];
    entry_t              way_wd;

    for (genvar w = 0; w < WAYS; w++) begin : g_way
        logic [$bits(entry_t)-1:0] rd_raw;
        sdp_ram #(.W($bits(entry_t)), .DEPTH(NSETS), .OREG(1), .IREG(1), .RREG(1)) u_ram (
            .clk, .we(way_we[w]),
            .waddr((state == CLEAR) ? clr_addr[SET_BITS-1:0] : e_ref[SET_BITS-1:0]),
            .wdata(way_wd), .raddr(way_raddr), .rdata(rd_raw)
        );
        assign way_rd[w] = entry_t'(rd_raw);
    end

    // ---------------------------------------------------------------- level quantity RAMs
    logic [WIN_BITS-1:0] lvl_raddr_bid, lvl_raddr_ask, op_pidx;
    logic [47:0]         lvl_rd_bid, lvl_rd_ask, lvl_new;
    logic                lvl_we_bid, lvl_we_ask;
    wire  [WIN_BITS-1:0] lvl_waddr = (state == CLEAR) ? clr_addr[WIN_BITS-1:0] : op_pidx;
    wire  [47:0]         lvl_wd    = (state == CLEAR) ? 48'd0 : lvl_new;

    sdp_ram #(.W(48), .DEPTH(NLVL), .OREG(1), .IREG(1), .RREG(1)) u_lvl_bid (
        .clk, .we(lvl_we_bid), .waddr(lvl_waddr), .wdata(lvl_wd),
        .raddr(lvl_raddr_bid), .rdata(lvl_rd_bid)
    );
    sdp_ram #(.W(48), .DEPTH(NLVL), .OREG(1), .IREG(1), .RREG(1)) u_lvl_ask (
        .clk, .we(lvl_we_ask), .waddr(lvl_waddr), .wdata(lvl_wd),
        .raddr(lvl_raddr_ask), .rdata(lvl_rd_ask)
    );

    // ---------------------------------------------------------------- non-empty bitmaps
    logic [NLVL-1:0] bm_bid, bm_ask;

    // Priority encoders over 64 bits, written as a two-level tree (eight groups of
    // eight bits) so synthesis does not build a 64-deep chain.
    function automatic logic [2:0] hi8(input logic [7:0] v);
        logic [2:0] r;
        r = '0;
        for (int i = 0; i < 8; i++) if (v[i]) r = 3'(i);
        return r;
    endfunction
    function automatic logic [2:0] lo8(input logic [7:0] v);
        logic [2:0] r;
        r = '0;
        for (int i = 7; i >= 0; i--) if (v[i]) r = 3'(i);
        return r;
    endfunction
    function automatic logic [5:0] highest(input logic [63:0] v);
        logic [7:0] any;
        logic [2:0] g;
        for (int i = 0; i < 8; i++) any[i] = |v[8*i +: 8];
        g = hi8(any);
        return {g, hi8(v[8*g +: 8])};
    endfunction
    function automatic logic [5:0] lowest(input logic [63:0] v);
        logic [7:0] any;
        logic [2:0] g;
        for (int i = 0; i < 8; i++) any[i] = |v[8*i +: 8];
        g = lo8(any);
        return {g, lo8(v[8*g +: 8])};
    endfunction

    // Bitmap write, split over two cycles so no single step decodes a 12-bit index
    // into 8,192 flip-flops: in LADD the word and bit enables are decoded into
    // registers (one-hot, 64 + 64 bits per side) along with the level's new
    // empty/non-empty flag; in LWR each bitmap bit loads when its word and bit
    // enables are both set. The flag is computed beside the adder, not after it:
    // cur + q is non-zero iff either is; cur - q is non-zero iff cur != q.
    (* max_fanout = 64 *) logic [NW-1:0] bm_word_bid, bm_word_ask;
    (* max_fanout = 64 *) logic [63:0]   bm_bit;
    (* max_fanout = 64 *) logic          bm_nz;
    logic                                bm_nz1;    // computed in LADD, one flop

    // ---------------------------------------------------------------- price index pipeline
    // (price - base) / 100 = (diff x 5243) >> 19, exact for every multiple of 100
    // below 2^19; the round trip q x 100 == diff rejects anything off the grid.
    logic [32:0] diff_q;                 // price - base, with borrow in bit 32
    (* use_dsp = "yes" *) logic [12:0] q_raw_q;   // (diff x 5243) >> 19
    logic        far_q, far_q2;          // below the base or >= 2^19 above it
    logic [18:0] diff19_q, diff19_q2;
    logic [12:0] q_q;
    logic [WIN_BITS-1:0] pidx_q;
    logic        pidx_ok_q;

    always_ff @(posedge clk) begin
        // RD1: multiply
        far_q    <= diff_q[32] || (diff_q[31:19] != '0);
        diff19_q <= diff_q[18:0];
        q_raw_q  <= 13'((32'(diff_q[18:0]) * 32'd5243) >> 19);
        // RD2: quotient
        far_q2    <= far_q;
        diff19_q2 <= diff19_q;
        q_q       <= q_raw_q;
        // TAG: window and round-trip check
        pidx_q    <= q_q[WIN_BITS-1:0];
        pidx_ok_q <= !far_q2 && (q_q < 13'(NLVL)) &&
                     ((19'(q_q) << 6) + (19'(q_q) << 5) + (19'(q_q) << 2) == diff19_q2);
    end

    // ---------------------------------------------------------------- lookup registers
    wire [TAGW-1:0] tag_of_e = e_ref[SET_BITS +: TAGW];
    wire            ref_ok   = (e_ref[63:SET_BITS + TAGW] == '0);   // refs below 2^44
    logic [WAYS-1:0] hit_v_q, free_v_q;
    entry_t          way_q [WAYS];
    logic            hit_q, any_free_q;
    logic [1:0]      hit_way_q, free_way_q;
    entry_t          hit_e_q;

    // decisions in APPLY (all inputs registered)
    wire whole = (e_type == T_DELETE) || (e_type == T_REPLACE) || (e_shares >= hit_e_q.qty);
    wire add_ok = ref_ok && pidx_ok_q && !hit_q && any_free_q;
    wire red_ok = ref_ok && hit_q;

    always_comb begin
        for (int w = 0; w < WAYS; w++) way_we[w] = 1'b0;
        way_wd = '0;
        if (state == CLEAR) begin
            for (int w = 0; w < WAYS; w++) way_we[w] = 1'b1;
        end else if (state == APPLY) begin
            if (e_type == T_ADD) begin
                if (add_ok) begin
                    way_we[free_way_q] = 1'b1;
                    way_wd = '{valid: 1'b1, sell: e_sell, tag: tag_of_e, pidx: pidx_q, qty: e_shares};
                end
            end else if (red_ok) begin
                way_we[hit_way_q] = 1'b1;
                way_wd = hit_e_q;
                if (whole) begin
                    way_wd.valid = 1'b0;
                    way_wd.qty = '0;
                end else begin
                    way_wd.qty = hit_e_q.qty - e_shares;
                end
            end
        end
        lvl_we_bid = (state == CLEAR) || (state == LWR && !op_sell);
        lvl_we_ask = (state == CLEAR) || (state == LWR && op_sell);
    end

    // level operation
    logic        op_sell, op_add;
    logic [31:0] op_qty;
    wire  [47:0] lvl_cur = op_sell ? lvl_rd_ask : lvl_rd_bid;

    // ---------------------------------------------------------------- best-level pipeline
    logic [NW-1:0] sum_bid_q, sum_ask_q;
    logic          has_bid, has_ask;
    logic [5:0]    bw_bid, bw_ask;
    logic [63:0]   word_bid, word_ask;
    logic [WIN_BITS-1:0] best_bid, best_ask;
    logic [18:0]   bid100, ask100;
    logic [31:0]   bpx, apx;
    logic [47:0]   bq, aq;
    logic          differs;
    logic [31:0]   last_bid_px, last_ask_px;
    logic [47:0]   last_bid_qty, last_ask_qty;

    assign ev_ready = (state == IDLE);

    always_ff @(posedge clk) begin
        for (int w = 0; w < NW; w++) begin
            bm_word_bid[w] <= (state == LWR) && !op_sell && (op_pidx[WIN_BITS-1:6] == (WIN_BITS-6)'(w));
            bm_word_ask[w] <= (state == LWR) &&  op_sell && (op_pidx[WIN_BITS-1:6] == (WIN_BITS-6)'(w));
        end
        for (int b = 0; b < 64; b++) bm_bit[b] <= (op_pidx[5:0] == 6'(b));
        bm_nz <= bm_nz1;                                     // fan-out copy, loaded in LWR
        if (rst) begin
            bm_bid <= '0;
            bm_ask <= '0;
            bm_word_bid <= '0;
            bm_word_ask <= '0;
        end else begin
            for (int w = 0; w < NW; w++)
                for (int b = 0; b < 64; b++) begin
                    if (bm_word_bid[w] && bm_bit[b]) bm_bid[64*w + b] <= bm_nz;
                    if (bm_word_ask[w] && bm_bit[b]) bm_ask[64*w + b] <= bm_nz;
                end
        end
    end

    // ---------------------------------------------------------------- state machine
    always_ff @(posedge clk) begin
        if (rst) begin
            state <= CLEAR;
            clr_addr <= '0;
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
                    e_sell <= ev_side_sell;
                    diff_q <= {1'b0, ev_price} - {1'b0, cfg_base_price};
                    way_raddr <= ev_ref[SET_BITS-1:0];
                    changed <= 1'b0;
                    u_add_pending <= 1'b0;
                    cnt_events <= cnt_events + 1;
                    state <= (ev_type == T_TRADE || ev_type == 3'd0) ? IDLE : RD1;  // trades: no book change
                end

                RD1: state <= RD2;                                   // set read (address reg) + multiply
                RD2: state <= RD3;                                   // set read + quotient
                RD3: state <= TAG;                                   // set read (output reg)

                TAG: begin                                           // set data valid
                    for (int w = 0; w < WAYS; w++) begin
                        hit_v_q[w]  <= way_rd[w].valid && (way_rd[w].tag == tag_of_e);
                        free_v_q[w] <= !way_rd[w].valid;
                        way_q[w]    <= way_rd[w];
                    end
                    state <= DECIDE;
                end

                DECIDE: begin
                    hit_q <= |hit_v_q;
                    any_free_q <= |free_v_q;
                    for (int w = WAYS - 1; w >= 0; w--) begin
                        if (hit_v_q[w])  begin hit_way_q  <= 2'(w); hit_e_q <= way_q[w]; end
                        if (free_v_q[w]) free_way_q <= 2'(w);
                    end
                    state <= APPLY;
                end

                APPLY: begin
                    state <= changed ? B1 : IDLE;                    // default: nothing to apply
                    if (e_type == T_ADD) begin
                        if (!ref_ok || !pidx_ok_q) cnt_out_of_window <= cnt_out_of_window + 1;
                        else if (hit_q) cnt_duplicates <= cnt_duplicates + 1;
                        else if (!any_free_q) cnt_collisions <= cnt_collisions + 1;
                        else begin
                            op_sell <= e_sell;
                            op_add  <= 1'b1;
                            op_pidx <= pidx_q;
                            op_qty  <= e_shares;
                            lvl_raddr_bid <= pidx_q;
                            lvl_raddr_ask <= pidx_q;
                            live_orders <= live_orders + 1;
                            state <= LV1;
                        end
                    end else if (!red_ok) begin
                        cnt_unknown <= cnt_unknown + 1;
                    end else begin
                        op_sell <= hit_e_q.sell;
                        op_add  <= 1'b0;
                        op_pidx <= hit_e_q.pidx;
                        op_qty  <= whole ? hit_e_q.qty : e_shares;
                        lvl_raddr_bid <= hit_e_q.pidx;
                        lvl_raddr_ask <= hit_e_q.pidx;
                        if (whole) live_orders <= live_orders - 1;
                        if (e_type == T_REPLACE) begin
                            u_add_pending <= 1'b1;                   // add half: same side
                            e_sell <= hit_e_q.sell;
                        end
                        state <= LV1;
                    end
                end

                LV1: state <= LV2;                                   // level read in flight
                LV2: state <= LV3;
                LV3: state <= LADD;

                LADD: begin
                    lvl_new <= op_add ? lvl_cur + 48'(op_qty) : lvl_cur - 48'(op_qty);
                    bm_nz1  <= op_add ? (lvl_cur != '0 || op_qty != '0) : (lvl_cur != 48'(op_qty));
                    state <= LWR;
                end

                LWR: begin                                           // level RAM write; bitmap enables
                    changed <= 1'b1;
                    state <= LBM;
                end

                LBM: begin                                           // bitmap bit written this cycle
                    if (u_add_pending) begin                         // Replace: now the add half
                        u_add_pending <= 1'b0;
                        e_type <= T_ADD;
                        e_ref <= e_new_ref;
                        state <= URD;
                    end else begin
                        state <= B1;
                    end
                end

                URD: begin
                    way_raddr <= e_ref[SET_BITS-1:0];                // e_ref is now the new ref
                    state <= RD1;
                end

                B1: begin                                            // which 64-level words are non-empty
                    for (int w = 0; w < NW; w++) begin
                        sum_bid_q[w] <= |bm_bid[64*w +: 64];
                        sum_ask_q[w] <= |bm_ask[64*w +: 64];
                    end
                    state <= B2;
                end
                B2: begin                                            // best word
                    has_bid <= |sum_bid_q;
                    has_ask <= |sum_ask_q;
                    bw_bid  <= highest(sum_bid_q);
                    bw_ask  <= lowest(sum_ask_q);
                    state <= B3;
                end
                B3: begin                                            // fetch that word
                    word_bid <= bm_bid[64*bw_bid +: 64];
                    word_ask <= bm_ask[64*bw_ask +: 64];
                    state <= B4;
                end
                B4: begin                                            // best bit in the word
                    best_bid <= {bw_bid, highest(word_bid)};
                    best_ask <= {bw_ask, lowest(word_ask)};
                    state <= B5;
                end
                B5: begin                                            // level reads; 100 x index
                    lvl_raddr_bid <= best_bid;
                    lvl_raddr_ask <= best_ask;
                    bid100 <= (19'(best_bid) << 6) + (19'(best_bid) << 5) + (19'(best_bid) << 2);
                    ask100 <= (19'(best_ask) << 6) + (19'(best_ask) << 5) + (19'(best_ask) << 2);
                    state <= B6;
                end
                B6: begin
                    bpx <= has_bid ? cfg_base_price + 32'(bid100) : '0;
                    apx <= has_ask ? cfg_base_price + 32'(ask100) : '0;
                    state <= B7;
                end
                B7: state <= B7B;                                    // level reads in flight
                B7B: state <= B8;
                B8: begin
                    bq <= has_bid ? lvl_rd_bid : '0;
                    aq <= has_ask ? lvl_rd_ask : '0;
                    differs <= (bpx != last_bid_px) || (apx != last_ask_px) ||
                               ((has_bid ? lvl_rd_bid : '0) != last_bid_qty) ||
                               ((has_ask ? lvl_rd_ask : '0) != last_ask_qty);
                    state <= OUT;
                end
                OUT: begin
                    if (!differs) state <= IDLE;
                    else if (!bbo_valid || bbo_ready) begin
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
                        state <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
