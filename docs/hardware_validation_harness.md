# BL808 Hardware Validation Harness

`tools/hw_validate.py` runs the HAL/kernel examples on a physical BL808 board
with both connected debug paths:

- UART boot/log path: flashes firmware with `tools/upload.sh` when requested,
  then captures runtime console output and sends scripted UART input when a
  test needs it.
- JTAG path: starts or attaches to OpenOCD, resets and resumes the target, and
  captures register/memory snapshots on failures. With `--jtag-flash`, it also
  programs external SPI flash through a RAM-resident M0 flash stub, so the BL808
  BOOT strap does not need to be asserted.
- M0 UART anchor path: loads a RAM-resident M0 flash anchor over JTAG, then
  streams persistent SPI flash writes over the normal UART pins. If that anchor
  is already running, `--uart-anchor-existing` can reuse it without JTAG.

The default JTAG target is M0/E907 through `pine64jtag.cfg` and
`tgt_e907_v2.cfg`. Cross-core tests still run D0/LP firmware; M0 JTAG is used
as the board-level reset/debug anchor while UART output proves runtime behavior.
When `../openocd-had/src/openocd` is present, the harness uses that patched
OpenOCD build for all cores because it recovers more cleanly from the BL808
RISC-V debug-module states than stock OpenOCD.

## Quick Start

List tests and detected serial ports:

```sh
make hw-list
```

Check the local UART/JTAG setup without flashing firmware:

```sh
make hw-preflight UART_PORT=/dev/cu.usbserial-XXXX
```

Preflight verifies tool availability, UART open, FTDI software reset, OpenOCD
attach, and JTAG mux access. It halts only long enough to program/check the
mux, resumes the target before exiting, and intentionally does not issue the
full SRST-based `reset halt` used by default hardware tests.

Run the smoke suite:

```sh
.venv/bin/python tools/hw_validate.py --tier smoke \
  --jtag-flash \
  --uart /dev/cu.usbserial-XXXX
```

Equivalent make target:

```sh
make hw-smoke UART_PORT=/dev/cu.usbserial-XXXX
```

The make targets create/update `.venv` from `requirements-hw.txt` before they
run the harness. That venv provides both `pyserial` for UART capture and
`bflb-iot-tool` for `tools/upload.sh`. To set it up explicitly:

```sh
make venv
```

The default UART and flash baud is `230400`. The harness also passes that value
into validation firmware with `-d:ConsoleBaud=<baud>` so runtime log capture and
firmware output stay aligned. Override with `UART_BAUD=<baud>` and
`FLASH_BAUD=<baud>` if the adapter/board setup changes.
`tools/upload.sh` uses the documented Ox64 `bflb-iot-tool` UART path with
single-image download mode for each core image. Before invoking
`bflb-iot-tool`, it also forces the BL808 eflash config to use the requested
baud for both the boot-ROM handshake and loader transfer, and disables the
tool's RTS/DTR reset/cutoff toggling so the manual BOOT sequence is not
disturbed.

The default make targets use `--jtag-flash`, so the board can stay in normal
boot mode. The harness resets the FTDI adapter, controls the JTAG mux, and
programs persistent flash through the M0 JTAG path.

Some BLE/WiFi tests set `jtag_flash_reset_capture` so the flashed image starts
from a fresh target reset before UART and host capture. Runtime JTAG stays
enabled by default in that mode, so a failing run still gets the post-run
register and symbol snapshot. If a specific test truly needs to isolate the
UART/host run from OpenOCD, set `jtag_flash_runtime_jtag: false` in that manifest
entry; `--jtag-flash-runtime-jtag` is still accepted as an explicit compatibility
flag.

## macOS BLE Host Actions

BLE connect/advertise validations that involve the Mac use the native
CoreBluetooth helper built by `tools/run_macos_ble_helper.py`. The helper app
is generated at:

```sh
~/Library/Application Support/bl808-hal/MacOSBLEHelper.app
```

The hardware harness launches this app through LaunchServices so macOS
Bluetooth privacy authorization is attached to the app bundle, not to Python or
the shell. Before running BLE host-action tests, verify permission with:

```sh
.venv/bin/python tools/run_macos_ble_helper.py permission --debug
```

