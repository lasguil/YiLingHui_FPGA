`ifndef VID_PARAMS_VH
`define VID_PARAMS_VH

`include "isp_params.vh"

`define VID_WIDTH          `ISP_WIDTH
`define VID_HEIGHT         `ISP_HEIGHT

// Packed pixel in DDR: {8'h00, R, G, B}, 4 pixels per 128-bit beat.
`define VID_BPP            4
`define VID_PIX_PER_BEAT   4
`define VID_BEATS_PER_LINE (`VID_WIDTH / `VID_PIX_PER_BEAT)

// 8 MB per bank, 16-byte aligned. Two banks for ping-pong.
`define VID_BANK0_BASE     32'h0000_0000
`define VID_BANK1_BASE     32'h0080_0000

// DDR store grade. 0=1080p30, 1=720p60, 2=720x480p60.
// ISP stays 1920x1080; vid_store_down emits the stored raster before pack.
// HDMI timing stays 1080p60. Runtime mode is scale_mode in the top.
`define SCALE_MODE         2'd0

// 1080p60 CEA-861
`define VID_H_FP           88
`define VID_H_SYNC         44
`define VID_H_BP           148
`define VID_H_TOTAL        2200
`define VID_V_FP           4
`define VID_V_SYNC         5
`define VID_V_BP           36
`define VID_V_TOTAL        1125

`endif
