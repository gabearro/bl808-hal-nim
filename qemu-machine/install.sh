#!/bin/bash
# Install BL808 machine files into a QEMU source tree and build.
#
# Usage: ./install.sh /path/to/qemu-source
#
# After running, use:
#   qemu-system-riscv64 -M bl808 -nographic -kernel m0_firmware.elf
#   qemu-system-riscv64 -M bl808,flash-image=ox64-flash.bin -nographic
#   qemu-system-riscv64 -M bl808,flash-image=ox64-flash.bin,boot-gpio39=on -nographic
#   qemu-system-riscv64 -M bl808,d0-firmware=d0.elf,lp-firmware=lp.elf -kernel m0_firmware.elf -nographic
#   qemu-system-riscv64 -M bl808,strict-fidelity=on,flash-image=ox64-flash.bin,bootrom-image=bootrom.bin -nographic

set -e

QEMU_SRC="${1:-/Users/gabriel/Documents/nimlang/qemu-bl808}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "$QEMU_SRC/meson.build" ]; then
    echo "Error: $QEMU_SRC does not look like a QEMU source tree"
    exit 1
fi

echo "Installing BL808 machine into $QEMU_SRC..."

# Copy headers
mkdir -p "$QEMU_SRC/include/hw/intc"
mkdir -p "$QEMU_SRC/include/hw/audio"
mkdir -p "$QEMU_SRC/include/hw/char"
mkdir -p "$QEMU_SRC/include/hw/dma"
mkdir -p "$QEMU_SRC/include/hw/block"
mkdir -p "$QEMU_SRC/include/hw/i2c"
mkdir -p "$QEMU_SRC/include/hw/misc"
mkdir -p "$QEMU_SRC/include/hw/net"
mkdir -p "$QEMU_SRC/include/hw/ssi"
mkdir -p "$QEMU_SRC/include/hw/timer"

