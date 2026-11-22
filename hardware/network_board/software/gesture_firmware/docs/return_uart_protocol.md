# J7 UART return link and semantic command protocol

## Physical interface

The B-board TX is FPGA ball B3 (`GPIOL_04`) on J7 physical pin 37. Its RX is ball B5 (`GPIOL_10`) on J7 physical pin 38. Both are TL-bank 3.3 V. The V4 schematic shows J7 pins 37/38 connected to `GPIOL_04`/`GPIOL_10` and pins 35/36 grounded (PDF page 11, sheet 10/13). Do not confuse J7 physical numbers with FPGA balls.

Connect:

| Link | Connection |
|---|---|
| Data out | board 2 J7-37 (`GPIOL_04`, B3, TX) → board 1 J7-38 (`GPIOL_10`, B5, RX) |
| Common ground | board 2 J7-35 (GND) ↔ board 1 J7-35 (GND) |
| ACK direction | board 1 J7-37 (TX) → board 2 J7-38 (RX) |

Both boards are the same model, so these J7 signal pins use 3.3 V. Do not connect J7-3 (5 V), or J7-36 (ground; use pin 35 for the documented ground lead). The two data directions and common ground are required for remote command confirmation.

## UART hardware

The second board exposes the UART at CPU APB `0xF8103000`. It is 8N1, default `BAUD_DIV=868` at the 100 MHz CPU clock (115,207.37 baud, 0.0064% above 115,200). The hardware has 64-byte TX/RX FIFOs. Firmware polls `STATUS.TX_FULL` and services the four-frame bounded queue without blocking inference. At most one web command waits for ACK; timeout is 500 ms and action commands are never retried. RX parsing checks sync, version, payload length, CRC, ACK status and matching sequence. The Sapphire USB diagnostic UART remains separate at `0xF8010000`.

| Offset | Register | Firmware use |
|---:|---|---|
| `0x00` | TXDATA | Write one byte when TX FIFO is not full |
| `0x04` | RXDATA | Read ACK bytes while RX is not empty |
| `0x08` | STATUS | `TX_FULL`, `TX_EMPTY`, `TX_BUSY` and sticky RX errors |
| `0x0C` | BAUD_DIV | Set to 868 while UART is idle at startup |
| `0x10` | STATUS_W1C | Clear observed RX error flags |

An increment of `gesture_return_frames_sent` means the transmitter drained its FIFO and shift register to wire idle. It is not a peer ACK. `gesture_return_frames_dropped` records invalid events and queue overflow, and `gesture_return_uart_errors` records RX overflow/framing/break flags. Firmware emits `RETURN_QUEUED`, `RETURN_TX`, `RETURN_DROP`, and `RETURN_UART_ERROR` over the independent diagnostic UART.

## B network-to-CPU command mailbox

The web-control APB window is `0xF8104000`. A command record is
`token:u32le, type:u8, length:u8, payload[length]`; it crosses from the network
clock through an asynchronous FIFO and is popped by the CPU. The UART service
drains a record only when its shared four-frame UART queue has room and the
current UART frame has reached wire idle. It then uses the same serializer and
sequence counter as gesture events, keeping each mailbox token's QUEUED/TX/ACK
status bound to that command.

| Offset | Access | Meaning |
|---:|---|---|
| `0x00` | read | bit 0 command FIFO empty; bit 1 result FIFO full |
| `0x04` | read/pop | next command byte; APB waits until a prefetched byte is available |
| `0x08` | write | result token `u32` |
| `0x0C` | write | result metadata `{uart_seq:u16, detail:u8, state:u8}` |
| `0x10` | write | commit result record to the return CDC FIFO |

The network bridge reports `B_QUEUED` at CT commit, `UART_QUEUED` when firmware
accepts the command, `SENT_UNCONFIRMED` after local wire idle, `A_ACCEPTED`
(stage 5) for a valid ACK, `A_REJECTED` (7) for a negative ACK, and
`ACK_TIMEOUT` (10) after 500 ms. `BUSY` remains stage 8. ACK acceptance means
validated and handed to A's UI input/scheduler; it does not mean a frame-boundary
commit or visible result. Tokens stay attached to their own queue entries. A
truncated RX frame is discarded after 50 ms without a new byte; a CRC-invalid
frame is scanned for the next sync pair without extending the per-service
64-byte receive budget.

