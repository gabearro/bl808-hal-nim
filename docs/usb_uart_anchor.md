# Resident Nim USB UART anchor (experimental)

`examples/m0_usb_uart_flash_anchor.nim` now boots as the M0 firmware and stays
resident while a **cooperative M0 application** runs from a separate image. The
anchor owns USB, UART0 recovery, UART1/2 configuration, and flash commands.
Applications register their console and UART use through the versioned Nim ABI
in `src/bl808/kernel/usb_anchor_app_api.nim`; they do not initialize those
peripherals themselves.

The anchor's boot2 wrapper remains in the normal M0 FW slot at physical flash
offset `0x10000`. Its code, data, and stack occupy 64 KiB of M0 OCRAM. An
application package lives at physical flash offset `0x40000`, loads into
`0x22030000` WRAM, and may use at most 112 KiB for code, data, and BSS. The
anchor checks the package version, bounds, and checksum before calling its
`anchor_app_init(api)` and then `anchor_app_poll()` repeatedly. An absent or
invalid package leaves the flash recovery anchor running. Application poll and
API calls must be nonblocking; an application that hangs on the M0 core also
stalls the anchor. This layout is for rebuilt cooperative applications. The
existing standalone M0 firmware images are not compatible with it as-is.
The demo initializes its own WRAM heap and Nim module runtime inside
`anchor_app_init`; other rebuilt applications must do the same before using
allocation or module globals. They must not call the full M0 `systemInit`,
which would reset peripherals owned by the anchor.

## Console and UART registration

`api.registerConsole(uartIndex, baud)` publishes application console channel 3:

- `uartIndex = 0`: UART0 pins GPIO14/15 at 230400 baud and the USB console PTY
  carry the same application console. The anchor still recognizes the reserved
  `UFA1` + `FRSH` flash command prefix on UART0. Other pin input reaches the
  app; application output is sent to both pins and USB. A partial flash prefix
  is forwarded to the app after an idle timeout.
- `uartIndex = 1` or `2`: the chosen physical UART and the USB console PTY
  carry the app console. The app sets a baud from 9600 through 3000000.
- `uartIndex = 255`: a USB-only virtual console; pass baud 0.

`api.registerUart(1 or 2, baud)` makes another UART app-owned. The app uses
`uartWrite` and `uartRead`; the anchor configures the pins and mirrors pin data
to that UART's host PTY. A UART can have only one owner. UART1 defaults to
GPIO20 TX/GPIO21 RX and UART2 to GPIO22 TX/GPIO23 RX; these are Nim build-time
pin defines. API writes return the number of bytes accepted, which may be less
than requested when USB or the UART FIFO is busy; applications must retry the
remainder. API reads return currently available bytes. Host-to-app input uses
credit frames so the USB helper does not overrun the application RX ring.

The Ox64 USB-C device advertises **one CDC ACM byte stream**. Channel 0 is the
anchor console/flash protocol, channels 1 and 2 are UART1/2, and channel 3 is
the application console. `tools/usb_anchor_uart_mux.py` creates PTYs when the
anchor registers channels and reconnects after USB re-enumeration. Registration
frames contain version 1, role, UART index, and baud. The older empty register
frame and host `--uart1`/`--uart2` bridge options remain supported. These PTYs
are host-side virtual ports, not separate USB CDC interfaces.

## Build without touching hardware

```sh
.venv/bin/python tools/hw_validate.py \
  --test m0_usb_uart_flash_anchor --build-only
.venv/bin/python tools/build_usb_anchor_app.py \
  examples/m0_usb_anchor_app_demo.nim
.venv/bin/python tools/hw_validate.py \
  --uart-anchor-flash-image build/usb-anchor-app/app.anchor.bin \
  --uart-anchor-flash-image-address 0x40000 \
  --uart-anchor-existing --no-jtag --uart-anchor-reset-after-flash \
  --uart <current-runtime-uart> --dry-run
```

The app builder writes an image, ELF, and SHA256 manifest. To install the app,
remove `--dry-run` from the last command **only after** the resident anchor is
actually flashed and answers an existing-anchor probe. That command uses the
hardware harness and updates only the app slot. Reboot returns to the anchor,
which loads the new app. Normal `--jtag-flash` or `--uart-anchor-flash` of a
standalone M0 test still replaces the anchor's FW slot.

When USB is connected, start the host helper with the current CDC path:

```sh
.venv/bin/python tools/usb_anchor_uart_mux.py --mux <anchor-usb-cdc-port>
```

It prints the anchor and application PTY paths as they register. Point
`tools/hw_validate.py --uart` at the anchor PTY for flash commands over USB,
with `--serial-dtr unchanged --serial-rts unchanged` on macOS PTYs. The
host's channel-0 OPEN retrieves the current app/UART registrations, including
registrations that predate the CDC open. The helper can also open unclaimed
UART1/2 for legacy bridging with `--uart1 230400 --uart2 230400`.

With the echo demo installed, check the **app console** PTY for exact
bidirectional delivery of 64 KiB of binary data. The check delays reading
to exercise partial writes and buffering. Use the same work directory as
the flash harness so both take the same hardware lock.

```sh
.venv/bin/python tools/check_usb_anchor_echo.py --uart <app-console-pty>
```

To test native USB independently of the PTY mux, stop the mux helper and run
this non-writing check against the raw CDC port. It interrupts a command and
a mux frame, reopens channel 0, and checks ordered binary replies in bursts.

```sh
.venv/bin/python tools/check_usb_anchor_transport.py \
  --uart <anchor-usb-cdc-port> --bursts 1152
```

