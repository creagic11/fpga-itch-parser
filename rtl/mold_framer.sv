// MoldUDP64 framer: splits each UDP payload into its ITCH messages.
//
// Input: one AXI-Stream packet per UDP payload, lane 0 aligned (from udp_rx_top).
//   MoldUDP64 = header [session 10][sequence 8, BE][count 2, BE]
//               then `count` blocks of [length 2, BE][message]
//   count 0 = heartbeat (sequence = next expected), count 0xFFFF = end of session.
// Output: one AXI-Stream packet per message, lane 0 aligned, tkeep contiguous,
//   with m_seq = that message's sequence number, stable for the whole packet.
//
// Datapath: a 32-byte ring buffer. Input bytes are written at the write pointer
// and the parser consumes from the read pointer, so consuming bytes only moves a
// pointer; the data never shifts (an earlier version shifted a 24-byte buffer by
// the number of bytes consumed, and that shifter could not run at 156.25 MHz).
// Input is accepted while at most 24 bytes are held, so s_ready is a register
// function. Messages may start at any byte offset and a
// length field may straddle two input beats; the buffer makes that invisible.
//
// Length look-ahead (for timing): how many bytes to consume each cycle must come
// from registers, because that number steers the 24-byte shifter. A message's
// body is tracked in registers (bytes left, bytes in the next beat, last beat or
// not). On a message's last beat its end position is one of those registers, so
// the next message's 2-byte length is read from that position in the same
// cycle, consumed together with the tail, and loaded into the body registers:
// the next message starts on the following cycle with no length step. A message
// therefore costs ceil(len/8) cycles; back-to-back 19-byte Deletes (21 bytes
// each with the length) run at 7 bytes/cycle against 8 in. Only the first
// message of a packet (or one whose length bytes have not arrived yet) takes a
// separate cycle in S_LEN.
//
// Sequencing: the first packet sets the expected sequence. A packet starting
// beyond it is a gap (counted, with the number of missing messages); messages
// below it are duplicates (e.g. the other copy of an A/B feed) and are dropped.
//
// Errors (counted, never fatal): a packet that ends inside the header or inside
// a message (the partial message is closed with tuser = 1), bytes left over after
// the last message, and payloads flagged truncated upstream.