cp "$SCRIPT_DIR/include/hw/riscv/bl808.h"     "$QEMU_SRC/include/hw/riscv/bl808.h"
cp "$SCRIPT_DIR/include/hw/char/bl808_uart.h" "$QEMU_SRC/include/hw/char/bl808_uart.h"
cp "$SCRIPT_DIR/include/hw/audio/bl808_audio.h" "$QEMU_SRC/include/hw/audio/bl808_audio.h"
cp "$SCRIPT_DIR/include/hw/audio/bl808_i2s.h" "$QEMU_SRC/include/hw/audio/bl808_i2s.h"
cp "$SCRIPT_DIR/include/hw/dma/bl808_dma.h"   "$QEMU_SRC/include/hw/dma/bl808_dma.h"
cp "$SCRIPT_DIR/include/hw/dma/bl808_dma2d.h" "$QEMU_SRC/include/hw/dma/bl808_dma2d.h"
cp "$SCRIPT_DIR/include/hw/block/bl808_sf_ctrl.h" "$QEMU_SRC/include/hw/block/bl808_sf_ctrl.h"
cp "$SCRIPT_DIR/include/hw/i2c/bl808_i2c.h"   "$QEMU_SRC/include/hw/i2c/bl808_i2c.h"
cp "$SCRIPT_DIR/include/hw/intc/thead_clint.h" "$QEMU_SRC/include/hw/intc/thead_clint.h"
cp "$SCRIPT_DIR/include/hw/intc/xt_clic.h"    "$QEMU_SRC/include/hw/intc/xt_clic.h"
cp "$SCRIPT_DIR/include/hw/misc/bl808_cci.h"   "$QEMU_SRC/include/hw/misc/bl808_cci.h"
cp "$SCRIPT_DIR/include/hw/misc/bl808_cks.h"   "$QEMU_SRC/include/hw/misc/bl808_cks.h"
cp "$SCRIPT_DIR/include/hw/misc/bl808_emi.h"   "$QEMU_SRC/include/hw/misc/bl808_emi.h"
cp "$SCRIPT_DIR/include/hw/misc/bl808_gpip.h"  "$QEMU_SRC/include/hw/misc/bl808_gpip.h"
cp "$SCRIPT_DIR/include/hw/misc/bl808_glb.h"   "$QEMU_SRC/include/hw/misc/bl808_glb.h"
cp "$SCRIPT_DIR/include/hw/misc/bl808_ipc.h"   "$QEMU_SRC/include/hw/misc/bl808_ipc.h"
cp "$SCRIPT_DIR/include/hw/misc/bl808_mcu_misc.h" "$QEMU_SRC/include/hw/misc/bl808_mcu_misc.h"
cp "$SCRIPT_DIR/include/hw/misc/bl808_mm_misc.h" "$QEMU_SRC/include/hw/misc/bl808_mm_misc.h"
cp "$SCRIPT_DIR/include/hw/misc/bl808_psram_ctrl.h" "$QEMU_SRC/include/hw/misc/bl808_psram_ctrl.h"
cp "$SCRIPT_DIR/include/hw/misc/bl808_sec_eng.h" "$QEMU_SRC/include/hw/misc/bl808_sec_eng.h"
cp "$SCRIPT_DIR/include/hw/misc/bl808_tzc.h" "$QEMU_SRC/include/hw/misc/bl808_tzc.h"
cp "$SCRIPT_DIR/include/hw/misc/bl808_usb.h" "$QEMU_SRC/include/hw/misc/bl808_usb.h"
cp "$SCRIPT_DIR/include/hw/net/bl808_emac.h"   "$QEMU_SRC/include/hw/net/bl808_emac.h"
cp "$SCRIPT_DIR/include/hw/ssi/bl808_spi.h"    "$QEMU_SRC/include/hw/ssi/bl808_spi.h"
cp "$SCRIPT_DIR/include/hw/timer/bl808_pwm.h"  "$QEMU_SRC/include/hw/timer/bl808_pwm.h"
cp "$SCRIPT_DIR/include/hw/timer/bl808_timer.h" "$QEMU_SRC/include/hw/timer/bl808_timer.h"

