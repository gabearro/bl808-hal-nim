# Resident USB UART anchor

The experimental [Nim USB UART anchor](../examples/m0_usb_uart_flash_anchor.nim)
runs as resident M0 firmware. It owns USB, UART configuration, and flash
commands while a cooperative M0 app runs from a separate image.

| Image | Physical flash start | Runtime memory |
| --- | ---: | --- |
| Boot2-wrapped M0 anchor | `0x10000` | 64 KiB M0 OCRAM |
| Application package | `0x40000` | Up to 112 KiB of WRAM from `0x22030000` |

The anchor validates the app package version, bounds, and checksum, then
calls `anchor_app_init(api)` and repeatedly calls `anchor_app_poll()`.
An absent or invalid app leaves the anchor available for recovery. The app
initializes its own WRAM heap and Nim run time as needed. Its callbacks must
return promptly and leave the anchor's peripheral setup and trap vector
intact. See the [application ABI](../src/bl808/kernel/usb_anchor_app_api.nim).

## USB channels

The Ox64 exposes one CDC ACM stream. The
[host mux](../tools/usb_anchor_uart_mux.py) creates PTYs from registrations
and reconnects when USB re-enumerates.

| Channel | Role |
| --- | --- |
| 0 | Anchor console and flash protocol. |
| 1 and 2 | UART1 and UART2. Assign through `registerUart`. |
| 3 | Application console. Assign through `registerConsole` to the chosen physical UART or use index 255 and baud 0 for USB-only. |

A physical UART has one owner. When the app console mirrors UART0, the
anchor still recognizes the reserved flash prefix on the serial pins.
API writes can be partial when USB or the UART FIFO is busy. Retry the
remaining bytes from a later poll. Input credit limits the host to the
app's available receive capacity.

## Build and update the app

```sh
.venv/bin/python tools/hw_validate.py --test m0_usb_uart_flash_anchor --build-only
.venv/bin/python tools/build_usb_anchor_app.py examples/m0_usb_anchor_app_demo.nim
.venv/bin/python tools/usb_anchor_uart_mux.py --mux "$ANCHOR_CDC_PORT"
```

Run the mux in its own terminal. Install or recover the resident firmware
through the [hardware harness](hardware_validation_harness.md). With a
resident anchor already running, set `ANCHOR_PTY` to the mux's channel 0
PTY and confirm it answers the probe before updating the app slot.

```sh
.venv/bin/python tools/hw_validate.py --uart-anchor-probe \
  --uart-anchor-existing --no-jtag --uart "$ANCHOR_PTY" \
  --serial-dtr unchanged --serial-rts unchanged
.venv/bin/python tools/hw_validate.py \
  --uart-anchor-flash-image build/usb-anchor-app/app.anchor.bin \
  --uart-anchor-flash-image-address 0x40000 \
  --uart-anchor-flash-image-end 0x5C000 \
  --uart-anchor-existing --no-jtag --uart-anchor-reset-after-flash \
  --uart "$ANCHOR_PTY" --serial-dtr unchanged --serial-rts unchanged --dry-run
```

Remove `--dry-run` to write the app and reboot after verifying the path and
slot. A normal standalone M0 flash can replace the anchor itself.

## Test coverage

With the echo app installed, run
`tools/check_usb_anchor_echo.py --uart "$APP_CONSOLE_PTY"` through the
test venv. Pass the same `--work-dir` as the flash harness so the checks
share its hardware lock. A bench run verified all 65,536 bytes after the
app handled partial writes. For a raw USB check, stop the mux and run
`tools/check_usb_anchor_transport.py --uart "$ANCHOR_CDC_PORT" --bursts 1152`.
USB-only flash write/readback, reboot, and raw CDC interruption recovery
passed on the Ox64. UART1/2 were observed registering. Physical loopback
for those ports and standalone UART0-pin command/reply remain unverified.

The `m0_allcore_usb_anchor_app` manifest test uses a cooperative M0 app,
D0 at flash `0xA0000`, and a RAM-linked polled LP peer at `0xC0000`.
That configuration passed five checks. The
[prior bench notes](https://github.com/gabearro/bl808-hal-nim/blob/eb932dddbb56ac5131b3d398e5463f18008fc639/docs/usb_uart_anchor.md)
record the peer install limits, transport stress counts, and test procedure.
