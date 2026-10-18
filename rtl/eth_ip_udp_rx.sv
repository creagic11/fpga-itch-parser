// Ethernet II / IPv4 / UDP receive: header parse, filter, checksum, payload extract.
//
// Input: AXI-Stream frames from a MAC (64-bit, lane 0 = first byte, FCS removed).
// Output: the UDP payload of accepted frames. The first output beat carries
// payload bytes in lanes 2..7 (the payload starts at frame byte 42 = beat 5,
// lane 2); `realign` shifts the stream so messages start at lane 0.
//
// Frame byte map (no VLAN, IPv4 without options):
//   0-5 dst MAC  6-11 src MAC  12-13 EtherType
//   14 ver/IHL 15 DSCP 16-17 total len 18-19 id 20-21 flags/frag 22 TTL 23 proto
//   24-25 hdr checksum 26-29 src IP 30-33 dst IP
//   34-35 src port 36-37 dst port 38-39 UDP len 40-41 UDP checksum  42.. payload
//
// All header fields are complete by the end of beat 4, so the accept decision is
// registered there and beat 5 is forwarded (or dropped) with no extra latency.
// The IPv4 header checksum (ten 16-bit words, ones' complement) is accumulated
// beat by beat. The payload is trimmed to the UDP length, which also discards
// Ethernet minimum-size padding.
//
// A frame is accepted only if: EtherType 0x0800, version 4, IHL 5 (no options),
// not a fragment, protocol 17 (UDP), header checksum valid, destination IP and
// UDP port match the configuration, the UDP payload is non-empty and fits the
// IP length.
// Everything else is dropped and counted by reason.

