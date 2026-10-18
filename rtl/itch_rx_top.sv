// Phase 4 top: Ethernet frames in, decoded ITCH book events out.
//   udp_rx_top -> axis_fifo -> mold_framer -> axis_skid -> itch_decode
// The FIFO absorbs bursts when a run of short messages makes the framer
// momentarily slower than line rate.

`default_nettype none

module itch_rx_top (
    input  wire         clk,
    input  wire         rst,
    input  wire  [31:0] cfg_dst_ip,
    input  wire  [15:0] cfg_dst_port,
    input  wire         cfg_filter_en,
    input  wire  [15:0] cfg_locate,

    input  wire  [63:0] s_axis_tdata,
    input  wire  [7:0]  s_axis_tkeep,
    input  wire         s_axis_tlast,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,

    output wire         ev_valid,
    input  wire         ev_ready,
    output wire  [2:0]  ev_type,
    output wire  [7:0]  ev_msg_type,
    output wire  [15:0] ev_locate,
    output wire  [47:0] ev_ts,
    output wire  [63:0] ev_ref,
    output wire  [63:0] ev_new_ref,
    output wire  [31:0] ev_shares,
    output wire  [31:0] ev_price,
    output wire         ev_side_sell,
    output wire  [63:0] ev_seq,

    // receive counters
    output wire  [31:0] cnt_frames,
    output wire  [31:0] cnt_accepted,
    output wire  [31:0] cnt_drop_eth,
    output wire  [31:0] cnt_drop_ip,
    output wire  [31:0] cnt_drop_dst,
    output wire  [31:0] cnt_drop_csum,
    output wire  [31:0] cnt_drop_runt,
    output wire  [31:0] cnt_truncated,
    // framer counters
    output wire  [63:0] expected_seq,
    output wire         end_of_session,
    output wire  [31:0] cnt_packets,
    output wire  [31:0] cnt_messages,
    output wire  [31:0] cnt_heartbeats,
    output wire  [31:0] cnt_gaps,
    output wire  [31:0] cnt_gap_msgs,
    output wire  [31:0] cnt_dup_msgs,
    output wire  [31:0] cnt_mold_errors,
    // decoder counters
    output wire  [31:0] cnt_events,
    output wire  [31:0] cnt_other,
    output wire  [31:0] cnt_filtered,
    output wire  [31:0] cnt_bad
);
    // ---- UDP payload
    wire [63:0] p_data;
    wire [7:0]  p_keep;
    wire        p_last, p_user, p_valid, p_ready;

    udp_rx_top u_udp (
        .clk, .rst, .cfg_dst_ip, .cfg_dst_port,
        .s_axis_tdata, .s_axis_tkeep, .s_axis_tlast, .s_axis_tvalid, .s_axis_tready,
        .m_axis_tdata(p_data), .m_axis_tkeep(p_keep), .m_axis_tlast(p_last),
        .m_axis_tuser(p_user), .m_axis_tvalid(p_valid), .m_axis_tready(p_ready),
        .cnt_frames, .cnt_accepted, .cnt_drop_eth, .cnt_drop_ip, .cnt_drop_dst,
        .cnt_drop_csum, .cnt_drop_runt, .cnt_truncated
    );

    // ---- burst buffer (64 beats = 512 bytes)
    wire [73:0] f_payload;
    wire        f_valid, f_ready;
    /* verilator lint_off PINCONNECTEMPTY */
    axis_fifo #(.W(74), .DEPTH(64)) u_fifo (
        .clk, .rst,
        .s_valid(p_valid), .s_ready(p_ready), .s_payload({p_user, p_last, p_keep, p_data}),
        .m_valid(f_valid), .m_ready(f_ready), .m_payload(f_payload), .level()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // ---- messages
    wire [63:0] m_data, m_seq;
    wire [7:0]  m_keep;
    wire        m_last, m_user, m_valid, m_ready;

    mold_framer u_mold (
        .clk, .rst,
        .s_axis_tdata(f_payload[63:0]), .s_axis_tkeep(f_payload[71:64]),
        .s_axis_tlast(f_payload[72]), .s_axis_tuser(f_payload[73]),
        .s_axis_tvalid(f_valid), .s_axis_tready(f_ready),
        .m_axis_tdata(m_data), .m_axis_tkeep(m_keep), .m_axis_tlast(m_last),
        .m_axis_tuser(m_user), .m_axis_tvalid(m_valid), .m_axis_tready(m_ready), .m_seq,
        .expected_seq, .end_of_session, .cnt_packets, .cnt_messages, .cnt_heartbeats,
        .cnt_gaps, .cnt_gap_msgs, .cnt_dup_msgs, .cnt_errors(cnt_mold_errors)
    );

    // ---- register slice between framer and decoder
    wire [137:0] k_payload;
    wire         k_valid, k_ready;
    axis_skid #(.W(138)) u_skid (
        .clk, .rst,
        .s_valid(m_valid), .s_ready(m_ready), .s_payload({m_seq, m_user, m_last, m_keep, m_data}),
        .m_valid(k_valid), .m_ready(k_ready), .m_payload(k_payload)
    );

    /* verilator lint_off PINCONNECTEMPTY */
    itch_decode u_dec (
        .clk, .rst, .cfg_filter_en, .cfg_locate,
        .s_axis_tdata(k_payload[63:0]), .s_axis_tkeep(k_payload[71:64]),
        .s_axis_tlast(k_payload[72]), .s_axis_tuser(k_payload[73]),
        .s_axis_tvalid(k_valid), .s_axis_tready(k_ready), .s_seq(k_payload[137:74]),
        .ev_valid, .ev_ready, .ev_type, .ev_msg_type, .ev_locate, .ev_ts, .ev_ref, .ev_new_ref,
        .ev_shares, .ev_price, .ev_side_sell, .ev_seq,
        .cnt_msgs(), .cnt_events, .cnt_other, .cnt_filtered, .cnt_bad
    );
    /* verilator lint_on PINCONNECTEMPTY */
endmodule

`default_nettype wire
