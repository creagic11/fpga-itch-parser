// Simple dual-port RAM: one write port, one read port, same clock.
// Written in the template Vivado maps to block RAM.
//   OREG = 1: the block RAM's built-in output register is used: 2-cycle read
//             latency, but the data leaves the RAM from a register (about 0.8 ns
//             clock-to-out instead of ~2.5 ns), so logic after a read gets almost
//             the whole clock period.
//   RREG = 1: the read address is registered inside the instance first (+1 cycle
//             read latency), so one address register per memory sits next to it
//             instead of one register driving the address pins of every memory.
//   IREG = 1: write enable, address and data are registered first, so the write
//             lands one cycle later and the RAM's write inputs come straight from
//             flip-flops (block RAM data inputs have a long setup time, and the RAM
//             sits wherever the placer puts it).
// Each memory is its own instance, which also keeps every array under Vivado's
// 1,000,000-bit limit for a single variable.

`default_nettype none

module sdp_ram #(
    parameter int W     = 32,
    parameter int DEPTH = 4096,
    parameter int OREG  = 1,
    parameter int IREG  = 0,
    parameter int RREG  = 0
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

    logic                     we_i;
    logic [$clog2(DEPTH)-1:0] waddr_i;
    logic [W-1:0]             wdata_i;

    logic [$clog2(DEPTH)-1:0] raddr_i;
    if (RREG != 0) begin : g_rreg
        always_ff @(posedge clk) raddr_i <= raddr;
    end else begin : g_norreg
        assign raddr_i = raddr;
    end

    if (IREG != 0) begin : g_ireg
        always_ff @(posedge clk) begin
            we_i    <= we;
            waddr_i <= waddr;
            wdata_i <= wdata;
        end
    end else begin : g_noireg
        assign we_i    = we;
        assign waddr_i = waddr;
        assign wdata_i = wdata;
    end

    always_ff @(posedge clk) begin
        if (we_i) mem[waddr_i] <= wdata_i;
        rd_q <= mem[raddr_i];
    end

    if (OREG != 0) begin : g_oreg
        always_ff @(posedge clk) rdata <= rd_q;
    end else begin : g_noreg
        assign rdata = rd_q;
    end
endmodule

`default_nettype wire