If this reports `authorization=notDetermined`, `denied`, or no central state,
open System Settings > Privacy & Security > Bluetooth and enable
MacOSBLEHelper. Until CoreBluetooth reports the helper as powered on, BLE tests
can still prove board-side advertising/scanning over UART/JTAG, but Mac-to-board
connect validation is blocked on macOS rather than firmware.

The preferred anchor path loads a temporary M0 flash anchor over JTAG, programs
the new image through UART, then pulses target nSRST before runtime capture:

```sh
.venv/bin/python tools/hw_validate.py --test m0_wifi_hal_test \
  --uart-anchor-flash \
  --uart /dev/cu.usbserial-XXXX
```

If an M0 UART flash anchor is already running on the board, the harness can
program a new image through UART and ask the anchor to reboot into it, without
entering UART boot mode or using runtime JTAG:

```sh
.venv/bin/python tools/hw_validate.py --test m0_wifi_hal_test \
  --uart-anchor-flash \
  --uart-anchor-existing \
  --uart-anchor-reset-after-flash \
  --no-jtag \
  --uart /dev/cu.usbserial-XXXX
```

This path still requires a live anchor. If neither JTAG nor an existing anchor
is reachable, the board must be put into UART boot once to restore a runnable
image or anchor.

For the explicit UART-flash fallback path, put the board into UART boot mode
before the flash step. The harness does not drive the BL808 BOOT strap.

Use the Ox64 UART0 pins for flashing/runtime M0 logs:

| USB-UART adapter | Ox64 |
| --- | --- |
| TXD | GPIO15 / UART0_RX / physical pin 2 |
| RXD | GPIO14 / UART0_TX / physical pin 1 |
| GND | GND, for example physical pin 38 |

Use 3.3 V UART logic. Do not connect a 5 V UART signal to the Ox64, and
normally leave the adapter VCC pin disconnected when the board is powered
separately.

1. Press and hold BOOT.
2. Reset or power-cycle the board with BOOT still held.
3. Release BOOT after power-up.
4. Let the harness flash the image.

Use `--manual-boot-reset` if you want the harness to pause before each flash
and prompt for this sequence.

The UART bootloader fallback is also available through:

```sh
make hw-smoke-uart UART_PORT=/dev/cu.usbserial-XXXX
```

If flashing still fails with `BFLB IMG LOAD HANDSHAKE FAIL` after the BOOT
sequence, retry with a slower flash baud before changing anything else:

```sh
.venv/bin/python tools/hw_validate.py --test m0_cps_test \
  --manual-boot-reset \
  --manual-target-reset \
  --flash-baud 115200 \
  --uart /dev/cu.usbserial-XXXX \
  --flash-port /dev/cu.usbserial-XXXX
```

To check whether the board is actually in BL808 UART boot mode before building
or flashing an image, use the bootloader probe:

```sh
.venv/bin/python tools/hw_validate.py --probe-uart-boot \
  --uart /dev/cu.usbserial-XXXX
```

Some CH340/CH340G UART adapters are unreliable with the Ox64 bootloader even
when normal serial logging works. In that case, switch to a known-good 3.3 V
UART bridge such as a CP2102, suitable FT232H, or Pico-based dual-UART setup.

After flashing, the harness opens the runtime UART, starts OpenOCD, resets and
halts the target before programming the BL808 JTAG GPIO mux, then resumes the
target and waits for the required UART markers. The reset is intentionally
performed before mux programming because a later SRST can clear the GPIO mux
and disconnect JTAG on the Ox64.
When the runtime UART is opened, DTR and RTS are deasserted by default so a
USB-UART adapter wired to BOOT or RESET does not unexpectedly hold the board in
bootloader/reset state. Override this only for adapters that need a different
state:

```sh
.venv/bin/python tools/hw_validate.py --test m0_cps_test \
  --uart /dev/cu.usbserial-XXXX \
  --serial-dtr unchanged --serial-rts unchanged
```

Before each OpenOCD attach, the harness attempts to build and run
`tools/ftdi_reset.c` so the FTDI adapter is USB-reset from software. The reset
is non-fatal by default; add `--ftdi-reset-required` if a failed reset should
fail the run or preflight. If your OS requires elevated USB access, use
`--ftdi-reset-sudo`, which runs `sudo -n` and will fail instead of prompting.
OpenOCD has the same option:

```sh
sudo -v
make hw-preflight UART_PORT=/dev/cu.usbserial-XXXX \
  HW_VALIDATE_FLAGS="--openocd-sudo --ftdi-reset-sudo"
```

