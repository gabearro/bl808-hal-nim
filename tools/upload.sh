#!/usr/bin/env bash
# =============================================================================
# BL808 firmware upload script for Pine64 Ox64
#
# Usage:
#   ./tools/upload.sh <core> <firmware.bin> [port] [baudrate]
#
# Examples:
#   ./tools/upload.sh m0 build/m0_firmware.bin /dev/ttyUSB0 230400
#   ./tools/upload.sh d0 build/d0_firmware.bin /dev/ttyACM0
#
# Prerequisites:
#   - bflb-iot-tool (pip install bflb-iot-tool)
#   - Ox64 connected via USB-serial adapter
#   - Ox64 BOOT button held during reset/power-up to enter UART boot mode
#
# Flashing procedure:
#   1. Connect USB-serial adapter to Ox64
#   2. Press and hold BOOT
#   3. Power on / reset the board with BOOT still held
#   4. Release BOOT after power-up
#   5. Run this script
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [ -d "$REPO_ROOT/.venv/bin" ]; then
    PATH="$REPO_ROOT/.venv/bin:$PATH"
fi

CORE="${1:-}"
FIRMWARE="${2:-}"
PORT="${3:-/dev/ttyUSB0}"
BAUD="${4:-230400}"

if [ -z "$CORE" ] || [ -z "$FIRMWARE" ]; then
    echo "Usage: $0 <m0|d0|lp> <firmware.bin> [port] [baudrate]"
    echo ""
    echo "Flash offsets:"
    echo "  m0 -> Boot2 + partition table + FW partition"
    echo "  d0 -> 0x100000 (D0 lowload bootloader)"
    echo "  lp -> 0x0A0000 (LP firmware; maps to XIP 0x58080000 with boot2 image offset 0x20000)"
    exit 1
fi

if ! command -v bflb-iot-tool &> /dev/null; then
    echo "Error: bflb-iot-tool not found."
    echo "Install with: pip install bflb-iot-tool"
    exit 1
fi

if [ ! -f "$FIRMWARE" ]; then
    echo "Error: Firmware file not found: $FIRMWARE"
    exit 1
fi

BFLB_TOOL="$(command -v bflb-iot-tool)"
BFLB_PYTHON="$(dirname "$BFLB_TOOL")/python"
if [ ! -x "$BFLB_PYTHON" ]; then
    BFLB_PYTHON="python3"
fi

find_default_boot2() {
    "$BFLB_PYTHON" - <<'PY'
import inspect
from pathlib import Path

import bflb_iot_tool

chip_dir = Path(inspect.getfile(bflb_iot_tool)).parent / "chips" / "bl808"
candidates = sorted(chip_dir.glob("builtin_imgs/**/boot2_isp_release.bin"))
if not candidates:
    raise SystemExit("no default BL808 boot2_isp_release.bin found")
print(candidates[0])
PY
}

case "$CORE" in
    m0)
        ADDR=""
        BOOT2="${BL808_BOOT2:-$(find_default_boot2)}"
        if [ ! -f "$BOOT2" ]; then
            echo "Error: BL808 Boot2 image not found: $BOOT2"
            exit 1
        fi
        echo "Flashing M0 firmware with BL808 Boot2/partition layout..."
        ;;
    d0)
        ADDR="0x100000"
        echo "Flashing D0 firmware at offset $ADDR..."
        ;;
    lp)
        ADDR="0x0A0000"
        echo "Flashing LP firmware at offset $ADDR..."
        ;;
    *)
        echo "Error: Unknown core '$CORE'. Use m0, d0, or lp."
        exit 1
        ;;
esac

echo "Port: $PORT"
echo "Baud: $BAUD"
echo "File: $FIRMWARE"
echo "Size: $(wc -c < "$FIRMWARE") bytes"
if [ "${BOOT2:-}" ]; then
    echo "Boot2: $BOOT2"
fi
echo ""

"$BFLB_PYTHON" - "$PORT" "$BAUD" <<'PY'
import configparser
import inspect
import os
import sys
from pathlib import Path

import bflb_iot_tool

