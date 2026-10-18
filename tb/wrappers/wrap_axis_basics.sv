// Test wrappers: expose standard AXI-Stream signal names (s_axis_* / m_axis_*)
// around modules that carry a flat payload, so cocotbext-axi can drive them.

`default_nettype none

module wrap_axis_skid (
    input  wire        clk,
    input  wire        rst,
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    output wire [63:0] m_axis_tdata,
    output wire [7:0]  m_axis_tkeep,
    output wire        m_axis_tlast,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready
);
    axis_skid #(.W(73)) dut (
        .clk, .rst,
        .s_valid(s_axis_tvalid), .s_ready(s_axis_tready),
        .s_payload({s_axis_tlast, s_axis_tkeep, s_axis_tdata}),
        .m_valid(m_axis_tvalid), .m_ready(m_axis_tready),
        .m_payload({m_axis_tlast, m_axis_tkeep, m_axis_tdata})
    );
endmodule

module wrap_axis_fifo (
    input  wire        clk,
    input  wire        rst,
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    output wire [63:0] m_axis_tdata,
    output wire [7:0]  m_axis_tkeep,
    output wire        m_axis_tlast,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire [4:0]  level
);
    axis_fifo #(.W(73), .DEPTH(16)) dut (
        .clk, .rst,
        .s_valid(s_axis_tvalid), .s_ready(s_axis_tready),
        .s_payload({s_axis_tlast, s_axis_tkeep, s_axis_tdata}),
        .m_valid(m_axis_tvalid), .m_ready(m_axis_tready),
        .m_payload({m_axis_tlast, m_axis_tkeep, m_axis_tdata}),
        .level
    );
endmodule

`default_nettype wire