On macOS, the harness can prompt through an AppleScript askpass helper instead
of requiring a prior `sudo -v`:

```sh
make hw-preflight UART_PORT=/dev/cu.usbserial-XXXX \
  HW_VALIDATE_FLAGS="--openocd-sudo --ftdi-reset-sudo --sudo-askpass"
```

If the askpass dialog does not appear or `FTDI reset/open` times out, refresh
sudo credentials in a terminal and rerun without relying on the GUI prompt:

```sh
sudo -v
make hw-preflight UART_PORT=/dev/cu.usbserial-XXXX \
  HW_VALIDATE_FLAGS="--openocd-sudo --ftdi-reset-sudo"
```

The harness also programs the BL808 JTAG GPIO mux. By default it keeps the mux
on M0/E907, which is the board-level debug anchor used by the validation suite.
To switch OpenOCD to another core for a focused debug run:

```sh
.venv/bin/python tools/hw_validate.py --test d0_kernel_test \
  --jtag-core d0 \
  --uart /dev/cu.usbserial-m0 \
  --secondary-uart /dev/cu.usbserial-d0
```

Use `--no-jtag-mux` or `--no-ftdi-reset` to disable those recovery steps.

If preflight reports `JTAG scan chain interrogation failed: all ones`,
`JTAG scan chain interrogation failed: all zeroes`, or `Target not examined
yet`, OpenOCD can see the FTDI adapter but not the BL808 TAP. The harness may
still successfully reset the FTDI adapter in software; that is a USB adapter
reset, not a deliberate target reset. For M0 attach recovery, the harness now
pulses nSRST with a direct libftdi helper so the reset does not depend on a
working OpenOCD JTAG scan. To run that target reset by hand:

```sh
build/ftdi_srst_pulse 0x0403 0x6014
```

Then rerun `make hw-preflight` and check target power plus the
GPIO6/GPIO7/GPIO12/GPIO13 wiring if M0 still does not attach.

## Useful Modes

Build without touching hardware:

```sh
.venv/bin/python tools/hw_validate.py --test m0_cps_test --build-only
```

Run a currently flashed image without reflashing:

```sh
.venv/bin/python tools/hw_validate.py --test m0_cps_test --no-flash \
  --uart /dev/cu.usbserial-XXXX
```

Program persistent SPI flash over JTAG instead of using UART boot mode:

```sh
.venv/bin/python tools/hw_validate.py --test m0_cps_test --jtag-flash \
  --uart /dev/cu.usbserial-XXXX
```

`--jtag-flash` builds the same boot2/partition/M0 firmware image used by the
UART flashing path, then loads a small M0 RAM stub over OpenOCD to erase,
program, and verify flash. Multi-core tests additionally program LP at
`0x091000` and D0 at `0x100000`. UART is still used for runtime logs after the
JTAG flash step completes. The stub only drives the SPI flash controller; it
does not access eFuse.

Program persistent flash through the M0 UART flash anchor:

```sh
.venv/bin/python tools/hw_validate.py --test m0_cps_test --uart-anchor-flash \
  --uart /dev/cu.usbserial-XXXX
```

Without `--uart-anchor-existing`, the harness first uses JTAG to reset-halt M0,
load `tools/uart_flash_anchor.c` into WRAM, and start it. The anchor receives
flash commands on UART0 and erases/programs/verifies SPI flash. By default the
harness opens the runtime UART and pulses target nSRST before capture, which is
the most reliable path when the FTDI reset line is available. Use
`--uart-anchor-reset-after-flash` only when you intentionally want the anchor to
request a chip reboot instead of relying on nSRST.

When a previously flashed anchor is already running, skip the JTAG load step:

```sh
.venv/bin/python tools/hw_validate.py --test m0_cps_test --uart-anchor-flash \
  --uart-anchor-existing \
  --uart-anchor-reset-after-flash \
  --no-jtag \
  --uart /dev/cu.usbserial-XXXX
```

`--uart-anchor-existing` uses UART acknowledgements only. It cannot recover if
the current image is not the anchor; in that case use JTAG or the manual UART
boot fallback to restore the anchor.

Build a persistent anchor recovery image without touching hardware:

```sh
.venv/bin/python tools/hw_validate.py --uart-anchor-build-only \
  --work-dir build/uart-anchor-recovery
```

