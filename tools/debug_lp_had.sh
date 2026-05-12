#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP_LOG=$(mktemp -t bl808_lp_had.XXXXXX)
trap 'rm -f "$TMP_LOG"' EXIT INT TERM

OPENOCD=${OPENOCD:-openocd}
M0_INTERFACE=${M0_INTERFACE:-"$ROOT/pine64jtag.cfg"}
M0_TARGET=${M0_TARGET:-"$ROOT/tgt_e907_v2.cfg"}
CC=${CC:-riscv64-unknown-elf-gcc}
OBJCOPY=${OBJCOPY:-riscv64-unknown-elf-objcopy}
LP_SOURCE=${LP_SOURCE:-"$ROOT/tools/lp_had_probe.S"}
LP_ELF=${LP_ELF:-"$ROOT/build/lp_had_probe.elf"}
LP_BIN=${LP_BIN:-"$ROOT/build/lp_had_probe.bin"}
M0_HELPER_SOURCE=${M0_HELPER_SOURCE:-"$ROOT/tools/m0_lp_probe_launcher.S"}
M0_HELPER_ELF=${M0_HELPER_ELF:-"$ROOT/build/m0_lp_probe_launcher.elf"}
M0_HELPER_BIN=${M0_HELPER_BIN:-"$ROOT/build/m0_lp_probe_launcher.bin"}
LP_PROBE_LOAD_ADDR=${LP_PROBE_LOAD_ADDR:-0x22050000}

PROBE_STATUS_ADDR=0x40003F00
PROBE_HEARTBEAT_ADDR=0x40003F04
PROBE_STAGE_ADDR=0x40003F08
PROBE_ALIVE_MARKER=48414432

HELPER_MARKER_ADDR=0x2203FFE0
HELPER_STAGE_ADDR=0x2203FFE4
HELPER_LP_STATUS_ADDR=0x2203FFE8
HELPER_LP_HEARTBEAT_ADDR=0x2203FFEC
HELPER_LP_STAGE_ADDR=0x2203FFF0
HELPER_MARKER=4d304c50

GPIO6_CFG=0x200008DC
GPIO7_CFG=0x200008E0
GPIO12_CFG=0x200008F4
GPIO13_CFG=0x200008F8

MM_PWR_CFG=0x2000E010
LP_BOOT_ADDR=0x2000E144
LP_RESET_CFG=0x20000548
LP_CLK_CFG=0x2000E110

if [ ! -x "$(command -v "$OPENOCD")" ]; then
  echo "error: OPENOCD='$OPENOCD' not found in PATH" >&2
  exit 1
fi

if [ ! -x "$(command -v "$CC")" ]; then
  echo "error: CC='$CC' not found in PATH" >&2
  exit 1
fi

if [ ! -x "$(command -v "$OBJCOPY")" ]; then
  echo "error: OBJCOPY='$OBJCOPY' not found in PATH" >&2
  exit 1
fi

mkdir -p "$ROOT/build"

echo "Building LP HAD probe firmware..."
"$CC" \
  -march=rv32imac_zicsr \
  -mabi=ilp32 \
  -nostdlib \
  -nostartfiles \
  -Wl,-Ttext="$LP_PROBE_LOAD_ADDR" \
  -o "$LP_ELF" \
  "$LP_SOURCE"
"$OBJCOPY" -O binary "$LP_ELF" "$LP_BIN"

echo "Building M0 LP launch helper..."
"$CC" \
  -march=rv32imafc \
  -mabi=ilp32f \
  -nostdlib \
  -nostartfiles \
  -Wl,-Ttext=0x22030000 \
  -o "$M0_HELPER_ELF" \
  "$M0_HELPER_SOURCE"
"$OBJCOPY" -O binary "$M0_HELPER_ELF" "$M0_HELPER_BIN"

echo "Running LP preflight over M0 JTAG..."
"$OPENOCD" \
  -f "$M0_INTERFACE" \
  -f "$M0_TARGET" \
  -c "halt" \
  -c "mww $PROBE_STATUS_ADDR 0x00000000" \
  -c "mww $PROBE_HEARTBEAT_ADDR 0x00000000" \
  -c "mww $PROBE_STAGE_ADDR 0x00000000" \
  -c "mww $HELPER_MARKER_ADDR 0x00000000" \
  -c "mww $HELPER_STAGE_ADDR 0x00000000" \
  -c "mww $HELPER_LP_STATUS_ADDR 0x00000000" \
  -c "mww $HELPER_LP_HEARTBEAT_ADDR 0x00000000" \
  -c "mww $HELPER_LP_STAGE_ADDR 0x00000000" \
  -c "load_image $LP_BIN $LP_PROBE_LOAD_ADDR bin" \
  -c "mdw $LP_PROBE_LOAD_ADDR 4" \
  -c "load_image $M0_HELPER_BIN 0x22030000 bin" \
  -c "mdw 0x22030000 4" \
  -c "resume 0x22030000" \
  -c "sleep 1500" \
  -c "halt" \
  -c "mdw $HELPER_MARKER_ADDR 1" \
  -c "mdw $HELPER_STAGE_ADDR 1" \
  -c "mdw $HELPER_LP_STATUS_ADDR 1" \
  -c "mdw $HELPER_LP_HEARTBEAT_ADDR 1" \
  -c "mdw $HELPER_LP_STAGE_ADDR 1" \
  -c "mdw $MM_PWR_CFG 1" \
  -c "mdw $LP_BOOT_ADDR 1" \
  -c "mdw $LP_RESET_CFG 1" \
  -c "mdw $LP_CLK_CFG 1" \
  -c "mdw $PROBE_STATUS_ADDR 1" \
  -c "mdw $PROBE_HEARTBEAT_ADDR 1" \
  -c "sleep 500" \
  -c "mdw $PROBE_HEARTBEAT_ADDR 1" \
  -c "mdw $PROBE_STAGE_ADDR 1" \
  -c "mdw $GPIO6_CFG 1" \
  -c "mdw $GPIO7_CFG 1" \
  -c "mdw $GPIO12_CFG 1" \
  -c "mdw $GPIO13_CFG 1" \
  -c "shutdown" \
  2>&1 | tee "$TMP_LOG"