# Copy source files
mkdir -p "$QEMU_SRC/hw/dma"
mkdir -p "$QEMU_SRC/hw/audio"
cp "$SCRIPT_DIR/hw/audio/bl808_audio.c"   "$QEMU_SRC/hw/audio/bl808_audio.c"
cp "$SCRIPT_DIR/hw/audio/bl808_i2s.c"     "$QEMU_SRC/hw/audio/bl808_i2s.c"
cp "$SCRIPT_DIR/hw/block/bl808_sf_ctrl.c" "$QEMU_SRC/hw/block/bl808_sf_ctrl.c"
cp "$SCRIPT_DIR/hw/dma/bl808_dma.c"      "$QEMU_SRC/hw/dma/bl808_dma.c"
cp "$SCRIPT_DIR/hw/dma/bl808_dma2d.c"    "$QEMU_SRC/hw/dma/bl808_dma2d.c"
mkdir -p "$QEMU_SRC/hw/i2c"
cp "$SCRIPT_DIR/hw/i2c/bl808_i2c.c"      "$QEMU_SRC/hw/i2c/bl808_i2c.c"
cp "$SCRIPT_DIR/hw/riscv/bl808.c"      "$QEMU_SRC/hw/riscv/bl808.c"
cp "$SCRIPT_DIR/hw/char/bl808_uart.c"  "$QEMU_SRC/hw/char/bl808_uart.c"
cp "$SCRIPT_DIR/hw/misc/bl808_cci.c"   "$QEMU_SRC/hw/misc/bl808_cci.c"
cp "$SCRIPT_DIR/hw/misc/bl808_cks.c"   "$QEMU_SRC/hw/misc/bl808_cks.c"
cp "$SCRIPT_DIR/hw/misc/bl808_emi.c"   "$QEMU_SRC/hw/misc/bl808_emi.c"
cp "$SCRIPT_DIR/hw/misc/bl808_gpip.c"  "$QEMU_SRC/hw/misc/bl808_gpip.c"
cp "$SCRIPT_DIR/hw/misc/bl808_glb.c"   "$QEMU_SRC/hw/misc/bl808_glb.c"
cp "$SCRIPT_DIR/hw/misc/bl808_ipc.c"   "$QEMU_SRC/hw/misc/bl808_ipc.c"
cp "$SCRIPT_DIR/hw/misc/bl808_mcu_misc.c" "$QEMU_SRC/hw/misc/bl808_mcu_misc.c"
cp "$SCRIPT_DIR/hw/misc/bl808_mm_misc.c" "$QEMU_SRC/hw/misc/bl808_mm_misc.c"
cp "$SCRIPT_DIR/hw/misc/bl808_psram_ctrl.c" "$QEMU_SRC/hw/misc/bl808_psram_ctrl.c"
cp "$SCRIPT_DIR/hw/misc/bl808_sec_eng.c" "$QEMU_SRC/hw/misc/bl808_sec_eng.c"
cp "$SCRIPT_DIR/hw/misc/bl808_tzc.c" "$QEMU_SRC/hw/misc/bl808_tzc.c"
cp "$SCRIPT_DIR/hw/misc/bl808_usb.c" "$QEMU_SRC/hw/misc/bl808_usb.c"
cp "$SCRIPT_DIR/hw/intc/thead_clint.c" "$QEMU_SRC/hw/intc/thead_clint.c"
cp "$SCRIPT_DIR/hw/intc/xt_clic.c"     "$QEMU_SRC/hw/intc/xt_clic.c"
cp "$SCRIPT_DIR/hw/net/bl808_emac.c"   "$QEMU_SRC/hw/net/bl808_emac.c"
cp "$SCRIPT_DIR/hw/ssi/bl808_spi.c"    "$QEMU_SRC/hw/ssi/bl808_spi.c"
cp "$SCRIPT_DIR/hw/timer/bl808_pwm.c"  "$QEMU_SRC/hw/timer/bl808_pwm.c"
cp "$SCRIPT_DIR/hw/timer/bl808_timer.c" "$QEMU_SRC/hw/timer/bl808_timer.c"

# Patch target/riscv/th_csr.c for BL808-specific T-Head CSR behavior.
python3 - "$QEMU_SRC/target/riscv/th_csr.c" << 'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
orig = text

if "#define CSR_TH_MAPBADDR 0xfc1" not in text:
    text = text.replace(
        "#define CSR_TH_MHINT    0x7c5\n",
        "#define CSR_TH_MHINT    0x7c5\n#define CSR_TH_MAPBADDR 0xfc1\n\n"
        "/*\n"
        " * BL808 integrates the D0 C906 APB-visible interrupt controller window under\n"
        " * 0xe0xx_xxxx, and vendor startup code uses MAPBADDR + 0x0020_0000 /\n"
        " * 0x0020_1000 to reach the M/S-mode PLIC claim-complete registers.\n"
        " */\n"
        "#define TH_MAPBADDR_BL808 0xe0000000ULL\n",
        1,
    )

if "static RISCVException read_th_mapbaddr" not in text:
    text = text.replace(
        "/* CLIC CSRs */\n",
        "/* T-Head mapbaddr: APB high address bits supplied by SoC integration */\n"
        "static RISCVException read_th_mapbaddr(CPURISCVState *env, int csrno,\n"
        "                                       target_ulong *val)\n"
        "{\n"
        "    *val = TH_MAPBADDR_BL808;\n"
        "    return RISCV_EXCP_NONE;\n"
        "}\n\n"
        "/* CLIC CSRs */\n",
        1,
    )

