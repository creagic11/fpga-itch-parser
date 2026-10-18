// Synchronous AXI-Stream FIFO, power-of-two depth, registered read.
//
// Pointers carry one extra bit to tell full from empty. Storage is a plain array
// that Vivado maps to distributed or block RAM depending on depth and width.

`default_nettype none

module axis_fifo #(
    parameter int W     = 64,
    parameter int DEPTH = 16  // must be a power of two
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          s_valid,
    output logic         s_ready,
    input  wire  [W-1:0] s_payload,
    output logic         m_valid,
    input  wire          m_ready,
    output logic [W-1:0] m_payload,
    output logic [$clog2(DEPTH):0] level
);
    localparam int AW = $clog2(DEPTH);

    logic [W-1:0] mem [DEPTH];
    logic [AW:0]  wr_ptr, rd_ptr;

    wire empty = (wr_ptr == rd_ptr);
    wire full  = (wr_ptr[AW] != rd_ptr[AW]) && (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]);

    assign s_ready = !full;
    assign level   = wr_ptr - rd_ptr;

    // Output register: holds the head entry. Refilled whenever it is empty or read.
    wire out_free = !m_valid || m_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            wr_ptr  <= '0;
            rd_ptr  <= '0;
            m_valid <= 1'b0;
        end else begin
            if (s_valid && s_ready) begin
                mem[wr_ptr[AW-1:0]] <= s_payload;
                wr_ptr <= wr_ptr + 1'b1;
            end
            if (out_free) begin
                if (!empty) begin
                    m_payload <= mem[rd_ptr[AW-1:0]];
                    m_valid   <= 1'b1;
                    rd_ptr    <= rd_ptr + 1'b1;
                end else begin
                    m_valid <= 1'b0;
                end
            end
        end
    end
endmodule

`default_nettype wire
