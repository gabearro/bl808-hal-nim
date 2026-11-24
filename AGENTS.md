# Agent Notes

This repository has real BL808 hardware validation flows. Prefer the harnesses
below over ad hoc flashing scripts so builds, UART logs, OpenOCD logs, resets,
and failure snapshots land in the expected places.

## Hardware Harness

Use `tools/hw_validate.py` for hardware runs. It reads
`tools/hardware_validation.json`, builds the selected examples, flashes or loads
them with the requested transport, captures UART output, and uses OpenOCD/JTAG
for reset and diagnostics.

Common setup:

```sh
make venv
.venv/bin/python tools/hw_validate.py --list
.venv/bin/python tools/hw_validate.py --preflight --uart /dev/ttyUSB0
```

Use the actual runtime UART device. The default baud is `230400`. If flashing
uses a different serial adapter, pass both `--uart <runtime-port>` and
`--flash-port <bootloader-port>`.
After moving the USB cable, rerun `tools/hw_validate.py --list` and update
`UART_PORT`/`--uart`; do not assume the old `/dev/ttyUSB*` or `/dev/cu.*` path
is still correct.

Logs and build products go under `build/hw-validation` by default:

- `build/hw-validation/logs/*.uart.log`
- `build/hw-validation/logs/*.openocd.log`
- `build/hw-validation/logs/*.target-reset.log`
- per-test ELF/bin outputs under the work directory

The harness takes a hardware lock for non-dry-run operations. Do not bypass it.

## Primary Validation Commands

Run one manifest test:

```sh
.venv/bin/python tools/hw_validate.py \
  --test m0_enclave_services_test \
  --jtag-flash \
  --uart /dev/ttyUSB0 \
  --keep-going
```

Run the smoke tier through JTAG flash:

```sh
make hw-smoke UART_PORT=/dev/ttyUSB0 HW_VALIDATE_FLAGS="--ftdi-reset-sudo"
```

Run the full tier through JTAG flash:

```sh
make hw-full UART_PORT=/dev/ttyUSB0 HW_VALIDATE_FLAGS="--ftdi-reset-sudo"
```

Run from RAM over JTAG without persistent flash:

```sh
make hw-smoke-jtag UART_PORT=/dev/ttyUSB0 HW_VALIDATE_FLAGS="--ftdi-reset-sudo"
```

Use `--build-only` or `--dry-run` before long or risky hardware runs when
changing harness behavior.

## Flashing Modes

`--jtag-flash`
: Builds normal firmware, loads the RAM-resident M0 JTAG flash stub, and writes
  persistent SPI flash through OpenOCD. This avoids UART bootloader mode.

`--jtag-load`
: Loads built firmware into RAM and runs it. This is useful for fast smoke
  checks and all-core RAM-load tests. It does not persist across reset.

plain UART flashing
: Default when neither `--jtag-flash`, `--jtag-load`, nor
  `--uart-anchor-flash` is passed. This uses `tools/upload.sh`/`bflb-iot-tool`
  and requires the board to be in UART boot mode unless another reset path has
  prepared it.

`--uart-anchor-flash`
: JTAG-loads a RAM-resident M0 UART flash anchor, then streams flash commands
  over UART0. This also avoids UART bootloader mode and is useful when the JTAG
  flash path is less reliable than UART data transfer.

These modes are mutually exclusive where the CLI says so. In particular,
`--uart-anchor-flash` cannot be combined with `--jtag-flash` or `--jtag-load`.

## UART Flash Anchor

There are two anchor implementations:

- `examples/m0_uart_flash_anchor.nim`: the Nim example anchor used as a
  persistent firmware test image.
- `tools/uart_flash_anchor.c`: the small RAM-resident anchor that
  `tools/hw_validate.py` builds and loads at `0x62020000`.

The anchor speaks a simple UART protocol on UART0 and prints:

```text
BL808-UART-FLASH-ANCHOR v1
```

It supports ping, read JEDEC ID, erase, write+verify, and reboot commands. The
host-side constants and protocol live in `tools/hw_validate.py`.

Probe the RAM-loaded anchor without erasing or writing flash:

```sh
.venv/bin/python tools/hw_validate.py \
  --uart-anchor-probe \
  --uart /dev/ttyUSB0 \
  --ftdi-reset-sudo
```

Restart the currently flashed image without writing flash when JTAG can
attach. This loads the corrected RAM anchor, verifies its JEDEC read, then
sends its reboot command:

```sh
.venv/bin/python tools/hw_validate.py \
  --uart-anchor-reboot --no-jtag-reset \
  --uart /dev/cu.usbmodem13401 --ftdi-reset-sudo
```

If a persistent anchor is already running, reboot over UART alone:

```sh
.venv/bin/python tools/hw_validate.py \
  --uart-anchor-reboot --uart-anchor-existing --no-jtag \
  --uart /dev/cu.usbmodem13401
```

The first form needs a working M0 JTAG TAP. The second needs a responding
anchor; it cannot reach a different flashed program that has replaced the
anchor. Both are reboot-only operations with no SPI flash erase or write.
Both forms passed on the current bench: JEDEC readback was `0x1860EF`, the
reboot was acknowledged, and a later JTAG check found the flashed hello
program running in its final WFI loop at `0x58000E72`.

Install/run the persistent Nim anchor test:

```sh
make hw-npu-anchor-install \
  UART_PORT=/dev/ttyUSB0 \
  HW_VALIDATE_FLAGS="--ftdi-reset-sudo"
```

That target runs:

```sh
.venv/bin/python tools/hw_validate.py \
  --test m0_uart_flash_anchor \
  --uart-anchor-flash \
  --uart-anchor-runtime-jtag \
  --uart-anchor-reset-after-flash \
  --uart /dev/ttyUSB0
```

After a persistent anchor is already running, prefer probing it before
reinstalling:

```sh
.venv/bin/python tools/hw_validate.py \
  --uart-anchor-probe --uart-anchor-existing --no-jtag \
  --uart /dev/ttyUSB0
```

Without `--uart-anchor-existing`, `--uart-anchor-probe` loads the RAM anchor
through JTAG and replaces the currently running M0 program. Use that form when
you intentionally need to start an anchor and JTAG can attach.

Use an existing persistent anchor to flash another test:

```sh
.venv/bin/python tools/hw_validate.py \
  --test m0_npu_smoke_test \
  --uart-anchor-flash \
  --uart-anchor-existing \
  --uart-anchor-runtime-jtag \
  --jtag-memory-log \
  --uart /dev/ttyUSB0 \
  --ftdi-reset-sudo
```

The Makefile target `hw-npu-smoke-anchor` does this pattern: probe the anchor,
install it if probing fails, then use `--uart-anchor-existing` for NPU tests.

## Persistent Anchor Recovery Image

Build a recovery/install image without touching hardware:

```sh
.venv/bin/python tools/hw_validate.py --uart-anchor-build-only
```

This creates a persistent wrapper image and a recovery manifest under
`build/hw-validation/uart-anchor-persistent/`. The manifest includes commands
for installing the generated `whole_flash_data.bin` through an existing anchor.

Flash a prebuilt image through an anchor:

```sh
.venv/bin/python tools/hw_validate.py \
  --uart-anchor-flash-image build/hw-validation/uart-anchor-persistent/whole_flash_data.bin \
  --uart-anchor-flash-image-address 0 \
  --uart-anchor-existing \
  --uart-anchor-reset-after-flash \
  --uart /dev/ttyUSB0
```

Do not assume a prebuilt image is safe just because it exists. Check the recovery
manifest and the intended flash address first.

## Reset And FTDI Behavior

The harness has four relevant control paths:

- OpenOCD `reset halt` / `halt` / `resume`.
- UART anchor reboot command, which pulses the M0-inclusive
  `GLB_SWRST_CFG2[0]` software power-on reset after acknowledging the command.
- FTDI nSRST output pulse through `tools/ftdi_srst_pulse.c`.
- FTDI USB adapter reset through `tools/ftdi_reset.c`.