The command writes the raw anchor firmware and a compact `whole_flash_data.bin`
containing boot2, partition tables, and the anchor firmware. The raw anchor can
be installed once with `tools/upload.sh m0 ...` from UART boot mode; the compact
image can be replayed later with `--uart-anchor-flash-image` if an anchor is
already live. The adjacent `recovery_manifest.json` records the anchor SHA256,
the compact image SHA256, each flash segment, and the exact flash offset where
the wrapped anchor payload appears.

Avoid the UART bootloader and BOOT button by loading validation images into RAM
over JTAG:

```sh
.venv/bin/python tools/hw_validate.py --tier smoke --jtag-load \
  --uart /dev/cu.usbserial-XXXX
```

Equivalent make target:

```sh
make hw-smoke-jtag UART_PORT=/dev/cu.usbserial-XXXX
```

This is a RAM-load path, not persistent external flash programming. It is meant
for validation loops where avoiding the manual BOOT strap matters more than
leaving firmware installed after power-off.

For the all-core case, run it after the M0-only checks so LP behavior is
validated last:

```sh
make hw-allcore-jtag UART_PORT=/dev/cu.usbserial-XXXX
```

In `--jtag-load` all-core mode, the harness first writes the LP image into the
reserved LP WRAM window through M0 JTAG, then starts M0. M0 releases LP from
that RAM address, switches the JTAG mux to D0, and the harness loads/resumes D0
over D0 JTAG. The test then verifies D0 RPC, LP RPC, and LP heartbeat over the
runtime UART.

If OpenOCD SRST disrupts the Ox64 JTAG chain, skip SRST while still using JTAG
for halt/mux/resume control:

```sh
.venv/bin/python tools/hw_validate.py --test m0_cps_test --no-flash \
  --no-jtag-reset \
  --uart /dev/cu.usbserial-XXXX
```

For a flashed-image run on an Ox64 where SRST disconnects JTAG, let the harness
open UART first, then manually reset or power-cycle the board with BOOT
released when prompted:

```sh
.venv/bin/python tools/hw_validate.py --test m0_cps_test \
  --manual-boot-reset \
  --manual-target-reset \
  --uart /dev/cu.usbserial-XXXX \
  --flash-port /dev/cu.usbserial-XXXX
```

`--manual-target-reset` implies `--no-jtag-reset`; the harness still uses the
FTDI software reset before OpenOCD attach.

Isolate UART flashing/runtime without OpenOCD:

```sh
.venv/bin/python tools/hw_validate.py --test m0_cps_test --no-jtag \
  --uart /dev/cu.usbserial-XXXX
```

`--no-jtag` is a diagnostic mode. A passing run with that flag does not count
as full hardware validation because the harness cannot reset the target or take
JTAG failure snapshots.

Use an existing OpenOCD instance:

```sh
.venv/bin/python tools/hw_validate.py --test m0_cps_test --attach-openocd \
  --uart /dev/cu.usbserial-XXXX
```

`--attach-openocd` does not reset the FTDI adapter. It also cannot switch to a
different JTAG target config; omit it when using `--jtag-core d0` or
`--jtag-core lp` so the harness can restart OpenOCD after programming the mux.

Attach to LP/E902 JTAG:

```sh
.venv/bin/python tools/hw_validate.py --preflight --jtag-core lp \
  --jtag-mux-bootstrap-core m0 \
  --uart /dev/cu.usbserial-XXXX
```

LP attach prefers the patched `../openocd-had/src/openocd` build when it is
available because stock OpenOCD does not reliably recover the BL808 LP RVDM
path. The E902 IP supports standard five-wire JTAG, but that only proves the
CPU macrocell can speak JTAG. The public BL808 datasheet and reference manual
pin tables list GPIO6/GPIO12/GPIO7/GPIO13 as M0 JTAG function 26 and D0 JTAG
function 27; they do not list an LP JTAG pad function. The Bouffalo SDK headers
do define function 25 as `GPIO_FUN_JTAG_LP`, so the harness can still try that
route, but current Ox64 evidence says it is not a proven external TAP.