OUTPUT=$(cat "$TMP_LOG")

if printf '%s\n' "$OUTPUT" | grep -q "invalid command name"; then
  echo ""
  echo "FAIL: OpenOCD rejected one of the helper commands."
  echo "The preflight did not complete; inspect the log above."
  exit 4
fi

extract_last_mdw() {
  addr=$1
  printf '%s\n' "$OUTPUT" | awk -v addr="$addr:" 'tolower($1) == tolower(addr) { value = $2 } END { print value }'
}

extract_nth_mdw() {
  addr=$1
  want=$2
  printf '%s\n' "$OUTPUT" | awk -v addr="$addr:" -v want="$want" '
    tolower($1) == tolower(addr) {
      seen += 1
      if (seen == want) {
        print $2
        exit
      }
    }
  '
}

STATUS=$(extract_last_mdw "$PROBE_STATUS_ADDR")
HB1=$(extract_nth_mdw "$PROBE_HEARTBEAT_ADDR" 1)
HB2=$(extract_nth_mdw "$PROBE_HEARTBEAT_ADDR" 2)
STAGE=$(extract_last_mdw "$PROBE_STAGE_ADDR")
HELPER_MARK=$(extract_last_mdw "$HELPER_MARKER_ADDR")
HELPER_STAGE=$(extract_last_mdw "$HELPER_STAGE_ADDR")
HELPER_LP_STATUS=$(extract_last_mdw "$HELPER_LP_STATUS_ADDR")
HELPER_LP_HEARTBEAT=$(extract_last_mdw "$HELPER_LP_HEARTBEAT_ADDR")
HELPER_LP_STAGE=$(extract_last_mdw "$HELPER_LP_STAGE_ADDR")
GPIO6=$(extract_last_mdw "$GPIO6_CFG")
GPIO7=$(extract_last_mdw "$GPIO7_CFG")
GPIO12=$(extract_last_mdw "$GPIO12_CFG")
GPIO13=$(extract_last_mdw "$GPIO13_CFG")

echo ""
echo "Summary:"
echo "  M0 helper marker : ${HELPER_MARK:-missing}"
echo "  M0 helper stage  : ${HELPER_STAGE:-missing}"
echo "  M0 LP snapshot   : ${HELPER_LP_STATUS:-missing} / ${HELPER_LP_HEARTBEAT:-missing} / ${HELPER_LP_STAGE:-missing}"
echo "  LP probe marker   : ${STATUS:-missing}"
echo "  LP heartbeat      : ${HB1:-missing} -> ${HB2:-missing}"
echo "  LP probe stage    : ${STAGE:-missing}"
echo "  GPIO6 cfg         : ${GPIO6:-missing}"
echo "  GPIO7 cfg         : ${GPIO7:-missing}"
echo "  GPIO12 cfg        : ${GPIO12:-missing}"
echo "  GPIO13 cfg        : ${GPIO13:-missing}"

if [ "${HELPER_MARK:-}" != "$HELPER_MARKER" ]; then
  if [ "${STATUS:-}" = "$PROBE_ALIVE_MARKER" ] && [ -n "${HB1:-}" ] && [ -n "${HB2:-}" ] && [ "$HB1" != "$HB2" ]; then
    echo ""
    echo "PASS: LP boots and runs from the LP WRAM window."
    echo "Note: M0 helper scratch reads are unreliable under this debug flow, but LP execution is confirmed."
    exit 0
  fi
  echo ""
  echo "WARN: The M0 helper scratch area did not read back cleanly."
  echo "LP execution did not succeed either, so keep treating the preflight as failed."
  exit 5
fi

if [ "${STATUS:-}" != "$PROBE_ALIVE_MARKER" ]; then
  echo ""
  echo "FAIL: LP probe did not write the expected LP probe marker."
  echo "The M0 helper ran, but LP still did not execute the probe."
  echo "This points to LP bring-up/reset/boot-address behavior, not HAD transport."
  exit 2
fi

if [ -z "${HB1:-}" ] || [ -z "${HB2:-}" ] || [ "$HB1" = "$HB2" ]; then
  echo ""
  echo "FAIL: LP probe heartbeat did not advance."
  echo "The LP core either did not start or did not continue executing."
  exit 3
fi

echo ""
echo "PASS: LP boots and runs under M0-controlled bring-up."
echo "Next step: hand the GPIO mux to LP with ./jtag_switch.sh lp, then retry HAD."