needle = (
    "    {\n"
    "        .csrno = CSR_TH_MHINT,\n"
    "        .insertion_test = test_thead_mvendorid,\n"
    "        .csr_ops = { \"th.mhint\", mmode, read_th_mhint, write_th_mhint }\n"
    "    },\n"
)
if '"th.mapbaddr"' not in text and needle in text:
    text = text.replace(
        needle,
        needle
        + "    {\n"
          "        .csrno = CSR_TH_MAPBADDR,\n"
          "        .insertion_test = test_thead_mvendorid,\n"
          "        .csr_ops = { \"th.mapbaddr\", mmode, read_th_mapbaddr }\n"
          "    },\n",
        1,
    )

if text != orig:
    path.write_text(text)
PY
echo "  Patched target/riscv/th_csr.c (BL808 MAPBADDR)"

# Remove the legacy BL808 USB model from the target tree. The BL808 machine
# now owns a single register-level USB block in hw/misc.
rm -f "$QEMU_SRC/hw/usb/bl808_usb.c" "$QEMU_SRC/include/hw/usb/bl808_usb.h"
python3 - "$QEMU_SRC/hw/usb/meson.build" << 'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
lines = [line for line in text.splitlines() if "bl808_usb.c" not in line]
new_text = "\n".join(lines) + "\n"
if new_text != text:
    path.write_text(new_text)
PY
echo "  Removed legacy hw/usb/bl808_usb.c from target tree"

# Normalize hw/riscv/Kconfig BL808 stanza
python3 - "$QEMU_SRC/hw/riscv/Kconfig" << 'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text().splitlines()
changed = False
desired = [
    "config BL808",
    "    bool",
    "    default y",
    "    depends on RISCV32 || RISCV64",
    "    select XT_CLIC",
    "    select THEAD_CLINT",
    "    select RISCV_ACLINT",
    "    select SIFIVE_PLIC",
    "    select BL808_DMA",
    "    select I2C",
    "    select AT24C",
    "    select SIFIVE_GPIO",
    "    select SIFIVE_SPI",
    "    select SIFIVE_PWM",
    "    select SIFIVE_PDMA",
    "    select SSI_M25P80",
    "    select BL808_EMAC",
    "    select SDHCI",
    "    select BL808_SF_CTRL",
    "    select UNIMP",
]

start = next((i for i, line in enumerate(lines) if line == "config BL808"), None)

if start is None:
    if lines and lines[-1] != "":
        lines.append("")
    lines.extend(desired)
    changed = True
else:
    end = start + 1
    while end < len(lines) and not lines[end].startswith("config "):
        end += 1
    if lines[start:end] != desired:
        lines[start:end] = desired
        changed = True

if changed:
    path.write_text("\n".join(lines) + "\n")
PY
echo "  Normalized hw/riscv/Kconfig (BL808)"

# Patch hw/riscv/meson.build if not already done
if ! grep -q "bl808" "$QEMU_SRC/hw/riscv/meson.build"; then
    sed -i.bak "/^riscv_ss.add/a\\
riscv_ss.add(when: 'CONFIG_BL808', if_true: files('bl808.c'))
" "$QEMU_SRC/hw/riscv/meson.build"
    echo "  Patched hw/riscv/meson.build"
fi

# Patch hw/char/meson.build if not already done
if ! grep -q "bl808_uart" "$QEMU_SRC/hw/char/meson.build"; then
    echo "system_ss.add(when: 'CONFIG_BL808', if_true: files('bl808_uart.c'))" \
        >> "$QEMU_SRC/hw/char/meson.build"
    echo "  Patched hw/char/meson.build"
fi

# Patch hw/audio/meson.build for BL808 audio-class devices
if ! grep -q "bl808_audio.c" "$QEMU_SRC/hw/audio/meson.build"; then
    echo "system_ss.add(when: 'CONFIG_BL808', if_true: files('bl808_audio.c', 'bl808_i2s.c'))" \
        >> "$QEMU_SRC/hw/audio/meson.build"
    echo "  Patched hw/audio/meson.build"
