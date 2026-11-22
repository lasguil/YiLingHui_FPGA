#ifndef STYLE_CAMERA_H
#define STYLE_CAMERA_H
#include <stdint.h>

/* Camera control registers live in the existing CPU APB window at 0xf8100500. */
#define CAMERA_CSR_BASE UINT32_C(0xf8100500)
#define CAM_CSR_STATUS  0x00u
#define CAM_CSR_EVENT   0x04u
#define CAM_CSR_VS      0x08u
#define CAM_CSR_CONTROL 0x0cu
#define CAM_CSR_MODE    0x10u
#define CAM_STATUS_READY       (1u << 0)
#define CAM_STATUS_RX_ACK      (1u << 1)
#define CAM_STATUS_CAPTURE_ACK (1u << 2)
#define CAM_STATUS_FAULT       (1u << 3)
#define CAM_STATUS_SWITCHING   (1u << 4)
#define CAM_STATUS_MODE_SHIFT  5u
#define CAM_STATUS_BOUNDARY_ACK (1u << 7)
#define CAM_CONTROL_READY      (1u << 0)
#define CAM_CONTROL_CAPTURE    (1u << 1)
#define CAM_CONTROL_RX         (1u << 2)
#define CAM_CONTROL_FAULT      (1u << 3)
#define CAM_CONTROL_SWITCHING  (1u << 4)
#define CAM_CONTROL_MODE_SHIFT 5u
#define CAM_CONTROL_BAYER_Y_XOR (1u << 7)
#ifndef CAMERA_VFLIP_BAYER_XOR
/* Sensor flip preserves the ISP input CFA phase in the board-tested mode. */
#define CAMERA_VFLIP_BAYER_XOR 0
#endif

void camera_init(void);
void camera_service(unsigned requested_vflip);
unsigned camera_faulted(void);

#endif
