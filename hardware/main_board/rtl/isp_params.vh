// Slight-warm CCM 2026-11-13; corrected BGGR/raster order.
// Source: hdmi_coloradjust_20261113/ccm_slight_warm_candidate.json; RGB row-vector Q8.
// Fixed white balance is folded into CCM; no FPGA digital gain.

`ifndef ISP_PARAMS_VH
`define ISP_PARAMS_VH

`define ISP_WIDTH          1920
`define ISP_HEIGHT         1080
`define ISP_PW             10
`define ISP_OW             8

`define ISP_BAYER          2

`define ISP_BLC            10'd65
// Camera shutter AE; no FPGA digital-gain stage remains.
`define ISP_SENSOR_AE_ENABLE 1

`define ISP_WB_R           16'd256
`define ISP_WB_G           16'd256
`define ISP_WB_B           16'd256

`define ISP_DPC_TH         10'd80
`define ISP_AWB_LO         10'd32
`define ISP_AWB_HI         10'd900
`define ISP_GAIN_MIN       16'd128
`define ISP_GAIN_MAX       16'd1024

`define ISP_CCM00          14'sd2564
`define ISP_CCM01          -14'sd619
`define ISP_CCM02          -14'sd31
`define ISP_CCM10          -14'sd549
`define ISP_CCM11          14'sd1825
`define ISP_CCM12          -14'sd846
`define ISP_CCM20          -14'sd837
`define ISP_CCM21          -14'sd932
`define ISP_CCM22          14'sd4803

`endif