## Envelope

Protocol version 1 uses a fixed, byte-oriented frame:

| Bytes | Field |
|---:|---|
| 0 | Sync `0xA5` |
| 1 | Sync `0x5A` |
| 2 | Version (`1`) |
| 3 | Message type |
| 4–5 | Sequence, little-endian `uint16` |
| 6–7 | Payload length, little-endian `uint16` |
| 8… | Payload (0–54 bytes) |
| last 2 | CRC-16/CCITT-FALSE, little-endian, over version through payload |

CRC parameters are polynomial `0x1021`, initial value `0xFFFF`, no reflection, xor-out zero. A receiver scans for the sync pair, rejects unsupported versions/types/lengths and bad CRC. Sequence wrap is modulo 65536. ACK type `0x30` uses payload `original_seq:u16le,status:u8,error:u8`; the header sequence also equals `original_seq`. Status 0 accepts with error 0; status 1 rejects with error 1 format/value, 2 unsupported, or 3 busy. CRC-invalid frames receive no ACK.

## Semantic command registry proposal

Commands identify intent and named parameters; the wire protocol never carries a target MMIO address or raw register write. B emits existing `GESTURE_EVENT` messages and the full remote UI input records. Legacy parameter commands remain compatible but are not used to claim unsupported web controls.

| Message type | Semantic payload | Existing first-board behavior this can map to |
|---:|---|---|
| `0x01 GESTURE_EVENT` | `event:u8, source_frame:u32le`; event 1=LEFT, 2=RIGHT | Event delivered to a future policy layer; no first-board receiver exists yet |
| `0x10 VIDEO_MODE_SET` | mode `u8`: 0=1920×1080@30, 1=1280×720@30, 2=854×480@30, 3=854×480@60 | Existing CPU firmware accepts these values from its own UART and requests the camera/display mode at frame boundaries |
| `0x11 SCENE_SET` | scene `u8` (`1=WIPE`), source A `u8`, source B `u8` | Existing display path's wipe scene; apply at a complete-frame boundary |
| `0x12 VIEW_SET` | source x/y/w/h `u16le`, destination x/y/w/h `u16le`, x/y scale `u32le` Q16.16; 24 bytes total | Existing display compositor has source/destination rectangles and Q16.16 scale steps |
| `0x13 EFFECT_SET` | effect `u8` (0=DIRECT, 4=LINE, 5=COMIC, 6=EMBOSS), flags `u16le` | Existing IPX spatial effect and config fields; flags bits 1:0=color mode, 2=preserve, 3=LUT enable, 5:4=emboss direction, 6=emboss reverse |
| `0x14 PARAMETER_SET` | parameter ID `u8`, value `i32le` in documented native units | Existing saturation, output saturation, alpha, AI alpha/enable, color min/max, edge threshold, seam low/high, line/background color parameters |
| `0x15 LUT_BEGIN` | table kind `u8`, byte count `u16le`, expected content CRC32 `u32le` | Start a staged curve/LUT upload |
| `0x16 LUT_CHUNK` | kind `u8`, offset `u32le`, count `u8` (1–48), data | Indexed staged table data; frame CRC covers every chunk |
| `0x17 LUT_COMMIT` | kind `u8`, generation `u16le`, content CRC32 `u32le` | Validate and atomically select the completed table generation |
| `0x18 CONFIG_BEGIN` | transaction `u16le`, expected command count `u8` | Stage semantic changes without altering the active frame |
| `0x19 CONFIG_COMMIT` | transaction `u16le`, target frame boundary `u32le` | Validate and apply a full staged bundle atomically at a frame boundary |
| `0x20 CAPS_QUERY` | minimum and maximum protocol version, two `u8` fields | Request peer protocol and feature support |
| `0x21 CAPS_REPORT` | minimum/maximum version `u8`, supported-command bitmap `u32le` | Reject unsupported commands before larger LUT/config transfers |
| `0x22 STATUS_QUERY` | requested status-group bitmap `u32le` | Query system, video mode, frame, NPU/IPX and error status |
| `0x23 STATUS_REPORT` | versioned semantic snapshot | Response to status query; no raw APB offsets |
| `0x24 UI_POINTER` | event `u8` (1=DOWN, 2=MOVE, 3=UP, 4=CANCEL), x/y `u16le`, browser time `u32le`; 9 bytes | Remote pointer mapped to 1920×1080 HDMI coordinates; CANCEL is not a click |
| `0x25 UI_ACTION` | action `u8`; `45=UI_HIDE_ALL`, `46=UI_RESTORE` | Same UI action dispatcher used by touch input; explicit set/clear, never toggle |
| `0x30 ACK` | original sequence `u16le`, status `u8`, error code `u8` | Accepted or rejected; bad CRC frames receive no response |