port, baud = sys.argv[1], sys.argv[2]
cfg_path = (
    Path(inspect.getfile(bflb_iot_tool)).parent
    / "chips"
    / "bl808"
    / "eflash_loader"
    / "eflash_loader_cfg.ini"
)

cfg = configparser.ConfigParser()
cfg.optionxform = str
cfg.read(cfg_path)

if not cfg.has_section("LOAD_CFG"):
    raise SystemExit(f"missing LOAD_CFG in {cfg_path}")

cfg.set("LOAD_CFG", "device", port)
cfg.set("LOAD_CFG", "interface", "uart")
cfg.set("LOAD_CFG", "speed_uart_boot", baud)
cfg.set("LOAD_CFG", "speed_uart_load", baud)
cfg.set("LOAD_CFG", "load_function", "2")
do_reset = os.environ.get("BL808_UART_DO_RESET", "false")
reset_revert = os.environ.get("BL808_UART_RESET_REVERT", "false")
reset_hold_time = os.environ.get("BL808_UART_RESET_HOLD_TIME", "50")
shake_hand_delay = os.environ.get("BL808_UART_SHAKE_HAND_DELAY", "100")
shake_hand_retry = os.environ.get("BL808_UART_SHAKE_HAND_RETRY", "3")
cutoff_time = os.environ.get("BL808_UART_CUTOFF_TIME", "0")
cfg.set("LOAD_CFG", "do_reset", do_reset)
cfg.set("LOAD_CFG", "reset_revert", reset_revert)
cfg.set("LOAD_CFG", "reset_hold_time", reset_hold_time)
cfg.set("LOAD_CFG", "shake_hand_delay", shake_hand_delay)
cfg.set("LOAD_CFG", "shake_hand_retry", shake_hand_retry)
cfg.set("LOAD_CFG", "cutoff_time", cutoff_time)

with cfg_path.open("w", encoding="utf-8") as f:
    cfg.write(f, space_around_delimiters=True)

print(
    "Configured bflb UART boot handshake: "
    f"speed_uart_boot={baud}, speed_uart_load={baud}, "
    "interface=uart, load_function=2, "
    f"do_reset={do_reset}, reset_revert={reset_revert}, "
    f"reset_hold_time={reset_hold_time}, shake_hand_delay={shake_hand_delay}, "
    f"shake_hand_retry={shake_hand_retry}, cutoff_time={cutoff_time}"
)
PY

if [ "$CORE" = "m0" ]; then
    FLASH_CMD=(
        bflb-iot-tool
        --chipname bl808
        --interface uart
        --port "$PORT"
        --baudrate "$BAUD"
        --firmware "$FIRMWARE"
        --boot2 "$BOOT2"
    )
else
    FLASH_CMD=(
        bflb-iot-tool
        --chipname bl808
        --interface uart
        --port "$PORT"
        --baudrate "$BAUD"
        --firmware "$FIRMWARE"
        --addr "$ADDR"
        --single
    )
fi

set +e
FLASH_OUTPUT="$("${FLASH_CMD[@]}" 2>&1)"
FLASH_STATUS=$?
set -e

printf '%s\n' "$FLASH_OUTPUT"

if [ "$FLASH_STATUS" -ne 0 ]; then
    echo ""
    echo "Error: bflb-iot-tool exited with status $FLASH_STATUS."
    exit "$FLASH_STATUS"
fi

if printf '%s\n' "$FLASH_OUTPUT" | grep -Eiq '(ErrorCode:|handshake failed|burn return with retry failed|load fail|verify fail)'; then
    if printf '%s\n' "$FLASH_OUTPUT" | grep -Eiq '(ErrorCode: 0050|handshake failed|BFLB IMG LOAD HANDSHAKE FAIL)'; then
        echo ""
        echo "UART bootloader handshake failed."
        echo "Hold BOOT high, reset or power-cycle the BL808, then release BOOT before retrying."
        echo "The harness does not drive the BL808 BOOT strap automatically."
        echo "If BOOT was asserted correctly, retry with --flash-baud 115200."
    fi
    echo ""
    echo "Error: bflb-iot-tool reported a flash failure."
    exit 1
fi

echo ""
echo "Flash complete! Reset the board to run the firmware."
