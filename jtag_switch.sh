#!/usr/bin/env bash
# =============================================================================
# BL808 JTAG core switch script
#
# Switches the JTAG debug target between M0 (E907), D0 (C906), and LP (E902).
# Loads a small program onto M0 that powers on the target core, switches the
# GPIO JTAG mux, then spins. OpenOCD is restarted with the new target config.
#
# Usage:
#   ./jtag_switch.sh [--preserve] <m0|d0|lp>
#
# Environment:
#   FTDI_RESET=0 disables USB reset before OpenOCD restart.
#   FTDI_RESET_REQUIRED=1 makes adapter reset failures fatal.
#   OPENOCD_START_RETRIES=<n> controls restart attempts after a mux switch.
#
# Prerequisites:
#   - OpenOCD running with M0 target (or any core that can write GLB/PDS regs)
#   - Pine64 JTAG adapter connected to Ox64 GPIO 6/7/12/13
# =============================================================================

set -euo pipefail

PRESERVE_TARGET=0
if [ "${1:-}" = "--preserve" ]; then
    PRESERVE_TARGET=1
    shift
fi
CORE="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JTAG_CFG="pine64jtag.cfg"
SWITCH_ELF="/tmp/bl808_jtag_switch_${CORE}.elf"
SWITCH_S="/tmp/bl808_jtag_switch_${CORE}.S"
GCC="${RISCV_GCC:-riscv64-unknown-elf-gcc}"
CC_HOST="${CC_HOST:-cc}"
PKG_CONFIG="${PKG_CONFIG:-pkg-config}"
PATCHED_OPENOCD_DEFAULT="$SCRIPT_DIR/../openocd-had/src/openocd"
if [ -x "$PATCHED_OPENOCD_DEFAULT" ]; then
    OPENOCD_BIN="${OPENOCD_BIN:-$PATCHED_OPENOCD_DEFAULT}"
else
    OPENOCD_BIN="${OPENOCD_BIN:-openocd}"
fi
OPENOCD_START_RETRIES="${OPENOCD_START_RETRIES:-3}"
OPENOCD_SETTLE="${OPENOCD_SETTLE:-2}"
FTDI_RESET="${FTDI_RESET:-1}"
FTDI_RESET_REQUIRED="${FTDI_RESET_REQUIRED:-0}"
FTDI_RESET_VID="${FTDI_RESET_VID:-0x0403}"
FTDI_RESET_PID="${FTDI_RESET_PID:-0x6014}"
FTDI_RESET_SERIAL="${FTDI_RESET_SERIAL:-}"
FTDI_RESET_C="${FTDI_RESET_C:-$SCRIPT_DIR/tools/ftdi_reset.c}"
FTDI_RESET_BIN="${FTDI_RESET_BIN:-$SCRIPT_DIR/build/ftdi_reset}"
FTDI_RESET_SETTLE="${FTDI_RESET_SETTLE:-1}"
LP_USE_HAD="${LP_USE_HAD:-0}"
LP_HAD_ROOT_DEFAULT="$SCRIPT_DIR/../openocd-had"
LP_OPENOCD_BIN_DEFAULT="$OPENOCD_BIN"
LP_OPENOCD_BIN="${LP_OPENOCD_BIN:-$LP_OPENOCD_BIN_DEFAULT}"
LP_INTERFACE_CFG="${LP_INTERFACE_CFG:-$SCRIPT_DIR/pine64jtag_slow.cfg}"
LP_TARGET_CFG="${LP_TARGET_CFG:-$SCRIPT_DIR/tgt_e902.cfg}"
LP_RAW_INTERFACE_CFG="${LP_RAW_INTERFACE_CFG:-$LP_HAD_ROOT_DEFAULT/tcl/interface/ftdi/pine64-raw-had.cfg}"
LP_RAW_TARGET_CFG="${LP_RAW_TARGET_CFG:-$LP_HAD_ROOT_DEFAULT/tcl/target/bl808_lp_had.cfg}"

run_priv() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        "$@"
    fi
}