The [Ox64 J6 schematic](https://files.pine64.org/doc/ox64/PINE64_Ox64-Schematic-202221018.pdf)
shows four JTAG signals and ground, without the board reset line. An FTDI nSRST
helper success message therefore does not establish that the Ox64 reset. An
FTDI USB reset only resets the adapter.
OpenOCD `reset halt` also requires a working JTAG TAP. On this bench, the
UART anchor reboot is the verified way to start newly flashed firmware while
the anchor is running. The corrected C and Nim anchors use bit 0; the former
bit-5 reboot and a trial bit-2 reboot did not restart M0.

If FTDI/OpenOCD is not responding, resetting the FTDI adapter is often required.
The harness already tries to do this around OpenOCD startup and after target
nSRST pulses. Use these flags when macOS or permissions require them:

```sh
--ftdi-reset-sudo --sudo-askpass
```

or, if the environment supports passwordless sudo:

```sh
--ftdi-reset-sudo
```

Useful reset flags:

- `--target-reset-before-flash`: pulse target nSRST before UART bootloader flash.
- `--target-reset-before-capture`: open UART first, then pulse target nSRST
  before capture/JTAG attach.
- `--manual-target-reset`: prompt for manual reset and imply `--no-jtag-reset`.
- `--no-ftdi-reset`: skip USB-resetting the FTDI adapter. Use only when preserving
  adapter state is intentional.

For `--uart-anchor-flash`, the default non-runtime-JTAG path resets the target
before UART capture. With `--uart-anchor-reset-after-flash`, JTAG-loaded anchors
and existing persistent anchors use the UART reboot command, including with
`--no-jtag`. The latter path requires a responding persistent anchor; probe
it with `--uart-anchor-existing` first.

### Verified Ox64 flash and reboot flow

For a new persistent M0 build on the current Mac bench, first run `--list`
and `--preflight` with the current runtime UART. Build and dry-run the selected
manifest test before a long flash. If the flash-image wrapper needs a
boot-info template, set `BL808_FW_BOOTINFO` to a verified `bootinfo.bin` from
a known-good BL808 image. Then use:

```sh
.venv/bin/python tools/hw_validate.py \
  --test m0_hello_nim_test \
  --uart-anchor-flash \
  --uart-anchor-reset-after-flash \
  --no-jtag-reset \
  --uart /dev/cu.usbmodem13401 \
  --ftdi-reset-sudo \
  --keep-going
```

Replace the test name with the build being validated. The harness JTAG-loads
the RAM C anchor, verifies boot2, partition tables and firmware through UART,
requests the anchor reboot, then captures the new image's UART output. This
exact sequence passed with the stock hello image and captured
`Hello from Nim!`. `--no-jtag-reset` makes the anchor load use `halt` without
an OpenOCD `reset halt`; the harness now honors it in both anchor flash paths.
The reboot command requires a live anchor. A newly flashed test image replaces
the anchor in flash, so `--uart-anchor-existing` only applies when a persistent
anchor is actually running and answers the probe above. To flash a new build
from a responding persistent anchor without JTAG, use:

```sh
.venv/bin/python tools/hw_validate.py \
  --test m0_hello_nim_test \
  --uart-anchor-flash --uart-anchor-existing --no-jtag \
  --uart-anchor-reset-after-flash \
  --uart /dev/cu.usbmodem13401 --keep-going
```

The harness then reboots through UART after verifying the new build. The
new image replaces the persistent anchor, so later flashes need a JTAG-loaded
RAM anchor or another running persistent anchor. This exact
flash-through-existing-anchor sequence has passed a dry run and protocol
tests; only the reboot-only existing-anchor path has been exercised on this
bench.

### Host recovery when UART anchor and JTAG are silent

On this bench, the UARTx4 adapter and FT232H JTAG adapter are behind a
switchable USB hub at `0-1` port 3. When a stalled Wi-Fi build left JTAG at
IDCODE 0 and the FTDI nSRST pulse did not recover it, cycling that hub port
restored M0 OpenOCD attach:

```sh
uhubctl -l 0-1 -p 3 -a cycle -d 3 -e
.venv/bin/python tools/hw_validate.py --list
.venv/bin/python tools/hw_validate.py \
  --preflight --uart /dev/cu.usbmodem13401 --ftdi-reset-sudo
```

Check the hub location and attached devices with plain `uhubctl` before
using this command on another setup. The cycle disconnects both adapters;
rediscover their device paths afterward. The observed result was restored
JTAG access, not proof that the BL808 power rail was cycled. Once JTAG is
back, use `--uart-anchor-reboot --no-jtag-reset` to load the RAM anchor and
restart the flashed image, or run the flash-and-reboot command above. If
both UART anchor and JTAG remain unavailable, neither anchor can issue a
software reset.

The Ox64's 5 V line is wired to the SLogic combo on this hub. A physical
LED check on 2026-11-21 found the Ox64 power LED stayed lit with port 3
disabled on both the USB 2 (`0-1`) and USB 3 (`0-2`) sides. It also stayed
lit while *every* downstream port on both sides was disabled for eight
seconds, including a repeat with the hub's separate PD power supply
unplugged. The downstream adapters re-enumerated afterward, but the upstream
VIA hub retained its macOS session ID. `uhubctl -R` failed to reset that
upstream hub. Treat `uhubctl` here as adapter reconnection, not Ox64 power
cycling. A real power cycle requires interrupting the SLogic 5 V feed or
its upstream supply physically, or adding a verified VBUS switch. Disabling
all hub ports also interrupts the Mac's USB Ethernet adapter on `en9`.

## JTAG Notes

Default OpenOCD is `../openocd-had/src/openocd` when present, otherwise
`openocd` from `PATH`. Default M0 target is `tgt_e907_v2.cfg`; D0 and LP use
their own target configs from `tools/hw_validate.py`.

The default Ox64 J6 JTAG GPIO pins are:

```text
TMS,TDO,TCK,TDI = 6,7,12,13
```

Override with:

```sh
--jtag-gpio-pins 6,7,12,13
```

The harness can switch the BL808 JTAG mux between M0, D0, and LP. For LP work,
expect extra flags such as `--lp-jtag-mode`, `--lp-attach-retries`, or
`--lp-jtag-cjtag-escape`; inspect `tools/hw_validate.py --help` before changing
LP validation flows.

## Debugging Failed Runs

Start with the specific per-test logs in `build/hw-validation/logs`.

Check these in order:

1. The primary UART log for required markers and forbidden strings.
2. The test OpenOCD log for attach, reset, resume, and snapshot output.
3. The target reset log if the run used target nSRST.
4. The UART anchor banner log if anchor flashing failed before ping/read-id.
5. The memory log when `--jtag-memory-log` was used.

Common failures:

- No UART banner: wrong UART port, target did not reset into the flashed image,
  UART pins/baud mismatch, or runtime JTAG held the target unexpectedly.
- Anchor ping fails after banner: stale bytes on UART, wrong ack mode, anchor
  not running, or OpenOCD/JTAG state interfering. Try
  `--uart-anchor-ack-mode uart` when using an existing persistent anchor, or
  keep runtime JTAG for diagnostics.
- OpenOCD cannot attach: reset the FTDI adapter, check permissions, check JTAG
  mux state, then let `prepare_jtag_session_with_recovery` pulse target nSRST.
- UART bootloader handshake fails: hold BOOT, reset or power-cycle, release BOOT,
  then retry `--probe-uart-boot`.

## Compile Checks

For enclave examples, include the enclave define. A plain `nim c` may fail or
compile the wrong surface because this is a bare-metal project.

```sh
make m0 FILE=examples/m0_enclave_abi_test.nim \
  NIM_FLAGS="-d:bl808kernel -d:bl808enclave"

make m0 FILE=examples/m0_enclave_services_test.nim \
  NIM_FLAGS="-d:bl808kernel -d:bl808enclave"
```

For ordinary M0 examples:

```sh
make m0 FILE=examples/m0_cps_test.nim
```

Use `make examples-check` for broad compile coverage, but hardware behavior
still needs `tools/hw_validate.py`.

## Source Ownership Rules

This worktree is often dirty during hardware debugging. Before editing, inspect
the relevant files and do not revert unrelated changes. Keep harness edits
scoped, then run:

```sh
python3 -m pytest tools/test_hw_validate_uart_anchor.py
```

When changing hardware validation behavior, also run a dry run for the affected
CLI path and one real hardware run when the device is available.