fi

# Patch hw/misc/meson.build for GLB and IPC
if ! grep -q "bl808_glb" "$QEMU_SRC/hw/misc/meson.build"; then
    echo "system_ss.add(when: 'CONFIG_BL808', if_true: files('bl808_glb.c'))" \
        >> "$QEMU_SRC/hw/misc/meson.build"
    echo "  Patched hw/misc/meson.build (glb)"
fi
if ! grep -q "bl808_ipc" "$QEMU_SRC/hw/misc/meson.build"; then
    echo "system_ss.add(when: 'CONFIG_BL808', if_true: files('bl808_ipc.c'))" \
        >> "$QEMU_SRC/hw/misc/meson.build"
    echo "  Patched hw/misc/meson.build (ipc)"
fi
if ! grep -q "bl808_cci" "$QEMU_SRC/hw/misc/meson.build"; then
    echo "system_ss.add(when: 'CONFIG_BL808', if_true: files('bl808_cci.c'))" \
        >> "$QEMU_SRC/hw/misc/meson.build"
    echo "  Patched hw/misc/meson.build (cci)"
fi
if ! grep -q "bl808_cks" "$QEMU_SRC/hw/misc/meson.build"; then
    echo "system_ss.add(when: 'CONFIG_BL808', if_true: files('bl808_cks.c'))" \
        >> "$QEMU_SRC/hw/misc/meson.build"
    echo "  Patched hw/misc/meson.build (cks)"
fi
if ! grep -q "bl808_emi" "$QEMU_SRC/hw/misc/meson.build"; then
    echo "system_ss.add(when: 'CONFIG_BL808', if_true: files('bl808_emi.c'))" \
        >> "$QEMU_SRC/hw/misc/meson.build"
    echo "  Patched hw/misc/meson.build (emi)"
fi
if ! grep -q "bl808_gpip" "$QEMU_SRC/hw/misc/meson.build"; then
    echo "system_ss.add(when: 'CONFIG_BL808', if_true: files('bl808_gpip.c'))" \
        >> "$QEMU_SRC/hw/misc/meson.build"
    echo "  Patched hw/misc/meson.build (gpip)"
fi
if ! grep -q "bl808_mcu_misc" "$QEMU_SRC/hw/misc/meson.build"; then
    echo "system_ss.add(when: 'CONFIG_BL808', if_true: files('bl808_mcu_misc.c'))" \
        >> "$QEMU_SRC/hw/misc/meson.build"
    echo "  Patched hw/misc/meson.build (mcu_misc)"
fi
if ! grep -q "bl808_mm_misc" "$QEMU_SRC/hw/misc/meson.build"; then
    echo "system_ss.add(when: 'CONFIG_BL808', if_true: files('bl808_mm_misc.c'))" \
        >> "$QEMU_SRC/hw/misc/meson.build"
    echo "  Patched hw/misc/meson.build (mm_misc)"
fi
if ! grep -q "bl808_psram_ctrl" "$QEMU_SRC/hw/misc/meson.build"; then
    echo "system_ss.add(when: 'CONFIG_BL808', if_true: files('bl808_psram_ctrl.c'))" \
        >> "$QEMU_SRC/hw/misc/meson.build"
    echo "  Patched hw/misc/meson.build (psram)"
fi
if ! grep -q "bl808_sec_eng" "$QEMU_SRC/hw/misc/meson.build"; then
    echo "system_ss.add(when: 'CONFIG_BL808', if_true: files('bl808_sec_eng.c'))" \
        >> "$QEMU_SRC/hw/misc/meson.build"
    echo "  Patched hw/misc/meson.build (sec_eng)"
