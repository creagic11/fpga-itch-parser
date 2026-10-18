// AXI-Stream skid buffer (two-entry register slice).
//
// Breaks the combinational tready path between pipeline stages: s_ready is a
// register output, so a stage's ready never depends on the stage after it in
// the same cycle. Full throughput (one beat per clock) when the sink is ready.
//
// The payload is a flat W-bit vector: callers pack {tlast, tuser, tkeep, tdata}.

`default_nettype none

module axis_skid #(
    parameter int W = 64
) (
    input  wire          clk,
    input  wire          rst,
    // sink side
    input  wire          s_valid,
    output logic         s_ready,
    input  wire  [W-1:0] s_payload,
    // source side
    output logic         m_valid,
    input  wire          m_ready,
    output logic [W-1:0] m_payload
);
    logic [W-1:0] main_q, skid_q;
    logic         main_v, skid_v;

    assign s_ready   = !skid_v;
    assign m_valid   = main_v;
    assign m_payload = main_q;

    wire main_free = !main_v || m_ready;  // main register empty or being read this cycle

    always_ff @(posedge clk) begin
        if (rst) begin
            main_v <= 1'b0;
            skid_v <= 1'b0;
        end else if (main_free) begin
            if (skid_v) begin             // drain the skid entry first (keeps order)
                main_q <= skid_q;
                main_v <= 1'b1;
                skid_v <= 1'b0;
            end else begin
                main_q <= s_payload;
                main_v <= s_valid;
            end
        end else if (s_valid && s_ready) begin  // main stalled: park the beat
            skid_q <= s_payload;
            skid_v <= 1'b1;
        end
    end
endmodule

`default_nettype wire