The attempted LP path is GPIO6=TMS, GPIO12=TCK, GPIO7=TDO, GPIO13=TDI with
function 25. It uses the slow Pine64 FTDI interface and the observed Ox64 TAP
ID `0x10000b6f`, then verifies that the attached core reports an RV32E-style
`misa`. This matters because a marginal LP attempt can otherwise appear to
attach while actually talking to the M0/E907 path. A no-expected-IDCODE scan
can sometimes reach a RISC-V debug module with `misa=0x40909125`; that is the
M0/E907 identity, not LP/E902.

By default the harness programs the Ox64 J6 pin map in signal order
`TMS,TDO,TCK,TDI`:

```sh
--jtag-gpio-pins 6,7,12,13
```

The LP core can perform the same reversible pad-mux writes itself once M0 has
released it. `lp_jtag_enable_test` loads a small LP WRAM program that records
XRAM diagnostics, writes `GLB_PARM_CFG0`, programs the selected GPIO config
registers to function 25, and then spins. These are GLB/GPIO MMIO writes, not
E902 core-local CSRs and not EFUSE writes. The harness passes
`--jtag-gpio-pins` and `--lp-jtag-p7-io2-5 set` into the LP image at build time,
so the same test can exercise either the J6 route or an alternate physically
wired pin route:

```sh
.venv/bin/python tools/hw_validate.py --test lp_jtag_enable_test --jtag-load \
  --jtag-gpio-pins 2,3,4,5 \
  --lp-jtag-p7-io2-5 set \
  --uart /dev/cu.usbserial-XXXX
```

On the tested J6 route, the LP program ran and read back function-25 GPIO config
on GPIO6/7/12/13, but direct LP OpenOCD attach still saw all-ones scan data.
Use the tap-only DTMCS probe when separating scan-chain visibility from RISC-V
DM attach:

```sh
.venv/bin/python tools/hw_validate.py --lp-dtmcs-probe \
  --uart /dev/cu.usbserial-XXXX
```

This path generates `build/hw-validation/lp-dtmcs-probe.cfg`, switches the JTAG
mux through the normal harness bootstrap when possible, then scans IDCODE,
DTMCS, DMI, and all 5-bit IR values without creating an OpenOCD `riscv` target.
That is deliberate: the normal target config immediately examines DTMCS and
exits before we can capture the raw sweep. The result classifications are:

- `LP TAP visible as 0x18005b31, but DTMCS is all ones`: the TAP is visible, but
  the RISC-V DTM is not selected or not driving TDO. This is the likely
  CKLink/XuanTie port-detect gap.
- `LP tap-only scan returned all ones before IDCODE`: the selected chain is not
  driving TDO at all, usually stale mux/adapter/target-reset state.

On the June 24, 2026 live run, an FTDI nSRST pulse and adapter USB reset both
succeeded without sudo, but M0 preflight still could not recover the default M0
TAP from the post-LP state; the next scan returned all ones. Treat that as a
board reset/power-state boundary before continuing LP DTMCS work.

To confirm LP-visible register state without switching the JTAG mux, use the
IPC register probe. M0 stays as the OpenOCD debug anchor, releases a small LP
WRAM RPC server, then asks LP to read selected GLB/PDS/GPIO/security registers.
This is read-only apart from normal RAM diagnostics and does not touch EFUSE
programming paths:

```sh
.venv/bin/python tools/hw_validate.py --test lp_ipc_reg_probe_test --jtag-load \
  --uart /dev/cu.usbserial-XXXX
```

On the tested Ox64, the probe showed LP was genuinely answering RPC calls:
`CORE_ID` read as `0xE9070000` from M0 and `0xDEADE902` from LP, while
`GLB_PARM_CFG0`, the relevant GPIO config registers, `SEC_DBG_STATUS`, and
`EF_CFG0` matched between cores.

The BL808 reference material agrees with the current target-side register
coverage. The public BL808 reference manual GPIO function list includes
functions 24, 26, and 27 as DPI, M0_JTAG, and D0_JTAG, but omits function 25.
The BL808 SDK still names GPIO function 25 as `GPIO_FUN_JTAG_LP` and names
`GLB_PARM_CFG0.P7_JTAG_USE_IO_2_5`, but it does not define the BL616D-only
`GLB_E902_JTAG_SEL` or `GLB_WL_JTG_CHAIN` fields. Those BL616D bits remain
probe-only experiments on BL808, not documented BL808 routes.