fi
if ! grep -q "bl808_tzc" "$QEMU_SRC/hw/misc/meson.build"; then
    echo "system_ss.add(when: 'CONFIG_BL808', if_true: files('bl808_tzc.c'))" \
        >> "$QEMU_SRC/hw/misc/meson.build"
    echo "  Patched hw/misc/meson.build (tzc)"
fi
if ! grep -q "bl808_usb" "$QEMU_SRC/hw/misc/meson.build"; then
    echo "system_ss.add(when: 'CONFIG_BL808', if_true: files('bl808_usb.c'))" \
        >> "$QEMU_SRC/hw/misc/meson.build"
    echo "  Patched hw/misc/meson.build (usb)"
fi

# Patch hw/ssi/meson.build for BL808 SPI
if ! grep -q "bl808_spi" "$QEMU_SRC/hw/ssi/meson.build"; then
    echo "system_ss.add(when: 'CONFIG_BL808', if_true: files('bl808_spi.c'))" \
        >> "$QEMU_SRC/hw/ssi/meson.build"
    echo "  Patched hw/ssi/meson.build"
fi

# Patch hw/i2c/meson.build for BL808 I2C
if ! grep -q "bl808_i2c" "$QEMU_SRC/hw/i2c/meson.build"; then
    echo "system_ss.add(when: 'CONFIG_BL808', if_true: files('bl808_i2c.c'))" \
        >> "$QEMU_SRC/hw/i2c/meson.build"
    echo "  Patched hw/i2c/meson.build"
fi

# Patch hw/timer/meson.build for BL808 PWM/Timer
if ! grep -q "bl808_pwm" "$QEMU_SRC/hw/timer/meson.build"; then
    echo "system_ss.add(when: 'CONFIG_BL808', if_true: files('bl808_pwm.c'))" \
        >> "$QEMU_SRC/hw/timer/meson.build"
    echo "  Patched hw/timer/meson.build"
fi
if ! grep -q "bl808_timer" "$QEMU_SRC/hw/timer/meson.build"; then
    echo "system_ss.add(when: 'CONFIG_BL808', if_true: files('bl808_timer.c'))" \
        >> "$QEMU_SRC/hw/timer/meson.build"
    echo "  Patched hw/timer/meson.build (timer)"
fi

# Patch hw/dma for BL808 DMA
if ! grep -q "^config BL808_DMA$" "$QEMU_SRC/hw/dma/Kconfig"; then
    cat >> "$QEMU_SRC/hw/dma/Kconfig" << 'DMA_EOF'

config BL808_DMA
    bool
DMA_EOF
    echo "  Patched hw/dma/Kconfig"
fi
if grep -q "CONFIG_BL808', if_true: files('bl808_dma.c')" "$QEMU_SRC/hw/dma/meson.build"; then
    sed -i.bak "s/CONFIG_BL808', if_true: files('bl808_dma.c')/CONFIG_BL808_DMA', if_true: files('bl808_dma.c')/" \
        "$QEMU_SRC/hw/dma/meson.build"
    echo "  Patched hw/dma/meson.build (config guard)"
fi
if ! grep -q "CONFIG_BL808_DMA', if_true: files('bl808_dma.c')" "$QEMU_SRC/hw/dma/meson.build"; then
    echo "system_ss.add(when: 'CONFIG_BL808_DMA', if_true: files('bl808_dma.c'))" \
        >> "$QEMU_SRC/hw/dma/meson.build"
    echo "  Patched hw/dma/meson.build"
fi
if ! grep -q "bl808_dma2d.c" "$QEMU_SRC/hw/dma/meson.build"; then
    echo "system_ss.add(when: 'CONFIG_BL808', if_true: files('bl808_dma2d.c'))" \
        >> "$QEMU_SRC/hw/dma/meson.build"
    echo "  Patched hw/dma/meson.build (dma2d)"
fi