build_ftdi_reset() {
    if [ "$FTDI_RESET" != "1" ]; then
        return 0
    fi

    if [ ! -f "$FTDI_RESET_C" ]; then
        echo "  Warning: FTDI reset helper source not found: $FTDI_RESET_C"
        return 1
    fi

    mkdir -p "$(dirname "$FTDI_RESET_BIN")"
    if [ -x "$FTDI_RESET_BIN" ] && [ "$FTDI_RESET_BIN" -nt "$FTDI_RESET_C" ]; then
        return 0
    fi

    if ! command -v "$PKG_CONFIG" >/dev/null 2>&1; then
        echo "  Warning: pkg-config not found; cannot build FTDI reset helper."
        return 1
    fi

    echo "  Building FTDI reset helper..."
    "$CC_HOST" -O2 -Wall -Wextra -o "$FTDI_RESET_BIN" "$FTDI_RESET_C" \
        $("$PKG_CONFIG" --cflags --libs libftdi1)
}

reset_ftdi_adapter() {
    if [ "$FTDI_RESET" != "1" ]; then
        return 0
    fi

    if ! build_ftdi_reset; then
        if [ "$FTDI_RESET_REQUIRED" = "1" ]; then
            echo "Error: FTDI reset helper is required but unavailable."
            exit 1
        fi
        echo "  Continuing without FTDI USB reset."
        return 0
    fi

    echo "  Resetting FTDI JTAG adapter..."
    if [ -n "$FTDI_RESET_SERIAL" ]; then
        if ! run_priv "$FTDI_RESET_BIN" "$FTDI_RESET_VID" "$FTDI_RESET_PID" "$FTDI_RESET_SERIAL"; then
            if [ "$FTDI_RESET_REQUIRED" = "1" ]; then
                echo "Error: FTDI USB reset failed."
                exit 1
            fi
            echo "  Warning: FTDI USB reset failed; continuing."
            return 0
        fi
    else
        if ! run_priv "$FTDI_RESET_BIN" "$FTDI_RESET_VID" "$FTDI_RESET_PID"; then
            if [ "$FTDI_RESET_REQUIRED" = "1" ]; then
                echo "Error: FTDI USB reset failed."
                exit 1
            fi
            echo "  Warning: FTDI USB reset failed; continuing."
            return 0
        fi
    fi

    sleep "$FTDI_RESET_SETTLE"
}

start_openocd_once() {
    if [ "$CORE" = "lp" ]; then
        if [ "$LP_USE_HAD" = "1" ]; then
            LP_SELECTED_INTERFACE_CFG="$LP_RAW_INTERFACE_CFG"
            LP_SELECTED_TARGET_CFG="$LP_RAW_TARGET_CFG"
            LP_MODE_LABEL="raw HAD"
        else
            LP_SELECTED_INTERFACE_CFG="$LP_INTERFACE_CFG"
            LP_SELECTED_TARGET_CFG="$LP_TARGET_CFG"
            LP_MODE_LABEL="regular JTAG/RVDM"
        fi

        if [ -x "$LP_OPENOCD_BIN" ] && [ -f "$LP_SELECTED_INTERFACE_CFG" ] && [ -f "$LP_SELECTED_TARGET_CFG" ]; then
            echo "  Starting LP OpenOCD ($LP_MODE_LABEL)..."
            BL808_XUANTIE_ASYNC_HALT=1 run_priv "$LP_OPENOCD_BIN" -f "$LP_SELECTED_INTERFACE_CFG" -f "$LP_SELECTED_TARGET_CFG" &
            OCDPID=$!
        else
            echo ""
            echo "============================================"
            echo " LP GPIO mux switched to func_sel=25"
            echo " Start LP OpenOCD manually:"
            echo "   sudo $LP_OPENOCD_BIN -f $LP_SELECTED_INTERFACE_CFG -f $LP_SELECTED_TARGET_CFG"
            echo "============================================"
            exit 0
        fi
    else
        echo "  Starting OpenOCD with $TARGET_CFG..."
        run_priv "$OPENOCD_BIN" -f "$JTAG_CFG" -f "$TARGET_CFG" &
        OCDPID=$!
    fi

    sleep "$OPENOCD_SETTLE"
}

if [ -z "$CORE" ]; then
    echo "Usage: $0 [--preserve] <m0|d0|lp>"
    echo ""
    echo "Switches JTAG debug target between BL808 cores."
    echo "--preserve only switches GPIO mux and does not reset/reboot the target core."
    echo "Requires OpenOCD to be running on any core."
    exit 1