For LP JTAG experiments with alternate wiring, the same mux switch can program a
different physical set of GPIOs. The strongest BL808-specific route hint is
`GLB_PARM_CFG0.P7_JTAG_USE_IO_2_5`. On the Ox64 production schematic, GPIO2-5
are SD-card nets (`GPIO2/SDH_DAT0`, `GPIO3/SDH_DAT1`, `GPIO4/SDH_DAT2`,
`GPIO5/SDH_DAT3`), not the separate J6 JTAG header. Testing that route requires
moving the FTDI signals to those SD-card nets and leaving the microSD path
unused during the experiment:

- FTDI TMS -> GPIO2 / SDH_DAT0
- FTDI TDO <- GPIO3 / SDH_DAT1
- FTDI TCK -> GPIO4 / SDH_DAT2
- FTDI TDI -> GPIO5 / SDH_DAT3

```sh
.venv/bin/python tools/hw_validate.py --preflight --preflight-reset-target \
  --jtag-core lp --jtag-mux-bootstrap-core m0 \
  --jtag-gpio-pins 2,3,4,5 \
  --lp-jtag-p7-io2-5 set \
  --uart /dev/cu.usbserial-XXXX
```

The `--jtag-gpio-pins` value is always `TMS,TDO,TCK,TDI`. The BL808 datasheet
shows the same signal order on GPIO2-5 for the public M0/D0 JTAG functions:
GPIO2=TMS, GPIO3=TDO, GPIO4=TCK, GPIO5=TDI. The OpenOCD FTDI driver still uses
the adapter's fixed MPSSE JTAG pins, so this option only works when the physical
wires match the selected BL808 GPIOs. BL808's public pin tables do not show the
LP function-25 names directly.

The LP WRAM helper can verify this alternate route register without moving the
FTDI wires. With `--jtag-gpio-pins 2,3,4,5 --lp-jtag-p7-io2-5 set`, LP reported
`lp_parm_requested=0x00800980` and `lp_parm_after=0x00800900`: bit 23
(`P7_JTAG_USE_IO_2_5`) is writable on the tested BL808, while the unrelated
BL616D-style bit 7 still reads back as zero. The harness keeps the M0 JTAG-load
anchor on the normal Ox64 J6 pins for this test; the alternate GPIO list is
only compiled into the LP helper and used by LP's own mux writes.

A dry-run of the physical GPIO2-5 attach command generated
`build/lp-jtag-io2-5-dryrun-corrected/jtag-switch/m0-to-lp-preserve.S`. The
stub sets `P7_JTAG_USE_IO_2_5` and programs GPIO2=TMS, GPIO3=TDO, GPIO4=TCK,
GPIO5=TDI to function 25. The remaining untested part is the actual physical
FTDI wiring to the SDH_DAT0-3 nets.

BL616D documents two GLB route bits in the same `GLB_PARM_CFG0` register:
`GLB_WL_JTG_CHAIN` at bit 6 and `GLB_E902_JTAG_SEL` at bit 7. BL808 leaves
those bit positions unnamed, so the harness exposes them only as explicit
experiments:

```sh
--lp-jtag-wl-chain set
--lp-jtag-e902-sel set
```

These are normal GLB register writes, not EFUSE writes, and they are cleared by
target reset. On the tested Ox64 J6 path, bit 7 alone, bit 6 alone, and both
bits together still produced the same invalid LP scan (`idcode=0x0` and
`dtmcontrol is 0`), so they are not enough to make LP JTAG appear on the current
header wiring. A follow-up M0-only readback test, leaving the pads on the
working M0 JTAG function, read `GLB_PARM_CFG0=0x00000900`; after writing
`0x000009c0`, it still read `0x00000900`. On this BL808, bits 6 and 7 behave as
reserved/readback-zero bits, matching the BL808 register header rather than the
BL616D register layout.

The GPIO mux values intentionally mirror the boot ROM's working JTAG pad
configuration: function select plus input-enable, Schmitt trigger, and
interrupt-mask bits. Do not set the GPIO output-enable bit on GPIO7/TDO; the
JTAG peripheral drives TDO itself. The SDK's fuller alternate-function pad
configuration was also tested and did not change the LP result, so the failure
does not appear to be weak pad drive or missing pull-up configuration. The LP
FTDI interface leaves nSRST tri-stated so starting LP OpenOCD should not reset
the chip back to the default M0 mux. After an LP mux switch, the harness also
skips the FTDI USB reset before starting LP OpenOCD; that keeps the failure on
the real LP handoff state instead of accidentally restoring M0 first.

