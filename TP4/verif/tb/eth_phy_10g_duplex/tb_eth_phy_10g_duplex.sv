// Full-duplex test harness: two taxi_eth_phy_10g instances (A and B).
//
// The SERDES ports of both PHYs are exposed so the cocotb Channel model links
// A.tx -> B.rx and B.tx -> A.rx (and can inject line impairments or bit slips).
// Each PHY's receiver runs on the link partner's transmit clock, as it would
// with a clock recovered from the line: A.rx_clk = clk_b, B.rx_clk = clk_a.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module tb_eth_phy_10g_duplex #
(
    parameter DATA_W = 64,
    parameter CTRL_W = (DATA_W/8),
    parameter HDR_W = 2,
    parameter COUNT_125US = 125000/6.4
)
(
    input  wire logic               clk_a,
    input  wire logic               clk_b,
    input  wire logic               rst,

    // PHY A
    input  wire logic [DATA_W-1:0]  a_xgmii_txd,
    input  wire logic [CTRL_W-1:0]  a_xgmii_txc,
    output wire logic [DATA_W-1:0]  a_xgmii_rxd,
    output wire logic [CTRL_W-1:0]  a_xgmii_rxc,
    output wire logic               a_xgmii_rx_valid,
    output wire logic [DATA_W-1:0]  a_serdes_tx_data,
    output wire logic [HDR_W-1:0]   a_serdes_tx_hdr,
    input  wire logic [DATA_W-1:0]  a_serdes_rx_data,
    input  wire logic [HDR_W-1:0]   a_serdes_rx_hdr,
    output wire logic               a_serdes_rx_bitslip,
    output wire logic               a_rx_block_lock,
    output wire logic               a_rx_high_ber,
    output wire logic               a_rx_status,

    // PHY B
    input  wire logic [DATA_W-1:0]  b_xgmii_txd,
    input  wire logic [CTRL_W-1:0]  b_xgmii_txc,
    output wire logic [DATA_W-1:0]  b_xgmii_rxd,
    output wire logic [CTRL_W-1:0]  b_xgmii_rxc,
    output wire logic               b_xgmii_rx_valid,
    output wire logic [DATA_W-1:0]  b_serdes_tx_data,
    output wire logic [HDR_W-1:0]   b_serdes_tx_hdr,
    input  wire logic [DATA_W-1:0]  b_serdes_rx_data,
    input  wire logic [HDR_W-1:0]   b_serdes_rx_hdr,
    output wire logic               b_serdes_rx_bitslip,
    output wire logic               b_rx_block_lock,
    output wire logic               b_rx_high_ber,
    output wire logic               b_rx_status
);

taxi_eth_phy_10g #(
    .DATA_W(DATA_W),
    .CTRL_W(CTRL_W),
    .HDR_W(HDR_W),
    .COUNT_125US(COUNT_125US)
)
phy_a (
    .rx_clk(clk_b),
    .rx_rst(rst),
    .tx_clk(clk_a),
    .tx_rst(rst),
    .xgmii_txd(a_xgmii_txd),
    .xgmii_txc(a_xgmii_txc),
    .xgmii_tx_valid(1'b1),
    .xgmii_rxd(a_xgmii_rxd),
    .xgmii_rxc(a_xgmii_rxc),
    .xgmii_rx_valid(a_xgmii_rx_valid),
    .tx_gbx_req_sync(),
    .tx_gbx_req_stall(),
    .tx_gbx_sync(1'b0),
    .rx_gbx_sync(),
    .serdes_tx_data(a_serdes_tx_data),
    .serdes_tx_data_valid(),
    .serdes_tx_hdr(a_serdes_tx_hdr),
    .serdes_tx_hdr_valid(),
    .serdes_tx_gbx_req_sync(1'b0),
    .serdes_tx_gbx_req_stall(1'b0),
    .serdes_tx_gbx_sync(),
    .serdes_rx_data(a_serdes_rx_data),
    .serdes_rx_data_valid(1'b1),
    .serdes_rx_hdr(a_serdes_rx_hdr),
    .serdes_rx_hdr_valid(1'b1),
    .serdes_rx_gbx_sync(1'b0),
    .serdes_rx_bitslip(a_serdes_rx_bitslip),
    .serdes_rx_reset_req(),
    .tx_bad_block(),
    .rx_error_count(),
    .rx_bad_block(),
    .rx_sequence_error(),
    .rx_block_lock(a_rx_block_lock),
    .rx_high_ber(a_rx_high_ber),
    .rx_status(a_rx_status),
    .cfg_tx_prbs31_enable(1'b0),
    .cfg_rx_prbs31_enable(1'b0)
);

taxi_eth_phy_10g #(
    .DATA_W(DATA_W),
    .CTRL_W(CTRL_W),
    .HDR_W(HDR_W),
    .COUNT_125US(COUNT_125US)
)
phy_b (
    .rx_clk(clk_a),
    .rx_rst(rst),
    .tx_clk(clk_b),
    .tx_rst(rst),
    .xgmii_txd(b_xgmii_txd),
    .xgmii_txc(b_xgmii_txc),
    .xgmii_tx_valid(1'b1),
    .xgmii_rxd(b_xgmii_rxd),
    .xgmii_rxc(b_xgmii_rxc),
    .xgmii_rx_valid(b_xgmii_rx_valid),
    .tx_gbx_req_sync(),
    .tx_gbx_req_stall(),
    .tx_gbx_sync(1'b0),
    .rx_gbx_sync(),
    .serdes_tx_data(b_serdes_tx_data),
    .serdes_tx_data_valid(),
    .serdes_tx_hdr(b_serdes_tx_hdr),
    .serdes_tx_hdr_valid(),
    .serdes_tx_gbx_req_sync(1'b0),
    .serdes_tx_gbx_req_stall(1'b0),
    .serdes_tx_gbx_sync(),
    .serdes_rx_data(b_serdes_rx_data),
    .serdes_rx_data_valid(1'b1),
    .serdes_rx_hdr(b_serdes_rx_hdr),
    .serdes_rx_hdr_valid(1'b1),
    .serdes_rx_gbx_sync(1'b0),
    .serdes_rx_bitslip(b_serdes_rx_bitslip),
    .serdes_rx_reset_req(),
    .tx_bad_block(),
    .rx_error_count(),
    .rx_bad_block(),
    .rx_sequence_error(),
    .rx_block_lock(b_rx_block_lock),
    .rx_high_ber(b_rx_high_ber),
    .rx_status(b_rx_status),
    .cfg_tx_prbs31_enable(1'b0),
    .cfg_rx_prbs31_enable(1'b0)
);

endmodule

`resetall
