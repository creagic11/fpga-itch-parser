// Simple dual-port RAM: one write port, one read port, same clock.
// Written in the template Vivado maps to block RAM. With OREG = 1 the block
// RAM's built-in output register is used: 2-cycle read latency, but the data
// leaves the RAM from a register (about 0.8 ns clock-to-out instead of ~2.5 ns),
// so logic after a read gets almost the whole clock period.
// Each memory is its own instance, which also keeps every array under Vivado's
// 1,000,000-bit limit for a single variable.

`default_nettype none

module sdp_ram #(
    parameter int W     = 32,
    parameter int DEPTH = 4096,
    parameter int OREG  = 1
) (
    input  wire                      clk,
    input  wire                      we,
    input  wire  [$clog2(DEPTH)-1:0] waddr,
    input  wire  [W-1:0]             wdata,
    input  wire  [$clog2(DEPTH)-1:0] raddr,
    output logic [W-1:0]             rdata
);
    (* ram_style = "block" *) logic [W-1:0] mem [DEPTH];
    logic [W-1:0] rd_q;

    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rd_q <= mem[raddr];
    end

    if (OREG != 0) begin : g_oreg
        always_ff @(posedge clk) rdata <= rd_q;
    end else begin : g_noreg
        assign rdata = rd_q;
    end
endmodule

`default_nettype wire