Preflight and `--no-jtag-reset` use a preserve-mode mux handoff: M0 only
switches GPIO6/7/12/13 to LP JTAG and does not reset or overwrite the running
LP firmware. If M0 is no longer examinable, the preserve path now falls back to
a direct LP attach in case a previous attempt already moved the pads to LP. If
both M0 and direct LP attach report floating, all-zero, or shifted IDCODEs,
power-cycle or reset the board with BOOT released to return to the boot-time
M0 JTAG mux before retrying.

The harness treats startup scan errors as hard attach failures. OpenOCD can log
messages such as `does not have valid IDCODE`, `IR capture error`, or
`Bypassing JTAG setup events due to errors` and then continue with a partially
examined target; the harness rejects that state before issuing `halt`, `reg`, or
memory commands.

For a more deterministic transport-only check, allow preflight to reset/release
LP into a tiny WRAM spin loop before switching the mux:

```sh
.venv/bin/python tools/hw_validate.py --preflight --preflight-reset-target \
  --jtag-core lp --jtag-mux-bootstrap-core m0 \
  --uart /dev/cu.usbserial-XXXX
```

That mode is the most deterministic LP debug-transport check, but it does not
preserve the currently running LP firmware. On the Ox64 + Pine64 FTDI adapter,
the current evidence is still that LP firmware boots and runs, while true LP
debug attach is not proven. The E902 manual says the core supports five-wire
JTAG and two-wire cJTAG; the Ox64 board-level JTAG header exposes the four
standard JTAG data/control pins, while reset is the board reset line rather than
a separate LP-only TRST pin. The BL808 datasheet's pin tables also omit LP JTAG
while listing M0/D0 JTAG on these same pads. Manual mux experiments showed these
failure modes:

- If the FTDI USB reset/reopen path is used after switching to LP, OpenOCD can
  examine a target but reading `0x200008dc`/`0x200008e0`/`0x200008f4` shows
  `0x00401a03`, meaning GPIO6/GPIO7/GPIO12 are back on M0 JTAG func_sel 26.
- If FTDI USB reset is skipped after the mux switch, the default M0 path no
  longer attaches cleanly, but LP OpenOCD sees shifted/all-zero scan data and
  cannot examine the target.
- Slowing TCK to 1 kHz and sampling TDO on the falling edge changes the garbage
  pattern but still does not produce a valid LP IDCODE or DTMCS read.
- A read-only EFUSE debug-state check over working M0 JTAG read
  `EF_IF_CFG_0=0x00000000` and `EF_SW_CFG_0=0x00000000`, so the visible debug
  disable bits are not set on the tested Ox64. No EFUSE programming or EFUSE
  writes were used for this check.
- BL616D-style chain route probes on BL808 `GLB_PARM_CFG0` bits 6 and 7 were
  tested on Ox64 J6. `--lp-jtag-e902-sel set`, `--lp-jtag-wl-chain set`, and
  both together all still failed with `idcode=0x0`. Keeping the pins on M0 JTAG
  and attempting to set both bits also failed readback (`0x00000900` remained
  `0x00000900` after writing `0x000009c0`), so these BL616D bits should not be
  treated as a BL808 LP JTAG route.
- BL808's SDK register map does not define the older BL602/BL702
  `GLB_JTAG_SWAP_SET` field; the BL808 SDK header only defines
  `JTAG_SIG_SWAP_NONE`. On the Ox64 J6 wiring, setting BL808's named
  `GLB_PARM_CFG0` JTAG-test bits also did not expose LP JTAG:
  `--lp-jtag-p4-adc-test set`, `--lp-jtag-p5-dac-test set`, and both together
  all failed with `idcode=0x0`.
- Clocking the older broad cJTAG/JTAG escape sequence after moving J6 to
  function 25 failed with `idcode=0x0`. Combining that escape with the SDK-style
  pull-up/drive pad config did not reach a stable OpenOCD scan either; the FTDI
  MPSSE queue stalled before telnet came up. A target reset restored normal M0
  JTAG afterward.
