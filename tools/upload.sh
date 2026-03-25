#!/usr/bin/env bash
# =============================================================================
# BL808 firmware upload script for Pine64 Ox64
#
# Usage:
#   ./tools/upload.sh <core> <firmware.bin> [port] [baudrate]
#
# Examples:
#   ./tools/upload.sh m0 build/m0_firmware.bin /dev/ttyUSB0 2000000
#   ./tools/upload.sh d0 build/d0_firmware.bin /dev/ttyACM0
#
# Prerequisites:
#   - bflb-iot-tool (pip install bflb-iot-tool)
#   - Ox64 connected via USB-serial adapter
#   - Boot pin held LOW during power-on to enter UART boot mode
#
# Flashing procedure:
#   1. Connect USB-serial adapter to Ox64
#   2. Hold BOOT button (or connect BOOT pin to GND)
#   3. Power on / reset the board
#   4. Release BOOT button
#   5. Run this script
# =============================================================================

set -euo pipefail

CORE="${1:-}"
FIRMWARE="${2:-}"
PORT="${3:-/dev/ttyUSB0}"
BAUD="${4:-2000000}"

if [ -z "$CORE" ] || [ -z "$FIRMWARE" ]; then
    echo "Usage: $0 <m0|d0|lp> <firmware.bin> [port] [baudrate]"
    echo ""
    echo "Flash offsets:"
    echo "  m0 -> 0x000000 (M0 firmware)"
    echo "  d0 -> 0x100000 (D0 lowload bootloader)"
    echo "  lp -> 0x080000 (LP firmware)"
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

case "$CORE" in
    m0)
        ADDR="0x000000"
        echo "Flashing M0 firmware at offset $ADDR..."
        ;;
    d0)
        ADDR="0x100000"
        echo "Flashing D0 firmware at offset $ADDR..."
        ;;
    lp)
        ADDR="0x080000"
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
echo ""

bflb-iot-tool \
    --chipname bl808 \
    --port "$PORT" \
    --baudrate "$BAUD" \
    --firmware "$FIRMWARE" \
    --addr "$ADDR"

echo ""
echo "Flash complete! Reset the board to run the firmware."