fi

case "$CORE" in
    m0)
        FUNC_SEL=26
        TARGET_CFG="tgt_e907_v2.cfg"
        ;;
    d0)
        FUNC_SEL=27
        TARGET_CFG="tgt_c906.cfg"
        ;;
    lp)
        FUNC_SEL=25
        TARGET_CFG="tgt_e902.cfg"
        ;;
    *)
        echo "Error: Unknown core '$CORE'. Use m0, d0, or lp."
        exit 1
        ;;
esac

# GPIO config: func_sel | INT_MASK (bit 22) | SMT (bit 1) | IE (bit 0)
# Matches the bootrom's JTAG GPIO configuration pattern for all four pads.
GPIO_VAL=$(printf "0x%08X" $(( (FUNC_SEL << 8) | (1 << 22) | (1 << 1) | (1 << 0) )))
GPIO_VAL_TDO="$GPIO_VAL"

echo "Switching to $CORE -- GPIO func_sel=$FUNC_SEL ($GPIO_VAL)"

# =============================================================================
# Build a small M0 program that:
#   1. Powers on MM subsystem (for D0/LP)
#   2. Writes a spin loop to the target core's boot address
#   3. Releases the target core from reset
#   4. Switches GPIO JTAG mux to the target core
#   5. Spins forever (M0 loses JTAG at this point)
# =============================================================================

cat > "$SWITCH_S" << ASMEOF
    .section .text
    .global _start
_start:
ASMEOF

# Add power-on commands for D0/LP
if { [ "$CORE" = "d0" ] || [ "$CORE" = "lp" ]; } && [ "$PRESERVE_TARGET" != "1" ]; then
    cat >> "$SWITCH_S" << 'ASMEOF'
    # Power on MM subsystem: PDS_CTL2 = 0
    li   a0, 0x2000E010
    sw   zero, 0(a0)
ASMEOF
fi

if [ "$CORE" = "d0" ] && [ "$PRESERVE_TARGET" != "1" ]; then
    cat >> "$SWITCH_S" << 'ASMEOF'
    # Write "j self" (0x0000006F) to DRAM for D0
    li   a0, 0x3EF80000
    li   a1, 0x0000006F
    sw   a1, 0(a0)
    # Set D0 boot address: MM_MISC_CPU0_BOOT = 0x3EF80000
    li   a0, 0x30000000
    li   a1, 0x3EF80000
    sw   a1, 0(a0)
    # Release D0 reset: MM_SW_SYS_RESET = 0
    li   a0, 0x30007040
    sw   zero, 0(a0)
    # Enable D0 clock: MM_CLK_CTRL_CPU = 0x5005 (bit 12 = clock enable)
    li   a0, 0x30007000
    li   a1, 0x00005005
    sw   a1, 0(a0)
ASMEOF
fi

if [ "$CORE" = "lp" ] && [ "$PRESERVE_TARGET" != "1" ]; then
    cat >> "$SWITCH_S" << 'ASMEOF'
    # Hold LP reset while programming its boot address
    li   a0, 0x20000548
    lw   a1, 0(a0)
    ori  a1, a1, 0x8
    sw   a1, 0(a0)
    fence iorw, iorw
    # Write "j self" (0x0000006F) to the LP WRAM window.
    li   a0, 0x22050000
    li   a1, 0x0000006F
    sw   a1, 0(a0)
    # Set LP boot address: PDS_CPU_CORE_CFG13 = 0x22050000
    li   a0, 0x2000E144
    li   a1, 0x22050000
    sw   a1, 0(a0)
    fence iorw, iorw
    # Enable and reset LP E902 CORET/mtime clock: PDS_CPU_CORE_CFG8
    li   a0, 0x2000E130
    lw   a1, 0(a0)
    li   a2, 0x80000000
    not  a2, a2
    and  a1, a1, a2
    sw   a1, 0(a0)
    fence iorw, iorw
    li   a2, 0x40000000
    not  a2, a2
    and  a1, a1, a2
    sw   a1, 0(a0)
    fence iorw, iorw
    li   a2, 0x40000000
    or   a1, a1, a2
    sw   a1, 0(a0)
    fence iorw, iorw
    li   a2, 0x40000000
    not  a2, a2
    and  a1, a1, a2
    li   a2, 0xFFFFFC00
    and  a1, a1, a2
    ori  a1, a1, 159
    li   a2, 0x80000000
    or   a1, a1, a2
    sw   a1, 0(a0)
    fence iorw, iorw
    # Enable LP clock: PDS_CPU_CORE_CFG0 |= bit 28
    li   a0, 0x2000E110
    lw   a1, 0(a0)
    li   a2, 0x10000000
    or   a1, a1, a2
    sw   a1, 0(a0)
    fence iorw, iorw
    # Release only LP reset bit in GLB_SWRST_CFG2
    li   a0, 0x20000548
    lw   a1, 0(a0)
    li   a2, -9
    and  a1, a1, a2
    sw   a1, 0(a0)
    fence iorw, iorw
