# Board 2 network control and board 1 UI action

This document is the source-of-truth companion for `rtl/network/net_route/udp_regs.v`.

## UDP register protocol

Control datagrams are sent to board 2 UDP port 5000. Every request payload is 12 bytes, network byte order: `magic:u16=0x4354` (`CT`), `version:u8=1`, `op:u8` (`0=read`, `1=write`), `sequence:u16`, `register:u16`, `value:u32`. The board answers reads and writes with the same sequence and register; a successful transaction is `op=2` (ACK), and a rejected write is `op=3` (NACK). Event packets use `op=5`.

Registers relevant to routing and remote board 1 commands:

| Register | Access | Meaning |
|---|---|---|
| `0x0014` | read/write | Destination IPv4 address, network-order numeric value (default from top-level parameter/input, currently `192.168.0.3`). This register now drives the MAC/ARP target. |
| `0x0018` | read/write | Control response UDP destination port (default 5000); drives the control-plane TX arbiter. |
| `0x002c` | read | Link/status placeholder fields. |
| `0x0030` | read | Control RX debug bundle. |
| `0x0034` | read | Most recently captured 4 request bytes. |
| `0x0040` | read | Board status bits supplied by the top-level design. |
| `0x012c` | read | UART bridge state. |
| `0x0130` | read | Latest UART status detail. |
| `0x0138` | read | UART accepted/TX status count. |
| `0x013c` | read | UART error status count. |
| `0x0150` | read | UART status generation count. |

The destination register write is accepted even if a periodic event is waiting
for ARP resolution: the receive state machine preempts that pending response,
applies the register, and then retries the control ACK. The ACK still waits for
the configured peer's ARP mapping. A client using a DHCP address should write
its current address to `0x0014`; the board learns only that exact peer from a
valid directed ARP request/reply and never associates another host's MAC with
the configured IP.

## Forward a complete hide/restore action to board 1

Board 2 already has an atomic network-to-CPU command mailbox and firmware UART forwarder. To enqueue a board 1 UI action, issue these three ordinary UDP register writes in order; wait for the ACK after each write:

1. Write `0x00002501` to `0x0180` (`type=0x25 UI_ACTION`, payload length 1).
2. Write `0x0000002d` to `0x0184` for `45 UI_HIDE_ALL`, or `0x0000002e` for `46 UI_RESTORE`.
3. Write a caller-chosen token to `0x01bc` to commit the mailbox entry.

The command then crosses the existing async mailbox and is queued by the firmware's existing return/UART service. The UART uses 115200 baud, 8 data bits, no parity, one stop bit. Its frame is `A5 5A, version=1, type=0x25, sequenceLE16, lengthLE16=1, action, CRC16LE`; CRC is CRC-16/CCITT-FALSE over version through the last payload byte. Board 1 replies with type `0x30` ACK. `45` hides all UI, prompts, and the hand marker while preserving video; `46` restores the normal home UI. The state persists until the opposite action or reset. While hidden, `UI_POINTER` and legacy CLEAN toggle action 8 are ignored; other valid UI actions and gesture events may still update state but remain invisible. These are explicit set/clear actions; do not use the legacy action `8` toggle for remote control.

The UDP register ACK confirms that each register write was accepted. UART bridge status registers report forwarding/ACK progress; a register ACK alone does not mean board 1 applied the action.

## ARP behavior

The one-entry ARP cache starts invalid and accepts only a structurally valid Ethernet/IPv4 ARP packet whose sender IP matches the configured destination IP, whose ARP sender MAC matches the Ethernet source MAC, and which is directed to this board (a request for the local IP or a reply addressed to the local IP/MAC). Both matching requests and replies can refresh the mapping. The entry expires after 30 seconds at the current 25 MHz network clock; while unresolved/expired, the existing control-plane ARP retry state machine probes once per second. Unrelated LAN ARP traffic cannot overwrite the destination entry.
