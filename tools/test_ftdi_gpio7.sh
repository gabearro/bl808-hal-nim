#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP_LOG=$(mktemp -t bl808_ftdi_gpio7.XXXXXX)
trap 'rm -f "$TMP_LOG"' EXIT INT TERM
OPENOCD=${OPENOCD:-openocd}
CC_RISCV=${CC_RISCV:-riscv64-unknown-elf-gcc}
CC_HOST=${CC_HOST:-cc}
OBJCOPY=${OBJCOPY:-riscv64-unknown-elf-objcopy}
SAMPLER_DURATION=${SAMPLER_DURATION:-2.0}
M0_INTERFACE=${M0_INTERFACE:-"$ROOT/pine64jtag.cfg"}
M0_TARGET=${M0_TARGET:-"$ROOT/tgt_e907_v2.cfg"}
HELPER_S=${HELPER_S:-"$ROOT/tools/m0_gpio7_toggler.S"}
HELPER_ELF=${HELPER_ELF:-"$ROOT/build/m0_gpio7_toggler.elf"}
HELPER_BIN=${HELPER_BIN:-"$ROOT/build/m0_gpio7_toggler.bin"}
SAMPLER_C=${SAMPLER_C:-"$ROOT/tools/ftdi_sample_adbus2.c"}
SAMPLER_BIN=${SAMPLER_BIN:-"$ROOT/build/ftdi_sample_adbus2"}

run_priv() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}

mkdir -p "$ROOT/build"

echo "Building M0 GPIO7 toggler..."
"$CC_RISCV" \
  -march=rv32imafc \
  -mabi=ilp32f \
  -nostdlib \
  -nostartfiles \
  -Wl,-Ttext=0x22030000 \
  -o "$HELPER_ELF" \
  "$HELPER_S"
"$OBJCOPY" -O binary "$HELPER_ELF" "$HELPER_BIN"

echo "Building FTDI sampler..."
"$CC_HOST" -O2 -Wall -Wextra -o "$SAMPLER_BIN" "$SAMPLER_C" $(pkg-config --cflags --libs libftdi1)

echo "Launching M0 GPIO7 toggler over JTAG..."
set +e
run_priv "$OPENOCD" \
  -f "$M0_INTERFACE" \
  -f "$M0_TARGET" \
  -c "halt" \
  -c "load_image $HELPER_BIN 0x22030000 bin" \
  -c "resume 0x22030000" \
  -c "shutdown" \
  2>&1 | tee "$TMP_LOG"
OPENOCD_STATUS=$?
set -e

if grep -q "bytes written at address 0x22030000" "$TMP_LOG"; then
  :
elif grep -Eq "all zeroes|dtmcontrol is 0|Target not examined yet|unable to open ftdi device|no device found" "$TMP_LOG"; then
  echo ""
  echo "FAIL: M0 JTAG did not come up, so the GPIO toggler never ran."
  echo "This result does not say anything about GPIO6/GPIO7 wiring yet."
  echo "Power cycle the board to restore M0/default JTAG ownership, then rerun this test."
  exit 2
elif [ "$OPENOCD_STATUS" -ne 0 ]; then
  echo ""
  echo "FAIL: OpenOCD exited before confirming the GPIO toggler was loaded."
  echo "Inspect the log above before treating the FTDI sample as meaningful."
  exit 3
fi

if [ "$OPENOCD_STATUS" -ne 0 ]; then
  echo "OpenOCD lost the M0 debug port after resume, which is expected once GPIO6/GPIO7 stop being JTAG."
fi

sleep 1

echo "Sampling FTDI ADBUS2/ADBUS3 for BL808 GPIO7/GPIO6 activity..."
run_priv "$SAMPLER_BIN" "$SAMPLER_DURATION"