`default_nettype none

module mold_framer (
    input  wire         clk,
    input  wire         rst,

    input  wire  [63:0] s_axis_tdata,
    input  wire  [7:0]  s_axis_tkeep,
    input  wire         s_axis_tlast,
    input  wire         s_axis_tuser,
    input  wire         s_axis_tvalid,
    output logic        s_axis_tready,

    output logic [63:0] m_axis_tdata,
    output logic [7:0]  m_axis_tkeep,
    output logic        m_axis_tlast,
    output logic        m_axis_tuser,   // message cut short by the end of its packet
    output logic        m_axis_tvalid,
    input  wire         m_axis_tready,
    output logic [63:0] m_seq,

    output logic [63:0] expected_seq,
    output logic        end_of_session,
    output logic [31:0] cnt_packets,
    output logic [31:0] cnt_messages,
    output logic [31:0] cnt_heartbeats,
    output logic [31:0] cnt_gaps,
    output logic [31:0] cnt_gap_msgs,   // messages missing across all gaps
    output logic [31:0] cnt_dup_msgs,
    output logic [31:0] cnt_errors
);
    localparam int NB = 32;  // ring bytes (power of two)

    typedef enum logic [2:0] {S_HDR, S_SEQ, S_SEQ2, S_LEN, S_BODY, S_DRAIN} state_t;
    state_t state;

    logic [7:0]      ring [NB];
    logic [4:0]      rd_ptr, wr_ptr;
    logic [5:0]      cnt;          // bytes held (0..32)
    logic [7:0]      v [18];       // view: v[j] = ring[rd_ptr + j], the next 18 bytes
    logic            closed;       // the current packet's last beat is in the buffer
    logic            pkt_err;      // upstream flagged this payload as truncated

    logic [4:0]      hdr_got;      // header bytes consumed so far (0..20)
    logic [63:0]     hdr_seq;
    logic [15:0]     hdr_count;
    logic            synced;

    logic [15:0]     msgs_left;    // messages still to parse in this packet
    logic [15:0]     drop_left;    // leading duplicate messages to drop
    logic [15:0]     body_left;    // bytes left in the current message
    logic [3:0]      nb_q;         // bytes of it in the next beat: min(body_left, 8)
    logic [4:0]      nb2_q;        // nb_q + 2 (tail plus the next length field)
    logic            last_q;       // body_left <= 8: the next beat ends the message
    logic            zero_q;       // body_left == 0: empty message
    // Look-ahead, one beat early: on the second-to-last beat of a message (9..16
    // bytes left) the next message's length sits at offset body_left; it is
    // registered raw, so the last beat only decodes registers.
    logic [15:0]     la_len;
    logic            la_v;         // la_len is valid (its bytes were held)
    // sequence checks of S_SEQ, registered for S_SEQ2
    logic [63:0]     sq_end, sq_back;
    logic [31:0]     sq_gap;
    logic            sq_ahead, sq_behind;
    logic            dropping;     // message in S_BODY is a duplicate
    logic            normal_end;   // S_DRAIN entered after a complete header/messages
    logic            trailing;     // bytes found after the end of a normal packet
    logic [63:0]     cur_seq;

    function automatic logic [3:0] keep_bytes(input logic [7:0] k);
        logic [3:0] n;
        n = 4'd0;
        for (int i = 0; i < 8; i++) if (k[i]) n = 4'(i + 1);
        return n;
    endfunction
    function automatic logic [7:0] keep_mask(input logic [3:0] n);  // n = 0..8
        return 8'((16'(1) << n) - 16'(1));
    endfunction

    // ---------------------------------------------------------------- input side
    wire        in_fire  = s_axis_tvalid && s_axis_tready;
    wire [3:0]  in_bytes = s_axis_tlast ? keep_bytes(s_axis_tkeep) : 4'd8;
    assign s_axis_tready = !closed && (cnt <= 6'd24);

    always_comb
        for (int j = 0; j < 18; j++) v[j] = ring[rd_ptr + 5'(j)];

    // ---------------------------------------------------------------- parser (comb)
    wire out_free = !m_axis_tvalid || m_axis_tready;

    wire [15:0] front_len = {v[0], v[1]};               // big-endian length at bytes 0-1
    wire [5:0]  hdr_need  = 6'd20 - {1'b0, hdr_got};
    wire        dup_now   = (drop_left != 16'd0);        // message starting in S_LEN is a duplicate
    logic       last_msg;                                // msgs_left == 1, kept as a register

    // Header bytes taken in S_HDR, from registers only.
    wire [5:0]  take_hdr0 = (cnt < hdr_need) ? cnt : hdr_need;
    wire [5:0]  take_hdr  = (take_hdr0 > 6'd8) ? 6'd8 : take_hdr0;

    // Next message's length, read at the end of the current one (bytes nb_q and
    // nb_q + 1 of the buffer; used only when they are held, cnt >= nb2_q).
    wire         pre = (state == S_BODY) && !last_q && (body_left <= 16'd16);   // 9..16 left
    logic [15:0] pre_len;
    always_comb begin
        pre_len = '0;
        for (int i = 9; i <= 16; i++)
            if (body_left[4:0] == 5'(i)) pre_len = {v[i], v[i + 1]};
    end

    logic [5:0]  take;         // bytes consumed from the front this cycle
    logic        emit;         // load the output register
    logic [63:0] e_data;
    logic [7:0]  e_keep;
    logic        e_last, e_user;
    logic        msg_done;     // a message (or duplicate) finished this cycle
    logic        chain;        // ...and the next message's length was consumed with it
    logic        load_front;   // S_LEN: load the body registers from front_len
    logic        truncated;    // packet ended inside a message / header / length

    always_comb begin
        take = 6'd0;
        emit = 1'b0;
        e_data = {v[7], v[6], v[5], v[4], v[3], v[2], v[1], v[0]};
        e_keep = 8'hFF;
        e_last = 1'b0;
        e_user = 1'b0;
        msg_done = 1'b0;
        chain = 1'b0;
        load_front = 1'b0;
        truncated = 1'b0;
        unique case (state)
            S_HDR: begin
                take = take_hdr;
                truncated = closed && (cnt < hdr_need) && (cnt <= 6'd8);
            end
            S_SEQ, S_SEQ2: ;
            S_LEN: begin
                if (cnt >= 6'd2) begin
                    take = 6'd2;
                    load_front = 1'b1;
                end else if (closed) begin
                    take = cnt;
                    truncated = 1'b1;
                end
            end
            S_BODY: begin
                if (zero_q) begin                            // empty message: nothing to send
                    msg_done = 1'b1;
                end else if (dropping || out_free) begin
                    if (cnt >= {2'b0, nb_q}) begin
                        chain  = last_q && !last_msg && la_v;
                        take   = chain ? {1'b0, nb2_q} : {2'b0, nb_q};
                        emit   = !dropping;
                        e_keep = keep_mask(nb_q);
                        e_last = last_q;
                        msg_done = last_q;
                    end else if (closed) begin               // packet ended inside the message
                        take   = cnt;
                        emit   = !dropping;
                        e_keep = keep_mask(cnt[3:0]);
                        e_last = 1'b1;
                        e_user = 1'b1;
                        truncated = 1'b1;
                    end
                end
            end
            S_DRAIN: take = cnt;
            default: ;
        endcase
    end

    // body registers for a message of length L
    function automatic logic [3:0] nb_of(input logic [15:0] l);
        return (l > 16'd8) ? 4'd8 : l[3:0];
    endfunction

    // ---------------------------------------------------------------- ring update
    // Input byte k goes to ring[wr_ptr + k]; bytes outside tkeep are not written.
    logic [NB-1:0] ring_we;
    logic [7:0]    ring_wd [NB];
    always_comb
        for (int i = 0; i < NB; i++) begin
            logic [4:0] k;
            k = 5'(i) - wr_ptr;                              // which input lane lands here
            ring_we[i] = in_fire && ({1'b0, k} < {2'b0, in_bytes});
            ring_wd[i] = s_axis_tdata[8*k[2:0] +: 8];
        end
    wire             in_dup   = dropping;

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_HDR;
            rd_ptr <= '0;
            wr_ptr <= '0;
            cnt <= '0;
            closed <= 1'b0;
            pkt_err <= 1'b0;
            hdr_got <= '0;
            synced <= 1'b0;
            expected_seq <= '0;
            end_of_session <= 1'b0;
            m_axis_tvalid <= 1'b0;
            dropping <= 1'b0;
            normal_end <= 1'b0;
            trailing <= 1'b0;
            drop_left <= '0;
            msgs_left <= '0;
            last_msg <= 1'b0;
            la_v <= 1'b0;
            {cnt_packets, cnt_messages, cnt_heartbeats, cnt_gaps} <= '0;
            {cnt_gap_msgs, cnt_dup_msgs, cnt_errors} <= '0;
        end else begin
            // ring: consume `take` from the read side, write the input beat
            for (int i = 0; i < NB; i++) if (ring_we[i]) ring[i] <= ring_wd[i];
            rd_ptr <= rd_ptr + take[4:0];
            if (in_fire) wr_ptr <= wr_ptr + {1'b0, in_bytes};
            cnt    <= cnt - take + (in_fire ? {2'b0, in_bytes} : 6'd0);
            if (in_fire && s_axis_tlast) begin
                closed  <= 1'b1;
                pkt_err <= s_axis_tuser;
            end

            // output register
            if (m_axis_tvalid && m_axis_tready) m_axis_tvalid <= 1'b0;
            if (emit) begin
                m_axis_tdata  <= e_data;
                m_axis_tkeep  <= e_keep;
                m_axis_tlast  <= e_last;
                m_axis_tuser  <= e_user;
                m_axis_tvalid <= 1'b1;
                m_seq         <= cur_seq;
            end

            // message bookkeeping shared by S_LEN and S_BODY
            if (msg_done) begin
                if (in_dup) begin
                    drop_left <= drop_left - 1;
                    cnt_dup_msgs <= cnt_dup_msgs + 1;
                end else begin
                    cnt_messages <= cnt_messages + 1;
                end
                msgs_left <= msgs_left - 1;
                last_msg  <= (msgs_left == 16'd2);
                cur_seq <= cur_seq + 1;
            end
            if (truncated) cnt_errors <= cnt_errors + 1;

            if (pre) begin                                   // look-ahead (see la_len)
                la_len <= pre_len;
                la_v   <= (cnt >= {1'b0, body_left[4:0]} + 6'd2);
            end

            unique case (state)
                S_HDR: begin
                    // header byte j = hdr_got + k sits in buffer lane k
                    for (int j = 10; j < 20; j++) begin
                        if (5'(j) >= hdr_got && {1'b0, 5'(j) - hdr_got} < take_hdr) begin
                            if (j < 18) hdr_seq[8*(17 - j) +: 8]   <= v[(5'(j) - hdr_got) & 5'd7];
                            else        hdr_count[8*(19 - j) +: 8] <= v[(5'(j) - hdr_got) & 5'd7];
                        end
                    end
                    hdr_got <= hdr_got + take_hdr[4:0];
                    if (cnt >= hdr_need && hdr_need <= 6'd8) state <= S_SEQ;   // = (hdr_got + take_hdr == 20)
                    else if (truncated) begin
                        normal_end <= 1'b0;
                        state <= S_DRAIN;
                    end
                end

                S_SEQ: begin                                 // 64-bit arithmetic, registered
                    sq_end    <= hdr_seq + 64'(hdr_count);
                    sq_back   <= expected_seq - hdr_seq;
                    sq_gap    <= 32'(hdr_seq - expected_seq);
                    sq_ahead  <= synced && (hdr_seq > expected_seq);
                    sq_behind <= synced && (hdr_seq < expected_seq);
                    state <= S_SEQ2;
                end

                S_SEQ2: begin
                    cnt_packets <= cnt_packets + 1;
                    if (pkt_err) cnt_errors <= cnt_errors + 1;
                    cur_seq <= hdr_seq;
                    msgs_left <= hdr_count;
                    last_msg  <= (hdr_count == 16'd1);
                    normal_end <= 1'b1;
                    if (hdr_count == 16'hFFFF) begin
                        end_of_session <= 1'b1;
                        msgs_left <= '0;
                        state <= S_DRAIN;
                    end else begin
                        if (sq_ahead) begin
                            cnt_gaps <= cnt_gaps + 1;
                            cnt_gap_msgs <= cnt_gap_msgs + sq_gap;
                        end
                        if (sq_behind)
                            drop_left <= (sq_back > 64'(hdr_count)) ? hdr_count : 16'(sq_back);
                        else
                            drop_left <= '0;
                        if (!synced || sq_end > expected_seq)
                            expected_seq <= sq_end;
                        synced <= 1'b1;
                        if (hdr_count == 16'd0) begin
                            cnt_heartbeats <= cnt_heartbeats + 1;
                            state <= S_DRAIN;
                        end else begin
                            state <= S_LEN;
                        end
                    end
                end

                S_LEN: begin
                    if (truncated) begin
                        normal_end <= 1'b0;
                        state <= S_DRAIN;
                    end else if (load_front) begin
                        body_left <= front_len;
                        nb_q      <= nb_of(front_len);
                        nb2_q     <= 5'd2 + {1'b0, nb_of(front_len)};
                        last_q    <= (front_len <= 16'd8);
                        zero_q    <= (front_len == 16'd0);
                        la_v      <= 1'b0;
                        dropping  <= dup_now;
                        state <= S_BODY;
                    end
                end

                S_BODY: begin
                    if (truncated) begin
                        normal_end <= 1'b0;
                        state <= S_DRAIN;
                    end else if (chain) begin                // next message starts next cycle
                        body_left <= la_len;
                        nb_q      <= nb_of(la_len);
                        nb2_q     <= 5'd2 + {1'b0, nb_of(la_len)};
                        last_q    <= (la_len <= 16'd8);
                        zero_q    <= (la_len == 16'd0);
                        la_v      <= 1'b0;
                        dropping  <= dropping && (drop_left != 16'd1);
                    end else if (msg_done) begin
                        state <= last_msg ? S_DRAIN : S_LEN;
                    end else if (take != 6'd0) begin         // a full 8-byte beat of the body
                        body_left <= body_left - 16'd8;
                        nb_q      <= (body_left > 16'd16) ? 4'd8 : 4'(body_left - 16'd8);
                        nb2_q     <= (body_left > 16'd16) ? 5'd10 : 5'(body_left - 16'd6);
                        last_q    <= (body_left <= 16'd16);
                    end
                end

                S_DRAIN: begin
                    if (take != 6'd0 && normal_end) trailing <= 1'b1;
                    if (closed) begin            // whole packet consumed (S_DRAIN takes all of cnt)
                        if (trailing || (take != 6'd0 && normal_end)) cnt_errors <= cnt_errors + 1;
                        closed   <= 1'b0;
                        pkt_err  <= 1'b0;
                        hdr_got  <= '0;
                        dropping <= 1'b0;
                        trailing <= 1'b0;
                        state    <= S_HDR;
                    end
                end

                default: state <= S_HDR;
            endcase
        end
    end
endmodule

`default_nettype wire
