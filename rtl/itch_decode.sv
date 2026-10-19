// ITCH 5.0 decoder: one message in (AXI-Stream packet), one decoded event out.
//
// Every field the book needs lies in the first 40 bytes of a message (the longest
// book message, F, is 40 bytes), so the first five beats are captured into a
// 320-bit register and fields are cut at fixed offsets once the last beat
// arrives. Fixed offsets per type are what make ITCH cheap in hardware: no
// field search, just a type-indexed mux.
//
// Two steps for timing: the last beat is written into the capture register like
// any other (with the final length, tuser and sequence number), and the message
// is checked and decoded from registers in the next cycle. While a decoded
// message waits for the output, input is held, so the next message's first beat
// cannot overwrite the capture register too early.
//
// Layouts (Nasdaq TotalView-ITCH 5.0): header = type(0) locate(1-2) tracking(3-4)
// timestamp(5-10); then
//   A/F  ref 11-18  side 19  shares 20-23  stock 24-31  price 32-35  (F: MPID 36-39)
//   E    ref 11-18  shares 19-22  match 23-30
//   C    ref 11-18  shares 19-22  match 23-30  printable 31  price 32-35
//   X    ref 11-18  shares 19-22
//   D    ref 11-18
//   U    ref 11-18  new ref 19-26  shares 27-30  price 31-34
//   P    ref 11-18  side 19  shares 20-23  stock 24-31  price 32-35  match 36-43
// All integers big-endian. Event type codes match the C++ lob::itch::EventType.
//
// Output: ev_valid/ev_ready handshake with registered fields. Messages that are
// not book messages, have the wrong length for their type, arrive flagged
// (tuser), or belong to another stock when the filter is on, are dropped and
// counted.

