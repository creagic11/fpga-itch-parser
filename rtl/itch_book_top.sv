// Full design: Ethernet frames in, best bid/offer of one stock out.
//   itch_rx_top (UDP, MoldUDP64, ITCH decode, stock filter) -> book_engine
// cfg_filter_en should be 1 with cfg_locate = the stock; cfg_base_price sets the
// engine's price window.

`default_nettype none

module itch_book_top (
    input  wire         clk,
    input  wire         rst,
    input  wire  [31:0] cfg_dst_ip,
    input  wire  [15:0] cfg_dst_port,
    input  wire         cfg_filter_en,
    input  wire  [15:0] cfg_locate,
    input  wire  [31:0] cfg_base_price,

    input  wire  [63:0] s_axis_tdata,
    input  wire  [7:0]  s_axis_tkeep,
    input  wire         s_axis_tlast,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,

    output wire         bbo_valid,
    input  wire         bbo_ready,
    output wire  [31:0] bbo_bid_px,
    output wire  [47:0] bbo_bid_qty,
    output wire  [31:0] bbo_ask_px,
    output wire  [47:0] bbo_ask_qty,
    output wire  [63:0] bbo_seq,

    output wire  [31:0] cnt_frames,
    output wire  [31:0] cnt_messages,
    output wire  [31:0] cnt_gaps,
    output wire  [31:0] cnt_mold_errors,
    output wire  [31:0] cnt_events,
    output wire  [31:0] cnt_bad,
    output wire  [31:0] cnt_book_events,
    output wire  [31:0] cnt_bbo,
    output wire  [31:0] cnt_out_of_window,
    output wire  [31:0] cnt_collisions,
    output wire  [31:0] cnt_unknown,
    output wire  [31:0] cnt_duplicates,
    output wire  [15:0] live_orders
);
    wire        ev_valid, ev_ready, ev_side_sell;
    wire [2:0]  ev_type;
    wire [63:0] ev_ref, ev_new_ref, ev_seq;
    wire [31:0] ev_shares, ev_price;

    /* verilator lint_off PINCONNECTEMPTY */
    itch_rx_top u_rx (
        .clk, .rst, .cfg_dst_ip, .cfg_dst_port, .cfg_filter_en, .cfg_locate,
        .s_axis_tdata, .s_axis_tkeep, .s_axis_tlast, .s_axis_tvalid, .s_axis_tready,
        .ev_valid, .ev_ready, .ev_type, .ev_msg_type(), .ev_locate(), .ev_ts(), .ev_ref, .ev_new_ref,
        .ev_shares, .ev_price, .ev_side_sell, .ev_seq,
        .cnt_frames, .cnt_accepted(), .cnt_drop_eth(), .cnt_drop_ip(), .cnt_drop_dst(),
        .cnt_drop_csum(), .cnt_drop_runt(), .cnt_truncated(),
        .expected_seq(), .end_of_session(), .cnt_packets(), .cnt_messages, .cnt_heartbeats(),
        .cnt_gaps, .cnt_gap_msgs(), .cnt_dup_msgs(), .cnt_mold_errors,
        .cnt_events, .cnt_other(), .cnt_filtered(), .cnt_bad
    );

    book_engine u_book (
        .clk, .rst, .cfg_base_price,
        .ev_valid, .ev_ready, .ev_type, .ev_ref, .ev_new_ref, .ev_shares, .ev_price,
        .ev_side_sell, .ev_seq,
        .bbo_valid, .bbo_ready, .bbo_bid_px, .bbo_bid_qty, .bbo_ask_px, .bbo_ask_qty, .bbo_seq,
        .cnt_events(cnt_book_events), .cnt_bbo, .cnt_out_of_window, .cnt_collisions,
        .cnt_unknown, .cnt_duplicates, .live_orders
    );
    /* verilator lint_on PINCONNECTEMPTY */
endmodule

`default_nettype wire
