// Simple dual-port RAM: one write port, one registered read port, same clock.
// Written in the template Vivado maps to block RAM (read-first, 1-cycle read
// latency). Each memory is its own instance, which also keeps every array well
// under Vivado's 1,000,000-bit limit for a single variable.

`default_nettype none

module sdp_ram #(
    parameter int W     = 32,
    parameter int DEPTH = 4096
) (
    input  wire                      clk,
    input  wire                      we,
    input  wire  [$clog2(DEPTH)-1:0] waddr,
    input  wire  [W-1:0]             wdata,
    input  wire  [$clog2(DEPTH)-1:0] raddr,
    output logic [W-1:0]             rdata
);
    (* ram_style = "block" *) logic [W-1:0] mem [DEPTH];

    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule

`default_nettype wire