# Patch hw/intc/meson.build for XT_CLIC
if ! grep -q "xt_clic" "$QEMU_SRC/hw/intc/meson.build"; then
    echo "specific_ss.add(when: 'CONFIG_XT_CLIC', if_true: files('xt_clic.c'))" \
        >> "$QEMU_SRC/hw/intc/meson.build"
    echo "  Patched hw/intc/meson.build"
fi
# Patch hw/intc/Kconfig for XT_CLIC
if ! grep -q "^config XT_CLIC$" "$QEMU_SRC/hw/intc/Kconfig"; then
    cat >> "$QEMU_SRC/hw/intc/Kconfig" << 'INTC_EOF'

config XT_CLIC
    bool
INTC_EOF
    echo "  Patched hw/intc/Kconfig"
fi
if ! grep -q "^config THEAD_CLINT$" "$QEMU_SRC/hw/intc/Kconfig"; then
    cat >> "$QEMU_SRC/hw/intc/Kconfig" << 'INTC_EOF'

config THEAD_CLINT
    bool
INTC_EOF
    echo "  Patched hw/intc/Kconfig (thead_clint)"
fi
if ! grep -q "thead_clint.c" "$QEMU_SRC/hw/intc/meson.build"; then
    echo "specific_ss.add(when: 'CONFIG_THEAD_CLINT', if_true: files('thead_clint.c'))" \
        >> "$QEMU_SRC/hw/intc/meson.build"
    echo "  Patched hw/intc/meson.build (thead_clint)"
fi

# Patch hw/net/meson.build for EMAC
if ! grep -q "bl808_emac" "$QEMU_SRC/hw/net/meson.build"; then
    echo "system_ss.add(when: 'CONFIG_BL808_EMAC', if_true: files('bl808_emac.c'))" \
        >> "$QEMU_SRC/hw/net/meson.build"
    echo "  Patched hw/net/meson.build"
fi
if ! grep -q "^config BL808_EMAC$" "$QEMU_SRC/hw/net/Kconfig"; then
    cat >> "$QEMU_SRC/hw/net/Kconfig" << 'NET_EOF'

config BL808_EMAC
    bool
    select NETDEVICES
NET_EOF
    echo "  Patched hw/net/Kconfig"
fi

# Patch hw/block for SF controller
if ! grep -q "^config BL808_SF_CTRL$" "$QEMU_SRC/hw/block/Kconfig"; then
    cat >> "$QEMU_SRC/hw/block/Kconfig" << 'BLOCK_EOF'

config BL808_SF_CTRL
    bool
BLOCK_EOF
    echo "  Patched hw/block/Kconfig"
fi
if ! grep -q "bl808_sf_ctrl.c" "$QEMU_SRC/hw/block/meson.build"; then
    echo "system_ss.add(when: 'CONFIG_BL808_SF_CTRL', if_true: files('bl808_sf_ctrl.c'))" \
        >> "$QEMU_SRC/hw/block/meson.build"
    echo "  Patched hw/block/meson.build"
fi

echo ""
echo "Files installed. To build QEMU with BL808 support:"
echo ""
echo "  cd $QEMU_SRC"
echo "  mkdir -p build && cd build"
echo "  ../configure --target-list=riscv32-softmmu,riscv64-softmmu"
echo "  make -j\$(nproc)"
echo ""
echo "Then run:"
echo "  ./build/qemu-system-riscv64 -M bl808 -nographic -kernel m0_firmware.elf"
echo "  ./build/qemu-system-riscv64 -M bl808,flash-image=ox64-flash.bin -nographic"
echo "  ./build/qemu-system-riscv64 -M bl808,flash-image=ox64-flash.bin,boot-gpio39=on -nographic"
echo "  ./build/qemu-system-riscv64 -M bl808,d0-firmware=d0.elf,lp-firmware=lp.elf -kernel m0.elf -nographic"
echo "  ./build/qemu-system-riscv64 -M bl808,strict-fidelity=on,flash-image=ox64-flash.bin,bootrom-image=bootrom.bin -nographic"
