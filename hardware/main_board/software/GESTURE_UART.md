# Bidirectional board-to-board UART interface


The first board receives UART from J7 B5 (connector pin 38, FPGA pad GPIOL_10) and sends ACKs from J7 B3 (connector pin 37, FPGA pad GPIOL_04) at 115200 baud, 8 data bits, no parity, one stop bit. The second-board UART TX connects to first-board RX, and second-board RX connects to first-board TX; connect both J7 pin 35 grounds. This uses the 3.3 V logic interface.

Frames follow `gesture_return_protocol.h`: `A5 5A`, version, type, sequence (LE16), payload length (LE16), payload, CRC16 (LE). CRC is CRC-16/CCITT-FALSE (initial value `FFFF`, polynomial `1021`) over version through the last payload byte. Version 1 frames are limited to 64 bytes. A partial frame is discarded after 20 ms. Only an identical sequence-and-CRC frame repeated within 100 ms is suppressed; other sequence values are accepted, including after the sender restarts and begins at zero.

Commands update the existing `style_input_state` shadow. The regular control loop remains responsible for applying those desired values at the existing frame and display boundaries. Gesture LEFT requests the next model and RIGHT requests the previous model; both are ignored for model switching while processing is paused.

| Type | Supported payload and behavior |
| --- | --- |
| `GESTURE_EVENT` (`01`) | 5 bytes; in WAVE PRO, LEFT (`01`) requests the next model, RIGHT (`02`) the previous model. The trailing frame number is accepted and ignored. |
| `GESTURE_PAUSE_SET` (`02`) | WAVE PRO only: one-byte absolute paused state, `1` holds the current picture and `0` resumes. Repeated values do not toggle; valid commands outside PRO are ACKed without changing state. |
| `VIDEO_MODE_SET` (`10`) | One byte 0–3; same four mode values as the first board. |
| `UI_POINTER` (`24`) | 9 bytes: event, x/y LE16, time_ms LE32. Coordinates use the 1920×1080 image; event 1–4 means DOWN/MOVE/UP/CANCEL. Remote touch has ID 255, an independent gesture context, and a two-second idle cancel. |
| `UI_ACTION` (`25`) | One byte, action ID 1–47, defined in `style_input.h`. 44 toggles vertical flip, 45 hides the UI, 46 restores it, and 47 cycles the WAVE mode. Uses the same action handler and operation gates as local touch. |
| `HAND_MARKER` (`26`) | Two bytes, little endian. Bits 6:0 carry x and bits 13:7 carry y. The marker is enabled in WAVE PRO for x < 120 and y < 68. |
| `UI_SET` (`27`) | Two bytes containing a field number and an absolute value. |
| `ACK` (`30`) | Four-byte response with the request sequence (LE16), status and error. |

`SCENE_SET` (`11`), `EFFECT_SET` (`13`) and `PARAMETER_SET` (`14`) are deprecated and rejected as unsupported; their UI controls use `UI_ACTION` instead. Other view geometry, LUT upload/commit, config transactions, and capability/status queries and reports remain unsupported. Unsupported commands are counted and receive a rejection ACK.

The RX CSR uses a 1024-byte byte FIFO, matching the existing CH9350 UART receiver. Firmware drains up to 64 bytes per service call from the regular polling path and during bounded camera waits. Hardware framing/overrun errors reset the parser and flush queued bytes so the tail of a damaged frame cannot join a later command. The diagnostic `d` output includes parser, framing, and FIFO-overrun counts. The CPU parser uses one 64-byte frame buffer and does not allocate a command queue.

## UI_SET fields

| Field | Setting | Value |
| --- | --- | --- |
| 1 | Model | Zero-based catalog index |
| 2 | Color table | Zero-based catalog index |
| 3–4 | AI and FX strength | 0–100% |
| 5 | WAVE mode | 0 OFF, 1 LITE, 2 PRO |
| 6 | Manual pause | 0 resume, 1 pause. Applies in every WAVE mode. |
| 7 | Saturation | 0–200% |
| 8 | Keep Color | 0 off, 1 on |
| 9 | Keep Color preset | 0 red, 1 green, 2 blue |
| 10–15 | RGB lower and upper bounds | R low/high, G low/high, B low/high. Each is 0–255, with low ≤ high. |

An accepted ACK reports command acceptance. State changes are applied by the control loop.
