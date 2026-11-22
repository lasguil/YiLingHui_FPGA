// DVI 1.0 TMDS encoder, video and control tokens only.
// One symbol per pixel clock. Channel 0 carries hs/vs; the others tie c0/c1 low.
module tmds_encode (
    input  wire       clk,
    input  wire       rst_p,
    input  wire [7:0] din,
    input  wire       c0,
    input  wire       c1,
    input  wire       de,
    output reg  [9:0] dout
);
    wire [3:0] n1d = din[0] + din[1] + din[2] + din[3]
                   + din[4] + din[5] + din[6] + din[7];
    wire       xnor_op = (n1d > 4'd4) || ((n1d == 4'd4) && (din[0] == 1'b0));

    wire [8:0] qm;
    assign qm[0] = din[0];
    assign qm[1] = xnor_op ? ~(qm[0] ^ din[1]) : (qm[0] ^ din[1]);
    assign qm[2] = xnor_op ? ~(qm[1] ^ din[2]) : (qm[1] ^ din[2]);
    assign qm[3] = xnor_op ? ~(qm[2] ^ din[3]) : (qm[2] ^ din[3]);
    assign qm[4] = xnor_op ? ~(qm[3] ^ din[4]) : (qm[3] ^ din[4]);
    assign qm[5] = xnor_op ? ~(qm[4] ^ din[5]) : (qm[4] ^ din[5]);
    assign qm[6] = xnor_op ? ~(qm[5] ^ din[6]) : (qm[5] ^ din[6]);
    assign qm[7] = xnor_op ? ~(qm[6] ^ din[7]) : (qm[6] ^ din[7]);
    assign qm[8] = ~xnor_op;

    wire [3:0] n1q = qm[0] + qm[1] + qm[2] + qm[3]
                   + qm[4] + qm[5] + qm[6] + qm[7];
    wire [3:0] n0q = 4'd8 - n1q;
    wire signed [5:0] n0_minus_n1 = $signed({2'b0, n0q}) - $signed({2'b0, n1q});
    wire signed [5:0] n1_minus_n0 = $signed({2'b0, n1q}) - $signed({2'b0, n0q});

    reg signed [5:0] cnt;

    wire bias_eq = (cnt == 6'sd0) || (n1q == n0q);
    wire invert  = (cnt > 6'sd0 && n1q > n0q) || (cnt < 6'sd0 && n1q < n0q);

    always @(posedge clk or posedge rst_p) begin
        if (rst_p) begin
            dout <= 10'b1101010100;
            cnt  <= 6'sd0;
        end else if (!de) begin
            case ({c1, c0})
                2'b00: dout <= 10'b1101010100;
                2'b01: dout <= 10'b0010101011;
                2'b10: dout <= 10'b0101010100;
                default: dout <= 10'b1010101011;
            endcase
            cnt <= 6'sd0;
        end else if (bias_eq) begin
            dout <= {~qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0]};
            if (qm[8])
                cnt <= cnt + n1_minus_n0;
            else
                cnt <= cnt + n0_minus_n1;
        end else if (invert) begin
            dout <= {1'b1, qm[8], ~qm[7:0]};
            cnt  <= cnt + (qm[8] ? 6'sd2 : 6'sd0) + n0_minus_n1;
        end else begin
            dout <= {1'b0, qm[8], qm[7:0]};
            cnt  <= cnt - (qm[8] ? 6'sd0 : 6'sd2) + n1_minus_n0;
        end
    end
endmodule
