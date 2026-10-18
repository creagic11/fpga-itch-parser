// Phase 2 top: Ethernet frames in, lane-0-aligned UDP payload out.
//   eth_ip_udp_rx -> axis_skid -> realign
// The skid buffer breaks the ready path between the receiver and the realigner.

`default_nettype none

module udp_rx_top (
    input  wire         clk,
    input  wire         rst,
    input  wire  [31:0] cfg_dst_ip,
    input  wire  [15:0] cfg_dst_port,

    input  wire  [63:0] s_axis_tdata,
    input  wire  [7:0]  s_axis_tkeep,
    input  wire         s_axis_tlast,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,

    output wire  [63:0] m_axis_tdata,
    output wire  [7:0]  m_axis_tkeep,
    output wire         m_axis_tlast,
    output wire         m_axis_tuser,
    output wire         m_axis_tvalid,
    input  wire         m_axis_tready,

    output wire  [31:0] cnt_frames,
    output wire  [31:0] cnt_accepted,
    output wire  [31:0] cnt_drop_eth,
    output wire  [31:0] cnt_drop_ip,
    output wire  [31:0] cnt_drop_dst,
    output wire  [31:0] cnt_drop_csum,
    output wire  [31:0] cnt_drop_runt,
    output wire  [31:0] cnt_truncated
);
    wire [63:0] rx_data;
    wire [7:0]  rx_keep;
    wire        rx_last, rx_user, rx_valid, rx_ready;

    eth_ip_udp_rx u_rx (
        .clk, .rst, .cfg_dst_ip, .cfg_dst_port,
        .s_axis_tdata, .s_axis_tkeep, .s_axis_tlast, .s_axis_tvalid, .s_axis_tready,
        .m_axis_tdata(rx_data), .m_axis_tkeep(rx_keep), .m_axis_tlast(rx_last),
        .m_axis_tuser(rx_user), .m_axis_tvalid(rx_valid), .m_axis_tready(rx_ready),
        .cnt_frames, .cnt_accepted, .cnt_drop_eth, .cnt_drop_ip, .cnt_drop_dst,
        .cnt_drop_csum, .cnt_drop_runt, .cnt_truncated
    );

    wire [73:0] sk_payload;
    wire        sk_valid, sk_ready;

    axis_skid #(.W(74)) u_skid (
        .clk, .rst,
        .s_valid(rx_valid), .s_ready(rx_ready), .s_payload({rx_user, rx_last, rx_keep, rx_data}),
        .m_valid(sk_valid), .m_ready(sk_ready), .m_payload(sk_payload)
    );

    realign u_realign (
        .clk, .rst,
        .s_axis_tdata(sk_payload[63:0]), .s_axis_tkeep(sk_payload[71:64]),
        .s_axis_tlast(sk_payload[72]), .s_axis_tuser(sk_payload[73]),
        .s_axis_tvalid(sk_valid), .s_axis_tready(sk_ready),
        .m_axis_tdata, .m_axis_tkeep, .m_axis_tlast, .m_axis_tuser, .m_axis_tvalid, .m_axis_tready
    );
endmodule

`default_nettype wire