`default_nettype none

module eth_ip_udp_rx (
    input  wire         clk,
    input  wire         rst,
    input  wire  [31:0] cfg_dst_ip,
    input  wire  [15:0] cfg_dst_port,

    input  wire  [63:0] s_axis_tdata,
    input  wire  [7:0]  s_axis_tkeep,
    input  wire         s_axis_tlast,
    input  wire         s_axis_tvalid,
    output logic        s_axis_tready,

    output logic [63:0] m_axis_tdata,
    output logic [7:0]  m_axis_tkeep,
    output logic        m_axis_tlast,
    output logic        m_axis_tuser,   // 1 on the last beat of a truncated payload
    output logic        m_axis_tvalid,
    input  wire         m_axis_tready,

    output logic [31:0] cnt_frames,
    output logic [31:0] cnt_accepted,
    output logic [31:0] cnt_drop_eth,   // not IPv4 (incl. VLAN-tagged)
    output logic [31:0] cnt_drop_ip,    // options, fragment, not UDP, bad lengths
    output logic [31:0] cnt_drop_dst,   // other destination IP or port
    output logic [31:0] cnt_drop_csum,  // bad IPv4 header checksum
    output logic [31:0] cnt_drop_runt,  // frame ended inside the headers
    output logic [31:0] cnt_truncated   // frame ended before the UDP length
);
    typedef enum logic [1:0] {HDR, FWD, DROP} state_t;
    state_t     state;
    logic [2:0] beat;          // beat index within the frame while in HDR (0..4)
    logic       first_fwd;     // next forwarded beat is beat 5 (payload from lane 2)
    logic [15:0] remaining;    // payload bytes still to forward

    // captured header fields
    logic [15:0] ethertype, ip_total_len;
    logic [13:0] ip_mf_frag;      // MF flag + fragment offset
    logic [7:0]  ver_ihl, proto;
    logic [15:0] dst_ip_hi;       // dst IP bytes 30-31 (beat 3); bytes 32-33 come in beat 4
    logic [19:0] csum_acc;

    // byte n of the current beat
    function automatic logic [7:0] lane(input logic [63:0] d, input int n);
        return d[8*n +: 8];
    endfunction
    function automatic logic [15:0] word(input logic [63:0] d, input int hi);
        return {d[8*hi +: 8], d[8*(hi+1) +: 8]};  // big-endian 16-bit word at lanes hi, hi+1
    endfunction
    // number of valid bytes in a beat (tkeep is contiguous from lane 0)
    function automatic logic [3:0] keep_bytes(input logic [7:0] k);
        logic [3:0] n;
        n = 4'd0;
        for (int i = 0; i < 8; i++) if (k[i]) n = 4'(i + 1);
        return n;
    endfunction
    function automatic logic [15:0] fold(input logic [19:0] s);
        logic [16:0] t;
        t = {1'b0, s[15:0]} + {13'd0, s[19:16]};
        return t[15:0] + {15'd0, t[16]};
    endfunction

    wire fire = s_axis_tvalid && s_axis_tready;
    wire [63:0] d = s_axis_tdata;

    // ---------------------------------------------------------------- beat-4 decision
    // Values as they will be once beat 4 is captured (beat 4 holds dst IP low half,
    // ports and UDP length, plus the last checksum word).
    wire [31:0] dst_ip_b4   = {dst_ip_hi, word(d, 0)};
    wire [15:0] dst_port_b4 = word(d, 4);
    wire [15:0] udp_len_b4  = word(d, 6);
    wire [15:0] csum_b4     = fold(csum_acc + {4'd0, word(d, 0)});

    wire bad_eth  = (ethertype != 16'h0800);
    wire bad_ip   = (ver_ihl != 8'h45) || (proto != 8'd17) ||
                    (ip_mf_frag != 14'd0) ||  /* more-fragments flag or nonzero offset */
                    (udp_len_b4 < 16'd9) || (ip_total_len < 16'd29) ||
                    (udp_len_b4 > ip_total_len - 16'd20);
    wire bad_csum = (csum_b4 != 16'hFFFF);
    wire bad_dst  = (dst_ip_b4 != cfg_dst_ip) || (dst_port_b4 != cfg_dst_port);

    // ---------------------------------------------------------------- forwarding
    // Bytes available in this beat for the payload and how many we send.
    wire [3:0]  start      = first_fwd ? 4'd2 : 4'd0;
    wire [3:0]  in_bytes   = s_axis_tlast ? keep_bytes(s_axis_tkeep) : 4'd8;
    wire [3:0]  avail      = (in_bytes > start) ? in_bytes - start : 4'd0;
    wire        ends_here  = (remaining <= {12'd0, avail});
    wire [3:0]  n_out      = ends_here ? remaining[3:0] : avail;
    wire [7:0]  out_keep   = 8'((16'(1) << n_out) - 16'(1)) << start;

    assign s_axis_tready  = (state == FWD) ? m_axis_tready : 1'b1;
    assign m_axis_tvalid  = (state == FWD) && s_axis_tvalid;
    assign m_axis_tdata   = s_axis_tdata;
    assign m_axis_tkeep   = out_keep;
    assign m_axis_tlast   = ends_here || s_axis_tlast;
    assign m_axis_tuser   = s_axis_tlast && !ends_here;  // frame shorter than UDP length

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= HDR;
            beat <= 3'd0;
            first_fwd <= 1'b0;
            csum_acc <= '0;
            {cnt_frames, cnt_accepted, cnt_drop_eth, cnt_drop_ip} <= '0;
            {cnt_drop_dst, cnt_drop_csum, cnt_drop_runt, cnt_truncated} <= '0;
        end else if (fire) begin
            case (state)
                HDR: begin
                    case (beat)
                        3'd0: begin
                            cnt_frames <= cnt_frames + 1;
                            csum_acc <= '0;
                        end
                        3'd1: begin
                            ethertype <= word(d, 4);
                            ver_ihl   <= lane(d, 6);
                            csum_acc  <= {4'd0, word(d, 6)};
                        end
                        3'd2: begin
                            ip_total_len  <= word(d, 0);
                            ip_mf_frag    <= {d[37:32], d[47:40]};  // byte 20 bits 5:0, byte 21
                            proto         <= lane(d, 7);
                            csum_acc <= csum_acc + {4'd0, word(d, 0)} + {4'd0, word(d, 2)}
                                                 + {4'd0, word(d, 4)} + {4'd0, word(d, 6)};
                        end
                        3'd3: begin
                            dst_ip_hi <= word(d, 6);
                            csum_acc <= csum_acc + {4'd0, word(d, 0)} + {4'd0, word(d, 2)}
                                                 + {4'd0, word(d, 4)} + {4'd0, word(d, 6)};
                        end
                        default: ;  // beat 4: decided below
                    endcase

                    if (s_axis_tlast) begin                 // ended inside the headers
                        cnt_drop_runt <= cnt_drop_runt + 1;
                        beat <= 3'd0;
                    end else if (beat == 3'd4) begin
                        beat <= 3'd0;
                        if (bad_eth) begin
                            cnt_drop_eth <= cnt_drop_eth + 1;
                            state <= DROP;
                        end else if (bad_ip) begin
                            cnt_drop_ip <= cnt_drop_ip + 1;
                            state <= DROP;
                        end else if (bad_csum) begin
                            cnt_drop_csum <= cnt_drop_csum + 1;
                            state <= DROP;
                        end else if (bad_dst) begin
                            cnt_drop_dst <= cnt_drop_dst + 1;
                            state <= DROP;
                        end else begin
                            cnt_accepted <= cnt_accepted + 1;
                            remaining <= udp_len_b4 - 16'd8;
                            first_fwd <= 1'b1;
                            state <= FWD;
                        end
                    end else begin
                        beat <= beat + 3'd1;
                    end
                end

                FWD: begin
                    first_fwd <= 1'b0;
                    remaining <= remaining - {12'd0, n_out};
                    if (s_axis_tlast) begin
                        if (!ends_here) cnt_truncated <= cnt_truncated + 1;
                        state <= HDR;
                    end else if (ends_here) begin
                        state <= DROP;  // discard padding up to the end of the frame
                    end
                end

                DROP: if (s_axis_tlast) state <= HDR;

                default: state <= HDR;
            endcase
        end
    end
endmodule

`default_nettype wire