ASMEOF
fi

# Add delay + GPIO switch + spin (always)
cat >> "$SWITCH_S" << ASMEOF
    # Delay for target core to start
    li   a2, 200000
1:  addi a2, a2, -1
    bnez a2, 1b

    # Switch GPIO JTAG mux
    li   a1, $GPIO_VAL
    li   a0, 0x200008DC     # GPIO 6  (TMS - input)
    sw   a1, 0(a0)
    li   a1, $GPIO_VAL_TDO
    li   a0, 0x200008E0     # GPIO 7  (TDO)
    sw   a1, 0(a0)
    li   a1, $GPIO_VAL
    li   a0, 0x200008F4     # GPIO 12 (TCK - input)
    sw   a1, 0(a0)
    li   a0, 0x200008F8     # GPIO 13 (TDI - input)
    sw   a1, 0(a0)

    # JTAG is now disconnected from this core. Spin forever.
2:  j    2b
ASMEOF

# Compile
echo "  Building switch program..."
"$GCC" -march=rv32imafc -mabi=ilp32f -nostdlib -nostartfiles \
    -Ttext=0x22030000 -o "$SWITCH_ELF" "$SWITCH_S" 2>&1

# =============================================================================
# Load and run the switch program via OpenOCD
# =============================================================================

echo "  Loading switch program to M0 WRAM..."
(
    sleep 0.3
    echo "halt"
    sleep 0.3
    echo "load_image $SWITCH_ELF"
    sleep 0.3
    echo "resume 0x22030000"
    sleep 3
    echo "shutdown"
) | nc localhost 6666 2>&1 | grep -v "^$" || true

echo "  Switch program running. Waiting for GPIO mux to change..."
sleep 2

# =============================================================================
# Kill OpenOCD and restart with new target
# =============================================================================

echo "  Stopping OpenOCD..."
run_priv killall openocd 2>/dev/null || true
sleep 1
run_priv killall -9 openocd 2>/dev/null || true
sleep 1

cd "$SCRIPT_DIR"

reset_ftdi_adapter

OCDPID=
OPENOCD_ATTEMPT=1
while [ "$OPENOCD_ATTEMPT" -le "$OPENOCD_START_RETRIES" ]; do
    if [ "$OPENOCD_ATTEMPT" -gt 1 ]; then
        echo "  Retrying OpenOCD start ($OPENOCD_ATTEMPT/$OPENOCD_START_RETRIES)..."
    fi

    start_openocd_once
    if kill -0 "$OCDPID" 2>/dev/null; then
        break
    fi

    if [ "$OPENOCD_ATTEMPT" -lt "$OPENOCD_START_RETRIES" ]; then
        reset_ftdi_adapter
    fi
    OPENOCD_ATTEMPT=$((OPENOCD_ATTEMPT + 1))
done

if [ -n "$OCDPID" ] && kill -0 "$OCDPID" 2>/dev/null; then
    echo ""
    echo "============================================"
    if [ "$CORE" = "lp" ]; then
        if [ "$LP_USE_HAD" = "1" ]; then
            echo " Connected to LP core via raw HAD"
        else
            echo " Connected to LP core via regular JTAG/RVDM"
        fi
    else
        echo " Connected to $CORE core"
    fi
    echo " Telnet: localhost:4444"
    echo " GDB:    localhost:3333"
    echo "============================================"
else
    echo ""
    echo "Error: OpenOCD failed to start."
    echo "Power cycle the Ox64 and try again."
    exit 1
fi