`default_nettype none

module itch_decode (
    input  wire         clk,
    input  wire         rst,
    input  wire         cfg_filter_en,
    input  wire  [15:0] cfg_locate,

    input  wire  [63:0] s_axis_tdata,
    input  wire  [7:0]  s_axis_tkeep,
    input  wire         s_axis_tlast,
    input  wire         s_axis_tuser,
    input  wire         s_axis_tvalid,
    output logic        s_axis_tready,
    input  wire  [63:0] s_seq,

    output logic        ev_valid,
    input  wire         ev_ready,
    output logic [2:0]  ev_type,      // 1 Add 2 Exec 3 ExecPrice 4 Cancel 5 Delete 6 Replace 7 Trade
    output logic [7:0]  ev_msg_type,  // raw ITCH type byte
    output logic [15:0] ev_locate,
    output logic [47:0] ev_ts,
    output logic [63:0] ev_ref,
    output logic [63:0] ev_new_ref,
    output logic [31:0] ev_shares,
    output logic [31:0] ev_price,
    output logic        ev_side_sell, // 1 = 'S', 0 = 'B' (A/F/P)
    output logic [63:0] ev_seq,

    output logic [31:0] cnt_msgs,
    output logic [31:0] cnt_events,
    output logic [31:0] cnt_other,     // valid ITCH, not a book message
    output logic [31:0] cnt_filtered,  // book message for another stock
    output logic [31:0] cnt_bad        // unknown type, wrong length, or flagged upstream
);
    localparam int CAP = 40;  // bytes captured per message

    logic [8*CAP-1:0] msg;     // byte i at msg[8*i +: 8]
    logic [2:0]       beat;    // beats seen in this message (saturates at 5)
    logic [15:0]      len;     // message length in bytes

    function automatic logic [3:0] keep_bytes(input logic [7:0] k);
        logic [3:0] n;
        n = 4'd0;
        for (int i = 0; i < 8; i++) if (k[i]) n = 4'(i + 1);
        return n;
    endfunction

    // Expected total length of each ITCH 5.0 message type (0 = unknown type).
    function automatic logic [5:0] itch_len(input logic [7:0] t);
        case (t)
            "S": return 6'd12;  "R": return 6'd39;  "H": return 6'd25;  "Y": return 6'd20;
            "L": return 6'd26;  "V": return 6'd35;  "W": return 6'd12;  "K": return 6'd28;
            "J": return 6'd35;  "h": return 6'd21;  "A": return 6'd36;  "F": return 6'd40;
            "E": return 6'd31;  "C": return 6'd36;  "X": return 6'd23;  "D": return 6'd19;
            "U": return 6'd35;  "P": return 6'd44;  "Q": return 6'd40;  "B": return 6'd19;
            "I": return 6'd50;  "N": return 6'd20;  "O": return 6'd48;
            default: return 6'd0;
        endcase
    endfunction

    // ---------------------------------------------------------------- capture
    // ---------------------------------------------------------------- capture
    logic        dv;           // a complete message is in msg, waiting to be decoded
    logic [15:0] d_len;        // its length
    logic        d_user;       // flagged upstream
    logic [63:0] d_seq;

    wire out_free  = !ev_valid || ev_ready;
    wire dec_go    = dv && out_free;                    // decode step runs this cycle
    assign s_axis_tready = !dv || out_free;
    wire fire      = s_axis_tvalid && s_axis_tready;
    wire [15:0] len_now = len + {12'd0, s_axis_tlast ? keep_bytes(s_axis_tkeep) : 4'd8};

    // ---------------------------------------------------------------- decode (registers only)
    function automatic logic [7:0]  b8 (input logic [8*CAP-1:0] m, input int i); return m[8*i +: 8]; endfunction
    function automatic logic [15:0] b16(input logic [8*CAP-1:0] m, input int i); return {b8(m,i), b8(m,i+1)}; endfunction
    function automatic logic [31:0] b32(input logic [8*CAP-1:0] m, input int i); return {b16(m,i), b16(m,i+2)}; endfunction
    function automatic logic [47:0] b48(input logic [8*CAP-1:0] m, input int i); return {b16(m,i), b32(m,i+2)}; endfunction
    function automatic logic [63:0] b64(input logic [8*CAP-1:0] m, input int i); return {b32(m,i), b32(m,i+4)}; endfunction

    // Message-type facts, registered when the first beat arrives (type at byte 0,
    // locate at bytes 1-2), so the decode step compares registers only.
    wire [23:0] d0       = s_axis_tdata[23:0];
    logic [5:0] tlen_q;        // expected length for this type, 0 = unknown type
    logic       isbook_q, wanted_q;
    wire [7:0]  t        = b8(msg, 0);
    wire [15:0] locate   = b16(msg, 1);
    wire        len_ok   = (tlen_q != 6'd0) && (d_len == {10'd0, tlen_q});
    wire        is_book  = isbook_q;
    wire        wanted   = wanted_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            beat <= '0;
            len <= '0;
            dv <= 1'b0;
            ev_valid <= 1'b0;
            {cnt_msgs, cnt_events, cnt_other, cnt_filtered, cnt_bad} <= '0;
        end else begin
            if (ev_valid && ev_ready) ev_valid <= 1'b0;

            // capture: every beat goes into msg (first five), the last one ends it
            if (fire && beat == 3'd0) begin
                tlen_q   <= itch_len(d0[7:0]);
                isbook_q <= (d0[7:0] == "A") || (d0[7:0] == "F") || (d0[7:0] == "E") || (d0[7:0] == "C") ||
                            (d0[7:0] == "X") || (d0[7:0] == "D") || (d0[7:0] == "U") || (d0[7:0] == "P");
                wanted_q <= !cfg_filter_en || ({d0[15:8], d0[23:16]} == cfg_locate);
            end
            if (fire) begin
                for (int i = 0; i < 5; i++) if (beat == 3'(i)) msg[64*i +: 64] <= s_axis_tdata;
                if (!s_axis_tlast) begin
                    len  <= len_now;
                    beat <= (beat < 3'd5) ? beat + 3'd1 : beat;
                end else begin
                    beat   <= '0;
                    len    <= '0;
                    d_len  <= len_now;
                    d_user <= s_axis_tuser;
                    d_seq  <= s_seq;
                end
            end
            if (fire && s_axis_tlast) dv <= 1'b1;
            else if (dec_go)          dv <= 1'b0;

            // decode
            if (dec_go) begin
                cnt_msgs <= cnt_msgs + 1;
                if (d_user || !len_ok) begin
                    cnt_bad <= cnt_bad + 1;
                end else if (!is_book) begin
                    cnt_other <= cnt_other + 1;
                end else if (!wanted) begin
                    cnt_filtered <= cnt_filtered + 1;
                end else begin
                    cnt_events  <= cnt_events + 1;
                    ev_valid    <= 1'b1;
                    ev_msg_type <= t;
                    ev_locate   <= locate;
                    ev_ts       <= b48(msg, 5);
                    ev_ref      <= b64(msg, 11);
                    ev_seq      <= d_seq;
                    ev_new_ref  <= '0;
                    ev_shares   <= '0;
                    ev_price    <= '0;
                    ev_side_sell <= 1'b0;
                    case (t)
                        "A", "F": begin
                            ev_type <= 3'd1;
                            ev_side_sell <= (b8(msg, 19) == "S");
                            ev_shares <= b32(msg, 20);
                            ev_price  <= b32(msg, 32);
                        end
                        "E": begin
                            ev_type <= 3'd2;
                            ev_shares <= b32(msg, 19);
                        end
                        "C": begin
                            ev_type <= 3'd3;
                            ev_shares <= b32(msg, 19);
                            ev_price  <= b32(msg, 32);
                        end
                        "X": begin
                            ev_type <= 3'd4;
                            ev_shares <= b32(msg, 19);
                        end
                        "D": ev_type <= 3'd5;
                        "U": begin
                            ev_type <= 3'd6;
                            ev_new_ref <= b64(msg, 19);
                            ev_shares  <= b32(msg, 27);
                            ev_price   <= b32(msg, 31);
                        end
                        default: begin  // "P"
                            ev_type <= 3'd7;
                            ev_side_sell <= (b8(msg, 19) == "S");
                            ev_shares <= b32(msg, 20);
                            ev_price  <= b32(msg, 32);
                        end
                    endcase
                end
            end
        end
    end
endmodule

`default_nettype wire
