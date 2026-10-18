// Shift an AXI-Stream packet left by 2 bytes so it starts at lane 0.
//
// The UDP payload starts at frame byte 42, i.e. lane 2 of a 64-bit beat. Output
// beat k is built from input beat k (lanes 2..7) and input beat k+1 (lanes 0..1):
//
//   out.data = {in[k+1].data[15:0], in[k].data[63:16]}
//
// so one input beat is held back. When the last input beat still has bytes in
// lanes 2..7, one extra "flush" output beat carries them. tkeep is assumed
// contiguous, starting at lane 2 on the first beat and at lane 0 afterwards.
// tuser (error) is carried to the packet's last output beat.
//
// The output is registered; s_ready depends on m_ready only through the
// output-register-free term, and the stage is followed by a skid buffer.

`default_nettype none

module realign (
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
    output logic        m_axis_tuser,
    output logic        m_axis_tvalid,
    input  wire         m_axis_tready
);
    logic [63:16] prev_data;   // only lanes 2..7 of the held beat are ever used
    logic [7:2]   prev_keep;
    logic        prev_user;
    logic        have_prev;  // holding the previous beat of the current packet
    logic        flush;      // one more output beat owed from prev (lanes 2..7)

    wire out_free = !m_axis_tvalid || m_axis_tready;
    assign s_axis_tready = out_free && !flush;
    wire fire = s_axis_tvalid && s_axis_tready;

    wire [63:0] joined_data = {s_axis_tdata[15:0], prev_data[63:16]};
    wire [7:0]  joined_keep = {s_axis_tkeep[1:0], prev_keep[7:2]};
    wire        tail_left   = |s_axis_tkeep[7:2];  // last input beat still has lanes 2..7

    always_ff @(posedge clk) begin
        if (rst) begin
            m_axis_tvalid <= 1'b0;
            have_prev <= 1'b0;
            flush <= 1'b0;
        end else begin
            if (m_axis_tvalid && m_axis_tready) m_axis_tvalid <= 1'b0;

            if (out_free && flush) begin
                m_axis_tdata  <= {16'd0, prev_data[63:16]};
                m_axis_tkeep  <= {2'b00, prev_keep[7:2]};
                m_axis_tlast  <= 1'b1;
                m_axis_tuser  <= prev_user;
                m_axis_tvalid <= 1'b1;
                flush <= 1'b0;
                have_prev <= 1'b0;
            end else if (fire) begin
                if (!have_prev) begin
                    if (s_axis_tlast) begin           // single-beat packet
                        if (tail_left) begin
                            m_axis_tdata  <= {16'd0, s_axis_tdata[63:16]};
                            m_axis_tkeep  <= {2'b00, s_axis_tkeep[7:2]};
                            m_axis_tlast  <= 1'b1;
                            m_axis_tuser  <= s_axis_tuser;
                            m_axis_tvalid <= 1'b1;
                        end
                    end else begin
                        prev_data <= s_axis_tdata[63:16];
                        prev_keep <= s_axis_tkeep[7:2];
                        prev_user <= s_axis_tuser;
                        have_prev <= 1'b1;
                    end
                end else begin
                    m_axis_tdata  <= joined_data;
                    m_axis_tkeep  <= joined_keep;
                    m_axis_tvalid <= 1'b1;
                    prev_data <= s_axis_tdata[63:16];
                    prev_keep <= s_axis_tkeep[7:2];
                    prev_user <= s_axis_tuser;
                    if (s_axis_tlast && tail_left) begin
                        m_axis_tlast <= 1'b0;
                        m_axis_tuser <= 1'b0;
                        flush <= 1'b1;               // lanes 2..7 still to send
                    end else begin
                        m_axis_tlast <= s_axis_tlast;
                        m_axis_tuser <= s_axis_tlast && s_axis_tuser;
                        have_prev <= !s_axis_tlast;
                    end
                end
            end
        end
    end
endmodule

`default_nettype wire