- Clocking the exact CKLink `link_config(0x18, 0)` sequence recovered from
  `libCklink.so`
  (`--lp-jtag-cjtag-escape --lp-jtag-cjtag-sequence cklink`) also failed on J6.
  It changed the scan signature to `idcode=0x06fa00fa`, auto-detected shifted
  values `0x037d007d`/`0xffff807d`, and `Unsupported DTM version: 15`. That looks
  like a cJTAG/probe-mode mismatch rather than a valid LP RVDM attach through
  FTDI/OpenOCD's normal 5-wire path.
- The BL808 SDK's `CORE_M0_JTAG_TCK_PIN`/`CORE_M0_JTAG_TMS_PIN` constants refer
  to GPIO27/GPIO28 with `GPIO_FUN_M_CJTAG`. That is a separate M0 two-wire
  cJTAG path, not evidence that LP/E902 is routed to the Ox64 J6 four-wire
  JTAG header.
- Pre-bringing D0/C906 before releasing LP and moving J6 to function 25
  (`--lp-jtag-prebring-d0`) still failed with `idcode=0x0`, so the J6 LP scan
  failure is not explained by missing D0/MM-side bring-up alone.
- Standard RISC-V DM hart selection through the working M0 DTM was probed after
  an FTDI nSRST pulse. The visible DTM examined only M0 (`misa=0x40909125`).
  `riscv dmi_write 0x10 0x00010001` and `riscv dmi_write 0x10 0x00020001`
  both read back `DMCONTROL=0x1` with unchanged `DMSTATUS=0x4303a2`, so LP is
  not selectable as hart 1 or hart 2 behind the currently visible M0 DTM.
- Standard RISC-V DM hart selection through the working D0 DTM also exposed only
  the C906 hart (`misa=0x8000000000b4112d`). Hartsel writes for harts 1, 2, and
  3 read back `DMCONTROL=0x1`, and hasel probes read back only the `hasel` bit
  with unchanged `DMSTATUS=0x430ca2`. OpenOCD with `BL808_LP_HARTID=1` failed
  with `dmcontrol read back hart 0`, so LP is not visible as a D0 hart either.
- The E902 manual describes standard RISC-V Debug 0.13.2 over 5-wire JTAG or
  2-wire cJTAG, including XuanTie DMI extension registers at `0x70..0x7f`.
  It does not describe the older OpenE902 raw-HAD register protocol used by the
  experimental `thead_had` transport, so raw-HAD failures should not be treated
  as strong evidence against the standard RVDM route.
- The local OpenOCD build lists `jtag`, `thead_had`, `swd`, and related adapter
  transports, but not a generic FTDI `cjtag` transport. The existing
  `thead_had` FTDI code is a T-Head JTAG2/HAD implementation, not an E902
  standard RISC-V-DM-over-cJTAG implementation. This leaves a gap between the
  CKLink port-mode behavior and what FTDI/OpenOCD can currently drive.

The patched OpenOCD can issue E902's XuanTie asynchronous debug request when
`BL808_XUANTIE_ASYNC_HALT=1`, but hart selection still reads back hart 0 when
probing `BL808_LP_HARTID=1`, matching the vendor CKLink notes that a proprietary
per-CPU or port-mode selection step may be missing. The raw-HAD diagnostic path
currently fails the same state with `Invalid HAD ID 0xffffffff`. Treat LP
OpenOCD attach as experimental until a real RV32E `misa` is observed through
either the function-25 RVDM path or another documented BL808 LP debug route.

Capture D0 UART output for D0-only tests:

```sh
.venv/bin/python tools/hw_validate.py --test d0_kernel_test \
  --uart /dev/cu.usbserial-m0 \
  --secondary-uart /dev/cu.usbserial-d0
```

## Outputs

All artifacts are written under `build/hw-validation/`:

- `bin/<test>/`: built ELF and binary images.
- `logs/*.build.log`: Nim build output.
- `logs/*.flash.log`: UART bootloader flashing output.
- `logs/*.primary.uart.log`: primary runtime UART capture.
- `logs/*.secondary.uart.log`: optional secondary UART capture.
- `logs/*.openocd.log`: OpenOCD transcript and JTAG snapshots.
- `jtag-flash/<test>/`: generated `--jtag-flash` whole-flash images, chunk
  staging files, and the M0 flash stub ELF.
- `logs/*.dry-run.log`: dry-run command transcript. Dry-runs do not overwrite
  logs from real hardware attempts.

On a timeout or forbidden marker, the harness halts the core and runs the
test's `jtag_snapshot` commands from `tools/hardware_validation.json`.