## Cooperative all-core test

Build the `m0_allcore_usb_anchor_app` manifest target with `--build-only`
for the D0/LP peers and the M0 ELF. Package M0 separately with
`tools/build_usb_anchor_app.py examples/m0_allcore_test.nim`. The ordinary
`m0_allcore_test` standalone entry and LP build are unchanged by this mode.

Install the three test payloads through the **anchor** PTY using the
bounded prebuilt-image command above. The resident wrapper is not part of
this update. Boot the app after installing the last payload.

| Payload | Physical flash start | Exclusive erase limit | Runtime location |
| --- | ---: | ---: | ---: |
| M0 application package | `0x40000` | `0x5C000` | `0x22030000` |
| D0 test binary | `0xA0000` | `0xB0000` | `0x3EF80000` |
| LP RAM-linked test binary | `0xC0000` | `0xD0000` | `0x22050000` |

The app registers a virtual USB console and waits for `r` before starting
the peers. It runs one scheduler iteration per call from the anchor. M0
and LP poll timers and IPC; D0 runs its normal scheduler. M0 does not
install an interrupt handler, change the anchor's trap vector, or set up
USB/UART again. The app holds both test peers in reset after the result.
Do not issue flash operations during the test.

Run the test once per reboot using the **app console** PTY:

```sh
.venv/bin/python tools/hw_validate.py \
  --test m0_allcore_usb_anchor_app --no-flash --no-jtag \
  --uart <app-console-pty> --serial-dtr unchanged --serial-rts unchanged
```

The harness sends `r` and requires the exact startup banner,
`Result: 5 passed, 0 failed`, and `=== ALL TESTS PASSED ===`.
To repeat, reboot via the **anchor** PTY,
then use the app PTY reported after re-enumeration.

## Validation status and limits

On the Ox64 with the USB-C data cable attached, the final resident M0
wrapper was 18,880 bytes, with erase end `0x15000`. The BL808 USB divider
and AHB gate are both needed: before enabling `CGEN_CFG1[13]`, the M0 and
debugger both read `0x090A9BAA` from the USB interrupt-group register.
With the gate enabled, macOS enumerated `/dev/cu.usbmodemBL808_ANCHOR1`.
Setting the controller's `AFT_CONF` bit on `SET_CONFIGURATION` enabled
bulk I/O. USB mux channels 0, 1, 2, and 3 registered. The UART1/2 check is
registration only; a physical loopback was not measured.

USB channel 0 passed ping, JEDEC ID `0x1860EF`, erase/write-verify,
and reboot without JTAG, including 512 consecutive pings with distinct
tokens and no mismatches. On USB channel 3, the old UART0-mirrored echo
demo returned only 6,283 of 65,536 bytes under load because it ignored
partial writes. After retaining and retrying those bytes, it returned the
full payload byte for byte. Reports are under
`build/hw-validation-usb-uart-bidi/`.

A later full-image flash stalled with the device still enumerated. A raw CDC
burst reproduced it without the mux: the anchor received 384 bytes, replied
to 13 requests, and left the OUT endpoint's zero-length packet flag pending
(`DEV_RXZ = 0x2`, `DEV_ISG2 = 0x40`). Acknowledging `DEV_RXZ` before the group
event fixed that reproduction. The updated anchor passed 36,864 ordered
request/reply pairs (884,736 request bytes and 589,824 response bytes), both
interrupted-stream recovery checks without a reboot, and USB-only flash
write/readback verification of the same 826,704-byte image that had stalled.
The resident wrapper and app/peer test payloads were restored over USB and the
mux re-registered its PTYs after a USB-only reboot. Logs are under
`build/hw-validation-usb-zlp/`.

The separate USB-to-UART adapter still received no reply on the UART0
pins. A raw UART0 reboot command restarted the anchor and caused native
USB detach/re-enumeration, which verifies the board received the command
but not that it can reply over those pins. Standalone pin recovery remains
unverified.

The resident all-core test passed all five checks over USB. LP reported
alive, D0 returned `square(3) = 9`, LP returned `add(7,8) = 15` and raw
`add(4,5) = 9`, and LP heartbeat advanced `4 -> 7`. LP direct XIP did
not boot in the test, and the interrupt-driven LP RAM variant later
recorded an illegal instruction; this result covers the polled LP peer,
not LP interrupts. Before the final transport changes, two of three boot
captures had a corrupted banner; the raw USB trace showed bytes from an
earlier mux credit frame. Waiting for the IN FIFO to drain still left
one of three banners corrupted. With the uncached bulk-IN staging buffer,
all four comparison boots had the exact banner and no NUL/non-ASCII bytes.
All passed the five core checks. This is a bounded hardware check, not a
long-run byte-error bound. Build and capture logs are under
`build/hw-validation-usb-anchor-app-live/` and
`build/hw-validation-usb-anchor-uncached-live/`.

The resident wrapper and the cooperative all-core test remain installed.
The normal Wi-Fi image is not currently running. Its verified recovery
wrapper is `build/hw-validation-allcore-mac-recovery-gate/m0-fw-boot2.bin`.
Restore it with the bounded M0-only anchor write at `0x10000`, limit
`0xE0000`, followed by reboot. Use USB while the resident anchor responds,
or use the JTAG-loaded C UART anchor through `tools/hw_validate.py`.
Boot2, partition tables and the retained Wi-Fi peer slots at `0xE0000`
and `0x100000` were not written. Larger M0 software, including the Wi-Fi
manager, still needs migration to the memory and poll ABI.