For the current IPX parameter registry, `PARAMETER_SET` carries `id:u8, value:i32le`:

| ID | Parameter | Native unit / valid range |
|---:|---|---|
| 1 | SATURATION | Q8 coefficient, 0–512; 256 = 100% |
| 2 | SATURATION_OUT | Q8 coefficient, 0–512; 256 = 100% |
| 3 | FX alpha | Q8 mix, 0–256; 256 = 100% |
| 4 | AI alpha | Q8 mix, 0–256; 256 = 100% |
| 5 | AI enable | 0 or 1 |
| 6 | RGB range minimum | RGB888 packed in 24 bits; byte 0=R, byte 1=G, byte 2=B |
| 7 | RGB range maximum | Same packing as ID 6 |
| 8 | Edge threshold | 0–2040 |
| 9 | Line color | RGB888 packed in 24 bits; byte 0=R, byte 1=G, byte 2=B |
| 10 | Background color | Same packing as ID 9 |
| 11 | Seam low halo | 0–8 pixels |
| 12 | Seam high halo | 0–8 pixels |

`EFFECT_SET.flags` and parameter records remain available for legacy compatibility. The current web page sends UI_ACTION for shortcuts and UI_POINTER for image interaction. It does not expose the removed spatial effects or 3D LUT upload controls.

The existing application selects video modes from a debounced KEY3 press or ASCII `0`–`3` on the USB UART. It also initializes IPX curve and table state, DIRECT/LINE/COMIC/EMBOSS spatial modes, color/preserve/LUT/emboss flags, saturation, alpha, AI alpha/mix, and display UI state. IPX register definitions include the parameter fields listed above. Saturation is the available color-intensity parameter; there is no parameter named contrast. The current application does not expose a named style catalog or user-selectable freeze. The display path atomically publishes completed frames, provides a wipe scene, and scales the selected video mode to HDMI geometry; it does not expose a separate animated transition effect. `CONFIG_BEGIN/COMMIT` are receiver-side semantic staging rules, not claims that the current second board executes them. Reserved feature bits can advertise freeze/contrast/transition only after those controls exist.

## Reliability and bandwidth

Gesture events are short (15 bytes including envelope and CRC). At 115,200 baud, 8N1, a complete frame takes about 1.30 ms on the wire. The 64-byte hardware FIFO and four-frame software queue absorb normal burst jitter; if software queue capacity is exceeded, the event is counted and reported rather than silently discarded. The current no-ACK operation provides UART framing/CRC integrity on the sender but cannot detect a disconnected cable or peer rejection. A future first-board receiver should ACK accepted sequence numbers and apply a command atomically at a frame boundary; LUT/profile transfers should be chunked and staged until commit so the active rendering state never sees a partial update.

The UART is electrically independent of HDMI TMDS and adds no work to the video pixel path. `UI_HIDE_ALL` (45) hides every UI layer, prompt, and hand marker while preserving video; `UI_RESTORE` (46) restores the normal home UI. Hide persists until restore or reset. While hidden, `UI_POINTER` and legacy CLEAN toggle action 8 are ignored; other valid UI actions and gesture events may update state but remain invisible. Physical board-to-board execution still requires hardware validation.
