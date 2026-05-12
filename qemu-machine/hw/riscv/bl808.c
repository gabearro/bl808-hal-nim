/*
 * QEMU Bouffalo Lab BL808 machine emulation
 *
 * Triple-core RISC-V SoC:
 *   M0: T-Head E907 (RV32IMAFC) -- boots from flash XIP at 0x58000000
 *   D0: T-Head C906 (RV64IMAFDC) -- loaded by M0 into DRAM
 *   LP: T-Head E902 (RV32EMC) -- boots from flash XIP at 0x58020000
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "qemu/log.h"
#include "qemu/timer.h"
#include "qemu/units.h"
#include "qapi/error.h"
#include "qapi/visitor.h"
#include "qobject/qdict.h"
#include "hw/boards.h"
#include "hw/core/cpu.h"
#include "hw/loader.h"
#include "hw/irq.h"
#include "hw/sysbus.h"
#include "hw/qdev-properties.h"
#include "hw/sd/sd.h"
#include "hw/i2c/bl808_i2c.h"
#include "hw/riscv/riscv_hart.h"
#include "hw/riscv/bl808.h"
#include "hw/intc/xt_clic.h"
#include "hw/intc/thead_clint.h"
#include "hw/misc/bl808_cci.h"
#include "hw/misc/bl808_cks.h"
#include "hw/misc/bl808_emi.h"
#include "hw/misc/bl808_glb.h"
#include "hw/misc/bl808_ipc.h"
#include "hw/misc/bl808_mcu_misc.h"
#include "hw/misc/bl808_mm_misc.h"
#include "hw/misc/bl808_psram_ctrl.h"
#include "hw/intc/riscv_aclint.h"
#include "hw/intc/sifive_plic.h"
#include "target/riscv/cpu.h"
#include "target/riscv/cpu-qom.h"
#include "system/system.h"
#include "system/reset.h"
#include "system/runstate.h"
#include "system/block-backend.h"
#include "system/block-backend-global-state.h"
#include "block/block-common.h"
#include "chardev/char.h"
#include "elf.h"
#include "exec/cpu-common.h"

/* ========================================================================= */
/* Core ID register (read-only, returns core identity)                        */
/* ========================================================================= */

static uint64_t core_id_read(void *opaque, hwaddr offset, unsigned size)
{
    CPUState *cpu = current_cpu;
    if (cpu) {
        RISCVCPU *rvcpu = RISCV_CPU(cpu);
        switch (rvcpu->env.mhartid) {
        case 0: return BL808_CORE_ID_M0;
        case 1: return BL808_CORE_ID_D0;
        case 2: return BL808_CORE_ID_LP;
        }
    }
    return BL808_CORE_ID_M0; /* fallback for DMA/non-CPU access */
}

static void core_id_write(void *opaque, hwaddr offset, uint64_t value,
                           unsigned size)
{
    /* Read-only */
}

static const MemoryRegionOps core_id_ops = {
    .read = core_id_read,
    .write = core_id_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
};

/* ========================================================================= */
/* XRAM shared memory (I/O-style for cross-CPU coherency)                     */
/* ========================================================================= */

static uint8_t *xram_buf;

static uint64_t xram_read(void *opaque, hwaddr offset, unsigned size)
{
    uint64_t val = 0;
    memcpy(&val, xram_buf + offset, size);
    return val;
}

static void xram_write(void *opaque, hwaddr offset, uint64_t value,
                        unsigned size)
{
    memcpy(xram_buf + offset, &value, size);
}

static const MemoryRegionOps xram_ops = {
    .read = xram_read,
    .write = xram_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 8 },
    .impl  = { .min_access_size = 1, .max_access_size = 8 },
};

static uint64_t psram_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808SoCState *s = opaque;
    uint64_t val = 0;

    if (!runstate_is_running() ||
        bl808_psram_ctrl_memory_enabled(&s->psram_ctrl)) {
        memcpy(&val, s->psram_buf + offset, size);
        return val;
    }

    memset(&val, 0xFF, size);
    return val;
}

static void psram_write(void *opaque, hwaddr offset, uint64_t value,
                        unsigned size)
{
    BL808SoCState *s = opaque;

    if (!runstate_is_running() ||
        bl808_psram_ctrl_memory_enabled(&s->psram_ctrl)) {
        memcpy(s->psram_buf + offset, &value, size);
    }
}

static const MemoryRegionOps psram_ops = {
    .read = psram_read,
    .write = psram_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 8 },
    .impl  = { .min_access_size = 1, .max_access_size = 8 },
};

static bool bl808_regbank_accessible(const BL808RegBank *bank)
{
    return !bank->mm_domain || bank->machine->mm_powered_on;
}

static uint64_t bl808_regbank_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808RegBank *bank = opaque;
    uint64_t value = 0;

    if (offset + size > sizeof(bank->regs)) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "%s: read beyond register window @ 0x%" HWADDR_PRIx "\n",
                      bank->name, offset);
        return 0;
    }

    if (!bl808_regbank_accessible(bank)) {
        return 0;
    }

    memcpy(&value, (uint8_t *)bank->regs + offset, size);
    return value;
}

static void bl808_regbank_write(void *opaque, hwaddr offset, uint64_t value,
                                unsigned size)
{
    BL808RegBank *bank = opaque;

    if (offset + size > sizeof(bank->regs)) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "%s: write beyond register window @ 0x%" HWADDR_PRIx "\n",
                      bank->name, offset);
        return;
    }

    if (!bl808_regbank_accessible(bank)) {
        return;
    }

    memcpy((uint8_t *)bank->regs + offset, &value, size);
}

static const MemoryRegionOps bl808_regbank_ops = {
    .read = bl808_regbank_read,
    .write = bl808_regbank_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 4 },
    .impl  = { .min_access_size = 1, .max_access_size = 4 },
};

static void bl808_reset_regbank(BL808RegBank *bank)
{
    memset(bank->regs, 0, sizeof(bank->regs));
}

static void bl808_reset_regbanks(BL808MachineState *s)
{
    bl808_reset_regbank(&s->lz4d);
    bl808_reset_regbank(&s->dvp0);
    bl808_reset_regbank(&s->osd_a);
    bl808_reset_regbank(&s->osd_dp);
    bl808_reset_regbank(&s->dbi);
    bl808_reset_regbank(&s->codec_misc);
    bl808_reset_regbank(&s->mjpeg);
    bl808_reset_regbank(&s->h264);
    bl808_reset_regbank(&s->mjpeg_dec);
    bl808_reset_regbank(&s->blai);
}

static void bl808_reset_mm_regbanks(BL808MachineState *s)
{
    bl808_reset_regbank(&s->dvp0);
    bl808_reset_regbank(&s->osd_a);
    bl808_reset_regbank(&s->osd_dp);
    bl808_reset_regbank(&s->dbi);
    bl808_reset_regbank(&s->codec_misc);
    bl808_reset_regbank(&s->mjpeg);
    bl808_reset_regbank(&s->h264);
    bl808_reset_regbank(&s->mjpeg_dec);
    bl808_reset_regbank(&s->blai);
}

static void bl808_sync_flash_xip_to_sf_ctrl(BL808SoCState *s)
{
    uint8_t *xip;

    if (!s->sf_ctrl.flash) {
        return;
    }

    xip = memory_region_get_ram_ptr(&s->flash_xip);
    memcpy(s->sf_ctrl.flash, xip, BL808_SF_CTRL_FLASH_SIZE);
    bl808_sf_ctrl_sync_all_xip(&s->sf_ctrl);
}

typedef struct BL808IRQFanout {
    qemu_irq first;
    qemu_irq second;
} BL808IRQFanout;

static void bl808_irq_fanout(void *opaque, int n, int level)
{
    BL808IRQFanout *fanout = opaque;

    qemu_set_irq(fanout->first, level);
    qemu_set_irq(fanout->second, level);
}

static qemu_irq bl808_split_irq2(qemu_irq first, qemu_irq second)
{
    BL808IRQFanout *fanout = g_new(BL808IRQFanout, 1);

    fanout->first = first;
    fanout->second = second;
    return qemu_allocate_irq(bl808_irq_fanout, fanout, 0);
}

#define BL808_GLB_UART_CFG0       0x150
#define BL808_GLB_EMI_CFG0        0x0E0
#define BL808_GLB_I2S_CFG0        0x190
#define BL808_GLB_SPI_CFG0        0x1B0
#define BL808_GLB_I2C_CFG0        0x180
#define BL808_GLB_DMA_CFG0        0x130
#define BL808_GLB_SWRST_CFG1      0x544
#define BL808_GLB_SWRST_CFG2      0x548
#define BL808_GLB_CGEN_CFG1       0x584
#define BL808_GLB_CGEN_CFG2       0x588
#define BL808_GLB_SYS_CFG0        0x090
#define BL808_GLB_SYS_CFG1        0x094
#define BL808_GLB_DIG_CLK_CFG1    0x254
#define BL808_GLB_WIFI_PLL_CFG0   0x810
#define BL808_GLB_WIFI_PLL_CFG1   0x814
#define BL808_GLB_WIFI_PLL_CFG5   0x824
#define BL808_MM_GLB_MM_CLK_CTRL_CPU 0x00
#define BL808_MM_GLB_MM_CLK_CPU   0x04
#define BL808_MM_GLB_MM_SW_SYS_RESET 0x40
#define BL808_MM_GLB_CLK_CTRL_PERI  0x10
#define BL808_MM_GLB_CLK_CTRL_PERI3 0x18
#define BL808_MM_GLB_SW_RESET_PERI  0x44

#define BL808_GLB_UART_CLK_EN       BIT(4)
#define BL808_GLB_I2S_CLK_EN        BIT(7)
#define BL808_GLB_SPI_CLK_EN        BIT(8)
#define BL808_GLB_I2C_CLK_EN        BIT(24)
#define BL808_GLB_REG_PLL_EN        BIT(0)
#define BL808_GLB_REG_BCLK_EN       BIT(3)
#define BL808_GLB_REG_CTRL_PICO_RESET BIT(3)
#define BL808_MM_RESET_DMA2         BIT(1)
#define BL808_MM_RESET_UART3        BIT(2)
#define BL808_MM_RESET_I2C2         BIT(3)
#define BL808_MM_RESET_I2C3         BIT(4)
#define BL808_MM_RESET_SPI1         BIT(8)
#define BL808_MM_RESET_TIMER1       BIT(9)
#define BL808_MM_GLB_REG_PLL_EN     BIT(0)
#define BL808_MM_GLB_REG_BCLK_EN    BIT(2)
#define BL808_MM_GLB_REG_MMCPU0_CLK_EN BIT(12)
#define BL808_MM_GLB_REG_CTRL_MMCPU0_RESET BIT(8)
#define BL808_MM_UART3_CLK_EN       BIT(16)
#define BL808_MM_SPI1_CLK_EN        BIT(23)
#define BL808_MM_I2C2_CLK_EN        BIT(9)
#define BL808_MM_I2C3_CLK_EN        BIT(9)
#define BL808_GLB_BCLK_DIV_ACT_PULSE BIT(0)
#define BL808_GLB_BCLK_DIV_BYPASS    BIT(1)
#define BL808_HBN_GLB_OFFSET        0x30
#define BL808_PDS_CPU_CORE_CFG0_OFFSET 0x110
#define BL808_PDS_CPU_CORE_CFG1_OFFSET 0x114
#define BL808_PDS_CPU_CORE_CFG13_OFFSET 0x144
#define BL808_PDS_CPU_CORE_CFG14_OFFSET 0x148
#define BL808_GLB_WIFI_PLL_CFG6     0x828
#define BL808_GLB_WIFI_PLL_CFG8     0x830
#define BL808_PDS_REG_PICO_CLK_EN   BIT(28)
#define BL808_PDS_REG_PLL_SEL_SHIFT 4
#define BL808_MM_MISC_CPU0_BOOT     0x000
#define BL808_MM_MISC_CPU0_BOOT_RESET 0x3eff0000U
#define BL808_CCI_AUDIO_PLL_CFG0    0x750
#define BL808_CCI_AUDIO_PLL_CFG1    0x754
#define BL808_CCI_AUDIO_PLL_CFG6    0x768
#define BL808_CCI_AUDIO_PLL_CFG8    0x770
#define BL808_CCI_CPU_PLL_CFG0      0x7D0
#define BL808_CCI_CPU_PLL_CFG1      0x7D4
#define BL808_CCI_CPU_PLL_CFG6      0x7E8
#define BL808_CCI_CPU_PLL_CFG8      0x7F0

static uint64_t bl808_soc_timer_xtal_hz(const BL808MachineState *s);
static uint64_t bl808_d0_reset_pc(BL808MachineState *s);
static bool bl808_d0_clock_enabled(const BL808MachineState *s);
static bool bl808_d0_reset_asserted(const BL808MachineState *s);
static uint64_t bl808_lp_reset_pc(BL808MachineState *s);
static bool bl808_lp_clock_enabled(const BL808MachineState *s);
static bool bl808_lp_reset_asserted(const BL808MachineState *s);
static void bl808_hold_lp(BL808MachineState *s, uint64_t pc);
static void bl808_update_lp_state(BL808MachineState *s, bool reset_lp);
static void bl808_hold_d0(BL808MachineState *s, uint64_t pc);
static void bl808_release_or_resume_d0(BL808MachineState *s);

static uint64_t bl808_soc_pll_vco_hz(uint64_t xtal_hz, uint32_t sdmin,
                                     bool audio_pll)
{
    uint64_t vco_hz;
    unsigned ref_div;

    if (xtal_hz == 0 || sdmin == 0) {
        return 0;
    }

    ref_div = (xtal_hz == 24000000ULL || xtal_hz == 26000000ULL) ? 2 : 4;
    vco_hz = (xtal_hz * (uint64_t)sdmin) / ((1u << 11) * ref_div);

    if (audio_pll) {
        if (vco_hz >= 451000000ULL && vco_hz <= 452000000ULL) {
            return 451584000ULL;
        }
        if (vco_hz >= 442000000ULL && vco_hz <= 443000000ULL) {
            return 442368000ULL;
        }
        return 0;
    }

    if (vco_hz >= 475000000ULL && vco_hz <= 485000000ULL) {
        return 480000000ULL;
    }
    if (vco_hz >= 395000000ULL && vco_hz <= 405000000ULL) {
        return 400000000ULL;
    }
    if (vco_hz >= 375000000ULL && vco_hz <= 385000000ULL) {
        return 380000000ULL;
    }
    return 0;
}

static bool bl808_soc_pll_core_enabled(uint32_t cfg0)
{
    return (cfg0 & BIT(0)) && (cfg0 & BIT(2)) &&
        (cfg0 & BIT(9)) && (cfg0 & BIT(10));
}

static uint64_t bl808_soc_pll_refclk_hz(const BL808MachineState *s,
                                        uint32_t cfg1, bool wifi_pll)
{
    uint32_t refclk_sel = extract32(cfg1, 16, 2);

    if (wifi_pll) {
        if (refclk_sel == 1) {
            return bl808_soc_timer_xtal_hz(s);
        }
    } else if (refclk_sel == 0) {
        return bl808_soc_timer_xtal_hz(s);
    }

    if (refclk_sel == 3) {
        return 32000000ULL;
    }

    return 0;
}

static bool bl808_soc_wifi_pll_output_enabled(const BL808MachineState *s,
                                              uint64_t requested_hz)
{
    if (!bl808_soc_pll_core_enabled(s->timer_glb_wifi_pll_cfg0)) {
        return false;
    }

    switch (requested_hz) {
    case 320000000ULL:
        return s->timer_glb_wifi_pll_cfg5 & BIT(12);
    case 240000000ULL:
        return s->timer_glb_wifi_pll_cfg8 & BIT(1);
    case 160000000ULL:
        return s->timer_glb_wifi_pll_cfg8 & BIT(3);
    default:
        return true;
    }
}

static bool bl808_soc_aupll_output_enabled(uint32_t cfg0, uint32_t cfg8,
                                           unsigned div)
{
    if (!bl808_soc_pll_core_enabled(cfg0)) {
        return false;
    }

    switch (div) {
    case 1:
        return cfg8 & BIT(0);
    case 2:
        return cfg8 & BIT(1);
    default:
        return true;
    }
}

static bool bl808_soc_cpu_pll_output_enabled(uint32_t cfg0, uint32_t cfg8,
                                             uint64_t requested_hz)
{
    if (!bl808_soc_pll_core_enabled(cfg0)) {
        return false;
    }

    switch (requested_hz) {
    case 400000000ULL:
        return cfg8 & BIT(0);
    case 200000000ULL:
        return cfg8 & BIT(1);
    case 160000000ULL:
        return cfg8 & BIT(2);
    case 100000000ULL:
        return cfg8 & BIT(4);
    case 80000000ULL:
        return cfg8 & BIT(5);
    default:
        return true;
    }
}

static uint64_t bl808_soc_wifi_pll_output_hz(const BL808MachineState *s,
                                             uint64_t requested_hz)
{
    uint32_t sdmin = extract32(s->timer_glb_wifi_pll_cfg6, 0, 26);
    uint64_t refclk_hz =
        bl808_soc_pll_refclk_hz(s, s->timer_glb_wifi_pll_cfg1, true);
    uint64_t calculation_div = 1u << 19;
    uint64_t vco_hz;

    if (sdmin == 0 || refclk_hz == 0 ||
        !bl808_soc_wifi_pll_output_enabled(s, requested_hz)) {
        return 0;
    }

    switch (refclk_hz) {
    case 24000000ULL:
        vco_hz = (sdmin / calculation_div) * 24000000ULL;
        break;
    case 32000000ULL:
        vco_hz = (sdmin / calculation_div) * 16000000ULL;
        break;
    case 38400000ULL:
        vco_hz = (sdmin / calculation_div) * 19200000ULL;
        break;
    case 40000000ULL:
        vco_hz = (sdmin / calculation_div) * 20000000ULL;
        break;
    case 26000000ULL:
        vco_hz = ((200ULL * sdmin) / calculation_div) * 26ULL * 5000ULL;
        break;
    default:
        return 0;
    }

    if (vco_hz >= 955000000ULL && vco_hz <= 965000000ULL) {
        return requested_hz;
    }

    return 0;
}

static uint64_t bl808_soc_aupll_output_hz(const BL808MachineState *s,
                                          unsigned div)
{
    uint32_t cfg0 = s->soc.cci.regs[BL808_CCI_AUDIO_PLL_CFG0 / 4];
    uint32_t cfg1 = s->soc.cci.regs[BL808_CCI_AUDIO_PLL_CFG1 / 4];
    uint32_t cfg8 = s->soc.cci.regs[BL808_CCI_AUDIO_PLL_CFG8 / 4];
    uint32_t sdmin = extract32(s->soc.cci.regs[BL808_CCI_AUDIO_PLL_CFG6 / 4],
                               0, 19);
    uint64_t refclk_hz = bl808_soc_pll_refclk_hz(s, cfg1, false);
    uint64_t vco_hz;

    if (div == 0 || refclk_hz == 0 ||
        !bl808_soc_aupll_output_enabled(cfg0, cfg8, div)) {
        return 0;
    }

    vco_hz = bl808_soc_pll_vco_hz(refclk_hz, sdmin, true);
    if (vco_hz == 0) {
        return 0;
    }

    return vco_hz / div;
}

static uint64_t bl808_soc_cpu_pll_output_hz(const BL808MachineState *s,
                                            uint64_t requested_hz)
{
    uint32_t cfg0 = s->soc.cci.regs[BL808_CCI_CPU_PLL_CFG0 / 4];
    uint32_t cfg1 = s->soc.cci.regs[BL808_CCI_CPU_PLL_CFG1 / 4];
    uint32_t cfg8 = s->soc.cci.regs[BL808_CCI_CPU_PLL_CFG8 / 4];
    uint32_t sdmin = extract32(s->soc.cci.regs[BL808_CCI_CPU_PLL_CFG6 / 4],
                               0, 19);
    uint64_t refclk_hz = bl808_soc_pll_refclk_hz(s, cfg1, false);
    uint64_t vco_hz;

    if (refclk_hz == 0 ||
        !bl808_soc_cpu_pll_output_enabled(cfg0, cfg8, requested_hz)) {
        return 0;
    }

    vco_hz = bl808_soc_pll_vco_hz(refclk_hz, sdmin, false);
    if (vco_hz == 0) {
        return 0;
    }

    if (vco_hz == 480000000ULL) {
        return (requested_hz / 100ULL) * 120ULL;
    }
    if (vco_hz == 400000000ULL) {
        return requested_hz;
    }
    if (vco_hz == 380000000ULL) {
        return (requested_hz / 100ULL) * 95ULL;
    }
    return 0;
}

static void bl808_soc_spi_clock_notify(void *opaque, bool enabled)
{
    bl808_spi_set_clock_enabled(BL808_SPI(opaque), enabled);
}

static void bl808_soc_spi_reset_notify(void *opaque, bool asserted)
{
    bl808_spi_set_reset_asserted(BL808_SPI(opaque), asserted);
}

static void bl808_soc_mcu_spi_clock_config_notify(void *opaque, hwaddr offset,
                                                  uint32_t value)
{
    (void)offset;
    bl808_spi_set_module_clock_enabled(BL808_SPI(opaque),
                                       (value & BL808_GLB_SPI_CLK_EN) != 0);
}

static void bl808_soc_mm_spi_clock_config_notify(void *opaque, hwaddr offset,
                                                 uint32_t value)
{
    (void)offset;
    bl808_spi_set_module_clock_enabled(BL808_SPI(opaque),
                                       (value & BL808_MM_SPI1_CLK_EN) != 0);
}

static void bl808_soc_pwm_clock_notify(void *opaque, bool enabled)
{
    bl808_pwm_set_clock_enabled(BL808_PWM(opaque), enabled);
}

static void bl808_soc_pwm_reset_notify(void *opaque, bool asserted)
{
    bl808_pwm_set_reset_asserted(BL808_PWM(opaque), asserted);
}

static void bl808_soc_dma_clock_notify(void *opaque, bool enabled)
{
    bl808_dma_set_clock_enabled(BL808_DMA(opaque), enabled);
}

static void G_GNUC_UNUSED bl808_soc_dma_reset_notify(void *opaque, bool asserted)
{
    bl808_dma_set_reset_asserted(BL808_DMA(opaque), asserted);
}

static void bl808_soc_uart_clock_notify(void *opaque, bool enabled)
{
    bl808_uart_set_clock_enabled(BL808_UART(opaque), enabled);
}

static void bl808_soc_uart_reset_notify(void *opaque, bool asserted)
{
    bl808_uart_set_reset_asserted(BL808_UART(opaque), asserted);
}

static void bl808_soc_i2c_clock_notify(void *opaque, bool enabled)
{
    bl808_i2c_set_clock_enabled(BL808_I2C(opaque), enabled);
}

static void bl808_soc_i2c_reset_notify(void *opaque, bool asserted)
{
    bl808_i2c_set_reset_asserted(BL808_I2C(opaque), asserted);
}

static bool bl808_soc_mcu_pbclk_enabled(const BL808MachineState *s)
{
    return (s->timer_glb_sys_cfg0 & BL808_GLB_REG_BCLK_EN) != 0;
}

static bool bl808_soc_mm_pbclk_enabled(const BL808MachineState *s)
{
    return (s->timer1_mm_clk_ctrl_cpu & BL808_MM_GLB_REG_BCLK_EN) != 0;
}

static bool bl808_soc_mcu_uart_clock_available(const BL808MachineState *s)
{
    uint32_t cfg = s->glb_uart_cfg0;
    uint32_t sel = extract32(cfg, 7, 1) | (extract32(cfg, 22, 1) << 1);

    if (!(cfg & BL808_GLB_UART_CLK_EN)) {
        return false;
    }

    return sel != 0 || bl808_soc_mcu_pbclk_enabled(s);
}

static void bl808_soc_refresh_mcu_uart_clocks(BL808MachineState *s)
{
    bool enabled = bl808_soc_mcu_uart_clock_available(s);

    for (unsigned i = 0; i < 3; i++) {
        bl808_uart_set_module_clock_enabled(&s->soc.uart[i], enabled);
    }
}

static bool bl808_soc_mcu_i2c_clock_available(const BL808MachineState *s)
{
    uint32_t cfg = s->glb_i2c_cfg0;

    if (!(cfg & BL808_GLB_I2C_CLK_EN)) {
        return false;
    }

    return extract32(cfg, 25, 1) != 0 || bl808_soc_mcu_pbclk_enabled(s);
}

static void bl808_soc_refresh_mcu_i2c_clocks(BL808MachineState *s)
{
    bool enabled = bl808_soc_mcu_i2c_clock_available(s);

    bl808_i2c_set_module_clock_enabled(&s->soc.i2c0, enabled);
    bl808_i2c_set_module_clock_enabled(&s->soc.i2c1, enabled);
}

static bool bl808_soc_mm_uart_clock_available(const BL808MachineState *s)
{
    uint32_t cfg = s->mm_clk_ctrl_peri;
    uint32_t sel = extract32(s->timer1_mm_clk_ctrl_cpu, 4, 2);

    if (!(cfg & BL808_MM_UART3_CLK_EN)) {
        return false;
    }

    return sel != 0 || bl808_soc_mm_pbclk_enabled(s);
}

static bool bl808_soc_mm_i2c2_clock_available(const BL808MachineState *s)
{
    if (!(s->mm_clk_ctrl_peri & BL808_MM_I2C2_CLK_EN)) {
        return false;
    }

    return extract32(s->timer1_mm_clk_ctrl_cpu, 6, 1) != 0 ||
        bl808_soc_mm_pbclk_enabled(s);
}

static bool bl808_soc_mm_i2c3_clock_available(const BL808MachineState *s)
{
    if (!(s->mm_clk_ctrl_peri3 & BL808_MM_I2C3_CLK_EN)) {
        return false;
    }

    return extract32(s->timer1_mm_clk_ctrl_cpu, 6, 1) != 0 ||
        bl808_soc_mm_pbclk_enabled(s);
}

static void bl808_soc_refresh_mm_uart_i2c_clocks(BL808MachineState *s)
{
    bl808_uart_set_module_clock_enabled(&s->soc.uart[3],
                                        bl808_soc_mm_uart_clock_available(s));
    bl808_i2c_set_module_clock_enabled(&s->soc.i2c2,
                                       bl808_soc_mm_i2c2_clock_available(s));
    bl808_i2c_set_module_clock_enabled(&s->soc.i2c3,
                                       bl808_soc_mm_i2c3_clock_available(s));
}

static void bl808_soc_mcu_uart_clock_config_notify(void *opaque, hwaddr offset,
                                                   uint32_t value)
{
    BL808MachineState *s = opaque;

    if (offset != BL808_GLB_UART_CFG0) {
        return;
    }

    s->glb_uart_cfg0 = value;
    bl808_soc_refresh_mcu_uart_clocks(s);
}

static void bl808_soc_mcu_i2c_clock_config_notify(void *opaque, hwaddr offset,
                                                  uint32_t value)
{
    BL808MachineState *s = opaque;

    if (offset != BL808_GLB_I2C_CFG0) {
        return;
    }

    s->glb_i2c_cfg0 = value;
    bl808_soc_refresh_mcu_i2c_clocks(s);
}

static void G_GNUC_UNUSED bl808_soc_mm_clk_ctrl_peri_notify(void *opaque,
                                                            hwaddr offset,
                                                            uint32_t value)
{
    BL808MachineState *s = opaque;

    if (offset != BL808_MM_GLB_CLK_CTRL_PERI) {
        return;
    }

    s->mm_clk_ctrl_peri = value;
    bl808_soc_refresh_mm_uart_i2c_clocks(s);
}

static void G_GNUC_UNUSED bl808_soc_mm_clk_ctrl_peri3_notify(void *opaque,
                                                             hwaddr offset,
                                                             uint32_t value)
{
    BL808MachineState *s = opaque;

    if (offset != BL808_MM_GLB_CLK_CTRL_PERI3) {
        return;
    }

    s->mm_clk_ctrl_peri3 = value;
    bl808_soc_refresh_mm_uart_i2c_clocks(s);
}

static uint64_t bl808_soc_timer_xtal_hz(const BL808MachineState *s)
{
    uint32_t xtal_type = s->hbn_regs[0x10C / 4] & 0xFFFFu;

    if ((xtal_type & 0xFF00u) != 0x5800u) {
        return 40000000ULL;
    }

    switch (xtal_type & 0xFFu) {
    case 0:
        return 0;
    case 1:
        return 24000000ULL;
    case 2:
        return 32000000ULL;
    case 3:
        return 38400000ULL;
    case 4:
        return 40000000ULL;
    case 5:
        return 26000000ULL;
    case 6:
        return 32000000ULL;
    default:
        return 40000000ULL;
    }
}

static uint64_t bl808_soc_timer0_root_hz(const BL808MachineState *s)
{
    uint32_t hbn_glb = s->hbn_regs[BL808_HBN_GLB_OFFSET / 4];
    uint32_t root_sel = extract32(hbn_glb, 0, 2);

    if ((root_sel & 0x2u) == 0) {
        return (root_sel & 0x1u) ? bl808_soc_timer_xtal_hz(s) : 32000000ULL;
    }
    if (!(s->timer_glb_sys_cfg0 & BL808_GLB_REG_PLL_EN)) {
        return 0;
    }

    switch (extract32(s->pds_regs[BL808_PDS_CPU_CORE_CFG1_OFFSET / 4],
                      BL808_PDS_REG_PLL_SEL_SHIFT, 2)) {
    case 0:
        return bl808_soc_cpu_pll_output_hz(s, 400000000ULL);
    case 1:
        return bl808_soc_aupll_output_hz(s, 1);
    case 2:
        return bl808_soc_wifi_pll_output_hz(s, 240000000ULL);
    case 3:
        return bl808_soc_wifi_pll_output_hz(s, 320000000ULL);
    default:
        return 0;
    }
}

static uint64_t bl808_soc_timer0_bclk_hz(const BL808MachineState *s)
{
    uint64_t mcu_clk_hz =
        bl808_soc_timer0_root_hz(s) /
        (extract32(s->timer_glb_sys_cfg0, 8, 8) + 1ULL);

    if (!bl808_soc_mcu_pbclk_enabled(s)) {
        return 0;
    }

    if (s->timer_glb_sys_cfg1 & BL808_GLB_BCLK_DIV_BYPASS) {
        return mcu_clk_hz;
    }

    return mcu_clk_hz / (s->timer0_bclk_div_live + 1ULL);
}

static uint64_t bl808_soc_timer1_mm_xclk_hz(const BL808MachineState *s)
{
    return extract32(s->timer1_mm_clk_ctrl_cpu, 10, 1) ?
        bl808_soc_timer_xtal_hz(s) : 32000000ULL;
}

static uint64_t bl808_soc_timer1_mm_muxpll_160_hz(const BL808MachineState *s)
{
    if (!(s->timer1_mm_clk_ctrl_cpu & BL808_MM_GLB_REG_PLL_EN)) {
        return 0;
    }

    return extract32(s->timer_glb_dig_clk_cfg1, 0, 1) ?
        bl808_soc_cpu_pll_output_hz(s, 160000000ULL) :
        bl808_soc_wifi_pll_output_hz(s, 160000000ULL);
}

static uint64_t bl808_soc_timer1_mm_muxpll_240_hz(const BL808MachineState *s)
{
    if (!(s->timer1_mm_clk_ctrl_cpu & BL808_MM_GLB_REG_PLL_EN)) {
        return 0;
    }

    return extract32(s->timer_glb_dig_clk_cfg1, 1, 1) ?
        bl808_soc_aupll_output_hz(s, 2) :
        bl808_soc_wifi_pll_output_hz(s, 240000000ULL);
}

static uint64_t bl808_soc_timer1_bclk_hz(const BL808MachineState *s)
{
    uint32_t ctrl = s->timer1_mm_clk_ctrl_cpu;
    uint32_t cpu = s->timer1_mm_clk_cpu;
    uint32_t sel = extract32(ctrl, 13, 2);
    uint32_t div = extract32(cpu, 24, 8);
    uint64_t base_hz;

    switch (sel) {
    case 0:
    case 1:
        base_hz = bl808_soc_timer1_mm_xclk_hz(s);
        break;
    case 2:
        base_hz = bl808_soc_timer1_mm_muxpll_160_hz(s);
        break;
    case 3:
        base_hz = bl808_soc_timer1_mm_muxpll_240_hz(s);
        break;
    default:
        base_hz = 0;
        break;
    }

    if (!bl808_soc_mm_pbclk_enabled(s)) {
        return 0;
    }

    return base_hz / (div + 1);
}

static void bl808_soc_refresh_timer0_clocks(BL808MachineState *s)
{
    if (!s->soc.timer0.channel_timer[0] || !s->soc.timer0.channel_timer[1] ||
        !s->soc.timer0.wdt_timer) {
        return;
    }

    bl808_timer_set_clock_inputs(&s->soc.timer0, bl808_soc_timer0_bclk_hz(s),
                                 bl808_soc_timer_xtal_hz(s),
                                 32768ULL);
}

static void bl808_soc_refresh_timer1_clocks(BL808MachineState *s)
{
    if (!s->soc.timer1.channel_timer[0] || !s->soc.timer1.channel_timer[1] ||
        !s->soc.timer1.wdt_timer) {
        return;
    }

    bl808_timer_set_clock_inputs(&s->soc.timer1, bl808_soc_timer1_bclk_hz(s),
                                 bl808_soc_timer_xtal_hz(s),
                                 32768ULL);
}

static void bl808_soc_timer0_clock_notify(void *opaque, bool enabled)
{
    BL808MachineState *s = opaque;

    bl808_timer_set_clock_enabled(&s->soc.timer0, enabled);
}

static void bl808_soc_timer0_reset_notify(void *opaque, bool asserted)
{
    BL808MachineState *s = opaque;

    bl808_timer_set_reset_asserted(&s->soc.timer0, asserted);
}

static void bl808_soc_timer0_clock_config_notify(void *opaque, hwaddr offset,
                                                 uint32_t value)
{
    BL808MachineState *s = opaque;

    if (offset != BL808_GLB_SYS_CFG0) {
        return;
    }

    s->timer_glb_sys_cfg0 = value;
    bl808_soc_refresh_timer0_clocks(s);
    bl808_soc_refresh_mcu_uart_clocks(s);
    bl808_soc_refresh_mcu_i2c_clocks(s);
}

static void bl808_soc_timer0_sys_cfg1_notify(void *opaque, hwaddr offset,
                                             uint32_t value)
{
    BL808MachineState *s = opaque;

    if (offset != BL808_GLB_SYS_CFG1) {
        return;
    }

    s->timer_glb_sys_cfg1 = value;
    if (value & BL808_GLB_BCLK_DIV_ACT_PULSE) {
        s->timer0_bclk_div_live = extract32(s->timer_glb_sys_cfg0, 16, 8);
    }
    bl808_soc_refresh_timer0_clocks(s);
}

static void bl808_soc_timer1_clock_notify(void *opaque, bool enabled)
{
    BL808MachineState *s = opaque;

    bl808_timer_set_clock_enabled(&s->soc.timer1, enabled);
}

static void bl808_soc_timer1_reset_notify(void *opaque, bool asserted)
{
    BL808MachineState *s = opaque;

    bl808_timer_set_reset_asserted(&s->soc.timer1, asserted);
}

static void bl808_soc_timer1_clk_ctrl_cpu_notify(void *opaque, hwaddr offset,
                                                 uint32_t value)
{
    BL808MachineState *s = opaque;
#ifdef TARGET_RISCV64
    uint32_t old_value = s->timer1_mm_clk_ctrl_cpu;
#endif

    if (offset != BL808_MM_GLB_MM_CLK_CTRL_CPU) {
        return;
    }

    s->timer1_mm_clk_ctrl_cpu = value;
    bl808_soc_refresh_timer1_clocks(s);
    bl808_soc_refresh_mm_uart_i2c_clocks(s);
#ifdef TARGET_RISCV64
    if (!s->mm_powered_on || bl808_d0_reset_asserted(s) ||
        ((old_value ^ value) & BL808_MM_GLB_REG_MMCPU0_CLK_EN) == 0) {
        return;
    }

    if (value & BL808_MM_GLB_REG_MMCPU0_CLK_EN) {
        bl808_release_or_resume_d0(s);
    } else {
        bl808_hold_d0(s, CPU(s->soc.d0_cpu)->cc->get_pc(CPU(s->soc.d0_cpu)));
    }
#endif
}

static void bl808_soc_timer1_clk_cpu_notify(void *opaque, hwaddr offset,
                                            uint32_t value)
{
    BL808MachineState *s = opaque;

    if (offset != BL808_MM_GLB_MM_CLK_CPU) {
        return;
    }

    s->timer1_mm_clk_cpu = value;
    bl808_soc_refresh_timer1_clocks(s);
}

static void G_GNUC_UNUSED bl808_soc_d0_sw_sys_reset_notify(void *opaque,
                                                           hwaddr offset,
                                                           uint32_t value)
{
    BL808MachineState *s = opaque;
#ifdef TARGET_RISCV64
    bool old_asserted;
    bool new_asserted;
#endif

    if (offset != BL808_MM_GLB_MM_SW_SYS_RESET) {
        return;
    }

#ifdef TARGET_RISCV64
    old_asserted = bl808_d0_reset_asserted(s);
#endif
    s->mm_sw_sys_reset = value;
#ifdef TARGET_RISCV64
    new_asserted = bl808_d0_reset_asserted(s);

    if (!old_asserted && new_asserted) {
        device_cold_reset(DEVICE(s->soc.d0_cpu));
        bl808_hold_d0(s, bl808_d0_reset_pc(s));
    } else if (old_asserted && !new_asserted) {
        if (s->mm_powered_on && bl808_d0_clock_enabled(s)) {
            bl808_release_or_resume_d0(s);
        } else {
            bl808_hold_d0(s, bl808_d0_reset_pc(s));
        }
    }
#endif
}

static void G_GNUC_UNUSED bl808_soc_lp_swrst_cfg2_notify(void *opaque,
                                                         hwaddr offset,
                                                         uint32_t value)
{
    BL808MachineState *s = opaque;
#ifdef TARGET_RISCV64
    bool old_asserted;
    bool new_asserted;
#endif

    if (offset != BL808_GLB_SWRST_CFG2) {
        return;
    }

#ifdef TARGET_RISCV64
    old_asserted = bl808_lp_reset_asserted(s);
#endif
    s->glb_swrst_cfg2 = value;
#ifdef TARGET_RISCV64
    new_asserted = bl808_lp_reset_asserted(s);

    if (!old_asserted && new_asserted) {
        device_cold_reset(DEVICE(s->soc.lp_cpu));
        bl808_hold_lp(s, bl808_lp_reset_pc(s));
    } else if (old_asserted && !new_asserted) {
        bl808_update_lp_state(s, false);
    }
#endif
}

static void bl808_soc_timer1_dig_clk_cfg1_notify(void *opaque, hwaddr offset,
                                                 uint32_t value)
{
    BL808MachineState *s = opaque;

    if (offset != BL808_GLB_DIG_CLK_CFG1) {
        return;
    }

    s->timer_glb_dig_clk_cfg1 = value;
    bl808_soc_refresh_timer1_clocks(s);
}

static void bl808_soc_wifi_pll_config_notify(void *opaque, hwaddr offset,
                                             uint32_t value)
{
    BL808MachineState *s = opaque;

    switch (offset) {
    case BL808_GLB_WIFI_PLL_CFG0:
        s->timer_glb_wifi_pll_cfg0 = value;
        break;
    case BL808_GLB_WIFI_PLL_CFG1:
        s->timer_glb_wifi_pll_cfg1 = value;
        break;
    case BL808_GLB_WIFI_PLL_CFG5:
        s->timer_glb_wifi_pll_cfg5 = value;
        break;
    case BL808_GLB_WIFI_PLL_CFG6:
        s->timer_glb_wifi_pll_cfg6 = value;
        break;
    case BL808_GLB_WIFI_PLL_CFG8:
        s->timer_glb_wifi_pll_cfg8 = value;
        break;
    default:
        return;
    }

    bl808_soc_refresh_timer0_clocks(s);
    bl808_soc_refresh_timer1_clocks(s);
}

static void bl808_soc_timer_pll_config_notify(void *opaque, hwaddr offset,
                                              uint32_t value)
{
    BL808MachineState *s = opaque;

    switch (offset) {
    case BL808_CCI_AUDIO_PLL_CFG0:
    case BL808_CCI_AUDIO_PLL_CFG1:
    case BL808_CCI_AUDIO_PLL_CFG6:
    case BL808_CCI_AUDIO_PLL_CFG8:
    case BL808_CCI_CPU_PLL_CFG0:
    case BL808_CCI_CPU_PLL_CFG1:
    case BL808_CCI_CPU_PLL_CFG6:
    case BL808_CCI_CPU_PLL_CFG8:
        break;
    default:
        return;
    }

    /*
     * Timer0 and timer1 can both source from CPU PLL or AUPLL through
     * different clock-tree branches, so refresh both on live PLL updates.
     */
    bl808_soc_refresh_timer0_clocks(s);
    bl808_soc_refresh_timer1_clocks(s);
}

static void bl808_soc_i2s_clock_notify(void *opaque, bool enabled)
{
    bl808_i2s_set_clock_enabled(BL808_I2S(opaque), enabled);
}

static void bl808_soc_i2s_reset_notify(void *opaque, bool asserted)
{
    bl808_i2s_set_reset_asserted(BL808_I2S(opaque), asserted);
}

static void bl808_soc_audio_clock_notify(void *opaque, bool enabled)
{
    bl808_audio_set_clock_enabled(BL808_AUDIO(opaque), enabled);
}

static void bl808_soc_audio_reset_notify(void *opaque, bool asserted)
{
    bl808_audio_set_reset_asserted(BL808_AUDIO(opaque), asserted);
}

static void bl808_soc_emi_clock_notify(void *opaque, bool enabled)
{
    bl808_emi_set_clock_enabled(BL808_EMI(opaque), enabled);
}

static void bl808_soc_psram_clock_notify(void *opaque, bool enabled)
{
    bl808_psram_ctrl_set_clock_enabled(BL808_PSRAM_CTRL(opaque), enabled);
}

static void bl808_soc_psram_reset_notify(void *opaque, bool asserted)
{
    bl808_psram_ctrl_set_reset_asserted(BL808_PSRAM_CTRL(opaque), asserted);
}

static void bl808_soc_cks_clock_notify(void *opaque, bool enabled)
{
    bl808_cks_set_clock_enabled(BL808_CKS(opaque), enabled);
}

static void bl808_soc_cks_reset_notify(void *opaque, bool asserted)
{
    bl808_cks_set_reset_asserted(BL808_CKS(opaque), asserted);
}

static void bl808_soc_mcu_i2s_clock_config_notify(void *opaque, hwaddr offset,
                                                  uint32_t value)
{
    bl808_i2s_set_module_clock_enabled(BL808_I2S(opaque),
                                       (value & BL808_GLB_I2S_CLK_EN) != 0);
}

static const BL808DMARequestOps bl808_soc_dma_spi_rx_ops = {
    .can_read = (bool (*)(void *, unsigned))bl808_spi_dma_can_read,
    .read = (uint32_t (*)(void *, unsigned))bl808_spi_dma_read,
};

static const BL808DMARequestOps bl808_soc_dma_spi_tx_ops = {
    .can_write = (bool (*)(void *, unsigned))bl808_spi_dma_can_write,
    .write = (void (*)(void *, uint32_t, unsigned))bl808_spi_dma_write,
};

static const BL808DMARequestOps bl808_soc_dma_uart_rx_ops = {
    .can_read = (bool (*)(void *, unsigned))bl808_uart_dma_can_read,
    .read = (uint32_t (*)(void *, unsigned))bl808_uart_dma_read,
};

static const BL808DMARequestOps bl808_soc_dma_uart_tx_ops = {
    .can_write = (bool (*)(void *, unsigned))bl808_uart_dma_can_write,
    .write = (void (*)(void *, uint32_t, unsigned))bl808_uart_dma_write,
};

static const BL808DMARequestOps bl808_soc_dma_i2c_rx_ops = {
    .can_read = (bool (*)(void *, unsigned))bl808_i2c_dma_can_read,
    .read = (uint32_t (*)(void *, unsigned))bl808_i2c_dma_read,
};

static const BL808DMARequestOps bl808_soc_dma_i2c_tx_ops = {
    .can_write = (bool (*)(void *, unsigned))bl808_i2c_dma_can_write,
    .write = (void (*)(void *, uint32_t, unsigned))bl808_i2c_dma_write,
};

static const BL808DMARequestOps bl808_soc_dma_i2s_rx_ops = {
    .can_read = (bool (*)(void *, unsigned))bl808_i2s_dma_can_read,
    .read = (uint32_t (*)(void *, unsigned))bl808_i2s_dma_read,
};

static const BL808DMARequestOps bl808_soc_dma_i2s_tx_ops = {
    .can_write = (bool (*)(void *, unsigned))bl808_i2s_dma_can_write,
    .write = (void (*)(void *, uint32_t, unsigned))bl808_i2s_dma_write,
};

static const BL808DMARequestOps bl808_soc_dma_audio_rx_ops = {
    .can_read = (bool (*)(void *, unsigned))bl808_audio_dma_can_read,
    .read = (uint32_t (*)(void *, unsigned))bl808_audio_dma_read,
};

static const BL808DMARequestOps bl808_soc_dma_audio_tx_ops = {
    .can_write = (bool (*)(void *, unsigned))bl808_audio_dma_can_write,
    .write = (void (*)(void *, uint32_t, unsigned))bl808_audio_dma_write,
};

static const BL808DMARequestOps bl808_soc_dma_gpip_adc_ops = {
    .can_read = (bool (*)(void *, unsigned))bl808_gpip_dma_adc_can_read,
    .read = (uint32_t (*)(void *, unsigned))bl808_gpip_dma_adc_read,
};

static const BL808DMARequestOps bl808_soc_dma_gpip_dac_ops = {
    .can_write = (bool (*)(void *, unsigned))bl808_gpip_dma_dac_can_write,
    .write = (void (*)(void *, uint32_t, unsigned))bl808_gpip_dma_dac_write,
};

static void bl808_soc_register_dma0_requests(BL808SoCState *s,
                                             BL808DMAState *dma)
{
    bl808_dma_register_request(dma, 0, &bl808_soc_dma_uart_rx_ops, &s->uart[0]);
    bl808_dma_register_request(dma, 1, &bl808_soc_dma_uart_tx_ops, &s->uart[0]);
    bl808_dma_register_request(dma, 2, &bl808_soc_dma_uart_rx_ops, &s->uart[1]);
    bl808_dma_register_request(dma, 3, &bl808_soc_dma_uart_tx_ops, &s->uart[1]);
    bl808_dma_register_request(dma, 4, &bl808_soc_dma_uart_rx_ops, &s->uart[2]);
    bl808_dma_register_request(dma, 5, &bl808_soc_dma_uart_tx_ops, &s->uart[2]);
    bl808_dma_register_request(dma, 6, &bl808_soc_dma_i2c_rx_ops, &s->i2c0);
    bl808_dma_register_request(dma, 7, &bl808_soc_dma_i2c_tx_ops, &s->i2c0);
    bl808_dma_register_request(dma, 10, &bl808_soc_dma_spi_rx_ops, &s->spi0);
    bl808_dma_register_request(dma, 11, &bl808_soc_dma_spi_tx_ops, &s->spi0);
    bl808_dma_register_request(dma, 12, &bl808_soc_dma_audio_rx_ops,
                               &s->audio);
    bl808_dma_register_request(dma, 13, &bl808_soc_dma_audio_tx_ops,
                               &s->audio);
    bl808_dma_register_request(dma, 14, &bl808_soc_dma_i2c_rx_ops, &s->i2c1);
    bl808_dma_register_request(dma, 15, &bl808_soc_dma_i2c_tx_ops, &s->i2c1);
    bl808_dma_register_request(dma, 16, &bl808_soc_dma_i2s_rx_ops, &s->i2s);
    bl808_dma_register_request(dma, 17, &bl808_soc_dma_i2s_tx_ops, &s->i2s);
    bl808_dma_register_request(dma, 18, &bl808_soc_dma_audio_rx_ops,
                               &s->audio);
    bl808_dma_register_request(dma, 22, &bl808_soc_dma_gpip_adc_ops,
                               &s->gpip);
    bl808_dma_register_request(dma, 23, &bl808_soc_dma_gpip_dac_ops,
                               &s->gpip);
}

static void G_GNUC_UNUSED bl808_soc_register_dma2_requests(BL808SoCState *s,
                                                           BL808DMAState *dma)
{
    bl808_dma_register_request(dma, 0, &bl808_soc_dma_uart_rx_ops, &s->uart[3]);
    bl808_dma_register_request(dma, 1, &bl808_soc_dma_uart_tx_ops, &s->uart[3]);
    bl808_dma_register_request(dma, 2, &bl808_soc_dma_spi_rx_ops, &s->spi1);
    bl808_dma_register_request(dma, 3, &bl808_soc_dma_spi_tx_ops, &s->spi1);
    bl808_dma_register_request(dma, 6, &bl808_soc_dma_i2c_rx_ops, &s->i2c2);
    bl808_dma_register_request(dma, 7, &bl808_soc_dma_i2c_tx_ops, &s->i2c2);
    bl808_dma_register_request(dma, 8, &bl808_soc_dma_i2c_rx_ops, &s->i2c3);
    bl808_dma_register_request(dma, 9, &bl808_soc_dma_i2c_tx_ops, &s->i2c3);
}

#define BL808_FLASH_OFFSET_M0          0x000000U
#define BL808_FLASH_OFFSET_LP          0x020000U
#define BL808_FLASH_OFFSET_D0          0x100000U
#define BL808_FLASH_OFFSET_D0_IMAGE    (BL808_FLASH_OFFSET_D0 + 0x1000U)
#define BL808_FLASH_SLOT_SIZE_LP       0x100000U
#define BL808_BOOTHEADER_SIZE          352U
#define BL808_BOOTHEADER_MAGIC_BFNP    0x504E4642U
#define BL808_BOOTHEADER_MAGIC_BFAP    0x50414642U
#define BL808_BOOTHEADER_FLASH_CFG_MAGIC 0x47464346U
#define BL808_BOOTHEADER_CRC_DEADBEEF  0xDEADBEEFU
#define BL808_BOOTHEADER_FLAGS_OFFSET  0x080U
#define BL808_BOOTHEADER_GROUP_OFFSET  0x084U
#define BL808_BOOTHEADER_CPU_CFG_BASE  0x0B0U
#define BL808_BOOTHEADER_CPU_CFG_SIZE  24U
#define BL808_BOOTHEADER_PT0_OFFSET    0x0F4U
#define BL808_BOOTHEADER_PT1_OFFSET    0x0F8U
#define BL808_BOOTHEADER_CRC_OFFSET    0x15CU
#define BL808_BOOTHEADER_FLAG_POWER_ON_MM BIT(18)
#define BL808_PT_TABLE0_ADDRESS        0x0000E000U
#define BL808_PT_TABLE1_ADDRESS        0x0000F000U
#define BL808_PT_MAGIC_CODE            0x54504642U
#define BL808_PT_ENTRY_MAX             16U
#define BL808_PT_ENTRY_SIZE            36U
#define BL808_PT_TABLE_SIZE            596U
#define BL808_BOOT2_PASS_PARAM_ADDR    (BL808_WRAM_CACHED + 0x27C00ULL)
#define BL808_BOOT2_PASS_PARAM_OFFSET  (BL808_BOOT2_PASS_PARAM_ADDR - BL808_WRAM_CACHED)
#define BL808_BOOT2_PASS_PARAM_SIZE    24U
#define BL808_IR_SIZE                  0x100
#define BL808_IR_RX_CFG_OFFSET         0x40
#define BL808_IR_RX_INT_STS_OFFSET     0x44
#define BL808_IR_RX_PW_CFG_OFFSET      0x48
#define BL808_IR_RX_DATA_COUNT_OFFSET  0x50
#define BL808_IR_RX_DATA_WORD0_OFFSET  0x54
#define BL808_IR_RX_DATA_WORD1_OFFSET  0x58
#define BL808_IR_RX_CFG_EN             BIT(0)
#define BL808_IR_RX_END_INT            BIT(0)
#define BL808_IR_RX_END_MASK           BIT(8)
#define BL808_IR_RX_END_CLR            BIT(16)
#define BL808_IR_RX_END_EN             BIT(24)
#define BL808_IR_RX_INT_STATUS_MASK    0x00000007U
#define BL808_IR_RX_INT_CTRL_MASK      0x07000700U

typedef struct BL808BootHeaderInfo {
    bool valid;
    bool power_on_mm;
    uint32_t flash_offset;
    uint32_t group_image_offset;
    uint32_t partition_table_offset[2];
    bool cpu_enabled[3];
    bool cpu_halt[3];
    uint32_t cpu_image_offset[3];
} BL808BootHeaderInfo;

typedef struct BL808PartitionInfo {
    bool valid;
    bool fallback_applied;
    uint32_t header_flash_offset;
    uint32_t table_flash_offset;
    uint32_t writeback_flash_offset;
    uint8_t table_index;
    uint16_t entry_index;
    uint16_t entry_count;
    uint8_t active_index;
    uint8_t entry_prefix[20];
} BL808PartitionInfo;

static uint32_t bl808_bootheader_crc32(const uint8_t *data, size_t len)
{
    uint32_t crc = 0xFFFFFFFFU;

    for (size_t i = 0; i < len; i++) {
        crc ^= data[i];
        for (unsigned bit = 0; bit < 8; bit++) {
            uint32_t mask = -(crc & 1U);
            crc = (crc >> 1) ^ (0xEDB88320U & mask);
        }
    }

    return ~crc;
}

static bool bl808_bootheader_read(BL808MachineState *s, uint32_t flash_offset,
                                  BL808BootHeaderInfo *info)
{
    const uint8_t *flash = s->soc.sf_ctrl.flash;
    const uint8_t *raw;
    uint32_t magic;
    uint32_t flash_cfg_magic;
    uint32_t flags;
    uint32_t stored_crc;

    memset(info, 0, sizeof(*info));

    if (!flash ||
        flash_offset + BL808_BOOTHEADER_SIZE > BL808_SF_CTRL_FLASH_SIZE) {
        return false;
    }

    raw = flash + flash_offset;
    magic = ldl_le_p(raw + 0x00);
    flash_cfg_magic = ldl_le_p(raw + 0x08);
    stored_crc = ldl_le_p(raw + BL808_BOOTHEADER_CRC_OFFSET);
    if ((magic != BL808_BOOTHEADER_MAGIC_BFNP &&
         magic != BL808_BOOTHEADER_MAGIC_BFAP) ||
        flash_cfg_magic != BL808_BOOTHEADER_FLASH_CFG_MAGIC) {
        return false;
    }
    if (stored_crc != BL808_BOOTHEADER_CRC_DEADBEEF &&
        bl808_bootheader_crc32(raw, BL808_BOOTHEADER_CRC_OFFSET) != stored_crc) {
        return false;
    }

    flags = ldl_le_p(raw + BL808_BOOTHEADER_FLAGS_OFFSET);

    info->valid = true;
    info->power_on_mm = (flags & BL808_BOOTHEADER_FLAG_POWER_ON_MM) != 0;
    info->flash_offset = flash_offset;
    info->group_image_offset =
        ldl_le_p(raw + BL808_BOOTHEADER_GROUP_OFFSET) & 0x0FFFFFFFU;
    info->partition_table_offset[0] =
        ldl_le_p(raw + BL808_BOOTHEADER_PT0_OFFSET) & 0x0FFFFFFFU;
    info->partition_table_offset[1] =
        ldl_le_p(raw + BL808_BOOTHEADER_PT1_OFFSET) & 0x0FFFFFFFU;

    for (unsigned cpu = 0; cpu < ARRAY_SIZE(info->cpu_enabled); cpu++) {
        hwaddr cpu_base = BL808_BOOTHEADER_CPU_CFG_BASE +
                          cpu * BL808_BOOTHEADER_CPU_CFG_SIZE;

        info->cpu_enabled[cpu] = raw[cpu_base] != 0;
        info->cpu_halt[cpu] = raw[cpu_base + 1] != 0;
        info->cpu_image_offset[cpu] = ldl_le_p(raw + cpu_base + 12);
    }

    return true;
}

static bool bl808_partition_name_matches(const uint8_t *raw_name,
                                         const char *want)
{
    size_t want_len = strlen(want);
    char name[10];

    memset(name, 0, sizeof(name));
    memcpy(name, raw_name, 9);
    return strncmp(name, want, want_len + 1) == 0;
}

static bool bl808_partition_table_valid(const uint8_t *raw, uint32_t *age_out,
                                        uint16_t *entry_count_out)
{
    uint16_t entry_count = lduw_le_p(raw + 0x06);
    uint32_t stored_crc;
    uint32_t entries_crc;

    if (ldl_le_p(raw + 0x00) != BL808_PT_MAGIC_CODE ||
        entry_count > BL808_PT_ENTRY_MAX) {
        return false;
    }

    stored_crc = ldl_le_p(raw + 0x0C);
    if (bl808_bootheader_crc32(raw, 12) != stored_crc) {
        return false;
    }

    entries_crc = ldl_le_p(raw + 0x10 + entry_count * BL808_PT_ENTRY_SIZE);
    if (bl808_bootheader_crc32(raw + 0x10,
                               entry_count * BL808_PT_ENTRY_SIZE) != entries_crc) {
        return false;
    }

    if (age_out) {
        *age_out = ldl_le_p(raw + 0x08);
    }
    if (entry_count_out) {
        *entry_count_out = entry_count;
    }
    return true;
}

static bool bl808_partition_entry_bootheader(BL808MachineState *s,
                                             const uint8_t *entry,
                                             uint8_t slot,
                                             BL808BootHeaderInfo *info)
{
    uint32_t header_flash_offset;

    if (slot > 1) {
        return false;
    }

    header_flash_offset = ldl_le_p(entry + 12 + slot * sizeof(uint32_t));
    if (header_flash_offset == 0) {
        return false;
    }

    return bl808_bootheader_read(s, header_flash_offset, info) &&
           info->cpu_enabled[0] && !info->cpu_halt[0];
}

static void bl808_boot2_clear_pass_params(BL808MachineState *s)
{
    uint8_t *wram = memory_region_get_ram_ptr(&s->soc.wram);

    if (!wram) {
        return;
    }

    memset(wram + BL808_BOOT2_PASS_PARAM_OFFSET, 0,
           BL808_BOOT2_PASS_PARAM_SIZE);
}

static void bl808_boot2_store_partition_params(BL808MachineState *s,
                                               const BL808PartitionInfo *info)
{
    uint8_t *wram = memory_region_get_ram_ptr(&s->soc.wram);

    if (!wram || !info || !info->valid) {
        return;
    }

    stl_le_p(wram + BL808_BOOT2_PASS_PARAM_OFFSET, info->table_index);
    memcpy(wram + BL808_BOOT2_PASS_PARAM_OFFSET + sizeof(uint32_t),
           info->entry_prefix, sizeof(info->entry_prefix));
}

static void bl808_partition_table_writeback(BL808MachineState *s,
                                            const uint8_t *table_raw,
                                            uint16_t entry_count,
                                            uint16_t entry_index,
                                            uint8_t new_active_index,
                                            uint32_t writeback_offset)
{
    uint8_t table[BL808_PT_TABLE_SIZE];
    hwaddr entry_base = 0x10 + entry_index * BL808_PT_ENTRY_SIZE;
    hwaddr entries_end = 0x10 + entry_count * BL808_PT_ENTRY_SIZE;

    if (entry_index >= entry_count || entries_end + sizeof(uint32_t) > sizeof(table)) {
        return;
    }

    memcpy(table, table_raw, sizeof(table));
    table[entry_base + 2] = new_active_index;
    stl_le_p(table + entry_base + 32, ldl_le_p(table + entry_base + 32) + 1);
    stl_le_p(table + 0x08, ldl_le_p(table + 0x08) + 1);
    stl_le_p(table + 0x0C, bl808_bootheader_crc32(table, 12));
    stl_le_p(table + entries_end,
             bl808_bootheader_crc32(table + 0x10,
                                    entry_count * BL808_PT_ENTRY_SIZE));
    bl808_sf_ctrl_write_flash(&s->soc.sf_ctrl, writeback_offset, table, sizeof(table));
}

static bool bl808_select_partition_header(BL808MachineState *s,
                                          const BL808BootHeaderInfo *boot2,
                                          BL808PartitionInfo *info,
                                          bool commit_fallback)
{
    const uint8_t *flash = s->soc.sf_ctrl.flash;
    uint32_t pt_offsets[2] = {
        boot2->partition_table_offset[0] ? boot2->partition_table_offset[0]
                                         : BL808_PT_TABLE0_ADDRESS,
        boot2->partition_table_offset[1] ? boot2->partition_table_offset[1]
                                         : BL808_PT_TABLE1_ADDRESS,
    };
    unsigned selected_copy = 0;
    uint32_t selected_age = 0;
    uint16_t selected_entries = 0;
    const uint8_t *selected_raw = NULL;

    memset(info, 0, sizeof(*info));

    if (!flash) {
        return false;
    }

    for (unsigned copy = 0; copy < ARRAY_SIZE(pt_offsets); copy++) {
        const uint8_t *raw;
        uint32_t age;
        uint16_t entry_count;

        if (pt_offsets[copy] + BL808_PT_TABLE_SIZE > BL808_SF_CTRL_FLASH_SIZE) {
            continue;
        }
        raw = flash + pt_offsets[copy];
        if (!bl808_partition_table_valid(raw, &age, &entry_count)) {
            continue;
        }
        if (!selected_raw || age >= selected_age) {
            selected_copy = copy;
            selected_age = age;
            selected_entries = entry_count;
            selected_raw = raw;
        }
    }

    if (!selected_raw) {
        return false;
    }

    for (uint16_t i = 0; i < selected_entries; i++) {
        const uint8_t *entry = selected_raw + 0x10 + i * BL808_PT_ENTRY_SIZE;
        BL808BootHeaderInfo candidate;
        uint8_t type = entry[0];
        uint8_t active_index = entry[2] & 1;
        uint8_t inactive_index = active_index ^ 1;

        if (!bl808_partition_name_matches(entry + 3, "FW") && type != 0) {
            continue;
        }
        if (entry[2] > 1) {
            continue;
        }

        if (bl808_partition_entry_bootheader(s, entry, active_index, &candidate)) {
            info->valid = true;
            info->header_flash_offset = candidate.flash_offset;
            info->table_flash_offset = pt_offsets[selected_copy];
            info->writeback_flash_offset = pt_offsets[selected_copy ^ 1];
            info->table_index = selected_copy;
            info->entry_index = i;
            info->entry_count = selected_entries;
            info->active_index = active_index;
            memcpy(info->entry_prefix, entry, sizeof(info->entry_prefix));
            return true;
        }
        if (!bl808_partition_entry_bootheader(s, entry, inactive_index, &candidate)) {
            continue;
        }

        if (commit_fallback) {
            bl808_partition_table_writeback(s, selected_raw, selected_entries, i,
                                            inactive_index,
                                            pt_offsets[selected_copy ^ 1]);
        }
        info->valid = true;
        info->fallback_applied = true;
        info->header_flash_offset = candidate.flash_offset;
        info->table_flash_offset = pt_offsets[selected_copy];
        info->writeback_flash_offset = pt_offsets[selected_copy ^ 1];
        info->table_index = selected_copy;
        info->entry_index = i;
        info->entry_count = selected_entries;
        info->active_index = inactive_index;
        memcpy(info->entry_prefix, entry, sizeof(info->entry_prefix));
        info->entry_prefix[2] = inactive_index;
        return true;
    }

    return false;
}

static bool bl808_primary_flash_bootheader(BL808MachineState *s,
                                           BL808BootHeaderInfo *info)
{
    BL808BootHeaderInfo boot2;
    BL808PartitionInfo partition;

    memset(info, 0, sizeof(*info));

    if (s->strict_fidelity || s->boot_gpio39 || s->have_m0_entry ||
        !bl808_bootheader_read(s, BL808_FLASH_OFFSET_M0, &boot2)) {
        return false;
    }

    if (bl808_select_partition_header(s, &boot2, &partition, false) &&
        bl808_bootheader_read(s, partition.header_flash_offset, info) &&
        info->cpu_enabled[0] && !info->cpu_halt[0]) {
        return true;
    }

    if (boot2.cpu_enabled[0] && !boot2.cpu_halt[0]) {
        *info = boot2;
        return true;
    }

    return false;
}
#define BL808_IR_RX_DATA_COUNT_MASK    0x0000007FU
#define BL808_BLE_BASE                 0x28000000ULL
#define BL808_BLE_SIZE                 0x1000
#define BL808_BLE_RWBLECNTL_OFFSET     0x00
#define BL808_BLE_VERSION_OFFSET       0x04
#define BL808_BLE_INTCNTL_OFFSET       0x0C
#define BL808_BLE_INTSTAT_OFFSET       0x10
#define BL808_BLE_INTRAWSTAT_OFFSET    0x14
#define BL808_BLE_INTACK_OFFSET        0x18
#define BL808_BLE_BASETIMECNT_OFFSET   0x1C
#define BL808_BLE_FINETIMECNT_OFFSET   0x20
#define BL808_BLE_INT_MASK             0x0000003FU
#define BL808_BLE_INT_FINE_TIMER       BIT(0)
#define BL808_BLE_BASETIME_LATCH       BIT(31)
#define BL808_BLE_SLOT_NS              625000ULL
#define BL808_BLE_BASETIME_MASK        0x007FFFFFU
#define BL808_WIFI_MAC_PL_BASE         0x44900000ULL
#define BL808_WIFI_MAC_PL_SIZE         0x1000
#define BL808_WIFI_MAC_PL_DIAG_CTRL_OFFSET 0x68
#define BL808_WIFI_MAC_PL_DIAG_SW_OFFSET  0x70
#define BL808_WIFI_MAC_PL_CTRL_OFFSET     0x84
#define BL808_WIFI_MAC_PL_CLK_GATE_OFFSET 0xE0
#define BL808_WIFI_MAC_IRQ_BASE        0x44910000ULL
#define BL808_WIFI_MAC_IRQ_SIZE        0x1000
#define BL808_WIFI_MAC_IRQ_STATUS0_OFFSET 0x00
#define BL808_WIFI_MAC_IRQ_STATUS1_OFFSET 0x04
#define BL808_WIFI_MAC_IRQ_HANDLER_OFFSET 0x40
#define BL808_WIFI_MACHW_BASE          0x44B00000ULL
#define BL808_WIFI_MACHW_SIZE          0x1000
#define BL808_WIFI_MACHW_STATE_CNTRL_OFFSET 0x38
#define BL808_WIFI_MACHW_STATUS_OFFSET 0x4C
#define BL808_WIFI_MACHW_DOZE_CNTRL2_OFFSET 0x54
#define BL808_WIFI_MACHW_RX_CNTRL_OFFSET 0x60
#define BL808_WIFI_MACHW_TIMLO_OFFSET  0x120
#define BL808_WIFI_MACHW_ABS_TIMER_OFFSET 0x13C
#define BL808_WIFI_MACHW_BCN_STATUS_OFFSET 0x400
#define BL808_WIFI_MACHW_INTC_BASE     0x44B08000ULL
#define BL808_WIFI_MACHW_INTC_SIZE     0x1000
#define BL808_WIFI_MACHW_INTC_SOFT_RESET_OFFSET 0x50
#define BL808_WIFI_MACHW_INTC_STATUS_RAW_OFFSET 0x6C
#define BL808_WIFI_MACHW_INTC_STATUS_ACK_OFFSET 0x70
#define BL808_WIFI_MACHW_INTC_UNMASK_OFFSET 0x74
#define BL808_WIFI_MACHW_INTC_FORCE_OFFSET 0x7C
#define BL808_WIFI_MACHW_INTC_GEN_STATUS_OFFSET 0x80
#define BL808_WIFI_MACHW_INTC_GEN_RAW_OFFSET 0x84
#define BL808_WIFI_MACHW_INTC_IRQ_SET_OFFSET 0x88
#define BL808_WIFI_MACHW_INTC_IRQ_STAT_OFFSET 0x8C
#define BL808_WIFI_MACHW_IRQ_GLOBAL_EN BIT(31)
#define BL808_WIFI_MACHW_IRQ_PRIMARY_TBTT 0x00040001U
#define BL808_WIFI_MACHW_IRQ_SECONDARY_TBTT 0x00080002U
#define BL808_WIFI_MACHW_IRQ_IDLE      BIT(2)
#define BL808_WIFI_MACHW_IRQ_GEN       BIT(3)
#define BL808_WIFI_MACHW_IRQ_MODEL_MASK \
    (BL808_WIFI_MACHW_IRQ_PRIMARY_TBTT | \
     BL808_WIFI_MACHW_IRQ_SECONDARY_TBTT | \
     BL808_WIFI_MACHW_IRQ_IDLE | \
     BL808_WIFI_MACHW_IRQ_GEN)
#define BL808_WIFI_MACHW_GEN_GLOBAL_EN BIT(31)
#define BL808_WIFI_MACHW_GEN_RX_TIMEOUT BIT(6)
#define BL808_WIFI_MACHW_GEN_RX_COMPLETE BIT(7)
#define BL808_WIFI_MACHW_GEN_TIMER     BIT(8)
#define BL808_WIFI_MAC_HANDLER_GEN     61U
#define BL808_WIFI_IPC_EMB_BASE        0x44800000ULL
#define BL808_WIFI_IPC_EMB_SIZE        0x1000
#define BL808_WIFI_IPC_STATUS_OFFSET   0x100
#define BL808_WIFI_IPC_UNMASK_SET_OFFSET 0x10C
#define BL808_WIFI_IPC_UNMASK_CLR_OFFSET 0x110
#define BL808_WIFI_IPC_CFG_OFFSET      0x114
#define BL808_WIFI_IPC_ACK_OFFSET      0x118
#define BL808_WIFI_IPC_STATUS2_OFFSET  0x11C
#define BL808_WIFI_IPC_MAGIC_OFFSET    0x140
#define BL808_WIFI_IPC_MAGIC           0x49504332U
#define BL808_WIFI_IPC_MSG_BIT         BIT(1)
#define BL808_PDS_CTL_OFFSET           0x00
#define BL808_PDS_TIME1_OFFSET         0x04
#define BL808_PDS_INT_OFFSET           0x0C
#define BL808_PDS_CTL2_OFFSET          0x10
#define BL808_PDS_STAT_OFFSET          0x1C
#define BL808_PDS_GPIO_I_SET_OFFSET    0x30
#define BL808_PDS_GPIO_PD_SET_OFFSET   0x34
#define BL808_PDS_GPIO_INT_OFFSET      0x40
#define BL808_PDS_GPIO_STAT_OFFSET     0x44
#define BL808_PDS_CTL_START_PS         BIT(0)
#define BL808_PDS_CTL_SLEEP_FOREVER    BIT(1)
#define BL808_PDS_INT_WAKEUP           BIT(0)
#define BL808_PDS_INT_STATUS_MASK      0x0000000FU
#define BL808_PDS_INT_MASK_BITS        0x000000F0U
#define BL808_PDS_INT_CLEAR            BIT(8)
#define BL808_PDS_WAKEUP_SRC_EN_MASK   (0x7FFU << 10)
#define BL808_PDS_WAKEUP_EVENT_MASK    (0x7FFU << 21)
#define BL808_PDS_WAKEUP_SRC_TIMER     BIT(10)
#define BL808_PDS_WAKEUP_SRC_HBN_IRQ   BIT(11)
#define BL808_PDS_WAKEUP_SRC_GLB_GPIO  BIT(12)
#define BL808_PDS_WAKEUP_SRC_PDS_GPIO  BIT(13)
#define BL808_PDS_WAKEUP_SRC_IRRX      BIT(14)
#define BL808_PDS_WAKEUP_SRC_WIFI_WKP  BIT(15)
#define BL808_PDS_WAKEUP_SRC_DM_SLP    BIT(16)
#define BL808_PDS_WAKEUP_SRC_WIFI_TBTT BIT(19)
#define BL808_PDS_WAKEUP_EVENT_TIMER   BIT(21)
#define BL808_PDS_WAKEUP_EVENT_HBN_IRQ BIT(22)
#define BL808_PDS_WAKEUP_EVENT_GLB_GPIO BIT(23)
#define BL808_PDS_WAKEUP_EVENT_PDS_GPIO BIT(24)
#define BL808_PDS_WAKEUP_EVENT_IRRX    BIT(25)
#define BL808_PDS_STATUS_WIFI_TBTT_SLEEP  BIT(2)
#define BL808_PDS_STATUS_WIFI_TBTT_WAKEUP BIT(3)
#define BL808_PDS_GPIO_IE_GROUP_MASK   0x7U
#define BL808_PDS_GPIO_PD_GROUP_MASK   (0x7U << 3)
#define BL808_PDS_GPIO_PU_GROUP_MASK   (0x7U << 6)
#define BL808_PDS_GPIO_INT_MASK_BITS   0xFFFFFFFFU
#define BL808_PDS_GPIO_SET1_CLR        BIT(2)
#define BL808_PDS_GPIO_SET1_MODE_SHIFT 4
#define BL808_PDS_GPIO_SET2_CLR        BIT(10)
#define BL808_PDS_GPIO_SET2_MODE_SHIFT 12
#define BL808_PDS_GPIO_SET3_CLR        BIT(18)
#define BL808_PDS_GPIO_SET3_MODE_SHIFT 20
#define BL808_PDS_GPIO_SET4_CLR        BIT(26)
#define BL808_PDS_GPIO_SET4_MODE_SHIFT 28
#define BL808_PDS_GPIO_SET_MODE_MASK   0xFU
#define BL808_PDS_STAT_BUSY            BIT(0)
#define BL808_PDS_MM_PWR_OFF           BIT(1)
#define BL808_PDS_MM_ISO_EN            BIT(5)
#define BL808_PDS_MM_PDS_RST           BIT(9)
#define BL808_PDS_MM_MEM_STBY          BIT(13)
#define BL808_PDS_MM_GATE_CLK          BIT(17)
#define BL808_PDS_MM_FORCE_MASK        (BL808_PDS_MM_PWR_OFF | \
                                        BL808_PDS_MM_ISO_EN | \
                                        BL808_PDS_MM_PDS_RST | \
                                        BL808_PDS_MM_MEM_STBY | \
                                        BL808_PDS_MM_GATE_CLK)
#define BL808_HBN_CTL_OFFSET           0x00
#define BL808_HBN_TIML_OFFSET          0x04
#define BL808_HBN_TIMH_OFFSET          0x08
#define BL808_HBN_RTC_TIML_OFFSET      0x0C
#define BL808_HBN_RTC_TIMH_OFFSET      0x10
#define BL808_HBN_IRQ_MODE_OFFSET      0x14
#define BL808_HBN_IRQ_STAT_OFFSET      0x18
#define BL808_HBN_IRQ_CLR_OFFSET       0x1C
#define BL808_HBN_PIR_CFG_OFFSET       0x20
#define BL808_HBN_PAD_CTRL_0_OFFSET    0x38
#define BL808_HBN_PAD_CTRL_1_OFFSET    0x3C
#define BL808_HBN_RSV0_OFFSET          0x100
#define BL808_HBN_RSV3_OFFSET          0x10C
#define BL808_HBN_RSV_COUNT            4
#define BL808_HBN_CTL_POWER_ON_RST     BIT(0)
#define BL808_HBN_CTL_MODE             BIT(7)
#define BL808_HBN_RTC_LATCH            BIT(31)
#define BL808_HBN_IRQ_RTC_STAT         BIT(16)
#define BL808_HBN_IRQ_PIR_STAT         BIT(17)
#define BL808_HBN_IRQ_BOD_STAT         BIT(18)
#define BL808_HBN_IRQ_BOD_EN           BIT(18)
#define BL808_HBN_IRQ_ACOMP0_STAT      BIT(20)
#define BL808_HBN_IRQ_ACOMP0_EN_SHIFT  20
#define BL808_HBN_IRQ_ACOMP0_EN_MASK   (0x3U << BL808_HBN_IRQ_ACOMP0_EN_SHIFT)
#define BL808_HBN_IRQ_ACOMP1_STAT      BIT(22)
#define BL808_HBN_IRQ_ACOMP1_EN_SHIFT  22
#define BL808_HBN_IRQ_ACOMP1_EN_MASK   (0x3U << BL808_HBN_IRQ_ACOMP1_EN_SHIFT)
#define BL808_HBN_GPIO_STATUS_MASK     0x000001FFU
#define BL808_HBN_PIN_WAKEUP_MODE_SHIFT 0
#define BL808_HBN_PIN_WAKEUP_MODE_MASK 0xFU
#define BL808_HBN_PIN_WAKEUP_MASK_SHIFT 4
#define BL808_HBN_PIN_WAKEUP_MASK_MASK (0x1FFU << BL808_HBN_PIN_WAKEUP_MASK_SHIFT)
#define BL808_HBN_REG_EN_HW_PU_PD      BIT(16)
#define BL808_HBN_PIN_WAKEUP_SEL_SHIFT 24
#define BL808_HBN_PIN_WAKEUP_SEL_LEN   3
#define BL808_HBN_PIN_WAKEUP_EN        BIT(27)
#define BL808_HBN_PAD_IE_SHIFT         0
#define BL808_HBN_PAD_LED_SHIFT        10
#define BL808_HBN_PAD_CTRL_SHIFT       20
#define BL808_HBN_PAD_CTRL_WIDTH       9
#define BL808_HBN_PAD_ISO_MODE         BIT(31)
#define BL808_HBN_PAD_OE_SHIFT         0
#define BL808_HBN_PAD_PD_SHIFT         10
#define BL808_HBN_PAD_PU_SHIFT         20
#define BL808_HBN_PIR_DIS_SHIFT        4
#define BL808_HBN_PIR_DIS_MASK         (0x3U << BL808_HBN_PIR_DIS_SHIFT)
#define BL808_HBN_PIR_EN               BIT(7)
#define BL808_HBN_GPADC_CMD_OFFSET     0x90c
#define BL808_HBN_GPADC_CFG1_OFFSET    0x910
#define BL808_HBN_GPADC_SCAN_POS1      0x918
#define BL808_HBN_GPADC_SCAN_POS2      0x91c
#define BL808_HBN_GPADC_STATUS         0x928
#define BL808_HBN_GPADC_RESULT         0x930
#define BL808_HBN_GPADC_RAW_RESULT     0x934
#define BL808_HBN_GPADC_GLOBAL_EN      BIT(0)
#define BL808_HBN_GPADC_CONV_START     BIT(1)
#define BL808_HBN_GPADC_POS_SEL_SHIFT  8
#define BL808_HBN_GPADC_POS_SEL_MASK   (0x1fU << BL808_HBN_GPADC_POS_SEL_SHIFT)
#define BL808_HBN_GPADC_SCAN_EN        BIT(25)
#define BL808_HBN_GPADC_SCAN_LEN_SHIFT 21
#define BL808_HBN_GPADC_SCAN_LEN_MASK  (0xfU << BL808_HBN_GPADC_SCAN_LEN_SHIFT)
#define BL808_HBN_OUT0_STATUS_MASK     (0x000001FFU | BL808_HBN_IRQ_RTC_STAT)
#define BL808_HBN_OUT1_STATUS_MASK     (BIT(17) | BIT(18) | BIT(20) | BIT(22))
#define BL808_HBN_F32K_HZ              32768ULL
#define BL808_HBN_F32K_PERIOD_NS       ((1000000000ULL + BL808_HBN_F32K_HZ - 1) / \
                                        BL808_HBN_F32K_HZ)
#define BL808_EF_CTRL0_OFFSET          0x800
#define BL808_EF_PGM_CMD_OFFSET        0x808
#define BL808_EF_RD_CMD_OFFSET         0x80C
#define BL808_EF_AUTO_LOAD_DONE        BIT(1)
#define BL808_EF_BUSY                  BIT(2)
#define BL808_EF_RW                    BIT(3)
#define BL808_EF_TRIG                  BIT(4)
#define BL808_EF_PGM_EN                BIT(16)
#define BL808_EF_DATA_WORDS            128

static const unsigned bl808_hbn_aon_gpio_map[BL808_HBN_AON_PINS] = {
    9, 10, 11, 12, 13, 14, 15, 40, 41,
};

static void bl808_pds_complete_sleep(BL808MachineState *s);
static int bl808_pds_gpio_index_from_pin(unsigned pin);
static bool bl808_hbn_gpio_irq_immediate(unsigned mode, bool old_level,
                                         bool new_level);
static bool bl808_hbn_gpio_irq_sampled(unsigned mode, uint8_t history);
static bool bl808_hbn_gpio_level_active(unsigned mode, bool level);
static uint64_t bl808_d0_reset_pc(BL808MachineState *s);

static uint32_t bl808_riscv_encode_lui(unsigned rd, uint32_t imm20)
{
    return ((imm20 & 0xFFFFF) << 12) | ((rd & 0x1F) << 7) | 0x37;
}

static uint32_t bl808_riscv_encode_jalr(unsigned rd, unsigned rs1, int32_t imm12)
{
    return (((uint32_t)imm12 & 0xFFF) << 20) |
           ((rs1 & 0x1F) << 15) |
           ((rd & 0x1F) << 7) |
           0x67;
}

static void bl808_bootrom_write32(uint8_t *bootrom, hwaddr offset,
                                  uint32_t value)
{
    stl_le_p(bootrom + offset, value);
}

static void bl808_bootrom_build_jump(uint8_t *bootrom, uint32_t target)
{
    uint32_t hi20 = (target + 0x800U) >> 12;
    int32_t lo12 = (int32_t)target - (int32_t)(hi20 << 12);

    bl808_bootrom_write32(bootrom, 0, bl808_riscv_encode_lui(5, hi20));
    bl808_bootrom_write32(bootrom, 4, bl808_riscv_encode_jalr(0, 5, lo12));
    bl808_bootrom_write32(bootrom, 8, 0x00000013);  /* nop */
}

static void bl808_bootrom_build_download_stub(uint8_t *bootrom)
{
    bl808_bootrom_write32(bootrom, 0, 0x0000006F);  /* j . */
    bl808_bootrom_write32(bootrom, 4, 0x00100073);  /* ebreak */
}

static bool bl808_load_external_bootrom(BL808MachineState *s, uint8_t *bootrom,
                                        Error **errp)
{
    int64_t size;
    ssize_t loaded;

    size = get_image_size(s->bootrom_image);
    if (size < 0) {
        error_setg_errno(errp, errno, "Could not size bootrom-image '%s'",
                         s->bootrom_image);
        return false;
    }
    if (size > BL808_BOOTROM_SIZE) {
        error_setg(errp, "bootrom-image '%s' is %" PRId64
                   " bytes, larger than the BL808 128 KiB boot ROM aperture",
                   s->bootrom_image, size);
        return false;
    }

    loaded = load_image_size(s->bootrom_image, bootrom, BL808_BOOTROM_SIZE);
    if (loaded < 0) {
        error_setg_errno(errp, errno, "Could not load bootrom-image '%s'",
                         s->bootrom_image);
        return false;
    }
    if ((int64_t)loaded != size) {
        error_setg(errp, "Short read while loading bootrom-image '%s'",
                   s->bootrom_image);
        return false;
    }

    return true;
}

static bool bl808_populate_bootrom(BL808MachineState *s, Error **errp)
{
    uint8_t *bootrom = memory_region_get_ram_ptr(&s->bootrom);
    BL808BootHeaderInfo boothdr;
    uint32_t target = BL808_FLASH_XIP_BASE;

    memset(bootrom, 0, BL808_BOOTROM_SIZE);
    if (s->bootrom_image) {
        return bl808_load_external_bootrom(s, bootrom, errp);
    }
    if (s->strict_fidelity) {
        error_setg(errp,
                   "strict-fidelity requires bootrom-image=...; the "
                   "synthetic BL808 boot ROM stub is disabled");
        return false;
    }

    /*
     * Direct ELF injection already overrides M0's reset PC, so do not also
     * add a synthetic ROM control path on top of that. Keep the aperture
     * mapped, but leave it zero-filled unless the caller explicitly supplied
     * a real BL808 boot ROM image.
     */
    if (s->have_m0_entry) {
        return true;
    }

    if (s->boot_gpio39) {
        bl808_bootrom_build_download_stub(bootrom);
    } else {
        if (bl808_primary_flash_bootheader(s, &boothdr)) {
            target += boothdr.cpu_image_offset[0];
        }
        bl808_bootrom_build_jump(bootrom, target);
    }

    memcpy(bootrom + BL808_BOOTROM_SIZE - 16, "BL808QEMUBOOT\0\0\0", 16);
    return true;
}

static void bl808_set_cpu_running(CPUState *cpu, uint64_t pc)
{
    cpu_set_pc(cpu, pc);
    cpu->halted = 0;
    cpu_resume(cpu);
}

static void G_GNUC_UNUSED bl808_set_cpu_halted(CPUState *cpu, uint64_t pc)
{
    cpu_set_pc(cpu, pc);
    cpu->halted = 1;
}

static void bl808_pulse_irq(qemu_irq irq)
{
    if (irq) {
        qemu_irq_pulse(irq);
    }
}

static void bl808_apply_boot_gpio39(BL808MachineState *s)
{
    if (!s->soc.glb) {
        return;
    }

    qemu_set_irq(qdev_get_gpio_in_named(s->soc.glb, "gpio-in",
                                        BL808_BOOT_GPIO39_PIN),
                 s->boot_gpio39);
}

static void bl808_apply_pds_gpio_levels(BL808MachineState *s)
{
    if (!s->soc.glb) {
        return;
    }

    for (unsigned pin = 0; pin < BL808_GLB_GPIO_PINS; pin++) {
        if (bl808_pds_gpio_index_from_pin(pin) < 0) {
            continue;
        }

        bl808_glb_set_gpio_input_state(s->soc.glb, pin,
                                       s->gpio_driven[pin],
                                       s->gpio_level[pin]);
    }
}

static void bl808_apply_aon_gpio_levels(BL808MachineState *s)
{
    if (!s->soc.glb) {
        return;
    }

    for (unsigned i = 0; i < ARRAY_SIZE(bl808_hbn_aon_gpio_map); i++) {
        bl808_glb_set_gpio_input_state(s->soc.glb,
                                       bl808_hbn_aon_gpio_map[i],
                                       s->aon_gpio_driven[i],
                                       s->aon_gpio_level[i]);
    }
}

static void bl808_hbn_apply_aon_pad_ctrl(BL808MachineState *s)
{
    uint32_t irq_mode;
    uint32_t pad_ctrl0;
    uint32_t pad_ctrl1;
    bool hw_pupd_enable;
    bool iso_mode;

    if (!s->soc.glb) {
        return;
    }

    irq_mode = s->hbn_regs[BL808_HBN_IRQ_MODE_OFFSET / 4];
    pad_ctrl0 = s->hbn_regs[BL808_HBN_PAD_CTRL_0_OFFSET / 4];
    pad_ctrl1 = s->hbn_regs[BL808_HBN_PAD_CTRL_1_OFFSET / 4];
    hw_pupd_enable = (irq_mode & BL808_HBN_REG_EN_HW_PU_PD) != 0;
    iso_mode = (pad_ctrl0 & BL808_HBN_PAD_ISO_MODE) != 0;

    bl808_glb_set_aon_iso_mode(s->soc.glb, iso_mode);
    for (unsigned pin = 0; pin < BL808_HBN_AON_PINS; pin++) {
        unsigned gpio = bl808_hbn_aon_gpio_map[pin];
        bool hw_ctrl = extract32(pad_ctrl0, BL808_HBN_PAD_CTRL_SHIFT + pin, 1);
        bool oe = extract32(pad_ctrl1, BL808_HBN_PAD_OE_SHIFT + pin, 1);
        bool pd = extract32(pad_ctrl1, BL808_HBN_PAD_PD_SHIFT + pin, 1);
        bool pu = extract32(pad_ctrl1, BL808_HBN_PAD_PU_SHIFT + pin, 1);

        bl808_glb_set_aon_pad_ctrl(s->soc.glb, gpio, hw_ctrl,
                                   hw_pupd_enable, oe, pu, pd);
    }
}

static uint64_t G_GNUC_UNUSED bl808_d0_reset_pc(BL808MachineState *s)
{
#ifdef TARGET_RISCV64
    uint32_t boot = s->soc.mm_misc.regs[BL808_MM_MISC_CPU0_BOOT / 4];

    if (s->have_d0_entry) {
        return s->d0_entry;
    }
    if (boot != BL808_MM_MISC_CPU0_BOOT_RESET) {
        return boot;
    }
    if (!s->strict_fidelity && !s->boot_gpio39) {
        return BL808_FLASH_XIP_BASE;
    }
    return BL808_MM_MISC_CPU0_BOOT_RESET;
#else
    return BL808_DRAM_BASE;
#endif
}

static bool G_GNUC_UNUSED bl808_d0_clock_enabled(const BL808MachineState *s)
{
#ifdef TARGET_RISCV64
    return (s->timer1_mm_clk_ctrl_cpu & BL808_MM_GLB_REG_MMCPU0_CLK_EN) != 0;
#else
    (void)s;
    return false;
#endif
}

static bool G_GNUC_UNUSED bl808_d0_reset_asserted(const BL808MachineState *s)
{
#ifdef TARGET_RISCV64
    return (s->mm_sw_sys_reset & BL808_MM_GLB_REG_CTRL_MMCPU0_RESET) != 0;
#else
    (void)s;
    return false;
#endif
}

static void G_GNUC_UNUSED bl808_hold_d0(BL808MachineState *s, uint64_t pc)
{
#ifdef TARGET_RISCV64
    CPUState *cpu = CPU(s->soc.d0_cpu);

    cpu_pause(cpu);
    bl808_set_cpu_halted(cpu, pc);
#else
    (void)s;
    (void)pc;
#endif
}

static uint64_t G_GNUC_UNUSED bl808_lp_reset_pc(BL808MachineState *s)
{
#ifdef TARGET_RISCV64
    uint32_t boot = s->pds_regs[BL808_PDS_CPU_CORE_CFG13_OFFSET / 4];

    if (boot != 0) {
        return boot;
    }
    return s->strict_fidelity ? BL808_BOOTROM_BASE : BL808_LP_FLASH_XIP_BASE;
#else
    return BL808_BOOTROM_BASE;
#endif
}

static bool G_GNUC_UNUSED bl808_lp_clock_enabled(const BL808MachineState *s)
{
#ifdef TARGET_RISCV64
    return (s->pds_regs[BL808_PDS_CPU_CORE_CFG0_OFFSET / 4] &
            BL808_PDS_REG_PICO_CLK_EN) != 0;
#else
    (void)s;
    return false;
#endif
}

static bool G_GNUC_UNUSED bl808_lp_reset_asserted(const BL808MachineState *s)
{
#ifdef TARGET_RISCV64
    return (s->glb_swrst_cfg2 & BL808_GLB_REG_CTRL_PICO_RESET) != 0;
#else
    (void)s;
    return false;
#endif
}

static void G_GNUC_UNUSED bl808_hold_lp(BL808MachineState *s, uint64_t pc)
{
#ifdef TARGET_RISCV64
    CPUState *cpu = CPU(s->soc.lp_cpu);

    cpu_pause(cpu);
    bl808_set_cpu_halted(cpu, pc);
#else
    (void)s;
    (void)pc;
#endif
}

static void G_GNUC_UNUSED bl808_release_or_resume_lp(BL808MachineState *s)
{
#ifdef TARGET_RISCV64
    CPUState *cpu = CPU(s->soc.lp_cpu);
    uint64_t pc = cpu->cc->get_pc(cpu);

    if (pc == 0) {
        pc = bl808_lp_reset_pc(s);
    }
    bl808_set_cpu_running(cpu, pc);
#else
    (void)s;
#endif
}

static void G_GNUC_UNUSED bl808_update_lp_state(BL808MachineState *s,
                                                bool reset_lp)
{
#ifdef TARGET_RISCV64
    CPUState *cpu = CPU(s->soc.lp_cpu);
    uint64_t reset_pc = bl808_lp_reset_pc(s);

    if (reset_lp) {
        device_cold_reset(DEVICE(s->soc.lp_cpu));
    }

    if (bl808_lp_reset_asserted(s)) {
        bl808_hold_lp(s, reset_pc);
    } else if (!bl808_lp_clock_enabled(s)) {
        uint64_t pc = reset_lp ? reset_pc : cpu->cc->get_pc(cpu);

        bl808_hold_lp(s, pc ? pc : reset_pc);
    } else if (reset_lp) {
        bl808_set_cpu_running(cpu, reset_pc);
    } else {
        bl808_release_or_resume_lp(s);
    }
#else
    (void)s;
    (void)reset_lp;
#endif
}

static bool bl808_pds_mm_powered_on(uint32_t ctl2)
{
    return (ctl2 & BL808_PDS_MM_FORCE_MASK) == 0;
}

static void G_GNUC_UNUSED bl808_release_d0_if_ready(BL808MachineState *s)
{
#ifdef TARGET_RISCV64
    if (s->have_d0_entry) {
        bl808_set_cpu_running(CPU(s->soc.d0_cpu), s->d0_entry);
    } else {
        bl808_set_cpu_running(CPU(s->soc.d0_cpu), bl808_d0_reset_pc(s));
    }
#endif
}

static void G_GNUC_UNUSED bl808_release_or_resume_d0(BL808MachineState *s)
{
#ifdef TARGET_RISCV64
    CPUState *cpu = CPU(s->soc.d0_cpu);
    uint64_t pc = cpu->cc->get_pc(cpu);

    if (s->have_d0_entry) {
        bl808_release_d0_if_ready(s);
        return;
    }

    if (pc == 0) {
        pc = bl808_d0_reset_pc(s);
    }
    bl808_set_cpu_running(cpu, pc);
#else
    (void)s;
#endif
}

static void bl808_update_mm_domain_state(BL808MachineState *s, bool powered_on,
                                         bool reset_d0)
{
#ifdef TARGET_RISCV64
    bl808_mm_misc_set_clock_enabled(&s->soc.mm_misc, powered_on);
    bl808_dma2d_set_clock_enabled(&s->soc.dma2d, powered_on);
    bl808_ipc_set_clock_enabled(&s->soc.ipc2, powered_on);
    bl808_uart_set_clock_enabled(&s->soc.uart[3], powered_on);
    bl808_spi_set_clock_enabled(&s->soc.spi1, powered_on);
    bl808_i2c_set_clock_enabled(&s->soc.i2c2, powered_on);
    bl808_i2c_set_clock_enabled(&s->soc.i2c3, powered_on);
    bl808_dma_set_clock_enabled(&s->soc.dma2, powered_on);
    bl808_timer_set_clock_enabled(&s->soc.timer1, powered_on);

    bl808_mm_misc_set_reset_asserted(&s->soc.mm_misc, !powered_on);
    bl808_dma2d_set_reset_asserted(&s->soc.dma2d, !powered_on);
    bl808_ipc_set_reset_asserted(&s->soc.ipc2, !powered_on);
    bl808_uart_set_reset_asserted(&s->soc.uart[3], !powered_on);
    bl808_spi_set_reset_asserted(&s->soc.spi1, !powered_on);
    bl808_i2c_set_reset_asserted(&s->soc.i2c2, !powered_on);
    bl808_i2c_set_reset_asserted(&s->soc.i2c3, !powered_on);
    bl808_dma_set_reset_asserted(&s->soc.dma2, !powered_on);
    bl808_timer_set_reset_asserted(&s->soc.timer1, !powered_on);

    if (!powered_on) {
        bl808_reset_mm_regbanks(s);
    }

    if (reset_d0) {
        device_cold_reset(DEVICE(s->soc.d0_cpu));
    }

    if (!powered_on) {
        bl808_hold_d0(s, bl808_d0_reset_pc(s));
    } else if (bl808_d0_reset_asserted(s)) {
        bl808_hold_d0(s, bl808_d0_reset_pc(s));
    } else if (!bl808_d0_clock_enabled(s)) {
        uint64_t pc = reset_d0 ? bl808_d0_reset_pc(s) :
            CPU(s->soc.d0_cpu)->cc->get_pc(CPU(s->soc.d0_cpu));

        bl808_hold_d0(s, pc);
    } else if (reset_d0) {
        bl808_release_or_resume_d0(s);
    } else {
        bl808_release_or_resume_d0(s);
    }
#else
    (void)reset_d0;
#endif
    s->mm_powered_on = powered_on;
}

static CPUState *bl808_pds_owner_cpu(void)
{
    if (!current_cpu) {
        return NULL;
    }

    switch (RISCV_CPU(current_cpu)->env.mhartid) {
    case 0:
    case 2:
        return current_cpu;
    default:
        return NULL;
    }
}

static bool bl808_pds_status_unmasked(uint32_t reg, unsigned bit)
{
    return (reg & BIT(bit)) && !(reg & BIT(bit + 4));
}

static void bl808_pds_update_irq(BL808MachineState *s)
{
    uint32_t reg = s->pds_regs[BL808_PDS_INT_OFFSET / 4];
    bool asserted = bl808_pds_status_unmasked(reg, 0) ||
                    bl808_pds_status_unmasked(reg, 1) ||
                    bl808_pds_status_unmasked(reg, 2) ||
                    bl808_pds_status_unmasked(reg, 3);

    if (s->m0_pds_wakeup_irq) {
        qemu_set_irq(s->m0_pds_wakeup_irq, asserted);
    }
    if (s->d0_pds_irq) {
        qemu_set_irq(s->d0_pds_irq, asserted);
    }
}

static void bl808_pds_clear_int(BL808MachineState *s)
{
    s->pds_regs[BL808_PDS_INT_OFFSET / 4] &=
        ~(BL808_PDS_INT_STATUS_MASK | BL808_PDS_WAKEUP_EVENT_MASK);
    bl808_pds_update_irq(s);
}

static void bl808_pds_trigger_wakeup(BL808MachineState *s, uint32_t source_bit);

static void bl808_pds_raise_status(BL808MachineState *s, uint32_t status_bit)
{
    s->pds_regs[BL808_PDS_INT_OFFSET / 4] |= status_bit;
    bl808_pds_update_irq(s);
}

static void bl808_pds_trigger_wifi_tbtt(BL808MachineState *s, uint32_t status_bit)
{
    bl808_pds_raise_status(s, status_bit);
    bl808_pds_trigger_wakeup(s, BL808_PDS_WAKEUP_SRC_WIFI_TBTT);
}

static bool bl808_irrx_enabled(BL808MachineState *s)
{
    return (s->ir_regs[BL808_IR_RX_CFG_OFFSET / 4] & BL808_IR_RX_CFG_EN) != 0;
}

static bool bl808_irrx_irq_asserted(BL808MachineState *s)
{
    uint32_t int_sts = s->ir_regs[BL808_IR_RX_INT_STS_OFFSET / 4];

    return bl808_irrx_enabled(s) &&
           (int_sts & BL808_IR_RX_END_INT) &&
           (int_sts & BL808_IR_RX_END_EN) &&
           !(int_sts & BL808_IR_RX_END_MASK);
}

static void bl808_ir_update_irq(BL808MachineState *s)
{
    bool asserted = bl808_irrx_irq_asserted(s);

    if (s->m0_irrx_irq) {
        qemu_set_irq(s->m0_irrx_irq, asserted);
    }
    if (s->lp_irrx_irq) {
        qemu_set_irq(s->lp_irrx_irq, asserted);
    }
}

static void bl808_ir_reset(BL808MachineState *s)
{
    memset(s->ir_regs, 0, sizeof(s->ir_regs));
    bl808_ir_update_irq(s);
}

static uint32_t bl808_ble_raw_status(BL808MachineState *s)
{
    return s->ble_regs[BL808_BLE_INTRAWSTAT_OFFSET / 4] & BL808_BLE_INT_MASK;
}

static uint32_t bl808_ble_masked_status(BL808MachineState *s)
{
    uint32_t enabled = s->ble_regs[BL808_BLE_INTCNTL_OFFSET / 4];

    return bl808_ble_raw_status(s) & enabled & BL808_BLE_INT_MASK;
}

static uint32_t bl808_ble_basetimecnt(BL808MachineState *s)
{
    uint64_t now_ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);

    return (uint32_t)((now_ns / BL808_BLE_SLOT_NS) & BL808_BLE_BASETIME_MASK);
}

static uint32_t bl808_ble_finetimecnt(BL808MachineState *s)
{
    uint64_t now_ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);

    return (uint32_t)((now_ns / 1000ULL) % 625ULL);
}

static void bl808_ble_latch_time(BL808MachineState *s)
{
    s->ble_regs[BL808_BLE_BASETIMECNT_OFFSET / 4] = bl808_ble_basetimecnt(s);
    s->ble_regs[BL808_BLE_FINETIMECNT_OFFSET / 4] = bl808_ble_finetimecnt(s);
}

static void bl808_wireless_update_summary_irq(BL808MachineState *s);

static void bl808_ble_update_irq(BL808MachineState *s)
{
    if (s->m0_ble_irq) {
        qemu_set_irq(s->m0_ble_irq, bl808_ble_masked_status(s) != 0);
    }
    bl808_wireless_update_summary_irq(s);
}

static void bl808_ble_reset(BL808MachineState *s)
{
    memset(s->ble_regs, 0, sizeof(s->ble_regs));
    bl808_ble_latch_time(s);
    bl808_ble_update_irq(s);
}

static void bl808_ble_raise_bits(BL808MachineState *s, uint32_t bits)
{
    s->ble_regs[BL808_BLE_INTRAWSTAT_OFFSET / 4] |= bits & BL808_BLE_INT_MASK;
    bl808_ble_update_irq(s);
}

static uint32_t bl808_wifi_mac_pending_gen(BL808MachineState *s)
{
    uint32_t gen_status =
        s->wifi_machw_intc_regs[BL808_WIFI_MACHW_INTC_GEN_STATUS_OFFSET / 4];
    uint32_t gen_raw =
        s->wifi_machw_intc_regs[BL808_WIFI_MACHW_INTC_GEN_RAW_OFFSET / 4];
    uint32_t gen_unmask =
        s->wifi_machw_intc_regs[BL808_WIFI_MACHW_INTC_IRQ_STAT_OFFSET / 4];

    if (!(gen_status & BL808_WIFI_MACHW_GEN_GLOBAL_EN)) {
        return 0;
    }

    return gen_raw & gen_unmask;
}

static uint32_t bl808_wifi_mac_raw_status(BL808MachineState *s)
{
    uint32_t raw =
        s->wifi_machw_intc_regs[BL808_WIFI_MACHW_INTC_STATUS_RAW_OFFSET / 4];

    if (bl808_wifi_mac_pending_gen(s)) {
        raw |= BL808_WIFI_MACHW_IRQ_GEN;
    }

    return raw;
}

static uint32_t bl808_wifi_mac_masked_status(BL808MachineState *s)
{
    uint32_t unmask =
        s->wifi_machw_intc_regs[BL808_WIFI_MACHW_INTC_UNMASK_OFFSET / 4];

    if (!(unmask & BL808_WIFI_MACHW_IRQ_GLOBAL_EN)) {
        return 0;
    }

    return bl808_wifi_mac_raw_status(s) &
           (unmask & ~BL808_WIFI_MACHW_IRQ_GLOBAL_EN);
}

static uint32_t bl808_wifi_ipc_status2_masked(BL808MachineState *s)
{
    return s->wifi_ipc_pending_status2 & s->wifi_ipc_enabled;
}

static void bl808_wireless_update_summary_irq(BL808MachineState *s)
{
    bool asserted = bl808_wifi_mac_raw_status(s) != 0 ||
                    s->wifi_ipc_pending_status2 != 0 ||
                    bl808_ble_raw_status(s) != 0;

    if (s->d0_wl_all_irq) {
        qemu_set_irq(s->d0_wl_all_irq, asserted);
    }
}

static uint32_t bl808_wifi_mac_handler(BL808MachineState *s)
{
    return bl808_wifi_mac_raw_status(s) ? BL808_WIFI_MAC_HANDLER_GEN : 0;
}

static void bl808_wifi_mac_update_irq(BL808MachineState *s)
{
    if (s->m0_wifi_irq) {
        qemu_set_irq(s->m0_wifi_irq, bl808_wifi_mac_masked_status(s) != 0);
    }
    bl808_wireless_update_summary_irq(s);
}

static void bl808_wifi_ipc_update_irq(BL808MachineState *s)
{
    if (s->m0_wifi_ipc_pub_irq) {
        qemu_set_irq(s->m0_wifi_ipc_pub_irq,
                     bl808_wifi_ipc_status2_masked(s) != 0);
    }
    bl808_wireless_update_summary_irq(s);
}

static void bl808_wifi_mac_raise_irq_bits(BL808MachineState *s, uint32_t bits)
{
    s->wifi_machw_intc_regs[BL808_WIFI_MACHW_INTC_STATUS_RAW_OFFSET / 4] |=
        bits & BL808_WIFI_MACHW_IRQ_MODEL_MASK;
    bl808_wifi_mac_update_irq(s);
}

static void bl808_wifi_mac_raise_gen_bits(BL808MachineState *s, uint32_t bits)
{
    s->wifi_machw_intc_regs[BL808_WIFI_MACHW_INTC_GEN_RAW_OFFSET / 4] |= bits;
    bl808_wifi_mac_update_irq(s);
}

static uint32_t bl808_wifi_machw_timlo(BL808MachineState *s)
{
    return (uint32_t)((qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) * 40) /
                      NANOSECONDS_PER_SECOND);
}

static void bl808_wifi_mac_reset(BL808MachineState *s)
{
    memset(s->wifi_mac_pl_regs, 0, sizeof(s->wifi_mac_pl_regs));
    memset(s->wifi_machw_regs, 0, sizeof(s->wifi_machw_regs));
    memset(s->wifi_machw_intc_regs, 0, sizeof(s->wifi_machw_intc_regs));
    s->wifi_machw_regs[BL808_WIFI_MACHW_STATE_CNTRL_OFFSET / 4] = 1;
    bl808_wifi_mac_update_irq(s);
}

static void bl808_wifi_ipc_reset(BL808MachineState *s)
{
    s->wifi_ipc_status_reg = 0;
    s->wifi_ipc_enabled = 0;
    s->wifi_ipc_cfg_reg = 0;
    s->wifi_ipc_pending_status2 = 0;
    bl808_wifi_ipc_update_irq(s);
}

static void bl808_ir_inject_frame(BL808MachineState *s)
{
    uint32_t bits = s->irrx_inject_bits ? s->irrx_inject_bits : 32;

    if (!bl808_irrx_enabled(s)) {
        return;
    }

    s->ir_regs[BL808_IR_RX_DATA_COUNT_OFFSET / 4] =
        bits & BL808_IR_RX_DATA_COUNT_MASK;
    s->ir_regs[BL808_IR_RX_DATA_WORD0_OFFSET / 4] = s->irrx_inject_data;
    s->ir_regs[BL808_IR_RX_DATA_WORD1_OFFSET / 4] = s->irrx_inject_data1;
    s->ir_regs[BL808_IR_RX_INT_STS_OFFSET / 4] |= BL808_IR_RX_END_INT;
    bl808_ir_update_irq(s);
    bl808_pds_trigger_wakeup(s, BL808_PDS_WAKEUP_SRC_IRRX);
}

static uint64_t bl808_ir_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808MachineState *s = opaque;
    uint32_t idx = offset / 4;

    (void)size;

    if (idx >= ARRAY_SIZE(s->ir_regs)) {
        return 0;
    }

    return s->ir_regs[idx];
}

static void bl808_ir_write(void *opaque, hwaddr offset, uint64_t value,
                           unsigned size)
{
    BL808MachineState *s = opaque;
    uint32_t idx = offset / 4;
    uint32_t old_value;
    uint32_t next_value;

    (void)size;

    if (idx >= ARRAY_SIZE(s->ir_regs)) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808.ir: write beyond register window @ 0x%"
                      HWADDR_PRIx " = 0x%" PRIx64 "\n", offset, value);
        return;
    }

    old_value = s->ir_regs[idx];
    next_value = (uint32_t)value;
    switch (offset) {
    case BL808_IR_RX_INT_STS_OFFSET:
        s->ir_regs[idx] = (old_value & BL808_IR_RX_INT_STATUS_MASK) |
                          (next_value & BL808_IR_RX_INT_CTRL_MASK);
        if (next_value & BL808_IR_RX_END_CLR) {
            s->ir_regs[idx] &= ~BL808_IR_RX_END_INT;
        }
        bl808_ir_update_irq(s);
        break;
    case BL808_IR_RX_DATA_COUNT_OFFSET:
    case BL808_IR_RX_DATA_WORD0_OFFSET:
    case BL808_IR_RX_DATA_WORD1_OFFSET:
        break;
    default:
        s->ir_regs[idx] = next_value;
        if (offset == BL808_IR_RX_CFG_OFFSET) {
            bl808_ir_update_irq(s);
        }
        break;
    }
}

static const MemoryRegionOps bl808_ir_ops = {
    .read = bl808_ir_read,
    .write = bl808_ir_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static uint64_t bl808_ble_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808MachineState *s = opaque;
    uint32_t idx = offset / 4;

    (void)size;

    if (idx >= ARRAY_SIZE(s->ble_regs)) {
        return 0;
    }

    switch (offset) {
    case BL808_BLE_INTSTAT_OFFSET:
        return bl808_ble_masked_status(s);
    case BL808_BLE_INTRAWSTAT_OFFSET:
        return bl808_ble_raw_status(s);
    case BL808_BLE_BASETIMECNT_OFFSET:
    case BL808_BLE_FINETIMECNT_OFFSET:
        bl808_ble_latch_time(s);
        return s->ble_regs[idx];
    case BL808_BLE_INTACK_OFFSET:
        return 0;
    default:
        return s->ble_regs[idx];
    }
}

static void bl808_ble_write(void *opaque, hwaddr offset, uint64_t value,
                            unsigned size)
{
    BL808MachineState *s = opaque;
    uint32_t idx = offset / 4;
    uint32_t next = (uint32_t)value;

    (void)size;

    if (idx >= ARRAY_SIZE(s->ble_regs)) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808.ble: write beyond register window @ 0x%"
                      HWADDR_PRIx " = 0x%" PRIx64 "\n", offset, value);
        return;
    }

    switch (offset) {
    case BL808_BLE_INTCNTL_OFFSET:
        s->ble_regs[idx] = next & BL808_BLE_INT_MASK;
        bl808_ble_update_irq(s);
        break;
    case BL808_BLE_INTACK_OFFSET:
        s->ble_regs[BL808_BLE_INTRAWSTAT_OFFSET / 4] &=
            ~(next & BL808_BLE_INT_MASK);
        bl808_ble_update_irq(s);
        break;
    case BL808_BLE_BASETIMECNT_OFFSET:
        if (next & BL808_BLE_BASETIME_LATCH) {
            bl808_ble_latch_time(s);
        } else {
            s->ble_regs[idx] = next & BL808_BLE_BASETIME_MASK;
        }
        break;
    case BL808_BLE_INTRAWSTAT_OFFSET:
    case BL808_BLE_INTSTAT_OFFSET:
        break;
    default:
        s->ble_regs[idx] = next;
        break;
    }
}

static const MemoryRegionOps bl808_ble_ops = {
    .read = bl808_ble_read,
    .write = bl808_ble_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static uint64_t bl808_wifi_mac_pl_read(void *opaque, hwaddr offset,
                                       unsigned size)
{
    BL808MachineState *s = opaque;
    uint32_t idx = offset / 4;

    (void)size;

    if (idx >= ARRAY_SIZE(s->wifi_mac_pl_regs)) {
        return 0;
    }

    return s->wifi_mac_pl_regs[idx];
}

static void bl808_wifi_mac_pl_write(void *opaque, hwaddr offset, uint64_t value,
                                    unsigned size)
{
    BL808MachineState *s = opaque;
    uint32_t idx = offset / 4;

    (void)size;

    if (idx >= ARRAY_SIZE(s->wifi_mac_pl_regs)) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808.wifi-mac-pl: write beyond register window @ 0x%"
                      HWADDR_PRIx " = 0x%" PRIx64 "\n", offset, value);
        return;
    }

    s->wifi_mac_pl_regs[idx] = (uint32_t)value;
}

static const MemoryRegionOps bl808_wifi_mac_pl_ops = {
    .read = bl808_wifi_mac_pl_read,
    .write = bl808_wifi_mac_pl_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static uint64_t bl808_wifi_mac_irq_read(void *opaque, hwaddr offset,
                                        unsigned size)
{
    BL808MachineState *s = opaque;

    (void)size;

    switch (offset) {
    case BL808_WIFI_MAC_IRQ_STATUS0_OFFSET:
        return bl808_wifi_mac_raw_status(s);
    case BL808_WIFI_MAC_IRQ_STATUS1_OFFSET:
        return 0;
    case BL808_WIFI_MAC_IRQ_HANDLER_OFFSET:
        return bl808_wifi_mac_handler(s);
    default:
        return 0;
    }
}

static void bl808_wifi_mac_irq_write(void *opaque, hwaddr offset, uint64_t value,
                                     unsigned size)
{
    (void)opaque;
    (void)offset;
    (void)value;
    (void)size;
}

static const MemoryRegionOps bl808_wifi_mac_irq_ops = {
    .read = bl808_wifi_mac_irq_read,
    .write = bl808_wifi_mac_irq_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static uint64_t bl808_wifi_machw_read(void *opaque, hwaddr offset,
                                      unsigned size)
{
    BL808MachineState *s = opaque;
    uint32_t idx = offset / 4;

    (void)size;

    if (offset == BL808_WIFI_MACHW_TIMLO_OFFSET) {
        return bl808_wifi_machw_timlo(s);
    }

    if (idx >= ARRAY_SIZE(s->wifi_machw_regs)) {
        return 0;
    }

    return s->wifi_machw_regs[idx];
}

static void bl808_wifi_machw_write(void *opaque, hwaddr offset, uint64_t value,
                                   unsigned size)
{
    BL808MachineState *s = opaque;
    uint32_t idx = offset / 4;

    (void)size;

    if (idx >= ARRAY_SIZE(s->wifi_machw_regs)) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808.wifi-machw: write beyond register window @ 0x%"
                      HWADDR_PRIx " = 0x%" PRIx64 "\n", offset, value);
        return;
    }

    if (offset != BL808_WIFI_MACHW_TIMLO_OFFSET) {
        s->wifi_machw_regs[idx] = (uint32_t)value;
    }
}

static const MemoryRegionOps bl808_wifi_machw_ops = {
    .read = bl808_wifi_machw_read,
    .write = bl808_wifi_machw_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static uint64_t bl808_wifi_machw_intc_read(void *opaque, hwaddr offset,
                                           unsigned size)
{
    BL808MachineState *s = opaque;
    uint32_t idx = offset / 4;

    (void)size;

    if (idx >= ARRAY_SIZE(s->wifi_machw_intc_regs)) {
        return 0;
    }

    switch (offset) {
    case BL808_WIFI_MACHW_INTC_SOFT_RESET_OFFSET:
        return 0;
    case BL808_WIFI_MACHW_INTC_STATUS_RAW_OFFSET:
        return bl808_wifi_mac_raw_status(s);
    case BL808_WIFI_MACHW_INTC_GEN_STATUS_OFFSET:
        return s->wifi_machw_intc_regs[idx] | bl808_wifi_mac_pending_gen(s);
    default:
        return s->wifi_machw_intc_regs[idx];
    }
}

static void bl808_wifi_machw_intc_write(void *opaque, hwaddr offset,
                                        uint64_t value, unsigned size)
{
    BL808MachineState *s = opaque;
    uint32_t idx = offset / 4;
    uint32_t next = (uint32_t)value;

    (void)size;

    if (idx >= ARRAY_SIZE(s->wifi_machw_intc_regs)) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808.wifi-machw-intc: write beyond register window @ "
                      "0x%" HWADDR_PRIx " = 0x%" PRIx64 "\n", offset, value);
        return;
    }

    switch (offset) {
    case BL808_WIFI_MACHW_INTC_SOFT_RESET_OFFSET:
        if (next & 0xFF) {
            memset(s->wifi_machw_intc_regs, 0, sizeof(s->wifi_machw_intc_regs));
            s->wifi_machw_regs[BL808_WIFI_MACHW_STATE_CNTRL_OFFSET / 4] = 1;
        }
        bl808_wifi_mac_update_irq(s);
        break;
    case BL808_WIFI_MACHW_INTC_STATUS_ACK_OFFSET:
        s->wifi_machw_intc_regs[BL808_WIFI_MACHW_INTC_STATUS_RAW_OFFSET / 4] &=
            ~(next & BL808_WIFI_MACHW_IRQ_MODEL_MASK);
        bl808_wifi_mac_update_irq(s);
        break;
    case BL808_WIFI_MACHW_INTC_UNMASK_OFFSET:
    case BL808_WIFI_MACHW_INTC_GEN_STATUS_OFFSET:
    case BL808_WIFI_MACHW_INTC_IRQ_STAT_OFFSET:
        s->wifi_machw_intc_regs[idx] = next;
        bl808_wifi_mac_update_irq(s);
        break;
    case BL808_WIFI_MACHW_INTC_FORCE_OFFSET:
        s->wifi_machw_intc_regs[BL808_WIFI_MACHW_INTC_STATUS_RAW_OFFSET / 4] |=
            next & BL808_WIFI_MACHW_IRQ_MODEL_MASK;
        bl808_wifi_mac_update_irq(s);
        break;
    case BL808_WIFI_MACHW_INTC_IRQ_SET_OFFSET:
        s->wifi_machw_intc_regs[BL808_WIFI_MACHW_INTC_GEN_RAW_OFFSET / 4] &=
            ~next;
        bl808_wifi_mac_update_irq(s);
        break;
    default:
        s->wifi_machw_intc_regs[idx] = next;
        break;
    }
}

static const MemoryRegionOps bl808_wifi_machw_intc_ops = {
    .read = bl808_wifi_machw_intc_read,
    .write = bl808_wifi_machw_intc_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static uint64_t bl808_wifi_ipc_emb_read(void *opaque, hwaddr offset,
                                        unsigned size)
{
    BL808MachineState *s = opaque;

    (void)size;

    switch (offset) {
    case BL808_WIFI_IPC_STATUS_OFFSET:
        return s->wifi_ipc_status_reg;
    case BL808_WIFI_IPC_UNMASK_SET_OFFSET:
        return s->wifi_ipc_enabled;
    case BL808_WIFI_IPC_UNMASK_CLR_OFFSET:
        return ~s->wifi_ipc_enabled;
    case BL808_WIFI_IPC_CFG_OFFSET:
        return s->wifi_ipc_cfg_reg;
    case BL808_WIFI_IPC_ACK_OFFSET:
        return 0;
    case BL808_WIFI_IPC_STATUS2_OFFSET:
        return bl808_wifi_ipc_status2_masked(s);
    case BL808_WIFI_IPC_MAGIC_OFFSET:
        return BL808_WIFI_IPC_MAGIC;
    default:
        return 0;
    }
}

static void bl808_wifi_ipc_emb_write(void *opaque, hwaddr offset, uint64_t value,
                                     unsigned size)
{
    BL808MachineState *s = opaque;
    uint32_t next = (uint32_t)value;

    (void)size;

    switch (offset) {
    case BL808_WIFI_IPC_STATUS_OFFSET:
        s->wifi_ipc_status_reg = next;
        break;
    case BL808_WIFI_IPC_UNMASK_SET_OFFSET:
        s->wifi_ipc_enabled |= next;
        bl808_wifi_ipc_update_irq(s);
        break;
    case BL808_WIFI_IPC_UNMASK_CLR_OFFSET:
        s->wifi_ipc_enabled &= ~next;
        bl808_wifi_ipc_update_irq(s);
        break;
    case BL808_WIFI_IPC_CFG_OFFSET:
        s->wifi_ipc_cfg_reg = next;
        break;
    case BL808_WIFI_IPC_ACK_OFFSET:
        s->wifi_ipc_pending_status2 &= ~next;
        bl808_wifi_ipc_update_irq(s);
        break;
    default:
        break;
    }
}

static const MemoryRegionOps bl808_wifi_ipc_emb_ops = {
    .read = bl808_wifi_ipc_emb_read,
    .write = bl808_wifi_ipc_emb_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static int bl808_pds_gpio_index_from_pin(unsigned pin)
{
    if (pin <= 8) {
        return (int)pin;
    }
    if (pin >= 16 && pin <= 38) {
        return (int)(pin - 7);
    }
    return -1;
}

static unsigned bl808_pds_gpio_pad_group(unsigned idx)
{
    if (idx <= 8) {
        return 0;
    }
    if (idx <= 16) {
        return 1;
    }
    return 2;
}

static unsigned bl808_pds_gpio_int_set(unsigned idx)
{
    if (idx <= 7) {
        return 0;
    }
    if (idx <= 15) {
        return 1;
    }
    if (idx <= 23) {
        return 2;
    }
    return 3;
}

static uint32_t bl808_pds_gpio_set_mask(unsigned set)
{
    switch (set) {
    case 0:
        return 0x000000FFU;
    case 1:
        return 0x0000FF00U;
    case 2:
        return 0x00FF0000U;
    default:
        return 0xFF000000U;
    }
}

static unsigned bl808_pds_gpio_int_mode(BL808MachineState *s, unsigned idx)
{
    uint32_t reg = s->pds_regs[BL808_PDS_GPIO_INT_OFFSET / 4];

    switch (bl808_pds_gpio_int_set(idx)) {
    case 0:
        return extract32(reg, BL808_PDS_GPIO_SET1_MODE_SHIFT, 4);
    case 1:
        return extract32(reg, BL808_PDS_GPIO_SET2_MODE_SHIFT, 4);
    case 2:
        return extract32(reg, BL808_PDS_GPIO_SET3_MODE_SHIFT, 4);
    default:
        return extract32(reg, BL808_PDS_GPIO_SET4_MODE_SHIFT, 4);
    }
}

static bool bl808_pds_gpio_ie_enabled(BL808MachineState *s, unsigned idx)
{
    uint32_t reg = s->pds_regs[BL808_PDS_GPIO_I_SET_OFFSET / 4];

    return extract32(reg, bl808_pds_gpio_pad_group(idx), 1);
}

static bool bl808_pds_gpio_unmasked(BL808MachineState *s, unsigned idx)
{
    return (s->pds_regs[BL808_PDS_GPIO_PD_SET_OFFSET / 4] & BIT(idx)) == 0;
}

static bool bl808_pds_gpio_event_enabled(BL808MachineState *s, unsigned idx)
{
    return bl808_pds_gpio_ie_enabled(s, idx) &&
           bl808_pds_gpio_unmasked(s, idx);
}

static bool bl808_pds_gpio_sampling_mode(unsigned mode)
{
    return mode <= 0x4;
}

static bool bl808_pds_gpio_sample_needed(BL808MachineState *s)
{
    for (unsigned idx = 0; idx < 32; idx++) {
        if (!bl808_pds_gpio_event_enabled(s, idx)) {
            continue;
        }
        if (bl808_pds_gpio_sampling_mode(bl808_pds_gpio_int_mode(s, idx))) {
            return true;
        }
    }

    return false;
}

static void bl808_pds_gpio_sample_reschedule(BL808MachineState *s)
{
    if (!s->pds_gpio_sample_timer) {
        return;
    }

    if (!bl808_pds_gpio_sample_needed(s)) {
        timer_del(s->pds_gpio_sample_timer);
        return;
    }

    timer_mod(s->pds_gpio_sample_timer,
              qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) +
              BL808_HBN_F32K_PERIOD_NS);
}

static void bl808_pds_gpio_reset_history(BL808MachineState *s, unsigned idx)
{
    s->pds_gpio_history[idx] = s->pds_gpio_level[idx] ? 0x7 : 0x0;
}

static void bl808_pds_gpio_update_wakeup(BL808MachineState *s)
{
    if (s->pds_regs[BL808_PDS_GPIO_STAT_OFFSET / 4]) {
        bl808_pds_trigger_wakeup(s, BL808_PDS_WAKEUP_SRC_PDS_GPIO);
    }
}

static void bl808_pds_gpio_refresh_live_sources(BL808MachineState *s)
{
    uint32_t *stat = &s->pds_regs[BL808_PDS_GPIO_STAT_OFFSET / 4];

    for (unsigned idx = 0; idx < 32; idx++) {
        unsigned mode;

        if (!bl808_pds_gpio_event_enabled(s, idx)) {
            continue;
        }

        mode = bl808_pds_gpio_int_mode(s, idx);
        if (mode == 0xA || mode == 0xB) {
            if (bl808_hbn_gpio_level_active(mode, s->pds_gpio_level[idx])) {
                *stat |= BIT(idx);
            }
        }
    }

    bl808_pds_gpio_update_wakeup(s);
}

static void bl808_pds_gpio_clear_set(BL808MachineState *s, unsigned set)
{
    s->pds_regs[BL808_PDS_GPIO_STAT_OFFSET / 4] &=
        ~bl808_pds_gpio_set_mask(set);
    bl808_pds_gpio_refresh_live_sources(s);
}

static uint32_t bl808_pds_wakeup_event_bit(uint32_t source_bit)
{
    return source_bit << 11;
}

static bool bl808_pds_wakeup_source_enabled(BL808MachineState *s,
                                            uint32_t source_bit)
{
    return (s->pds_regs[BL808_PDS_INT_OFFSET / 4] & source_bit) != 0;
}

static void bl808_pds_trigger_wakeup(BL808MachineState *s, uint32_t source_bit)
{
    if (!bl808_pds_wakeup_source_enabled(s, source_bit)) {
        return;
    }

    s->pds_regs[BL808_PDS_INT_OFFSET / 4] |=
        BL808_PDS_INT_WAKEUP | bl808_pds_wakeup_event_bit(source_bit);
    bl808_pds_update_irq(s);

    if (s->pds_sleep_pending) {
        bl808_pds_complete_sleep(s);
    }
}

static void bl808_glb_pds_wakeup_set(void *opaque, int n, int level)
{
    BL808MachineState *s = opaque;

    (void)n;

    s->glb_gpio_irq_pending = level != 0;
    if (level) {
        bl808_pds_trigger_wakeup(s, BL808_PDS_WAKEUP_SRC_GLB_GPIO);
    }
}

static void bl808_refresh_cached_irqs(BL808MachineState *s)
{
    if (s->soc.m0_clic) {
        s->m0_irrx_irq =
            qdev_get_gpio_in(s->soc.m0_clic, BL808_M0_IRRX_IRQ);
        s->m0_pds_wakeup_irq =
            qdev_get_gpio_in(s->soc.m0_clic, BL808_M0_PDS_WAKEUP_IRQ);
        s->m0_hbn_out0_irq =
            qdev_get_gpio_in(s->soc.m0_clic, BL808_M0_HBN_OUT0_IRQ);
        s->m0_hbn_out1_irq =
            qdev_get_gpio_in(s->soc.m0_clic, BL808_M0_HBN_OUT1_IRQ);
        s->m0_wifi_irq =
            qdev_get_gpio_in(s->soc.m0_clic, BL808_M0_WIFI_IRQ);
        s->m0_bz_phy_irq =
            qdev_get_gpio_in(s->soc.m0_clic, BL808_M0_BZ_PHY_IRQ);
        s->m0_ble_irq =
            qdev_get_gpio_in(s->soc.m0_clic, BL808_M0_BLE_IRQ);
        s->m0_wifi_ipc_pub_irq =
            qdev_get_gpio_in(s->soc.m0_clic, BL808_M0_WIFI_IPC_PUB_IRQ);
    }

    if (s->soc.d0_plic) {
        s->d0_wl_all_irq =
            qdev_get_gpio_in(s->soc.d0_plic, BL808_D0_WL_ALL_IRQ);
        s->d0_pds_irq =
            qdev_get_gpio_in(s->soc.d0_plic, BL808_D0_PDS_IRQ);
    }

    if (s->soc.lp_clic) {
        s->lp_irrx_irq =
            qdev_get_gpio_in(s->soc.lp_clic, BL808_LP_IRRX_IRQ);
    }
}

static void bl808_pds_gpio_level_set(void *opaque, int n, int level)
{
    BL808MachineState *s = opaque;
    int idx = bl808_pds_gpio_index_from_pin((unsigned)n);
    unsigned mode;
    bool old_level;
    bool new_level;

    if (idx < 0) {
        return;
    }

    old_level = s->pds_gpio_level[idx];
    new_level = level != 0;
    s->pds_gpio_level[idx] = new_level;

    if (!bl808_pds_gpio_event_enabled(s, idx)) {
        return;
    }

    mode = bl808_pds_gpio_int_mode(s, idx);
    if (bl808_hbn_gpio_irq_immediate(mode, old_level, new_level) ||
        bl808_hbn_gpio_level_active(mode, new_level)) {
        s->pds_regs[BL808_PDS_GPIO_STAT_OFFSET / 4] |= BIT(idx);
        bl808_pds_gpio_update_wakeup(s);
    }
}

static void bl808_pds_gpio_sample_cb(void *opaque)
{
    BL808MachineState *s = opaque;

    for (unsigned idx = 0; idx < 32; idx++) {
        unsigned mode = bl808_pds_gpio_int_mode(s, idx);

        s->pds_gpio_history[idx] =
            ((s->pds_gpio_history[idx] << 1) |
             (s->pds_gpio_level[idx] ? 1 : 0)) & 0x7;
        if (!bl808_pds_gpio_event_enabled(s, idx)) {
            continue;
        }
        if (bl808_hbn_gpio_irq_sampled(mode, s->pds_gpio_history[idx])) {
            s->pds_regs[BL808_PDS_GPIO_STAT_OFFSET / 4] |= BIT(idx);
        }
    }

    bl808_pds_gpio_update_wakeup(s);
    bl808_pds_gpio_sample_reschedule(s);
}

static void bl808_hbn_update_irqs(BL808MachineState *s)
{
    uint32_t stat = s->hbn_regs[BL808_HBN_IRQ_STAT_OFFSET / 4];
    bool out0_asserted = (stat & BL808_HBN_OUT0_STATUS_MASK) != 0;
    bool out1_asserted = (stat & BL808_HBN_OUT1_STATUS_MASK) != 0;
    qemu_irq out0_irq = s->soc.m0_clic ?
        qdev_get_gpio_in(s->soc.m0_clic, BL808_M0_HBN_OUT0_IRQ) :
        s->m0_hbn_out0_irq;
    qemu_irq out1_irq = s->soc.m0_clic ?
        qdev_get_gpio_in(s->soc.m0_clic, BL808_M0_HBN_OUT1_IRQ) :
        s->m0_hbn_out1_irq;

    if (out0_irq) {
        qemu_set_irq(out0_irq, out0_asserted);
    }
    if (out1_irq) {
        qemu_set_irq(out1_irq, out1_asserted);
    }
    if (out0_asserted || out1_asserted) {
        bl808_pds_trigger_wakeup(s, BL808_PDS_WAKEUP_SRC_HBN_IRQ);
    }
}

static unsigned bl808_hbn_gpio_mode(BL808MachineState *s)
{
    return extract32(s->hbn_regs[BL808_HBN_IRQ_MODE_OFFSET / 4],
                     BL808_HBN_PIN_WAKEUP_MODE_SHIFT, 4);
}

static uint16_t bl808_hbn_gpio_mask(BL808MachineState *s)
{
    return extract32(s->hbn_regs[BL808_HBN_IRQ_MODE_OFFSET / 4],
                     BL808_HBN_PIN_WAKEUP_MASK_SHIFT, BL808_HBN_AON_PINS);
}

static bool bl808_hbn_gpio_delay_enabled(BL808MachineState *s)
{
    return (s->hbn_regs[BL808_HBN_IRQ_MODE_OFFSET / 4] &
            BL808_HBN_PIN_WAKEUP_EN) != 0;
}

static uint64_t bl808_hbn_gpio_delay_ns(BL808MachineState *s)
{
    uint32_t seconds = extract32(s->hbn_regs[BL808_HBN_IRQ_MODE_OFFSET / 4],
                                 BL808_HBN_PIN_WAKEUP_SEL_SHIFT,
                                 BL808_HBN_PIN_WAKEUP_SEL_LEN);

    if (seconds == 0) {
        seconds = 1;
    }

    return (uint64_t)seconds * NANOSECONDS_PER_SECOND;
}

static bool bl808_hbn_gpio_sampling_mode(unsigned mode)
{
    return mode <= 0x4;
}

static bool bl808_hbn_gpio_sample_needed(BL808MachineState *s)
{
    return bl808_hbn_gpio_mask(s) != 0 &&
           bl808_hbn_gpio_sampling_mode(bl808_hbn_gpio_mode(s));
}

static void bl808_hbn_gpio_sample_reschedule(BL808MachineState *s)
{
    if (!s->hbn_gpio_sample_timer) {
        return;
    }

    if (!bl808_hbn_gpio_sample_needed(s)) {
        timer_del(s->hbn_gpio_sample_timer);
        return;
    }

    timer_mod(s->hbn_gpio_sample_timer,
              qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) +
              BL808_HBN_F32K_PERIOD_NS);
}

static void bl808_hbn_reset_aon_history(BL808MachineState *s, unsigned pin)
{
    s->hbn_aon_history[pin] = s->hbn_aon_level[pin] ? 0x7 : 0x0;
}

static bool bl808_hbn_gpio_irq_immediate(unsigned mode, bool old_level,
                                         bool new_level)
{
    switch (mode) {
    case 0x8:
        return old_level && !new_level;
    case 0x9:
        return !old_level && new_level;
    default:
        return false;
    }
}

static bool bl808_hbn_gpio_irq_sampled(unsigned mode, uint8_t history)
{
    switch (mode) {
    case 0x0:
        return history == 0x4;
    case 0x1:
        return history == 0x3;
    case 0x2:
    case 0xA:
        return history == 0x0;
    case 0x3:
    case 0xB:
        return history == 0x7;
    case 0x4:
        return history == 0x4 || history == 0x3;
    default:
        return false;
    }
}

static bool bl808_hbn_gpio_mode_is_edge(unsigned mode)
{
    switch (mode) {
    case 0x0:
    case 0x1:
    case 0x4:
    case 0x8:
    case 0x9:
        return true;
    default:
        return false;
    }
}

static bool bl808_hbn_gpio_mode_is_level(unsigned mode)
{
    switch (mode) {
    case 0x2:
    case 0x3:
    case 0xA:
    case 0xB:
        return true;
    default:
        return false;
    }
}

static bool bl808_hbn_gpio_level_active(unsigned mode, bool level)
{
    switch (mode) {
    case 0xA:
    case 0xB:
        return bl808_hbn_gpio_irq_sampled(mode, level ? 0x7 : 0x0);
    default:
        return false;
    }
}

static bool bl808_hbn_gpio_sample_level_active(BL808MachineState *s,
                                               unsigned pin,
                                               unsigned mode)
{
    switch (mode) {
    case 0x2:
    case 0x3:
        return bl808_hbn_gpio_irq_sampled(mode, s->hbn_aon_history[pin]);
    default:
        return false;
    }
}

static void bl808_hbn_gpio_delay_reschedule(BL808MachineState *s)
{
    int64_t deadline_ns = -1;

    if (!s->hbn_gpio_delay_timer) {
        return;
    }

    for (unsigned pin = 0; pin < BL808_HBN_AON_PINS; pin++) {
        int64_t pin_deadline = s->hbn_aon_delay_deadline_ns[pin];

        if (pin_deadline < 0) {
            continue;
        }

        if (deadline_ns < 0 || pin_deadline < deadline_ns) {
            deadline_ns = pin_deadline;
        }
    }

    if (deadline_ns < 0) {
        timer_del(s->hbn_gpio_delay_timer);
    } else {
        timer_mod(s->hbn_gpio_delay_timer, deadline_ns);
    }
}

static void bl808_hbn_gpio_delay_cancel_pin(BL808MachineState *s, unsigned pin)
{
    s->hbn_aon_delay_deadline_ns[pin] = -1;
}

static void bl808_hbn_gpio_delay_cancel_all(BL808MachineState *s)
{
    for (unsigned pin = 0; pin < BL808_HBN_AON_PINS; pin++) {
        s->hbn_aon_delay_deadline_ns[pin] = -1;
    }
    bl808_hbn_gpio_delay_reschedule(s);
}

static void bl808_hbn_gpio_delay_arm_pin(BL808MachineState *s, unsigned pin)
{
    uint32_t stat = s->hbn_regs[BL808_HBN_IRQ_STAT_OFFSET / 4];
    uint16_t mask = bl808_hbn_gpio_mask(s);
    int64_t now_ns;

    if (!bl808_hbn_gpio_delay_enabled(s) ||
        !(mask & BIT(pin)) ||
        (stat & BIT(pin)) ||
        s->hbn_aon_delay_deadline_ns[pin] >= 0) {
        return;
    }

    now_ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);
    s->hbn_aon_delay_deadline_ns[pin] = now_ns + bl808_hbn_gpio_delay_ns(s);
    bl808_hbn_gpio_delay_reschedule(s);
}

static bool bl808_hbn_gpio_delay_qualifies(BL808MachineState *s, unsigned pin)
{
    unsigned mode = bl808_hbn_gpio_mode(s);

    if (bl808_hbn_gpio_mode_is_edge(mode)) {
        return true;
    }

    if (bl808_hbn_gpio_sample_level_active(s, pin, mode)) {
        return true;
    }

    return bl808_hbn_gpio_level_active(mode, s->hbn_aon_level[pin]);
}

/*
 * The SDK exposes a 1-7 second AON pad wake delay but the RM does not spell
 * out how that timer interacts with each trigger mode. Model edge modes as a
 * delayed latch and level modes as needing to remain qualified at expiry.
 */
static void bl808_hbn_gpio_delay_cb(void *opaque)
{
    BL808MachineState *s = opaque;
    int64_t now_ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);

    for (unsigned pin = 0; pin < BL808_HBN_AON_PINS; pin++) {
        int64_t deadline_ns = s->hbn_aon_delay_deadline_ns[pin];

        if (deadline_ns < 0 || deadline_ns > now_ns) {
            continue;
        }

        s->hbn_aon_delay_deadline_ns[pin] = -1;
        if (bl808_hbn_gpio_delay_qualifies(s, pin)) {
            s->hbn_regs[BL808_HBN_IRQ_STAT_OFFSET / 4] |= BIT(pin);
        }
    }

    bl808_hbn_update_irqs(s);
    bl808_hbn_gpio_delay_reschedule(s);
}

static void bl808_hbn_gpio_sync_delayed_level(BL808MachineState *s,
                                              unsigned pin)
{
    unsigned mode = bl808_hbn_gpio_mode(s);
    uint32_t stat = s->hbn_regs[BL808_HBN_IRQ_STAT_OFFSET / 4];
    bool active;

    if (!bl808_hbn_gpio_delay_enabled(s) ||
        !bl808_hbn_gpio_mode_is_level(mode) ||
        (stat & BIT(pin))) {
        return;
    }

    active = bl808_hbn_gpio_sample_level_active(s, pin, mode) ||
             bl808_hbn_gpio_level_active(mode, s->hbn_aon_level[pin]);
    if (active) {
        bl808_hbn_gpio_delay_arm_pin(s, pin);
    } else {
        bl808_hbn_gpio_delay_cancel_pin(s, pin);
    }
}

static void bl808_hbn_refresh_gpio_live_sources(BL808MachineState *s)
{
    unsigned mode = bl808_hbn_gpio_mode(s);
    uint16_t mask = bl808_hbn_gpio_mask(s);

    if (mode != 0xA && mode != 0xB) {
        bl808_hbn_update_irqs(s);
        return;
    }

    for (unsigned pin = 0; pin < BL808_HBN_AON_PINS; pin++) {
        bool active;

        if (!(mask & BIT(pin))) {
            bl808_hbn_gpio_delay_cancel_pin(s, pin);
            continue;
        }

        active = bl808_hbn_gpio_level_active(mode, s->hbn_aon_level[pin]);
        if (bl808_hbn_gpio_delay_enabled(s)) {
            if (active) {
                bl808_hbn_gpio_delay_arm_pin(s, pin);
            } else {
                bl808_hbn_gpio_delay_cancel_pin(s, pin);
            }
            continue;
        }

        if (active) {
            s->hbn_regs[BL808_HBN_IRQ_STAT_OFFSET / 4] |= BIT(pin);
        }
    }

    bl808_hbn_update_irqs(s);
    bl808_hbn_gpio_delay_reschedule(s);
}

static void bl808_hbn_gpio_level_set(void *opaque, int n, int level)
{
    BL808MachineState *s = opaque;
    unsigned mode = bl808_hbn_gpio_mode(s);
    uint16_t mask = bl808_hbn_gpio_mask(s);
    bool old_level;
    bool new_level;

    if (n < 0 || n >= BL808_HBN_AON_PINS) {
        return;
    }

    old_level = s->hbn_aon_level[n];
    new_level = level != 0;
    s->hbn_aon_level[n] = new_level;

    if (!(mask & BIT(n))) {
        bl808_hbn_gpio_delay_cancel_pin(s, n);
        bl808_hbn_gpio_delay_reschedule(s);
        return;
    }

    if (bl808_hbn_gpio_delay_enabled(s)) {
        if (bl808_hbn_gpio_irq_immediate(mode, old_level, new_level)) {
            bl808_hbn_gpio_delay_arm_pin(s, n);
        } else if (mode == 0xA || mode == 0xB) {
            if (bl808_hbn_gpio_level_active(mode, new_level)) {
                bl808_hbn_gpio_delay_arm_pin(s, n);
            } else {
                bl808_hbn_gpio_delay_cancel_pin(s, n);
            }
        }
        bl808_hbn_gpio_delay_reschedule(s);
        return;
    }

    if (bl808_hbn_gpio_irq_immediate(mode, old_level, new_level)) {
        s->hbn_regs[BL808_HBN_IRQ_STAT_OFFSET / 4] |= BIT(n);
        bl808_hbn_update_irqs(s);
    } else if (mode == 0xA || mode == 0xB) {
        bl808_hbn_refresh_gpio_live_sources(s);
    }
}

static void bl808_hbn_gpio_sample_cb(void *opaque)
{
    BL808MachineState *s = opaque;
    unsigned mode = bl808_hbn_gpio_mode(s);
    uint16_t mask = bl808_hbn_gpio_mask(s);

    for (unsigned pin = 0; pin < BL808_HBN_AON_PINS; pin++) {
        s->hbn_aon_history[pin] =
            ((s->hbn_aon_history[pin] << 1) |
             (s->hbn_aon_level[pin] ? 1 : 0)) & 0x7;

        if (!(mask & BIT(pin))) {
            bl808_hbn_gpio_delay_cancel_pin(s, pin);
            continue;
        }

        if (bl808_hbn_gpio_delay_enabled(s)) {
            if (bl808_hbn_gpio_mode_is_edge(mode) &&
                bl808_hbn_gpio_irq_sampled(mode, s->hbn_aon_history[pin])) {
                bl808_hbn_gpio_delay_arm_pin(s, pin);
            } else if (mode == 0x2 || mode == 0x3) {
                bl808_hbn_gpio_sync_delayed_level(s, pin);
            }
            continue;
        }

        if (bl808_hbn_gpio_irq_sampled(mode, s->hbn_aon_history[pin])) {
            s->hbn_regs[BL808_HBN_IRQ_STAT_OFFSET / 4] |= BIT(pin);
        }
    }

    bl808_hbn_update_irqs(s);
    bl808_hbn_gpio_delay_reschedule(s);
    bl808_hbn_gpio_sample_reschedule(s);
}

static bool bl808_hbn_pir_active(BL808MachineState *s)
{
    uint32_t cfg = s->hbn_regs[BL808_HBN_PIR_CFG_OFFSET / 4];
    uint32_t dis = (cfg & BL808_HBN_PIR_DIS_MASK) >> BL808_HBN_PIR_DIS_SHIFT;

    if (!(cfg & BL808_HBN_PIR_EN)) {
        return false;
    }

    if (s->hbn_pir_level) {
        return (dis & BIT(0)) == 0;
    }

    return (dis & BIT(1)) == 0;
}

static void bl808_hbn_refresh_live_sources(BL808MachineState *s)
{
    uint32_t *stat = &s->hbn_regs[BL808_HBN_IRQ_STAT_OFFSET / 4];
    uint32_t irq_mode = s->hbn_regs[BL808_HBN_IRQ_MODE_OFFSET / 4];

    if (bl808_hbn_pir_active(s)) {
        *stat |= BL808_HBN_IRQ_PIR_STAT;
    } else {
        *stat &= ~BL808_HBN_IRQ_PIR_STAT;
    }

    if (s->hbn_bod_level && (irq_mode & BL808_HBN_IRQ_BOD_EN)) {
        *stat |= BL808_HBN_IRQ_BOD_STAT;
    } else {
        *stat &= ~BL808_HBN_IRQ_BOD_STAT;
    }

    bl808_hbn_update_irqs(s);
}

static bool bl808_hbn_acomp_edge_enabled(BL808MachineState *s,
                                         unsigned int shift, bool rising)
{
    uint32_t irq_mode = s->hbn_regs[BL808_HBN_IRQ_MODE_OFFSET / 4];
    uint32_t mask = extract32(irq_mode, shift, 2);

    return mask & BIT(rising ? 0 : 1);
}

static void bl808_hbn_note_acomp_transition(BL808MachineState *s,
                                            uint32_t stat_bit,
                                            unsigned int shift,
                                            bool old_level,
                                            bool new_level)
{
    bool rising = !old_level && new_level;
    bool falling = old_level && !new_level;

    if ((rising && bl808_hbn_acomp_edge_enabled(s, shift, true)) ||
        (falling && bl808_hbn_acomp_edge_enabled(s, shift, false))) {
        s->hbn_regs[BL808_HBN_IRQ_STAT_OFFSET / 4] |= stat_bit;
        bl808_hbn_update_irqs(s);
    }
}

static void bl808_pds_complete_sleep(BL808MachineState *s)
{
    CPUState *cpu = s->pds_sleep_cpu;

    timer_del(s->pds_wake_timer);
    s->pds_sleep_pending = false;
    s->pds_sleep_cpu = NULL;
    s->pds_regs[BL808_PDS_CTL_OFFSET / 4] &= ~BL808_PDS_CTL_START_PS;
    s->pds_regs[BL808_PDS_STAT_OFFSET / 4] &= ~BL808_PDS_STAT_BUSY;
    bl808_pds_update_irq(s);

    if (cpu) {
        bl808_set_cpu_running(cpu, cpu->cc->get_pc(cpu));
    }
}

static void bl808_pds_wake_cb(void *opaque)
{
    BL808MachineState *s = opaque;

    bl808_pds_trigger_wakeup(s, BL808_PDS_WAKEUP_SRC_TIMER);
}

static void bl808_pds_schedule_sleep(BL808MachineState *s, CPUState *cpu)
{
    uint32_t ctl = s->pds_regs[BL808_PDS_CTL_OFFSET / 4];
    uint32_t hbn_stat = s->hbn_regs[BL808_HBN_IRQ_STAT_OFFSET / 4];
    uint64_t now_ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);
    uint64_t ticks = s->pds_regs[BL808_PDS_TIME1_OFFSET / 4];
    uint64_t delay_ns;

    timer_del(s->pds_wake_timer);
    s->pds_sleep_cpu = cpu;
    s->pds_sleep_pending = true;
    s->pds_regs[BL808_PDS_INT_OFFSET / 4] &=
        ~(BL808_PDS_INT_STATUS_MASK | BL808_PDS_WAKEUP_EVENT_MASK);
    s->pds_regs[BL808_PDS_STAT_OFFSET / 4] |= BL808_PDS_STAT_BUSY;
    bl808_pds_update_irq(s);

    if (hbn_stat & (BL808_HBN_OUT0_STATUS_MASK | BL808_HBN_OUT1_STATUS_MASK)) {
        bl808_pds_trigger_wakeup(s, BL808_PDS_WAKEUP_SRC_HBN_IRQ);
        if (!s->pds_sleep_pending) {
            return;
        }
    }
    if (s->glb_gpio_irq_pending) {
        bl808_pds_trigger_wakeup(s, BL808_PDS_WAKEUP_SRC_GLB_GPIO);
        if (!s->pds_sleep_pending) {
            return;
        }
    }
    if (s->pds_regs[BL808_PDS_GPIO_STAT_OFFSET / 4]) {
        bl808_pds_trigger_wakeup(s, BL808_PDS_WAKEUP_SRC_PDS_GPIO);
        if (!s->pds_sleep_pending) {
            return;
        }
    }

    if ((ctl & BL808_PDS_CTL_SLEEP_FOREVER) ||
        !bl808_pds_wakeup_source_enabled(s, BL808_PDS_WAKEUP_SRC_TIMER)) {
        return;
    }

    if (!ticks) {
        return;
    }

    delay_ns = (uint64_t)(((__uint128_t)ticks * 1000000000ULL +
                           BL808_HBN_F32K_HZ - 1) /
                          BL808_HBN_F32K_HZ);
    delay_ns = MAX(delay_ns, 1ULL);
    timer_mod(s->pds_wake_timer, now_ns + delay_ns);
}

static uint64_t bl808_pds_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808MachineState *s = opaque;
    uint32_t idx = offset / 4;

    (void)size;

    if (idx >= ARRAY_SIZE(s->pds_regs)) {
        return 0;
    }

    return s->pds_regs[idx];
}

static void bl808_pds_write(void *opaque, hwaddr offset, uint64_t value,
                            unsigned size)
{
    BL808MachineState *s = opaque;
    uint32_t idx = offset / 4;
    uint32_t old_value;
    uint32_t next_value;

    (void)size;

    if (idx >= ARRAY_SIZE(s->pds_regs)) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808.pds: write beyond register window @ 0x%"
                      HWADDR_PRIx " = 0x%" PRIx64 "\n", offset, value);
        return;
    }

    old_value = s->pds_regs[idx];
    next_value = (uint32_t)value;
    switch (offset) {
    case BL808_PDS_INT_OFFSET:
        s->pds_regs[idx] =
            (old_value & (BL808_PDS_INT_STATUS_MASK |
                          BL808_PDS_WAKEUP_EVENT_MASK)) |
            (next_value & (BL808_PDS_INT_MASK_BITS |
                           BL808_PDS_WAKEUP_SRC_EN_MASK));
        if (next_value & BL808_PDS_INT_CLEAR) {
            bl808_pds_clear_int(s);
        } else {
            bl808_pds_update_irq(s);
        }
        break;
    case BL808_PDS_GPIO_I_SET_OFFSET:
        s->pds_regs[idx] = next_value & (BL808_PDS_GPIO_IE_GROUP_MASK |
                                         BL808_PDS_GPIO_PD_GROUP_MASK |
                                         BL808_PDS_GPIO_PU_GROUP_MASK);
        bl808_pds_gpio_refresh_live_sources(s);
        bl808_pds_gpio_sample_reschedule(s);
        break;
    case BL808_PDS_GPIO_PD_SET_OFFSET:
        s->pds_regs[idx] = next_value;
        bl808_pds_gpio_refresh_live_sources(s);
        bl808_pds_gpio_sample_reschedule(s);
        break;
    case BL808_PDS_GPIO_INT_OFFSET:
        s->pds_regs[idx] = next_value & BL808_PDS_GPIO_INT_MASK_BITS;
        if (!(old_value & BL808_PDS_GPIO_SET1_CLR) &&
            (next_value & BL808_PDS_GPIO_SET1_CLR)) {
            bl808_pds_gpio_clear_set(s, 0);
        }
        if (!(old_value & BL808_PDS_GPIO_SET2_CLR) &&
            (next_value & BL808_PDS_GPIO_SET2_CLR)) {
            bl808_pds_gpio_clear_set(s, 1);
        }
        if (!(old_value & BL808_PDS_GPIO_SET3_CLR) &&
            (next_value & BL808_PDS_GPIO_SET3_CLR)) {
            bl808_pds_gpio_clear_set(s, 2);
        }
        if (!(old_value & BL808_PDS_GPIO_SET4_CLR) &&
            (next_value & BL808_PDS_GPIO_SET4_CLR)) {
            bl808_pds_gpio_clear_set(s, 3);
        }
        if (((old_value ^ next_value) &
             ((BL808_PDS_GPIO_SET_MODE_MASK << BL808_PDS_GPIO_SET1_MODE_SHIFT) |
              (BL808_PDS_GPIO_SET_MODE_MASK << BL808_PDS_GPIO_SET2_MODE_SHIFT) |
              (BL808_PDS_GPIO_SET_MODE_MASK << BL808_PDS_GPIO_SET3_MODE_SHIFT) |
              (BL808_PDS_GPIO_SET_MODE_MASK << BL808_PDS_GPIO_SET4_MODE_SHIFT))) != 0) {
            for (unsigned gpio = 0; gpio < 32; gpio++) {
                bl808_pds_gpio_reset_history(s, gpio);
            }
        }
        bl808_pds_gpio_refresh_live_sources(s);
        bl808_pds_gpio_sample_reschedule(s);
        break;
    case BL808_PDS_GPIO_STAT_OFFSET:
        break;
    default:
        s->pds_regs[idx] = next_value;
        break;
    }

    if (offset == BL808_PDS_CTL_OFFSET &&
        (next_value & BL808_PDS_CTL_START_PS)) {
        CPUState *cpu = bl808_pds_owner_cpu();

        /*
         * qtest and monitor MMIO pokes do not execute in a guest CPU context,
         * but we still want to validate the PDS state machine at register
         * level. Preserve the real owner-core restriction for guest accesses
         * while allowing context-free test writes to exercise the block.
         */
        if (cpu || !current_cpu) {
            bl808_pds_schedule_sleep(s, cpu);
        }
    } else if (offset == BL808_PDS_CTL2_OFFSET) {
        bool old_mm_powered = bl808_pds_mm_powered_on(old_value);
        bool new_mm_powered = bl808_pds_mm_powered_on(next_value);

        if (old_mm_powered != new_mm_powered) {
            bl808_update_mm_domain_state(s, new_mm_powered, true);
        }
    } else if (offset == BL808_PDS_CPU_CORE_CFG0_OFFSET) {
#ifdef TARGET_RISCV64
        bool old_clock_enabled = (old_value & BL808_PDS_REG_PICO_CLK_EN) != 0;
        bool new_clock_enabled = (next_value & BL808_PDS_REG_PICO_CLK_EN) != 0;

        if (old_clock_enabled != new_clock_enabled) {
            bl808_update_lp_state(s, false);
        }
#endif
    } else if (offset == BL808_PDS_CPU_CORE_CFG1_OFFSET) {
        bl808_soc_refresh_timer0_clocks(s);
    } else if (offset == BL808_PDS_CPU_CORE_CFG13_OFFSET) {
#ifdef TARGET_RISCV64
        if (bl808_lp_reset_asserted(s) || !bl808_lp_clock_enabled(s)) {
            bl808_hold_lp(s, bl808_lp_reset_pc(s));
        }
#endif
    }
}

static const MemoryRegionOps bl808_pds_ops = {
    .read = bl808_pds_read,
    .write = bl808_pds_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static void bl808_pds_reset(BL808MachineState *s)
{
    timer_del(s->pds_wake_timer);
    timer_del(s->pds_gpio_sample_timer);
    memset(s->pds_regs, 0, sizeof(s->pds_regs));
    s->pds_regs[BL808_PDS_INT_OFFSET / 4] = BL808_PDS_WAKEUP_SRC_EN_MASK;
    s->pds_regs[BL808_PDS_CTL2_OFFSET / 4] = BL808_PDS_MM_FORCE_MASK;
    s->mm_powered_on = false;
    s->pds_sleep_pending = false;
    s->glb_gpio_irq_pending = false;
    s->pds_sleep_cpu = NULL;
    for (unsigned gpio = 0; gpio < 32; gpio++) {
        bl808_pds_gpio_reset_history(s, gpio);
    }
    bl808_pds_update_irq(s);
    bl808_pds_gpio_sample_reschedule(s);
}

static uint64_t bl808_hbn_rtc_ticks(BL808MachineState *s)
{
    uint64_t now_ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);

    return (uint64_t)(((__uint128_t)now_ns * BL808_HBN_F32K_HZ) /
                      1000000000ULL);
}

static uint64_t bl808_hbn_rtc_value(BL808MachineState *s)
{
    return s->hbn_rtc_latched ? s->hbn_rtc_latch : bl808_hbn_rtc_ticks(s);
}

static uint64_t bl808_hbn_alarm_ticks(BL808MachineState *s)
{
    uint64_t lo = s->hbn_regs[BL808_HBN_TIML_OFFSET / 4];
    uint64_t hi = s->hbn_regs[BL808_HBN_TIMH_OFFSET / 4] & 0xFF;

    return (hi << 32) | lo;
}

static void bl808_hbn_request_reset(BL808MachineState *s)
{
    timer_del(s->hbn_alarm_timer);
    timer_del(s->hbn_alarm_rt_timer);
    s->hbn_regs[BL808_HBN_IRQ_STAT_OFFSET / 4] |= BL808_HBN_IRQ_RTC_STAT;
    s->hbn_wake_pending = true;
    bl808_hbn_update_irqs(s);
    qemu_system_reset(SHUTDOWN_CAUSE_GUEST_RESET);
}

static void bl808_hbn_alarm_cb(void *opaque)
{
    BL808MachineState *s = opaque;

    bl808_hbn_request_reset(s);
}

static void bl808_hbn_schedule_alarm(BL808MachineState *s)
{
    uint32_t ctl = s->hbn_regs[BL808_HBN_CTL_OFFSET / 4];
    uint64_t now_ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);
    uint64_t now_rt_ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL_RT);
    uint64_t alarm_ticks = bl808_hbn_alarm_ticks(s);
    uint64_t now_ticks = bl808_hbn_rtc_ticks(s);
    uint64_t delta_ns;
    uint64_t deadline_ns;

    timer_del(s->hbn_alarm_timer);
    timer_del(s->hbn_alarm_rt_timer);
    if (!(ctl & BL808_HBN_CTL_MODE)) {
        return;
    }

    if (!alarm_ticks || alarm_ticks <= now_ticks) {
        delta_ns = 1;
    } else {
        delta_ns = (uint64_t)(((__uint128_t)(alarm_ticks - now_ticks) *
                               1000000000ULL + BL808_HBN_F32K_HZ - 1) /
                              BL808_HBN_F32K_HZ);
    }

    deadline_ns = now_ns + delta_ns;
    timer_mod(s->hbn_alarm_timer, deadline_ns);
    timer_mod(s->hbn_alarm_rt_timer, now_rt_ns + delta_ns);
}

static uint32_t bl808_hbn_adc_sample(unsigned channel)
{
    switch (channel) {
    case 14:
        return 0x0580u;
    case 15:
        return 0x0900u;
    default:
        return 0x0400u + ((channel & 0xfu) << 6);
    }
}

static unsigned bl808_hbn_adc_scan_channel(BL808MachineState *s, unsigned idx)
{
    uint32_t reg = idx < 6 ? s->hbn_regs[BL808_HBN_GPADC_SCAN_POS1 / 4] :
                             s->hbn_regs[BL808_HBN_GPADC_SCAN_POS2 / 4];
    unsigned shift = (idx % 6) * 5;

    return extract32(reg, shift, 5);
}

static void bl808_hbn_adc_trigger(BL808MachineState *s)
{
    uint32_t cmd = s->hbn_regs[BL808_HBN_GPADC_CMD_OFFSET / 4];
    uint32_t cfg1 = s->hbn_regs[BL808_HBN_GPADC_CFG1_OFFSET / 4];
    bool scan = (cfg1 & BL808_HBN_GPADC_SCAN_EN) != 0;
    uint32_t sample;

    s->hbn_regs[BL808_HBN_GPADC_STATUS / 4] = 0;

    if (scan) {
        unsigned count = extract32(cfg1, BL808_HBN_GPADC_SCAN_LEN_SHIFT, 4) + 1;

        bl808_gpip_adc_fifo_clear(&s->soc.gpip);
        for (unsigned i = 0; i < count && i < 12; i++) {
            uint32_t scan_sample =
                bl808_hbn_adc_sample(bl808_hbn_adc_scan_channel(s, i));

            bl808_gpip_push_adc_sample(&s->soc.gpip, scan_sample);
            if (i == 0) {
                s->hbn_regs[BL808_HBN_GPADC_RESULT / 4] = scan_sample;
                s->hbn_regs[BL808_HBN_GPADC_RAW_RESULT / 4] =
                    scan_sample & 0x0fffu;
            }
        }
    } else {
        sample = bl808_hbn_adc_sample(
            extract32(cmd, BL808_HBN_GPADC_POS_SEL_SHIFT, 5));
        s->hbn_regs[BL808_HBN_GPADC_RESULT / 4] = sample;
        s->hbn_regs[BL808_HBN_GPADC_RAW_RESULT / 4] = sample & 0x0fffu;
    }

    s->hbn_regs[BL808_HBN_GPADC_STATUS / 4] = 1;
}

static uint64_t bl808_hbn_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808MachineState *s = opaque;
    uint32_t idx = offset / 4;
    uint64_t rtc_ticks;

    (void)size;

    if (idx >= ARRAY_SIZE(s->hbn_regs)) {
        return 0;
    }

    switch (offset) {
    case BL808_HBN_RTC_TIML_OFFSET:
        rtc_ticks = bl808_hbn_rtc_value(s);
        return (uint32_t)rtc_ticks;
    case BL808_HBN_RTC_TIMH_OFFSET:
        rtc_ticks = bl808_hbn_rtc_value(s);
        return ((uint32_t)((rtc_ticks >> 32) & 0xFF) |
                (s->hbn_rtc_latched ? BL808_HBN_RTC_LATCH : 0));
    case BL808_HBN_IRQ_CLR_OFFSET:
        return 0;
    default:
        return s->hbn_regs[idx];
    }
}

static void bl808_hbn_write(void *opaque, hwaddr offset, uint64_t value,
                            unsigned size)
{
    BL808MachineState *s = opaque;
    uint32_t idx = offset / 4;

    (void)size;

    if (idx >= ARRAY_SIZE(s->hbn_regs)) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808.hbn: write beyond register window @ 0x%"
                      HWADDR_PRIx " = 0x%" PRIx64 "\n", offset, value);
        return;
    }

    switch (offset) {
    case BL808_HBN_CTL_OFFSET:
        s->hbn_regs[idx] = (uint32_t)value;
        bl808_hbn_schedule_alarm(s);
        break;
    case BL808_HBN_TIML_OFFSET:
        s->hbn_regs[idx] = (uint32_t)value;
        bl808_hbn_schedule_alarm(s);
        break;
    case BL808_HBN_TIMH_OFFSET:
        s->hbn_regs[idx] = (uint32_t)value & 0xFF;
        bl808_hbn_schedule_alarm(s);
        break;
    case BL808_HBN_RTC_TIMH_OFFSET:
        s->hbn_regs[idx] = 0;
        if (value & BL808_HBN_RTC_LATCH) {
            s->hbn_rtc_latch = bl808_hbn_rtc_ticks(s);
            s->hbn_rtc_latched = true;
        } else {
            s->hbn_rtc_latched = false;
        }
        break;
    case BL808_HBN_IRQ_MODE_OFFSET:
        bl808_hbn_gpio_delay_cancel_all(s);
        s->hbn_regs[idx] = (uint32_t)value;
        bl808_hbn_apply_aon_pad_ctrl(s);
        for (unsigned pin = 0; pin < BL808_HBN_AON_PINS; pin++) {
            bl808_hbn_reset_aon_history(s, pin);
        }
        bl808_hbn_refresh_live_sources(s);
        bl808_hbn_refresh_gpio_live_sources(s);
        bl808_hbn_gpio_sample_reschedule(s);
        break;
    case BL808_HBN_PAD_CTRL_0_OFFSET:
    case BL808_HBN_PAD_CTRL_1_OFFSET:
        s->hbn_regs[idx] = (uint32_t)value;
        bl808_hbn_apply_aon_pad_ctrl(s);
        break;
    case BL808_HBN_IRQ_CLR_OFFSET:
        s->hbn_regs[BL808_HBN_IRQ_STAT_OFFSET / 4] &= ~(uint32_t)value;
        for (unsigned pin = 0; pin < BL808_HBN_AON_PINS; pin++) {
            if (value & BIT(pin)) {
                bl808_hbn_gpio_delay_cancel_pin(s, pin);
            }
        }
        bl808_hbn_refresh_live_sources(s);
        bl808_hbn_refresh_gpio_live_sources(s);
        bl808_hbn_gpio_sample_reschedule(s);
        break;
    case BL808_HBN_PIR_CFG_OFFSET:
        s->hbn_regs[idx] = (uint32_t)value;
        bl808_hbn_refresh_live_sources(s);
        break;
    case BL808_HBN_GLB_OFFSET:
        s->hbn_regs[idx] = (uint32_t)value;
        bl808_soc_refresh_timer0_clocks(s);
        break;
    case BL808_HBN_GPADC_CMD_OFFSET:
        s->hbn_regs[idx] = (uint32_t)value;
        if (((uint32_t)value & (BL808_HBN_GPADC_GLOBAL_EN |
                                BL808_HBN_GPADC_CONV_START)) ==
            (BL808_HBN_GPADC_GLOBAL_EN | BL808_HBN_GPADC_CONV_START)) {
            bl808_hbn_adc_trigger(s);
        } else {
            s->hbn_regs[BL808_HBN_GPADC_STATUS / 4] = 0;
        }
        break;
    case BL808_HBN_RSV3_OFFSET:
        s->hbn_regs[idx] = (uint32_t)value;
        bl808_soc_refresh_timer0_clocks(s);
        bl808_soc_refresh_timer1_clocks(s);
        break;
    default:
        s->hbn_regs[idx] = (uint32_t)value;
        break;
    }
}

static const MemoryRegionOps bl808_hbn_ops = {
    .read = bl808_hbn_read,
    .write = bl808_hbn_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static void bl808_hbn_seed(BL808MachineState *s)
{
    memset(s->hbn_regs, 0, sizeof(s->hbn_regs));
    s->hbn_rtc_latch = 0;
    s->hbn_rtc_latched = false;
    s->hbn_wake_pending = false;
    bl808_hbn_gpio_delay_cancel_all(s);
    bl808_hbn_apply_aon_pad_ctrl(s);
    for (unsigned pin = 0; pin < BL808_HBN_AON_PINS; pin++) {
        bl808_hbn_reset_aon_history(s, pin);
    }
    bl808_hbn_refresh_live_sources(s);
    bl808_hbn_refresh_gpio_live_sources(s);
}

static void bl808_hbn_reset(BL808MachineState *s)
{
    uint32_t retention[BL808_HBN_RSV_COUNT];
    uint32_t pad_ctrl0 = s->hbn_regs[BL808_HBN_PAD_CTRL_0_OFFSET / 4];
    uint32_t pad_ctrl1 = s->hbn_regs[BL808_HBN_PAD_CTRL_1_OFFSET / 4];
    bool retain_pad_ctrl = s->hbn_wake_pending ||
                           (pad_ctrl0 & BL808_HBN_PAD_ISO_MODE);

    for (size_t i = 0; i < BL808_HBN_RSV_COUNT; i++) {
        retention[i] = s->hbn_regs[(BL808_HBN_RSV0_OFFSET / 4) + i];
    }

    memset(s->hbn_regs, 0, sizeof(s->hbn_regs));
    for (size_t i = 0; i < BL808_HBN_RSV_COUNT; i++) {
        s->hbn_regs[(BL808_HBN_RSV0_OFFSET / 4) + i] = retention[i];
    }
    if (retain_pad_ctrl) {
        s->hbn_regs[BL808_HBN_PAD_CTRL_0_OFFSET / 4] = pad_ctrl0;
        s->hbn_regs[BL808_HBN_PAD_CTRL_1_OFFSET / 4] = pad_ctrl1;
    }

    timer_del(s->hbn_alarm_timer);
    timer_del(s->hbn_alarm_rt_timer);
    timer_del(s->hbn_gpio_sample_timer);
    timer_del(s->hbn_gpio_delay_timer);
    s->hbn_rtc_latched = false;
    s->hbn_rtc_latch = 0;
    if (s->hbn_wake_pending) {
        s->hbn_regs[BL808_HBN_IRQ_STAT_OFFSET / 4] = BL808_HBN_IRQ_RTC_STAT;
    }
    s->hbn_wake_pending = false;
    bl808_hbn_gpio_delay_cancel_all(s);
    bl808_hbn_apply_aon_pad_ctrl(s);
    for (unsigned pin = 0; pin < BL808_HBN_AON_PINS; pin++) {
        bl808_hbn_reset_aon_history(s, pin);
    }
    bl808_hbn_refresh_live_sources(s);
    bl808_hbn_refresh_gpio_live_sources(s);
    bl808_hbn_gpio_sample_reschedule(s);
}

static void bl808_ef_ctrl_seed(BL808MachineState *s)
{
    memset(s->efuse_data, 0, sizeof(s->efuse_data));
    /* BL808DK-style device info: UHS PSRAM present so vendor board_init runs. */
    s->efuse_data[0x06] = 0x06000000U;
    s->efuse_data[0x28] = 0x08080001U;
    s->efuse_data[0x29] = 0x00000001U;
    s->efuse_data[0x2C] = 0x00088002U;
    s->efuse_data[0x2D] = 0x00000100U;
    memcpy(s->efuse_shadow, s->efuse_data, sizeof(s->efuse_shadow));
}

static void bl808_ef_ctrl_reset(BL808MachineState *s)
{
    memset(s->ef_ctrl_regs, 0, sizeof(s->ef_ctrl_regs));
    memcpy(s->efuse_shadow, s->efuse_data, sizeof(s->efuse_shadow));
    s->ef_ctrl_regs[BL808_EF_CTRL0_OFFSET / 4] = BL808_EF_AUTO_LOAD_DONE;
}

static uint64_t bl808_ef_ctrl_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808MachineState *s = opaque;
    uint32_t idx = offset / 4;

    (void)size;

    if (offset < BL808_EF_DATA_WORDS * sizeof(uint32_t)) {
        return s->efuse_shadow[idx];
    }
    if (idx >= ARRAY_SIZE(s->ef_ctrl_regs)) {
        return 0;
    }

    if (offset == BL808_EF_CTRL0_OFFSET) {
        return s->ef_ctrl_regs[idx] | BL808_EF_AUTO_LOAD_DONE;
    }

    return s->ef_ctrl_regs[idx];
}

static void bl808_ef_ctrl_write(void *opaque, hwaddr offset, uint64_t value,
                                unsigned size)
{
    BL808MachineState *s = opaque;
    uint32_t idx = offset / 4;

    (void)size;

    if (offset < BL808_EF_DATA_WORDS * sizeof(uint32_t)) {
        s->efuse_shadow[idx] = (uint32_t)value;
        return;
    }
    if (idx >= ARRAY_SIZE(s->ef_ctrl_regs)) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808.ef_ctrl: write beyond register window @ 0x%"
                      HWADDR_PRIx " = 0x%" PRIx64 "\n", offset, value);
        return;
    }

    switch (offset) {
    case BL808_EF_CTRL0_OFFSET:
        s->ef_ctrl_regs[idx] = (uint32_t)value & ~BL808_EF_BUSY;
        if (value & BL808_EF_TRIG) {
            if (value & BL808_EF_RW) {
                if (s->ef_ctrl_regs[idx] & BL808_EF_PGM_EN) {
                    for (size_t i = 0; i < ARRAY_SIZE(s->efuse_data); i++) {
                        s->efuse_data[i] |= s->efuse_shadow[i];
                    }
                }
            } else {
                memcpy(s->efuse_shadow, s->efuse_data, sizeof(s->efuse_shadow));
            }
            s->ef_ctrl_regs[idx] |= BL808_EF_AUTO_LOAD_DONE;
            s->ef_ctrl_regs[idx] &= ~BL808_EF_BUSY;
        } else if (!(value & BL808_EF_RW)) {
            s->ef_ctrl_regs[idx] |= BL808_EF_AUTO_LOAD_DONE;
        }
        break;
    case BL808_EF_RD_CMD_OFFSET:
        memcpy(s->efuse_shadow, s->efuse_data, sizeof(s->efuse_shadow));
        s->ef_ctrl_regs[idx] = 0;
        break;
    case BL808_EF_PGM_CMD_OFFSET:
        if ((value & 1) &&
            (s->ef_ctrl_regs[BL808_EF_CTRL0_OFFSET / 4] & BL808_EF_PGM_EN)) {
            for (size_t i = 0; i < ARRAY_SIZE(s->efuse_data); i++) {
                s->efuse_data[i] |= s->efuse_shadow[i];
            }
            memcpy(s->efuse_shadow, s->efuse_data, sizeof(s->efuse_shadow));
        }
        s->ef_ctrl_regs[idx] = 0;
        break;
    default:
        s->ef_ctrl_regs[idx] = (uint32_t)value;
        break;
    }
}

static const MemoryRegionOps bl808_ef_ctrl_ops = {
    .read = bl808_ef_ctrl_read,
    .write = bl808_ef_ctrl_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

/* ========================================================================= */
/* SoC initialization                                                         */
/* ========================================================================= */

/*
 * Helper: create a CPU with per-CPU address space.
 *
 * Creates a MemoryRegion container, adds system memory as a low-priority
 * alias, sets the CPU's "memory" link to the container, then realizes.
 * Returns the RISCVCPU pointer. Per-CPU private devices (CLIC, CLINT, PLIC)
 * are added to the container AFTER this call, at higher priority.
 */
static RISCVCPU *bl808_create_cpu(const char *cpu_type, int hartid,
                                  uint64_t resetvec,
                                  MemoryRegion *container,
                                  MemoryRegion *sys_alias,
                                  const char *name)
{
    char alias_name[64];
    Object *cpuobj;

    /* Per-CPU memory container */
    memory_region_init(container, NULL, name, UINT64_MAX);

    /* Add system memory as low-priority background */
    snprintf(alias_name, sizeof(alias_name), "%s-sysmem", name);
    memory_region_init_alias(sys_alias, NULL, alias_name,
                             get_system_memory(), 0, UINT64_MAX);
    memory_region_add_subregion_overlap(container, 0, sys_alias, -1);

    /* Create CPU, set address space, realize */
    cpuobj = object_new(cpu_type);
    qdev_prop_set_uint64(DEVICE(cpuobj), "resetvec", resetvec);
    object_property_set_link(cpuobj, "memory", OBJECT(container),
                             &error_abort);
    qdev_realize(DEVICE(cpuobj), NULL, &error_fatal);

    /* Set hart ID after realization (not a QOM property) */
    RISCV_CPU(cpuobj)->env.mhartid = hartid;

    return RISCV_CPU(cpuobj);
}

static void bl808_soc_init(Object *obj)
{
    BL808SoCState *s = BL808_SOC(obj);

    /* CPUs are created individually in realize (not via hart arrays) */

    /* Peripherals */
    object_initialize_child(obj, "uart0", &s->uart[0], TYPE_BL808_UART);
    object_initialize_child(obj, "uart1", &s->uart[1], TYPE_BL808_UART);
    object_initialize_child(obj, "uart2", &s->uart[2], TYPE_BL808_UART);
    object_initialize_child(obj, "uart3", &s->uart[3], TYPE_BL808_UART);
    object_initialize_child(obj, "i2c0", &s->i2c0, TYPE_BL808_I2C);
    object_initialize_child(obj, "i2c1", &s->i2c1, TYPE_BL808_I2C);
    object_initialize_child(obj, "spi0", &s->spi0, TYPE_BL808_SPI);
    object_initialize_child(obj, "spi1", &s->spi1, TYPE_BL808_SPI);
    object_initialize_child(obj, "dma0", &s->dma0, TYPE_BL808_DMA);
    object_initialize_child(obj, "dma1", &s->dma1, TYPE_BL808_DMA);
    object_initialize_child(obj, "gpip", &s->gpip, TYPE_BL808_GPIP);
    object_initialize_child(obj, "sec-eng", &s->sec_eng, TYPE_BL808_SEC_ENG);
    object_initialize_child(obj, "cci", &s->cci, TYPE_BL808_CCI);
    object_initialize_child(obj, "tzc-sec", &s->tzc_sec, TYPE_BL808_TZC);
    object_initialize_child(obj, "tzc-nsec", &s->tzc_nsec, TYPE_BL808_TZC);
    object_initialize_child(obj, "mcu_misc", &s->mcu_misc, TYPE_BL808_MCU_MISC);
    object_initialize_child(obj, "cks", &s->cks, TYPE_BL808_CKS);
    object_initialize_child(obj, "ipc0", &s->ipc0, TYPE_BL808_IPC);
    object_initialize_child(obj, "ipc1", &s->ipc1, TYPE_BL808_IPC);
    object_initialize_child(obj, "ipc2", &s->ipc2, TYPE_BL808_IPC);
    object_initialize_child(obj, "i2s", &s->i2s, TYPE_BL808_I2S);
    object_initialize_child(obj, "audio", &s->audio, TYPE_BL808_AUDIO);
    object_initialize_child(obj, "emi", &s->emi, TYPE_BL808_EMI);
    object_initialize_child(obj, "mm_misc", &s->mm_misc, TYPE_BL808_MM_MISC);
    object_initialize_child(obj, "dma2d", &s->dma2d, TYPE_BL808_DMA2D);
    object_initialize_child(obj, "psram_ctrl", &s->psram_ctrl,
                            TYPE_BL808_PSRAM_CTRL);
    object_initialize_child(obj, "usb", &s->usb, TYPE_BL808_USB);
    object_initialize_child(obj, "pwm", &s->pwm, TYPE_BL808_PWM);
    object_initialize_child(obj, "timer0", &s->timer0, TYPE_BL808_TIMER);
    object_initialize_child(obj, "emac", &s->emac, TYPE_BL808_EMAC);
    object_initialize_child(obj, "sdh", &s->sdh, TYPE_SYSBUS_SDHCI);
    object_initialize_child(obj, "sf_ctrl", &s->sf_ctrl, TYPE_BL808_SF_CTRL);
#ifdef TARGET_RISCV64
    object_initialize_child(obj, "i2c2", &s->i2c2, TYPE_BL808_I2C);
    object_initialize_child(obj, "i2c3", &s->i2c3, TYPE_BL808_I2C);
    object_initialize_child(obj, "dma2", &s->dma2, TYPE_BL808_DMA);
    object_initialize_child(obj, "timer1", &s->timer1, TYPE_BL808_TIMER);
#endif
}

static void bl808_soc_realize(DeviceState *dev, Error **errp)
{
    BL808SoCState *s = BL808_SOC(dev);
    BL808MachineState *machine = container_of(s, BL808MachineState, soc);
    MemoryRegion *sys_mem = get_system_memory();

    /*
     * ---- CPUs with per-CPU address spaces ----
     *
     * Each core gets its own MemoryRegion container so that the private
     * bus at 0xE0000000 maps to different devices per core (CLIC vs PLIC).
     */

    /* M0: T-Head E907 (RV32IMAFC), hart 0 */
    s->m0_cpu = bl808_create_cpu(TYPE_RISCV_CPU_THEAD_E907, 0,
                                 BL808_BOOTROM_BASE,
                                 &s->m0_mem, &s->m0_sys_alias, "m0-mem");

#ifdef TARGET_RISCV64
    /* D0: T-Head C906 (RV64IMAFDC), hart 1 */
    s->d0_cpu = bl808_create_cpu(TYPE_RISCV_CPU_THEAD_C906, 1,
                                 BL808_DRAM_BASE,
                                 &s->d0_mem, &s->d0_sys_alias, "d0-mem");

    /* LP: T-Head E902 (RV32EMC), hart 2 */
    s->lp_cpu = bl808_create_cpu(TYPE_RISCV_CPU_THEAD_E902, 2,
                                 BL808_BOOTROM_BASE,
                                 &s->lp_mem, &s->lp_sys_alias, "lp-mem");
#endif

    /* ---- RAM regions ---- */

    /* OCRAM (64 KB) -- non-cached at 0x22020000, cached alias at 0x62020000 */
    memory_region_init_ram(&s->ocram, OBJECT(dev), "bl808.ocram",
                           BL808_OCRAM_SIZE, errp);
    memory_region_add_subregion(sys_mem, BL808_OCRAM_BASE, &s->ocram);

    memory_region_init_alias(&s->ocram_alias, OBJECT(dev),
                             "bl808.ocram.cached",
                             &s->ocram, 0, BL808_OCRAM_SIZE);
    memory_region_add_subregion(sys_mem, BL808_OCRAM_CACHED, &s->ocram_alias);

    /* WRAM (160 KB) */
    memory_region_init_ram(&s->wram, OBJECT(dev), "bl808.wram",
                           BL808_WRAM_SIZE, errp);
    memory_region_add_subregion(sys_mem, BL808_WRAM_BASE, &s->wram);

    memory_region_init_alias(&s->wram_alias, OBJECT(dev),
                             "bl808.wram.cached",
                             &s->wram, 0, BL808_WRAM_SIZE);
    memory_region_add_subregion(sys_mem, BL808_WRAM_CACHED, &s->wram_alias);

    /* DRAM (512 KB) */
    memory_region_init_ram(&s->dram, OBJECT(dev), "bl808.dram",
                           BL808_DRAM_SIZE, errp);
    memory_region_add_subregion(sys_mem, BL808_DRAM_BASE, &s->dram);

    memory_region_init_alias(&s->dram_alias, OBJECT(dev),
                             "bl808.dram.cached",
                             &s->dram, 0, BL808_DRAM_SIZE);
    memory_region_add_subregion(sys_mem, BL808_DRAM_CACHED, &s->dram_alias);

    /* VRAM (32 KB) */
    memory_region_init_ram(&s->vram, OBJECT(dev), "bl808.vram",
                           BL808_VRAM_SIZE, errp);
    memory_region_add_subregion(sys_mem, BL808_VRAM_BASE, &s->vram);

    memory_region_init_alias(&s->vram_alias, OBJECT(dev),
                             "bl808.vram.cached",
                             &s->vram, 0, BL808_VRAM_SIZE);
    memory_region_add_subregion(sys_mem, BL808_VRAM_CACHED, &s->vram_alias);

    /* XRAM (16 KB) -- shared IPC memory
     * Implemented as I/O (not RAM) to bypass TCG TLB caching,
     * ensuring writes from one CPU are immediately visible to the other.
     * Also add per-CPU aliases at priority 0 to ensure XRAM accesses
     * go directly through I/O ops rather than through the system memory
     * alias (which may get TLB-cached in per-CPU softmmu). */
    xram_buf = g_malloc0(BL808_XRAM_SIZE);
    memory_region_init_io(&s->xram, OBJECT(dev), &xram_ops, NULL,
                          "bl808.xram", BL808_XRAM_SIZE);
    memory_region_add_subregion(sys_mem, BL808_XRAM_BASE, &s->xram);

    /*
     * Per-CPU XRAM: add the XRAM I/O region directly into each CPU's
     * address space at priority 0 (above the -1 system memory alias).
     * Using aliases to the same I/O region ensures all CPUs hit the
     * same xram_ops callbacks and shared xram_buf.
     * Also mark each alias as non-romd to prevent TLB caching.
     */
    memory_region_init_alias(&s->m0_xram_alias, OBJECT(dev),
                             "m0-xram", &s->xram, 0, BL808_XRAM_SIZE);
    memory_region_add_subregion_overlap(&s->m0_mem, BL808_XRAM_BASE,
                                        &s->m0_xram_alias, 0);
#ifdef TARGET_RISCV64
    memory_region_init_alias(&s->d0_xram_alias, OBJECT(dev),
                             "d0-xram", &s->xram, 0, BL808_XRAM_SIZE);
    memory_region_add_subregion_overlap(&s->d0_mem, BL808_XRAM_BASE,
                                        &s->d0_xram_alias, 0);
    memory_region_init_alias(&s->lp_xram_alias, OBJECT(dev),
                             "lp-xram", &s->xram, 0, BL808_XRAM_SIZE);
    memory_region_add_subregion_overlap(&s->lp_mem, BL808_XRAM_BASE,
                                        &s->lp_xram_alias, 0);
#endif

    /* PSRAM (64 MB) */
    s->psram_buf = g_malloc0(BL808_PSRAM_SIZE);
    memory_region_init_io(&s->psram, OBJECT(dev), &psram_ops, s,
                          "bl808.psram", BL808_PSRAM_SIZE);
    memory_region_add_subregion(sys_mem, BL808_PSRAM_BASE, &s->psram);

    /* Flash XIP (64 MB) -- board flash contents mirrored by SF_CTRL */
    memory_region_init_rom(&s->flash_xip, OBJECT(dev), "bl808.flash.xip",
                           BL808_FLASH_XIP_SIZE, errp);
    memory_region_add_subregion(sys_mem, BL808_FLASH_XIP_BASE, &s->flash_xip);

    memory_region_init_alias(&s->flash_xip2, OBJECT(dev),
                             "bl808.flash.xip2",
                             &s->flash_xip, 0, BL808_FLASH_XIP_SIZE);
    memory_region_add_subregion(sys_mem, BL808_FLASH_XIP2_BASE,
                                &s->flash_xip2);

    memory_region_init_alias(&s->flash_remap, OBJECT(dev),
                             "bl808.flash.remap",
                             &s->flash_xip, 0, BL808_FLASH_XIP_SIZE);
    memory_region_add_subregion(sys_mem, BL808_FLASH_REMAP_BASE,
                                &s->flash_remap);

    s->sf_ctrl.xip_ptr[0][0] = memory_region_get_ram_ptr(&s->flash_xip);

#ifdef TARGET_RISCV64
    memory_region_init_rom(&s->d0_flash_xip, OBJECT(dev),
                           "bl808.d0.flash.xip",
                           BL808_FLASH_XIP_SIZE, errp);
    memory_region_add_subregion_overlap(&s->d0_mem, BL808_FLASH_XIP_BASE,
                                        &s->d0_flash_xip, 0);

    memory_region_init_alias(&s->d0_flash_xip2, OBJECT(dev),
                             "bl808.d0.flash.xip2",
                             &s->d0_flash_xip, 0, BL808_FLASH_XIP_SIZE);
    memory_region_add_subregion_overlap(&s->d0_mem, BL808_FLASH_XIP2_BASE,
                                        &s->d0_flash_xip2, 0);

    memory_region_init_alias(&s->d0_flash_remap, OBJECT(dev),
                             "bl808.d0.flash.remap",
                             &s->d0_flash_xip, 0, BL808_FLASH_XIP_SIZE);
    memory_region_add_subregion_overlap(&s->d0_mem, BL808_FLASH_REMAP_BASE,
                                        &s->d0_flash_remap, 0);

    s->sf_ctrl.xip_ptr[1][0] = memory_region_get_ram_ptr(&s->d0_flash_xip);
#endif

    /*
     * BL808 exposes a core-ID word at 0xF0000000; vendor startup uses it
     * during common clock/delay paths before higher-level bring-up.
     */
    memory_region_init_io(&s->core_id, OBJECT(dev), &core_id_ops,
                          NULL, "bl808.coreid", 4);
    memory_region_add_subregion(sys_mem, BL808_CORE_ID_ADDR, &s->core_id);
#ifdef TARGET_RISCV64
    /*
     * BL808 D0 firmware commonly materializes high MMIO addresses with RV64
     * sign-extended 32-bit literals, e.g. 0xfffffffff0000000 for CORE_ID.
     * Mirror the register into that canonical RV64 view.
     */
    memory_region_init_alias(&s->d0_core_id_sext_alias, OBJECT(dev),
                             "bl808.d0.coreid.sext32",
                             &s->core_id, 0, memory_region_size(&s->core_id));
    memory_region_add_subregion_overlap(&s->d0_mem,
                                        BL808_RV64_SEXT32(BL808_CORE_ID_ADDR),
                                        &s->d0_core_id_sext_alias, 0);
#endif

    /*
     * ---- M0 interrupt controller (CLIC + CLINT) ----
     *
     * Real hardware: M0 private bus maps CLINT at 0xE0000000 and
     * CLIC interrupt control at 0xE0800000. CLINT timer/SWI outputs
     * feed into CLIC as IRQ 7 (timer) and IRQ 3 (software).
     *
     * We map these into M0's per-CPU address space container.
     */

    /* M0 xt_clic at 0xE0800000 (in M0's private address space) */
    s->m0_clic = xt_clic_create(BL808_CLIC_BASE, true,
                                0,  /* hartid_base (M0 = cpu_index 0) */
                                1, BL808_CLIC_NUM_IRQS,
                                BL808_CLIC_INTCTLBITS);
    /* xt_clic_create maps into system memory; remap into M0's container */
    memory_region_del_subregion(sys_mem,
        sysbus_mmio_get_region(SYS_BUS_DEVICE(s->m0_clic), 0));
    memory_region_add_subregion_overlap(&s->m0_mem, BL808_CLIC_BASE,
        sysbus_mmio_get_region(SYS_BUS_DEVICE(s->m0_clic), 0), 0);

    /* Manually set env->clic for M0 (xt_clic_realize uses cpu_index 0) */
    s->m0_cpu->env.clic = XT_CLIC(s->m0_clic);
    s->m0_cpu->env.mclicbase = BL808_CLIC_BASE;

    /* M0 thead_clint at 0xE0000000 (in M0's private address space) */
    s->m0_clint = thead_clint_create(BL808_CLINT_BASE,
                                     BL808_ACLINT_TIMEBASE_FREQ, 1);
    /* Remap CLINT into M0's container */
    memory_region_del_subregion(sys_mem,
        sysbus_mmio_get_region(SYS_BUS_DEVICE(s->m0_clint), 0));
    memory_region_add_subregion_overlap(&s->m0_mem, BL808_CLINT_BASE,
        sysbus_mmio_get_region(SYS_BUS_DEVICE(s->m0_clint), 0), 0);

    /* Wire CLINT outputs → CLIC inputs: soft→IRQ 3, timer→IRQ 7 */
    qdev_connect_gpio_out(s->m0_clint, 0,
                          qdev_get_gpio_in(s->m0_clic, IRQ_M_SOFT));
    qdev_connect_gpio_out(s->m0_clint, 1,
                          qdev_get_gpio_in(s->m0_clic, IRQ_M_TIMER));

    /* Set rdtime for M0 */
    riscv_cpu_set_rdtime_fn(&s->m0_cpu->env, thead_clint_read_rtc_cb,
                            s->m0_clint);

#ifdef TARGET_RISCV64
    /*
     * ---- D0 interrupt controller (PLIC + ACLINT) ----
     *
     * Real hardware: D0 private bus maps PLIC at 0xE0000000 and
     * CLINT at 0xE4000000.  D0 uses PLIC (not CLIC) for interrupts.
     *
     * We use ACLINT at the real D0 CLINT address (T-Head layout)
     * and map PLIC + ACLINT into D0's per-CPU address space.
     */

    /* D0 PLIC at 0xE0000000 (in D0's private address space) */
    s->d0_plic = sifive_plic_create(BL808_D0_PLIC_BASE,
        (char *)"M",
        1,                  /* num_harts */
        1,                  /* hartid_base */
        BL808_D0_IRQ_COUNT,
        7,                  /* num_priorities */
        0x0,                /* priority_base */
        0x1000,             /* pending_base */
        0x2000,             /* enable_base */
        0x80,               /* enable_stride */
        0x200000,           /* context_base */
        0x1000,             /* context_stride */
        BL808_D0_PLIC_SIZE);
    /* Remap PLIC into D0's container */
    memory_region_del_subregion(sys_mem,
        sysbus_mmio_get_region(SYS_BUS_DEVICE(s->d0_plic), 0));
    memory_region_add_subregion_overlap(&s->d0_mem, BL808_D0_PLIC_BASE,
        sysbus_mmio_get_region(SYS_BUS_DEVICE(s->d0_plic), 0), 0);
    memory_region_init_alias(&s->d0_plic_sext_alias, OBJECT(dev),
        "bl808.d0.plic.sext32",
        sysbus_mmio_get_region(SYS_BUS_DEVICE(s->d0_plic), 0), 0,
        BL808_D0_PLIC_SIZE);
    memory_region_add_subregion_overlap(&s->d0_mem,
        BL808_RV64_SEXT32(BL808_D0_PLIC_BASE), &s->d0_plic_sext_alias, 0);

    /* D0 ACLINT at 0xE4000000 (T-Head layout, in D0's private space) */
    {
        DeviceState *d0_clint = thead_clint_create(BL808_D0_CLINT_BASE,
                                                   BL808_ACLINT_TIMEBASE_FREQ,
                                                   1);
        MemoryRegion *d0_clint_mr = sysbus_mmio_get_region(SYS_BUS_DEVICE(d0_clint), 0);
        /* Remap into D0's container */
        memory_region_del_subregion(sys_mem,
            d0_clint_mr);
        memory_region_add_subregion_overlap(&s->d0_mem, BL808_D0_CLINT_BASE,
            d0_clint_mr, 0);
        memory_region_init_alias(&s->d0_clint_sext_alias, OBJECT(dev),
            "bl808.d0.clint.sext32", d0_clint_mr, 0,
            memory_region_size(d0_clint_mr));
        memory_region_add_subregion_overlap(&s->d0_mem,
            BL808_RV64_SEXT32(BL808_D0_CLINT_BASE),
            &s->d0_clint_sext_alias, 0);

        /* D0 CLINT drives CPU directly via mip (no CLIC for D0) */
        RISCVCPU *d0_rv = s->d0_cpu;
        riscv_cpu_set_rdtime_fn(&d0_rv->env, thead_clint_read_rtc_cb,
                                d0_clint);
        /* Wire CLINT outputs to D0 CPU IRQ lines directly */
        qdev_connect_gpio_out(d0_clint, 0,
                              qdev_get_gpio_in(DEVICE(d0_rv), IRQ_M_SOFT));
        qdev_connect_gpio_out(d0_clint, 1,
                              qdev_get_gpio_in(DEVICE(d0_rv), IRQ_M_TIMER));
    }

    /*
     * ---- LP interrupt controller (CLIC + CLINT) ----
     *
     * Same as M0: CLINT at 0xE0000000, CLIC at 0xE0800000,
     * but in LP's private address space.
     */

    /* LP xt_clic at 0xE0800000 (in LP's private address space) */
    s->lp_clic = xt_clic_create(BL808_CLIC_BASE, true,
                                2,  /* hartid_base (LP = cpu_index 2) */
                                1, BL808_LP_CLIC_NUM_IRQS,
                                BL808_CLIC_INTCTLBITS);
    memory_region_del_subregion(sys_mem,
        sysbus_mmio_get_region(SYS_BUS_DEVICE(s->lp_clic), 0));
    memory_region_add_subregion_overlap(&s->lp_mem, BL808_CLIC_BASE,
        sysbus_mmio_get_region(SYS_BUS_DEVICE(s->lp_clic), 0), 0);

    /* Manually set env->clic for LP */
    s->lp_cpu->env.clic = XT_CLIC(s->lp_clic);
    s->lp_cpu->env.mclicbase = BL808_CLIC_BASE;

    /* LP thead_clint at 0xE0000000 (in LP's private address space) */
    s->lp_clint = thead_clint_create(BL808_CLINT_BASE,
                                     BL808_ACLINT_TIMEBASE_FREQ, 1);
    memory_region_del_subregion(sys_mem,
        sysbus_mmio_get_region(SYS_BUS_DEVICE(s->lp_clint), 0));
    memory_region_add_subregion_overlap(&s->lp_mem, BL808_CLINT_BASE,
        sysbus_mmio_get_region(SYS_BUS_DEVICE(s->lp_clint), 0), 0);

    /* Wire LP CLINT → LP CLIC: soft→IRQ 3, timer→IRQ 7 */
    qdev_connect_gpio_out(s->lp_clint, 0,
                          qdev_get_gpio_in(s->lp_clic, IRQ_M_SOFT));
    qdev_connect_gpio_out(s->lp_clint, 1,
                          qdev_get_gpio_in(s->lp_clic, IRQ_M_TIMER));

    riscv_cpu_set_rdtime_fn(&s->lp_cpu->env, thead_clint_read_rtc_cb,
                            s->lp_clint);
#endif

    /* ---- UARTs ---- */
    {
        static const hwaddr uart_base[] = {
            BL808_UART0_BASE, BL808_UART1_BASE,
            BL808_UART2_BASE, BL808_UART3_BASE
        };
        static const int uart_irq[] = {
            BL808_M0_UART0_IRQ, BL808_M0_UART1_IRQ,
            BL808_M0_UART2_IRQ, BL808_D0_UART3_IRQ
        };

        for (int i = 0; i < 4; i++) {
            Chardev *chr = serial_hd(i);

            if (chr) {
                qdev_prop_set_chr(DEVICE(&s->uart[i]), "chardev", chr);
            }
            if (!sysbus_realize(SYS_BUS_DEVICE(&s->uart[i]), errp)) {
                return;
            }
            sysbus_mmio_map(SYS_BUS_DEVICE(&s->uart[i]), 0, uart_base[i]);
            if (i < 3 && uart_irq[i] >= 0 && s->m0_clic) {
                sysbus_connect_irq(SYS_BUS_DEVICE(&s->uart[i]), 0,
                                   qdev_get_gpio_in(s->m0_clic, uart_irq[i]));
            } else if (i == 3 && uart_irq[i] >= 0 && s->d0_plic) {
                sysbus_connect_irq(SYS_BUS_DEVICE(&s->uart[i]), 0,
                                   qdev_get_gpio_in(s->d0_plic, uart_irq[i]));
            }
        }

    }

    /* ---- GLB (Global Register) ---- */
    {
        s->glb = qdev_new(TYPE_BL808_GLB);
        if (!sysbus_realize(SYS_BUS_DEVICE(s->glb), errp)) {
            return;
        }
        sysbus_mmio_map(SYS_BUS_DEVICE(s->glb), 0, BL808_GLB_BASE);
        if (s->m0_clic) {
            sysbus_connect_irq(SYS_BUS_DEVICE(s->glb), 0,
                qdev_get_gpio_in(s->m0_clic, BL808_M0_GPIO_IRQ));
        }
#ifdef TARGET_RISCV64
        /*
         * The RM lists GPIO_INT0 in the shared M0/LP interrupt table, but the
         * LP core chapter only documents 32 external CLIC sources. Do not
         * alias LP GPIO onto an out-of-range CLIC input until that routing is
         * confirmed from silicon behavior.
         */
        if (s->lp_clic && BL808_M0_GPIO_IRQ < BL808_LP_CLIC_NUM_IRQS) {
            sysbus_connect_irq(SYS_BUS_DEVICE(s->glb), 1,
                qdev_get_gpio_in(s->lp_clic, BL808_M0_GPIO_IRQ));
        }
#endif
    }
    {
        s->mm_glb = qdev_new(TYPE_BL808_GLB);
        qdev_prop_set_bit(s->mm_glb, "mm-domain", true);
        if (!sysbus_realize(SYS_BUS_DEVICE(s->mm_glb), errp)) {
            return;
        }
        sysbus_mmio_map(SYS_BUS_DEVICE(s->mm_glb), 0, BL808_MM_GLB_BASE);
    }
    bl808_glb_register_device(s->glb,
                              BL808_GLB_CGEN_CFG1, BIT(16),
                              BL808_GLB_SWRST_CFG1, BIT(16),
                              (hwaddr)-1,
                              bl808_soc_uart_clock_notify,
                              bl808_soc_uart_reset_notify,
                              NULL,
                              &s->uart[0]);
    bl808_glb_register_device(s->glb,
                              BL808_GLB_CGEN_CFG1, BIT(17),
                              BL808_GLB_SWRST_CFG1, BIT(17),
                              (hwaddr)-1,
                              bl808_soc_uart_clock_notify,
                              bl808_soc_uart_reset_notify,
                              NULL,
                              &s->uart[1]);
    bl808_glb_register_device(s->glb,
                              BL808_GLB_CGEN_CFG1, BIT(26),
                              BL808_GLB_SWRST_CFG1, BIT(26),
                              (hwaddr)-1,
                              bl808_soc_uart_clock_notify,
                              bl808_soc_uart_reset_notify,
                              NULL,
                              &s->uart[2]);
    bl808_glb_register_device(s->mm_glb,
                              (hwaddr)-1, 0,
                              BL808_MM_GLB_SW_RESET_PERI,
                              BL808_MM_RESET_UART3,
                              (hwaddr)-1,
                              NULL,
                              bl808_soc_uart_reset_notify,
                              NULL,
                              &s->uart[3]);
    bl808_glb_register_device(s->glb,
                              (hwaddr)-1, 0,
                              (hwaddr)-1, 0,
                              BL808_GLB_UART_CFG0,
                              NULL,
                              NULL,
                              bl808_soc_mcu_uart_clock_config_notify,
                              machine);

    /* ---- SPI0 ---- */
    if (!sysbus_realize(SYS_BUS_DEVICE(&s->spi0), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->spi0), 0, BL808_SPI0_BASE);
    if (s->m0_clic) {
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->spi0), 0,
            qdev_get_gpio_in(s->m0_clic, BL808_M0_SPI0_IRQ));
    }
    bl808_glb_register_device(s->glb,
                              BL808_GLB_CGEN_CFG1, BIT(18),
                              BL808_GLB_SWRST_CFG1, BIT(18),
                              BL808_GLB_SPI_CFG0,
                              bl808_soc_spi_clock_notify,
                              bl808_soc_spi_reset_notify,
                              bl808_soc_mcu_spi_clock_config_notify,
                              &s->spi0);

    /* ---- I2C0 ---- */
    qdev_prop_set_bit(DEVICE(&s->i2c0), "attach-default-eeprom",
                      s->attach_default_eeproms && !s->strict_fidelity);
    if (!sysbus_realize(SYS_BUS_DEVICE(&s->i2c0), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->i2c0), 0, BL808_I2C0_BASE);
    if (s->m0_clic) {
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->i2c0), 0,
            qdev_get_gpio_in(s->m0_clic, BL808_M0_I2C0_IRQ));
    }
    bl808_glb_register_device(s->glb,
                              BL808_GLB_CGEN_CFG1, BIT(19),
                              BL808_GLB_SWRST_CFG1, BIT(19),
                              (hwaddr)-1,
                              bl808_soc_i2c_clock_notify,
                              bl808_soc_i2c_reset_notify,
                              NULL,
                              &s->i2c0);

    /* ---- Timer0 ---- */
    if (!sysbus_realize(SYS_BUS_DEVICE(&s->timer0), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->timer0), 0, BL808_TIMER0_BASE);
    if (s->m0_clic) {
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->timer0), 0,
            qdev_get_gpio_in(s->m0_clic, BL808_M0_TIMER0_CH0_IRQ));
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->timer0), 1,
            qdev_get_gpio_in(s->m0_clic, BL808_M0_TIMER0_CH1_IRQ));
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->timer0), 2,
            qdev_get_gpio_in(s->m0_clic, BL808_M0_TIMER0_WDT_IRQ));
    }
    bl808_glb_register_device(s->glb,
                              BL808_GLB_CGEN_CFG1, BIT(21),
                              BL808_GLB_SWRST_CFG1, BIT(21),
                              BL808_GLB_SYS_CFG0,
                              bl808_soc_timer0_clock_notify,
                              bl808_soc_timer0_reset_notify,
                              bl808_soc_timer0_clock_config_notify,
                              machine);
    bl808_glb_register_device(s->glb,
                              (hwaddr)-1, 0,
                              (hwaddr)-1, 0,
                              BL808_GLB_SYS_CFG1,
                              NULL,
                              NULL,
                              bl808_soc_timer0_sys_cfg1_notify,
                              machine);
    bl808_glb_register_device(s->glb,
                              (hwaddr)-1, 0,
                              (hwaddr)-1, 0,
                              BL808_GLB_SWRST_CFG2,
                              NULL,
                              NULL,
                              bl808_soc_lp_swrst_cfg2_notify,
                              machine);
    bl808_glb_register_device(s->glb,
                              (hwaddr)-1, 0,
                              (hwaddr)-1, 0,
                              BL808_GLB_WIFI_PLL_CFG0,
                              NULL,
                              NULL,
                              bl808_soc_wifi_pll_config_notify,
                              machine);
    bl808_glb_register_device(s->glb,
                              (hwaddr)-1, 0,
                              (hwaddr)-1, 0,
                              BL808_GLB_WIFI_PLL_CFG1,
                              NULL,
                              NULL,
                              bl808_soc_wifi_pll_config_notify,
                              machine);
    bl808_glb_register_device(s->glb,
                              (hwaddr)-1, 0,
                              (hwaddr)-1, 0,
                              BL808_GLB_WIFI_PLL_CFG5,
                              NULL,
                              NULL,
                              bl808_soc_wifi_pll_config_notify,
                              machine);
    bl808_glb_register_device(s->glb,
                              (hwaddr)-1, 0,
                              (hwaddr)-1, 0,
                              BL808_GLB_WIFI_PLL_CFG6,
                              NULL,
                              NULL,
                              bl808_soc_wifi_pll_config_notify,
                              machine);
    bl808_glb_register_device(s->glb,
                              (hwaddr)-1, 0,
                              (hwaddr)-1, 0,
                              BL808_GLB_WIFI_PLL_CFG8,
                              NULL,
                              NULL,
                              bl808_soc_wifi_pll_config_notify,
                              machine);

    /* ---- SPI1 ---- */
    if (!sysbus_realize(SYS_BUS_DEVICE(&s->spi1), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->spi1), 0, BL808_SPI1_BASE);
#ifdef TARGET_RISCV64
    if (s->d0_plic) {
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->spi1), 0,
            qdev_get_gpio_in(s->d0_plic, BL808_D0_SPI1_IRQ));
    }
#endif
    bl808_glb_register_device(s->mm_glb,
                              (hwaddr)-1, 0,
                              BL808_MM_GLB_SW_RESET_PERI,
                              BL808_MM_RESET_SPI1,
                              BL808_MM_GLB_CLK_CTRL_PERI,
                              NULL,
                              bl808_soc_spi_reset_notify,
                              bl808_soc_mm_spi_clock_config_notify,
                              &s->spi1);

    /* ---- DMA0 ---- */
    if (!sysbus_realize(SYS_BUS_DEVICE(&s->dma0), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->dma0), 0, BL808_DMA0_BASE);
    if (s->m0_clic) {
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->dma0), 0,
            qdev_get_gpio_in(s->m0_clic, BL808_M0_DMA0_IRQ));
    }
    bl808_soc_register_dma0_requests(s, &s->dma0);
    bl808_glb_register_device(s->glb,
                              BL808_GLB_DMA_CFG0, BIT(24),
                              (hwaddr)-1, 0,
                              (hwaddr)-1,
                              bl808_soc_dma_clock_notify,
                              NULL,
                              NULL,
                              &s->dma0);

    /* ---- PWM ---- */
    if (!sysbus_realize(SYS_BUS_DEVICE(&s->pwm), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->pwm), 0, BL808_PWM_BASE);
    if (s->m0_clic && s->d0_plic) {
        /*
         * RM Table 1.5/1.6 routes the shared PWM block to both M0 ("PWM")
         * and D0 ("PWM1").
         */
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->pwm), 0,
            bl808_split_irq2(qdev_get_gpio_in(s->m0_clic, BL808_M0_PWM_IRQ),
                             qdev_get_gpio_in(s->d0_plic, BL808_D0_PWM_IRQ)));
    } else if (s->m0_clic) {
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->pwm), 0,
            qdev_get_gpio_in(s->m0_clic, BL808_M0_PWM_IRQ));
#ifdef TARGET_RISCV64
    } else if (s->d0_plic) {
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->pwm), 0,
            qdev_get_gpio_in(s->d0_plic, BL808_D0_PWM_IRQ));
#endif
    }
    bl808_glb_register_device(s->glb,
                              BL808_GLB_CGEN_CFG1, BIT(20),
                              BL808_GLB_SWRST_CFG1, BIT(20),
                              (hwaddr)-1,
                              bl808_soc_pwm_clock_notify,
                              bl808_soc_pwm_reset_notify,
                              NULL,
                              &s->pwm);

    /* ---- Ethernet MAC (BL808 EMAC) ---- */
    if (!sysbus_realize(SYS_BUS_DEVICE(&s->emac), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->emac), 0, BL808_EMAC_BASE);
    if (s->m0_clic && s->d0_plic) {
        /*
         * RM Table 1.5/1.6 routes the shared EMAC block to both M0 ("EMAC")
         * and D0 ("EMAC2").
         */
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->emac), 0,
            bl808_split_irq2(qdev_get_gpio_in(s->m0_clic, BL808_M0_EMAC_IRQ),
                             qdev_get_gpio_in(s->d0_plic,
                                              BL808_D0_EMAC2_IRQ)));
    } else if (s->m0_clic) {
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->emac), 0,
            qdev_get_gpio_in(s->m0_clic, BL808_M0_EMAC_IRQ));
#ifdef TARGET_RISCV64
    } else if (s->d0_plic) {
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->emac), 0,
            qdev_get_gpio_in(s->d0_plic, BL808_D0_EMAC2_IRQ));
#endif
    }

    /* ---- SD Host (BL808 SDHCI-compatible controller) ---- */
    if (!sysbus_realize(SYS_BUS_DEVICE(&s->sdh), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->sdh), 0, BL808_SDH_BASE);

    /* ---- SF Controller (Serial Flash) ---- */
    {
        if (!sysbus_realize(SYS_BUS_DEVICE(&s->sf_ctrl), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->sf_ctrl), 0, BL808_SF_CTRL_BASE);
    }

    if (!sysbus_realize(SYS_BUS_DEVICE(&s->gpip), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->gpip), 0, BL808_GPIP_BASE);

    if (!sysbus_realize(SYS_BUS_DEVICE(&s->sec_eng), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->sec_eng), 0, BL808_SEC_ENG_BASE);
    if (s->m0_clic) {
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->sec_eng), 0,
            qdev_get_gpio_in(s->m0_clic, BL808_M0_SEC_ENG_ID1_IRQ));
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->sec_eng), 1,
            qdev_get_gpio_in(s->m0_clic, BL808_M0_SEC_ENG_ID0_IRQ));
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->sec_eng), 2,
            qdev_get_gpio_in(s->m0_clic, BL808_M0_SEC_ENG_CDET_ID1_IRQ));
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->sec_eng), 3,
            qdev_get_gpio_in(s->m0_clic, BL808_M0_SEC_ENG_CDET_ID0_IRQ));
    }

    s->tzc_sec.secure = true;
    if (!sysbus_realize(SYS_BUS_DEVICE(&s->tzc_sec), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->tzc_sec), 0, BL808_TZC_SEC_BASE);

    s->tzc_nsec.secure = false;
    if (!sysbus_realize(SYS_BUS_DEVICE(&s->tzc_nsec), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->tzc_nsec), 0, BL808_TZC_NSEC_BASE);

    if (!sysbus_realize(SYS_BUS_DEVICE(&s->cci), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->cci), 0, BL808_CCI_BASE);
    bl808_cci_register_config_notify(DEVICE(&s->cci), BL808_CCI_AUDIO_PLL_CFG0,
                                     bl808_soc_timer_pll_config_notify,
                                     machine);
    bl808_cci_register_config_notify(DEVICE(&s->cci), BL808_CCI_AUDIO_PLL_CFG1,
                                     bl808_soc_timer_pll_config_notify,
                                     machine);
    bl808_cci_register_config_notify(DEVICE(&s->cci), BL808_CCI_AUDIO_PLL_CFG6,
                                     bl808_soc_timer_pll_config_notify,
                                     machine);
    bl808_cci_register_config_notify(DEVICE(&s->cci), BL808_CCI_AUDIO_PLL_CFG8,
                                     bl808_soc_timer_pll_config_notify,
                                     machine);
    bl808_cci_register_config_notify(DEVICE(&s->cci), BL808_CCI_CPU_PLL_CFG0,
                                     bl808_soc_timer_pll_config_notify,
                                     machine);
    bl808_cci_register_config_notify(DEVICE(&s->cci), BL808_CCI_CPU_PLL_CFG1,
                                     bl808_soc_timer_pll_config_notify,
                                     machine);
    bl808_cci_register_config_notify(DEVICE(&s->cci), BL808_CCI_CPU_PLL_CFG6,
                                     bl808_soc_timer_pll_config_notify,
                                     machine);
    bl808_cci_register_config_notify(DEVICE(&s->cci), BL808_CCI_CPU_PLL_CFG8,
                                     bl808_soc_timer_pll_config_notify,
                                     machine);

    if (!sysbus_realize(SYS_BUS_DEVICE(&s->mcu_misc), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->mcu_misc), 0, BL808_MCU_MISC_BASE);

    if (!sysbus_realize(SYS_BUS_DEVICE(&s->cks), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->cks), 0, BL808_CKS_BASE);
    bl808_glb_register_device(s->glb,
                              BL808_GLB_CGEN_CFG1, BIT(23),
                              BL808_GLB_SWRST_CFG1, BIT(23),
                              (hwaddr)-1,
                              bl808_soc_cks_clock_notify,
                              bl808_soc_cks_reset_notify,
                              NULL,
                              &s->cks);

    /* ---- IPC (Inter-Processor Communication) mailboxes ---- */
    if (!sysbus_realize(SYS_BUS_DEVICE(&s->ipc0), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->ipc0), 0, BL808_IPC0_BASE);
    if (s->m0_clic) {
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->ipc0), 0,
            qdev_get_gpio_in(s->m0_clic, BL808_M0_IPC_IRQ));
    }
    bl808_ipc_set_clock_enabled(&s->ipc0, true);

    if (!sysbus_realize(SYS_BUS_DEVICE(&s->ipc1), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->ipc1), 0, BL808_IPC1_BASE);
#ifdef TARGET_RISCV64
    if (s->lp_clic) {
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->ipc1), 0,
            qdev_get_gpio_in(s->lp_clic, BL808_LP_IPC_IRQ));
    }
#endif
    bl808_ipc_set_clock_enabled(&s->ipc1, true);

    qdev_prop_set_bit(DEVICE(&s->i2c1), "attach-default-eeprom",
                      s->attach_default_eeproms && !s->strict_fidelity);
    if (!sysbus_realize(SYS_BUS_DEVICE(&s->i2c1), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->i2c1), 0, BL808_I2C1_BASE);
    if (s->m0_clic) {
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->i2c1), 0,
            qdev_get_gpio_in(s->m0_clic, BL808_M0_I2C1_IRQ));
    }
    bl808_glb_register_device(s->glb,
                              BL808_GLB_CGEN_CFG1, BIT(25),
                              BL808_GLB_SWRST_CFG1, BIT(25),
                              (hwaddr)-1,
                              bl808_soc_i2c_clock_notify,
                              bl808_soc_i2c_reset_notify,
                              NULL,
                              &s->i2c1);
    bl808_glb_register_device(s->glb,
                              (hwaddr)-1, 0,
                              (hwaddr)-1, 0,
                              BL808_GLB_I2C_CFG0,
                              NULL,
                              NULL,
                              bl808_soc_mcu_i2c_clock_config_notify,
                              machine);

    if (!sysbus_realize(SYS_BUS_DEVICE(&s->i2s), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->i2s), 0, BL808_I2S_BASE);
    if (s->m0_clic) {
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->i2s), 0,
            qdev_get_gpio_in(s->m0_clic, BL808_M0_I2S_IRQ));
    }
    bl808_glb_register_device(s->glb,
                              (hwaddr)-1, 0,
                              (hwaddr)-1, 0,
                              BL808_GLB_I2S_CFG0,
                              bl808_soc_i2s_clock_notify,
                              bl808_soc_i2s_reset_notify,
                              bl808_soc_mcu_i2s_clock_config_notify,
                              &s->i2s);

    if (!sysbus_realize(SYS_BUS_DEVICE(&s->audio), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->audio), 0, BL808_AUDIO_BASE);
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->audio), 1, BL808_AUADC_BASE);
#ifdef TARGET_RISCV64
    if (s->d0_plic) {
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->audio), 0,
            qdev_get_gpio_in(s->d0_plic, BL808_D0_AUDIO_IRQ));
    }
#endif
    bl808_glb_register_device(s->glb,
                              BL808_GLB_CGEN_CFG2, BIT(21),
                              (hwaddr)-1, 0,
                              (hwaddr)-1,
                              bl808_soc_audio_clock_notify,
                              bl808_soc_audio_reset_notify,
                              NULL,
                              &s->audio);

    if (!sysbus_realize(SYS_BUS_DEVICE(&s->emi), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->emi), 0, BL808_EMI_MISC_BASE);
    bl808_glb_register_device(s->glb,
                              BL808_GLB_CGEN_CFG2, BIT(16),
                              (hwaddr)-1, 0,
                              BL808_GLB_EMI_CFG0,
                              bl808_soc_emi_clock_notify,
                              NULL,
                              NULL,
                              &s->emi);

    if (!sysbus_realize(SYS_BUS_DEVICE(&s->psram_ctrl), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->psram_ctrl), 0, BL808_PSRAM_CTRL_BASE);
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->psram_ctrl), 1, BL808_PSRAM_UHS_BASE);
    bl808_glb_register_device(s->glb,
                              BL808_GLB_CGEN_CFG2, BIT(17) | BIT(18),
                              (hwaddr)-1, 0,
                              BL808_GLB_EMI_CFG0,
                              bl808_soc_psram_clock_notify,
                              bl808_soc_psram_reset_notify,
                              NULL,
                              &s->psram_ctrl);

    if (!sysbus_realize(SYS_BUS_DEVICE(&s->usb), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->usb), 0, BL808_USB_BASE);
    if (s->m0_clic) {
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->usb), 0,
            qdev_get_gpio_in(s->m0_clic, BL808_M0_USB_IRQ));
    }

    /* ---- DMA1 ---- */
    qdev_prop_set_uint8(DEVICE(&s->dma1), "channel-count", 4);
    if (!sysbus_realize(SYS_BUS_DEVICE(&s->dma1), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->dma1), 0, BL808_DMA1_BASE);
    if (s->m0_clic) {
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->dma1), 0,
            qdev_get_gpio_in(s->m0_clic, BL808_M0_DMA1_IRQ));
    }
    bl808_soc_register_dma0_requests(s, &s->dma1);
    bl808_glb_register_device(s->glb,
                              BL808_GLB_DMA_CFG0, BIT(25),
                              (hwaddr)-1, 0,
                              (hwaddr)-1,
                              bl808_soc_dma_clock_notify,
                              NULL,
                              NULL,
                              &s->dma1);
    /* CLIC interrupt controller -- now handled by bl808-clic device above */

    if (!sysbus_realize(SYS_BUS_DEVICE(&s->mm_misc), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->mm_misc), 0, BL808_MM_MISC_BASE);

    if (!sysbus_realize(SYS_BUS_DEVICE(&s->dma2d), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->dma2d), 0, BL808_DMA2D_BASE);
#ifdef TARGET_RISCV64
    if (s->d0_plic) {
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->dma2d), 0,
            qdev_get_gpio_in(s->d0_plic, BL808_D0_DMA2D_INT0_IRQ));
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->dma2d), 1,
            qdev_get_gpio_in(s->d0_plic, BL808_D0_DMA2D_INT1_IRQ));
    }
    qdev_prop_set_bit(DEVICE(&s->i2c2), "attach-default-eeprom",
                      s->attach_default_eeproms && !s->strict_fidelity);
    if (!sysbus_realize(SYS_BUS_DEVICE(&s->i2c2), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->i2c2), 0, BL808_I2C2_BASE);
    if (s->d0_plic) {
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->i2c2), 0,
            qdev_get_gpio_in(s->d0_plic, BL808_D0_I2C2_IRQ));
    }
    bl808_glb_register_device(s->mm_glb,
                              (hwaddr)-1, 0,
                              BL808_MM_GLB_SW_RESET_PERI,
                              BL808_MM_RESET_I2C2,
                              (hwaddr)-1,
                              NULL,
                              bl808_soc_i2c_reset_notify,
                              NULL,
                              &s->i2c2);

    qdev_prop_set_bit(DEVICE(&s->i2c3), "attach-default-eeprom",
                      s->attach_default_eeproms && !s->strict_fidelity);
    if (!sysbus_realize(SYS_BUS_DEVICE(&s->i2c3), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->i2c3), 0, BL808_I2C3_BASE);
    if (s->d0_plic) {
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->i2c3), 0,
            qdev_get_gpio_in(s->d0_plic, BL808_D0_I2C3_IRQ));
    }
    bl808_glb_register_device(s->mm_glb,
                              (hwaddr)-1, 0,
                              BL808_MM_GLB_SW_RESET_PERI,
                              BL808_MM_RESET_I2C3,
                              (hwaddr)-1,
                              NULL,
                              bl808_soc_i2c_reset_notify,
                              NULL,
                              &s->i2c3);
    bl808_glb_register_device(s->mm_glb,
                              (hwaddr)-1, 0,
                              (hwaddr)-1, 0,
                              BL808_MM_GLB_CLK_CTRL_PERI,
                              NULL,
                              NULL,
                              bl808_soc_mm_clk_ctrl_peri_notify,
                              machine);
    bl808_glb_register_device(s->mm_glb,
                              (hwaddr)-1, 0,
                              (hwaddr)-1, 0,
                              BL808_MM_GLB_CLK_CTRL_PERI3,
                              NULL,
                              NULL,
                              bl808_soc_mm_clk_ctrl_peri3_notify,
                              machine);

    /* ---- DMA2 ---- */
    qdev_prop_set_bit(DEVICE(&s->dma2), "supports-doubleword-width", true);
    if (!sysbus_realize(SYS_BUS_DEVICE(&s->dma2), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->dma2), 0, BL808_DMA2_BASE);
    bl808_soc_register_dma2_requests(s, &s->dma2);
    bl808_glb_register_device(s->mm_glb,
                              (hwaddr)-1, 0,
                              BL808_MM_GLB_SW_RESET_PERI,
                              BL808_MM_RESET_DMA2,
                              (hwaddr)-1,
                              NULL,
                              bl808_soc_dma_reset_notify,
                              NULL,
                              &s->dma2);
    if (s->d0_plic) {
        static const int dma2_irq[] = {
            BL808_D0_DMA2_INT0_IRQ, BL808_D0_DMA2_INT1_IRQ,
            BL808_D0_DMA2_INT2_IRQ, BL808_D0_DMA2_INT3_IRQ,
            BL808_D0_DMA2_INT4_IRQ, BL808_D0_DMA2_INT5_IRQ,
            BL808_D0_DMA2_INT6_IRQ, BL808_D0_DMA2_INT7_IRQ,
        };

        for (int i = 0; i < 8; i++) {
            sysbus_connect_irq(SYS_BUS_DEVICE(&s->dma2), i + 1,
                qdev_get_gpio_in(s->d0_plic, dma2_irq[i]));
        }
    }
#endif
    /* IPC2: D0's mailbox -- receives from M0 and LP */
    if (!sysbus_realize(SYS_BUS_DEVICE(&s->ipc2), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->ipc2), 0, BL808_IPC2_BASE);
#ifdef TARGET_RISCV64
    if (s->d0_plic) {
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->ipc2), 0,
            qdev_get_gpio_in(s->d0_plic, BL808_D0_IPC_IRQ));
    }
#endif
#ifdef TARGET_RISCV64
    if (!sysbus_realize(SYS_BUS_DEVICE(&s->timer1), errp)) {
        return;
    }
    sysbus_mmio_map(SYS_BUS_DEVICE(&s->timer1), 0, BL808_TIMER1_BASE);
    if (s->d0_plic) {
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->timer1), 0,
            qdev_get_gpio_in(s->d0_plic, BL808_D0_TIMER1_CH0_IRQ));
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->timer1), 1,
            qdev_get_gpio_in(s->d0_plic, BL808_D0_TIMER1_CH1_IRQ));
        sysbus_connect_irq(SYS_BUS_DEVICE(&s->timer1), 2,
            qdev_get_gpio_in(s->d0_plic, BL808_D0_TIMER1_WDT_IRQ));
    }
    bl808_glb_register_device(s->mm_glb,
                              (hwaddr)-1, 0,
                              BL808_MM_GLB_SW_RESET_PERI,
                              BL808_MM_RESET_TIMER1,
                              BL808_MM_GLB_MM_CLK_CTRL_CPU,
                              bl808_soc_timer1_clock_notify,
                              bl808_soc_timer1_reset_notify,
                              bl808_soc_timer1_clk_ctrl_cpu_notify,
                              machine);
    bl808_glb_register_device(s->mm_glb,
                              (hwaddr)-1, 0,
                              (hwaddr)-1, 0,
                              BL808_MM_GLB_MM_CLK_CPU,
                              NULL,
                              NULL,
                              bl808_soc_timer1_clk_cpu_notify,
                              machine);
    bl808_glb_register_device(s->mm_glb,
                              (hwaddr)-1, 0,
                              (hwaddr)-1, 0,
                              BL808_MM_GLB_MM_SW_SYS_RESET,
                              NULL,
                              NULL,
                              bl808_soc_d0_sw_sys_reset_notify,
                              machine);
    bl808_glb_register_device(s->glb,
                              (hwaddr)-1, 0,
                              (hwaddr)-1, 0,
                              BL808_GLB_DIG_CLK_CFG1,
                              NULL,
                              NULL,
                              bl808_soc_timer1_dig_clk_cfg1_notify,
                              machine);
#endif
}

static void bl808_soc_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    dc->realize = bl808_soc_realize;
    /* Uses serial_hds in realize function, thus can't be used twice */
    dc->user_creatable = false;
}

static const TypeInfo bl808_soc_info = {
    .name          = TYPE_BL808_SOC,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(BL808SoCState),
    .instance_init = bl808_soc_init,
    .class_init    = bl808_soc_class_init,
};

/* ========================================================================= */
/* Machine initialization                                                     */
/* ========================================================================= */

static bool bl808_assign_flash_backend(BL808MachineState *s, Error **errp)
{
    Error *local_err = NULL;
    DriveInfo *legacy = drive_get(IF_MTD, 0, 0);

    if (s->flash_image && legacy) {
        error_setg(errp,
                   "use either -M bl808,flash-image=... or -drive if=mtd,... "
                   "for BL808 flash, not both");
        return false;
    }

    if (s->flash_image) {
        QDict *options = qdict_new();

        qdict_put_str(options, "driver", "raw");
        s->flash_blk = blk_new_open(s->flash_image, NULL, options,
                                    BDRV_O_RDWR | BDRV_O_AUTO_RDONLY,
                                    errp);
        if (!s->flash_blk) {
            return false;
        }

        qdev_prop_set_drive_err(DEVICE(&s->soc.sf_ctrl), "drive",
                                s->flash_blk, &local_err);
        if (local_err) {
            error_propagate(errp, local_err);
            return false;
        }
        return true;
    }

    if (legacy) {
        qdev_prop_set_drive_err(DEVICE(&s->soc.sf_ctrl), "drive",
                                blk_by_legacy_dinfo(legacy), &local_err);
        if (local_err) {
            error_propagate(errp, local_err);
            return false;
        }
    }

    return true;
}

static bool bl808_assign_sd_backend(BL808MachineState *s, Error **errp)
{
    DriveInfo *legacy = drive_get(IF_SD, 0, 0);

    if (s->sd_image && legacy) {
        error_setg(errp,
                   "use either -M bl808,sd-image=... or -drive if=sd,... "
                   "for BL808 SD media, not both");
        return false;
    }

    if (s->sd_image) {
        QDict *options = qdict_new();

        qdict_put_str(options, "driver", "raw");
        s->sd_blk = blk_new_open(s->sd_image, NULL, options,
                                 BDRV_O_RDWR | BDRV_O_AUTO_RDONLY,
                                 errp);
        if (!s->sd_blk) {
            return false;
        }
    }

    return true;
}

static bool bl808_attach_sd_card(BL808MachineState *s, Error **errp)
{
    Error *local_err = NULL;
    DriveInfo *legacy = drive_get(IF_SD, 0, 0);
    BlockBackend *blk = s->sd_blk;
    BusState *bus;
    DeviceState *card;

    if (!blk && legacy) {
        blk = blk_by_legacy_dinfo(legacy);
    }
    if (!blk) {
        return true;
    }

    bus = qdev_get_child_bus(DEVICE(&s->soc.sdh), "sd-bus");
    if (!bus) {
        error_setg(errp, "BL808 SDH bus is unavailable");
        return false;
    }

    card = qdev_new(TYPE_SD_CARD);
    qdev_prop_set_drive_err(card, "drive", blk, &local_err);
    if (local_err) {
        object_unref(OBJECT(card));
        error_propagate(errp, local_err);
        return false;
    }

    qdev_realize_and_unref(card, bus, &local_err);
    if (local_err) {
        error_propagate(errp, local_err);
        return false;
    }

    return true;
}

static bool bl808_machine_has_flash_source(BL808MachineState *s)
{
    return s->flash_image || drive_get(IF_MTD, 0, 0);
}

static bool bl808_configure_net_phy(BL808MachineState *s, Error **errp)
{
    DeviceState *emac = DEVICE(&s->soc.emac);

    if (!s->net_phy || s->net_phy[0] == '\0' ||
        g_strcmp0(s->net_phy, "none") == 0) {
        qdev_prop_set_bit(emac, "phy-attached", false);
        return true;
    }

    if (g_strcmp0(s->net_phy, "ip101g") == 0) {
        qdev_prop_set_bit(emac, "phy-attached", true);
        qdev_prop_set_uint8(emac, "phy-addr", 0);
        return true;
    }

    error_setg(errp,
               "unsupported bl808 board property 'net-phy=%s'; "
               "supported values are 'ip101g' and 'none'",
               s->net_phy);
    return false;
}

static bool bl808_reject_pending_property(const char *prop, const char *value,
                                          const char *detail, Error **errp)
{
    if (!value || value[0] == '\0') {
        return true;
    }

    error_setg(errp, "bl808 board property '%s' is not wired yet: %s",
               prop, detail);
    return false;
}

static bool bl808_prepare_board_backends(BL808MachineState *s,
                                         MachineState *machine,
                                         Error **errp)
{
    if (s->strict_fidelity &&
        (machine->kernel_filename || s->d0_firmware || s->lp_firmware)) {
        error_setg(errp,
                   "strict-fidelity disables direct ELF injection; boot the "
                   "SoC from flash instead");
        return false;
    }
    if (s->strict_fidelity && !bl808_machine_has_flash_source(s)) {
        error_setg(errp,
                   "strict-fidelity requires flash-image=... or -drive "
                   "if=mtd,... so the BL808 boots from flash");
        return false;
    }
    if (s->strict_fidelity && !s->bootrom_image) {
        error_setg(errp,
                   "strict-fidelity requires bootrom-image=... with a real "
                   "BL808 boot ROM image");
        return false;
    }

    return bl808_assign_flash_backend(s, errp) &&
           bl808_assign_sd_backend(s, errp) &&
           bl808_configure_net_phy(s, errp) &&
           bl808_reject_pending_property("usb-role", s->usb_role,
                                         "native BL808 USB board wiring is not implemented yet",
                                         errp) &&
           bl808_reject_pending_property("camera-source", s->camera_source,
                                         "MM capture backends are not implemented yet",
                                         errp) &&
           bl808_reject_pending_property("display-sink", s->display_sink,
                                         "MM display backends are not implemented yet",
                                         errp) &&
           bl808_reject_pending_property("wifi-backend", s->wifi_backend,
                                         "wireless host backends are not implemented yet",
                                         errp) &&
           bl808_reject_pending_property("ble-backend", s->ble_backend,
                                         "wireless host backends are not implemented yet",
                                         errp) &&
           bl808_reject_pending_property("zigbee-backend", s->zigbee_backend,
                                         "wireless host backends are not implemented yet",
                                         errp);
}

static bool bl808_init_bootrom(BL808MachineState *s, Error **errp)
{
    if (!memory_region_init_rom(&s->bootrom, NULL, "bl808.bootrom",
                                BL808_BOOTROM_SIZE, errp)) {
        return false;
    }

    memory_region_add_subregion(get_system_memory(), BL808_BOOTROM_BASE,
                                &s->bootrom);
    return bl808_populate_bootrom(s, errp);
}

static void bl808_init_ir(BL808MachineState *s)
{
    memory_region_init_io(&s->ir, OBJECT(s), &bl808_ir_ops, s,
                          "bl808.ir", BL808_IR_SIZE);
    memory_region_add_subregion(get_system_memory(), BL808_IR_BASE, &s->ir);
    bl808_ir_reset(s);
}

static void bl808_init_pds(BL808MachineState *s)
{
    if (!s->pds_wake_timer) {
        s->pds_wake_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL,
                                         bl808_pds_wake_cb, s);
    }
    if (!s->pds_gpio_sample_timer) {
        s->pds_gpio_sample_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL,
                                                bl808_pds_gpio_sample_cb, s);
    }

    memory_region_init_io(&s->pds, OBJECT(s), &bl808_pds_ops, s,
                          "bl808.pds", 0x1000);
    memory_region_add_subregion(get_system_memory(), BL808_PDS_BASE, &s->pds);
    bl808_pds_reset(s);
}

static void bl808_init_hbn_ram(BL808MachineState *s, Error **errp)
{
    if (!memory_region_init_ram(&s->hbn_ram, NULL, "bl808.hbn-ram",
                                BL808_HBN_RAM_SIZE, errp)) {
        return;
    }

    memory_region_add_subregion(get_system_memory(), BL808_HBN_RAM_BASE,
                                &s->hbn_ram);
}

static void bl808_init_hbn(BL808MachineState *s)
{
    if (!s->hbn_alarm_timer) {
        s->hbn_alarm_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL,
                                          bl808_hbn_alarm_cb, s);
    }
    if (!s->hbn_alarm_rt_timer) {
        s->hbn_alarm_rt_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL_RT,
                                             bl808_hbn_alarm_cb, s);
    }
    if (!s->hbn_gpio_delay_timer) {
        s->hbn_gpio_delay_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL,
                                               bl808_hbn_gpio_delay_cb, s);
    }

    memory_region_init_io(&s->hbn, OBJECT(s), &bl808_hbn_ops, s,
                          "bl808.hbn", 0x1000);
    memory_region_add_subregion(get_system_memory(), BL808_HBN_BASE, &s->hbn);
    bl808_hbn_seed(s);
}

static void bl808_init_ef_ctrl(BL808MachineState *s)
{
    memory_region_init_io(&s->ef_ctrl, OBJECT(s), &bl808_ef_ctrl_ops, s,
                          "bl808.ef_ctrl", 0x1000);
    memory_region_add_subregion(get_system_memory(), BL808_EF_CTRL_BASE,
                                &s->ef_ctrl);
    bl808_ef_ctrl_seed(s);
}

static void bl808_init_ble(BL808MachineState *s)
{
    memory_region_init_io(&s->ble, OBJECT(s), &bl808_ble_ops, s,
                          "bl808.ble", BL808_BLE_SIZE);
    memory_region_add_subregion(get_system_memory(), BL808_BLE_BASE, &s->ble);
}

static void bl808_init_wifi_mac(BL808MachineState *s)
{
    memory_region_init_io(&s->wifi_mac_pl, OBJECT(s), &bl808_wifi_mac_pl_ops,
                          s, "bl808.wifi-mac-pl", BL808_WIFI_MAC_PL_SIZE);
    memory_region_add_subregion(get_system_memory(), BL808_WIFI_MAC_PL_BASE,
                                &s->wifi_mac_pl);

    memory_region_init_io(&s->wifi_mac_irq, OBJECT(s), &bl808_wifi_mac_irq_ops,
                          s, "bl808.wifi-mac-irq", BL808_WIFI_MAC_IRQ_SIZE);
    memory_region_add_subregion(get_system_memory(), BL808_WIFI_MAC_IRQ_BASE,
                                &s->wifi_mac_irq);

    memory_region_init_io(&s->wifi_machw, OBJECT(s), &bl808_wifi_machw_ops,
                          s, "bl808.wifi-machw", BL808_WIFI_MACHW_SIZE);
    memory_region_add_subregion(get_system_memory(), BL808_WIFI_MACHW_BASE,
                                &s->wifi_machw);

    memory_region_init_io(&s->wifi_machw_intc, OBJECT(s),
                          &bl808_wifi_machw_intc_ops, s,
                          "bl808.wifi-machw-intc",
                          BL808_WIFI_MACHW_INTC_SIZE);
    memory_region_add_subregion(get_system_memory(), BL808_WIFI_MACHW_INTC_BASE,
                                &s->wifi_machw_intc);

    memory_region_init_io(&s->wifi_ipc_emb, OBJECT(s),
                          &bl808_wifi_ipc_emb_ops, s,
                          "bl808.wifi-ipc-emb", BL808_WIFI_IPC_EMB_SIZE);
    memory_region_add_subregion(get_system_memory(), BL808_WIFI_IPC_EMB_BASE,
                                &s->wifi_ipc_emb);
}

static void bl808_init_regbank(BL808MachineState *s, BL808RegBank *bank,
                               const char *name, hwaddr base, uint64_t size,
                               bool mm_domain)
{
    bank->machine = s;
    bank->name = name;
    bank->mm_domain = mm_domain;
    bl808_reset_regbank(bank);
    memory_region_init_io(&bank->mr, OBJECT(s), &bl808_regbank_ops, bank,
                          name, size);
    memory_region_add_subregion(get_system_memory(), base, &bank->mr);
}

static void bl808_init_regbanks(BL808MachineState *s)
{
    bl808_init_regbank(s, &s->lz4d, "bl808.lz4d", BL808_LZ4D_BASE,
                       BL808_LZ4D_SIZE, false);
    bl808_init_regbank(s, &s->dvp0, "bl808.dvp0", BL808_DVP0_BASE,
                       BL808_REGBANK_SIZE, true);
    bl808_init_regbank(s, &s->osd_a, "bl808.osd-a", BL808_OSD_A_BASE,
                       BL808_REGBANK_SIZE, true);
    bl808_init_regbank(s, &s->osd_dp, "bl808.osd-dp", BL808_OSD_DP_BASE,
                       BL808_REGBANK_SIZE, true);
    bl808_init_regbank(s, &s->dbi, "bl808.dbi", BL808_DBI_BASE,
                       BL808_REGBANK_SIZE, true);
    bl808_init_regbank(s, &s->codec_misc, "bl808.codec-misc",
                       BL808_CODEC_MISC_BASE, BL808_REGBANK_SIZE, true);
    bl808_init_regbank(s, &s->mjpeg, "bl808.mjpeg", BL808_MJPEG_BASE,
                       BL808_REGBANK_SIZE, true);
    bl808_init_regbank(s, &s->h264, "bl808.h264", BL808_H264_BASE,
                       BL808_REGBANK_SIZE, true);
    bl808_init_regbank(s, &s->mjpeg_dec, "bl808.mjpeg-dec",
                       BL808_MJPEG_DEC_BASE, BL808_REGBANK_SIZE, true);
    bl808_init_regbank(s, &s->blai, "bl808.blai", BL808_BLAI_BASE,
                       BL808_REGBANK_SIZE, true);
}

static void bl808_machine_reset(void *opaque)
{
    BL808MachineState *s = opaque;
    BL808BootHeaderInfo boothdr;
    BL808BootHeaderInfo boot2hdr;
    BL808PartitionInfo partition;
    Error *local_err = NULL;

    if (!bl808_populate_bootrom(s, &local_err)) {
        error_report_err(local_err);
        exit(1);
    }
    if (s->have_m0_entry) {
        /*
         * Direct -kernel ELF loading uses QEMU ROM blobs. Mirror the ROM-reset
         * contents into the SF_CTRL flash backing before the flash offset
         * reset below refreshes the XIP aperture from that backing store.
         */
        bl808_sync_flash_xip_to_sf_ctrl(&s->soc);
    }

    s->timer_glb_sys_cfg0 = 0x0003000F;
    s->timer_glb_sys_cfg1 = 0x00000000;
    s->timer_glb_dig_clk_cfg1 = 0x00000000;
    s->timer_glb_wifi_pll_cfg0 = 0x00000FFF;
    s->timer_glb_wifi_pll_cfg1 = 0x00010200;
    s->timer_glb_wifi_pll_cfg5 = 0x00001005;
    s->timer_glb_wifi_pll_cfg6 = 0x01800000;
    s->timer_glb_wifi_pll_cfg8 = 0x800000AE;
    s->glb_uart_cfg0 = 0x00000017;
    s->glb_i2c_cfg0 = 0x01FF0000;
    s->timer0_bclk_div_live = 3;
    s->timer1_mm_clk_ctrl_cpu = 0x00004005;
    s->timer1_mm_clk_cpu = 0x00000000;
    s->mm_clk_ctrl_peri = 0x00810300;
    s->mm_clk_ctrl_peri3 = 0x00010300;
    bl808_refresh_cached_irqs(s);

    bl808_pds_reset(s);
    bl808_hbn_reset(s);
    s->pds_regs[BL808_PDS_CPU_CORE_CFG1_OFFSET / 4] = 3u << BL808_PDS_REG_PLL_SEL_SHIFT;
    memset(&boothdr, 0, sizeof(boothdr));
    memset(&boot2hdr, 0, sizeof(boot2hdr));
    memset(&partition, 0, sizeof(partition));
    bl808_boot2_clear_pass_params(s);
    s->soc.sf_ctrl.reset_xip_offset[0][0] = 0;
    bl808_sf_ctrl_set_flash_image_offset(&s->soc.sf_ctrl, 0, 0, 0);
    if (!s->strict_fidelity && !s->boot_gpio39 && !s->have_m0_entry &&
        bl808_bootheader_read(s, BL808_FLASH_OFFSET_M0, &boot2hdr) &&
        bl808_select_partition_header(s, &boot2hdr, &partition, true) &&
        bl808_bootheader_read(s, partition.header_flash_offset, &boothdr) &&
        boothdr.cpu_enabled[0] && !boothdr.cpu_halt[0]) {
        uint32_t group_offset = boothdr.flash_offset + boothdr.group_image_offset;

        bl808_boot2_store_partition_params(s, &partition);
        s->soc.sf_ctrl.reset_xip_offset[0][0] = group_offset;
        bl808_sf_ctrl_set_flash_image_offset(&s->soc.sf_ctrl, 0, 0, group_offset);
        if (boothdr.power_on_mm) {
            s->pds_regs[BL808_PDS_CTL2_OFFSET / 4] = 0;
        }
    } else if (bl808_primary_flash_bootheader(s, &boothdr)) {
        uint32_t group_offset = boothdr.flash_offset + boothdr.group_image_offset;

        s->soc.sf_ctrl.reset_xip_offset[0][0] = group_offset;
        bl808_sf_ctrl_set_flash_image_offset(&s->soc.sf_ctrl, 0, 0, group_offset);
        if (boothdr.power_on_mm) {
            s->pds_regs[BL808_PDS_CTL2_OFFSET / 4] = 0;
        }
    }
    if (s->have_lp_entry) {
        s->pds_regs[BL808_PDS_CPU_CORE_CFG13_OFFSET / 4] = (uint32_t)s->lp_entry;
    } else if (boothdr.valid && boothdr.cpu_enabled[2] && !boothdr.cpu_halt[2]) {
        s->pds_regs[BL808_PDS_CPU_CORE_CFG13_OFFSET / 4] =
            (uint32_t)(BL808_FLASH_XIP_BASE + boothdr.cpu_image_offset[2]);
    } else if (!s->strict_fidelity) {
        s->pds_regs[BL808_PDS_CPU_CORE_CFG13_OFFSET / 4] =
            (uint32_t)BL808_LP_FLASH_XIP_BASE;
    }
    s->hbn_regs[BL808_HBN_GLB_OFFSET / 4] = 0x2u;
    if (s->have_d0_entry) {
        s->soc.mm_misc.regs[BL808_MM_MISC_CPU0_BOOT / 4] = (uint32_t)s->d0_entry;
    } else if (boothdr.valid && boothdr.cpu_enabled[1] && !boothdr.cpu_halt[1]) {
        s->soc.mm_misc.regs[BL808_MM_MISC_CPU0_BOOT / 4] =
            (uint32_t)(BL808_FLASH_XIP_BASE + boothdr.cpu_image_offset[1]);
    } else if (!s->strict_fidelity && !s->boot_gpio39) {
        s->soc.mm_misc.regs[BL808_MM_MISC_CPU0_BOOT / 4] =
            (uint32_t)BL808_FLASH_XIP_BASE;
    } else {
        s->soc.mm_misc.regs[BL808_MM_MISC_CPU0_BOOT / 4] =
            BL808_MM_MISC_CPU0_BOOT_RESET;
    }
    s->soc.sf_ctrl.reset_xip_offset[1][0] =
        (boothdr.valid && boothdr.cpu_enabled[1] && !boothdr.cpu_halt[1]) ?
            (boothdr.flash_offset + boothdr.group_image_offset) :
        ((!s->strict_fidelity && !s->boot_gpio39) ? BL808_FLASH_OFFSET_D0_IMAGE
                                                  : 0);
    bl808_sf_ctrl_set_flash_image_offset(&s->soc.sf_ctrl, 1, 0,
                                         s->soc.sf_ctrl.reset_xip_offset[1][0]);
    bl808_ef_ctrl_reset(s);
    bl808_ir_reset(s);
    bl808_ble_reset(s);
    bl808_wifi_mac_reset(s);
    bl808_wifi_ipc_reset(s);
    bl808_reset_regbanks(s);
    bl808_apply_boot_gpio39(s);
    bl808_apply_pds_gpio_levels(s);
    bl808_apply_aon_gpio_levels(s);
    bl808_hbn_apply_aon_pad_ctrl(s);
    bl808_soc_refresh_timer0_clocks(s);
    bl808_soc_refresh_timer1_clocks(s);
    bl808_soc_refresh_mcu_uart_clocks(s);
    bl808_soc_refresh_mcu_i2c_clocks(s);
    bl808_soc_refresh_mm_uart_i2c_clocks(s);

    if (s->have_m0_entry) {
        bl808_set_cpu_running(CPU(s->soc.m0_cpu), s->m0_entry);
    } else {
        bl808_set_cpu_running(CPU(s->soc.m0_cpu), BL808_BOOTROM_BASE);
    }

    bl808_update_mm_domain_state(s,
                                 bl808_pds_mm_powered_on(
                                     s->pds_regs[BL808_PDS_CTL2_OFFSET / 4]),
                                 true);
#ifdef TARGET_RISCV64
    bl808_update_lp_state(s, true);
#endif
}

static void bl808_machine_init(MachineState *machine)
{
    BL808MachineState *s = BL808_MACHINE(machine);
    Error *local_err = NULL;

    object_initialize_child(OBJECT(machine), "soc", &s->soc, TYPE_BL808_SOC);
    s->soc.strict_fidelity = s->strict_fidelity;
    s->soc.expose_core_id_shortcut = s->expose_core_id_shortcut;
    s->soc.attach_default_eeproms = s->attach_default_eeproms;
    s->soc.sec_eng.efuse_shadow = s->efuse_shadow;
    s->soc.sec_eng.efuse_words = ARRAY_SIZE(s->efuse_shadow);
    qemu_configure_nic_device(DEVICE(&s->soc.emac), true, NULL);

    if (!bl808_prepare_board_backends(s, machine, &local_err)) {
        error_report_err(local_err);
        exit(1);
    }

    if (!sysbus_realize(SYS_BUS_DEVICE(&s->soc), &local_err)) {
        error_report_err(local_err);
        exit(1);
    }

    if (!bl808_attach_sd_card(s, &local_err)) {
        error_report_err(local_err);
        exit(1);
    }

    if (!bl808_init_bootrom(s, &local_err)) {
        error_report_err(local_err);
        exit(1);
    }

    bl808_init_ir(s);
    bl808_init_pds(s);
    bl808_init_hbn(s);
    bl808_init_hbn_ram(s, &local_err);
    if (local_err) {
        error_report_err(local_err);
        exit(1);
    }
    bl808_init_ef_ctrl(s);
    bl808_init_ble(s);
    bl808_init_wifi_mac(s);
    bl808_init_regbanks(s);
    bl808_refresh_cached_irqs(s);
    if (s->soc.glb && !s->glb_pds_wakeup_irq) {
        s->glb_pds_wakeup_irq =
            qemu_allocate_irq(bl808_glb_pds_wakeup_set, s, 0);
        sysbus_connect_irq(SYS_BUS_DEVICE(s->soc.glb), 2,
                           s->glb_pds_wakeup_irq);
    }
    if (s->soc.glb && !s->pds_gpio_level_irqs) {
        s->pds_gpio_level_irqs =
            qemu_allocate_irqs(bl808_pds_gpio_level_set, s,
                               BL808_GLB_GPIO_PINS);
        for (unsigned pin = 0; pin < BL808_GLB_GPIO_PINS; pin++) {
            qdev_connect_gpio_out_named(s->soc.glb, "gpio-level", pin,
                                        s->pds_gpio_level_irqs[pin]);
        }
    }
    s->hbn_gpio_sample_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL,
                                            bl808_hbn_gpio_sample_cb, s);
    s->hbn_aon_level_irqs =
        qemu_allocate_irqs(bl808_hbn_gpio_level_set, s, BL808_HBN_AON_PINS);
    for (unsigned i = 0; i < BL808_HBN_AON_PINS; i++) {
        qdev_connect_gpio_out_named(s->soc.glb, "gpio-level",
                                    bl808_hbn_aon_gpio_map[i],
                                    s->hbn_aon_level_irqs[i]);
    }
    bl808_pds_update_irq(s);
    bl808_hbn_update_irqs(s);
    bl808_ir_update_irq(s);

    /* Load M0 firmware ELF -- bare-metal, no bootloader */
    if (machine->kernel_filename) {
        if (load_elf_ram_sym(machine->kernel_filename, NULL, NULL, NULL,
                             &s->m0_entry, NULL, NULL, NULL, 0, EM_RISCV,
                             1, 0, NULL, true, NULL) <= 0) {
            error_report("Could not load kernel '%s'",
                         machine->kernel_filename);
            exit(1);
        }
        s->have_m0_entry = true;
    }

    bl808_sync_flash_xip_to_sf_ctrl(&s->soc);

#ifdef TARGET_RISCV64
    if (s->d0_firmware) {
        if (load_elf_ram_sym(s->d0_firmware, NULL, NULL, NULL,
                             &s->d0_entry, NULL, NULL, NULL, 0, EM_RISCV,
                             1, 0, NULL, true, NULL) <= 0) {
            error_report("Could not load D0 firmware '%s'", s->d0_firmware);
            exit(1);
        }
        s->have_d0_entry = true;
    }

    if (s->lp_firmware) {
        if (load_elf_ram_sym(s->lp_firmware, NULL, NULL, NULL,
                             &s->lp_entry, NULL, NULL, NULL, 0, EM_RISCV,
                             1, 0, NULL, true, NULL) <= 0) {
            error_report("Could not load LP firmware '%s'", s->lp_firmware);
            exit(1);
        }
        s->have_lp_entry = true;
    }
#endif

    qemu_register_reset(bl808_machine_reset, s);
    bl808_machine_reset(s);
}

#define BL808_DEFINE_MACHINE_STR_ACCESSORS(field)                           \
static char *bl808_get_##field(Object *obj, Error **errp)                   \
{                                                                           \
    BL808MachineState *s = BL808_MACHINE(obj);                              \
    return g_strdup(s->field);                                              \
}                                                                           \
                                                                            \
static void bl808_set_##field(Object *obj, const char *value, Error **errp) \
{                                                                           \
    BL808MachineState *s = BL808_MACHINE(obj);                              \
    g_free(s->field);                                                       \
    s->field = g_strdup(value);                                             \
}

#define BL808_MACHINE_STRING_PROPERTIES(_)                                          \
    _(flash_image, "flash-image", "Path to Ox64 SPI flash image")                  \
    _(bootrom_image, "bootrom-image", "Path to an external 128 KiB BL808 Boot ROM image") \
    _(d0_firmware, "d0-firmware", "Path to D0 core (C906) firmware ELF")           \
    _(lp_firmware, "lp-firmware", "Path to LP core (E902) firmware ELF")           \
    _(sd_image, "sd-image", "Path to board SD-card image")                         \
    _(usb_role, "usb-role", "Board USB role/backend selector")                     \
    _(camera_source, "camera-source", "Host camera source for MM capture blocks")  \
    _(display_sink, "display-sink", "Host display sink for DBI/MIPI output")       \
    _(net_phy, "net-phy", "Board Ethernet PHY backend selector")                   \
    _(wifi_backend, "wifi-backend", "Host Wi-Fi backend selector")                 \
    _(ble_backend, "ble-backend", "Host BLE backend selector")                     \
    _(zigbee_backend, "zigbee-backend", "Host Zigbee backend selector")

#define BL808_MACHINE_PDS_GPIO_PROPERTIES(_)                                     \
    _(gpio0_level, 0, "gpio0-level", "External GPIO0 input level")              \
    _(gpio1_level, 1, "gpio1-level", "External GPIO1 input level")              \
    _(gpio2_level, 2, "gpio2-level", "External GPIO2 input level")              \
    _(gpio3_level, 3, "gpio3-level", "External GPIO3 input level")              \
    _(gpio4_level, 4, "gpio4-level", "External GPIO4 input level")              \
    _(gpio5_level, 5, "gpio5-level", "External GPIO5 input level")              \
    _(gpio6_level, 6, "gpio6-level", "External GPIO6 input level")              \
    _(gpio7_level, 7, "gpio7-level", "External GPIO7 input level")              \
    _(gpio8_level, 8, "gpio8-level", "External GPIO8 input level")              \
    _(gpio16_level, 16, "gpio16-level", "External GPIO16 input level")          \
    _(gpio17_level, 17, "gpio17-level", "External GPIO17 input level")          \
    _(gpio18_level, 18, "gpio18-level", "External GPIO18 input level")          \
    _(gpio19_level, 19, "gpio19-level", "External GPIO19 input level")          \
    _(gpio20_level, 20, "gpio20-level", "External GPIO20 input level")          \
    _(gpio21_level, 21, "gpio21-level", "External GPIO21 input level")          \
    _(gpio22_level, 22, "gpio22-level", "External GPIO22 input level")          \
    _(gpio23_level, 23, "gpio23-level", "External GPIO23 input level")          \
    _(gpio24_level, 24, "gpio24-level", "External GPIO24 input level")          \
    _(gpio25_level, 25, "gpio25-level", "External GPIO25 input level")          \
    _(gpio26_level, 26, "gpio26-level", "External GPIO26 input level")          \
    _(gpio27_level, 27, "gpio27-level", "External GPIO27 input level")          \
    _(gpio28_level, 28, "gpio28-level", "External GPIO28 input level")          \
    _(gpio29_level, 29, "gpio29-level", "External GPIO29 input level")          \
    _(gpio30_level, 30, "gpio30-level", "External GPIO30 input level")          \
    _(gpio31_level, 31, "gpio31-level", "External GPIO31 input level")          \
    _(gpio32_level, 32, "gpio32-level", "External GPIO32 input level")          \
    _(gpio33_level, 33, "gpio33-level", "External GPIO33 input level")          \
    _(gpio34_level, 34, "gpio34-level", "External GPIO34 input level")          \
    _(gpio35_level, 35, "gpio35-level", "External GPIO35 input level")          \
    _(gpio36_level, 36, "gpio36-level", "External GPIO36 input level")          \
    _(gpio37_level, 37, "gpio37-level", "External GPIO37 input level")          \
    _(gpio38_level, 38, "gpio38-level", "External GPIO38 input level")

#define BL808_MACHINE_PDS_GPIO_DRIVEN_PROPERTIES(_)                                      \
    _(gpio0_driven, 0, "gpio0-driven", "Whether external hardware drives GPIO0")        \
    _(gpio1_driven, 1, "gpio1-driven", "Whether external hardware drives GPIO1")        \
    _(gpio2_driven, 2, "gpio2-driven", "Whether external hardware drives GPIO2")        \
    _(gpio3_driven, 3, "gpio3-driven", "Whether external hardware drives GPIO3")        \
    _(gpio4_driven, 4, "gpio4-driven", "Whether external hardware drives GPIO4")        \
    _(gpio5_driven, 5, "gpio5-driven", "Whether external hardware drives GPIO5")        \
    _(gpio6_driven, 6, "gpio6-driven", "Whether external hardware drives GPIO6")        \
    _(gpio7_driven, 7, "gpio7-driven", "Whether external hardware drives GPIO7")        \
    _(gpio8_driven, 8, "gpio8-driven", "Whether external hardware drives GPIO8")        \
    _(gpio16_driven, 16, "gpio16-driven", "Whether external hardware drives GPIO16")    \
    _(gpio17_driven, 17, "gpio17-driven", "Whether external hardware drives GPIO17")    \
    _(gpio18_driven, 18, "gpio18-driven", "Whether external hardware drives GPIO18")    \
    _(gpio19_driven, 19, "gpio19-driven", "Whether external hardware drives GPIO19")    \
    _(gpio20_driven, 20, "gpio20-driven", "Whether external hardware drives GPIO20")    \
    _(gpio21_driven, 21, "gpio21-driven", "Whether external hardware drives GPIO21")    \
    _(gpio22_driven, 22, "gpio22-driven", "Whether external hardware drives GPIO22")    \
    _(gpio23_driven, 23, "gpio23-driven", "Whether external hardware drives GPIO23")    \
    _(gpio24_driven, 24, "gpio24-driven", "Whether external hardware drives GPIO24")    \
    _(gpio25_driven, 25, "gpio25-driven", "Whether external hardware drives GPIO25")    \
    _(gpio26_driven, 26, "gpio26-driven", "Whether external hardware drives GPIO26")    \
    _(gpio27_driven, 27, "gpio27-driven", "Whether external hardware drives GPIO27")    \
    _(gpio28_driven, 28, "gpio28-driven", "Whether external hardware drives GPIO28")    \
    _(gpio29_driven, 29, "gpio29-driven", "Whether external hardware drives GPIO29")    \
    _(gpio30_driven, 30, "gpio30-driven", "Whether external hardware drives GPIO30")    \
    _(gpio31_driven, 31, "gpio31-driven", "Whether external hardware drives GPIO31")    \
    _(gpio32_driven, 32, "gpio32-driven", "Whether external hardware drives GPIO32")    \
    _(gpio33_driven, 33, "gpio33-driven", "Whether external hardware drives GPIO33")    \
    _(gpio34_driven, 34, "gpio34-driven", "Whether external hardware drives GPIO34")    \
    _(gpio35_driven, 35, "gpio35-driven", "Whether external hardware drives GPIO35")    \
    _(gpio36_driven, 36, "gpio36-driven", "Whether external hardware drives GPIO36")    \
    _(gpio37_driven, 37, "gpio37-driven", "Whether external hardware drives GPIO37")    \
    _(gpio38_driven, 38, "gpio38-driven", "Whether external hardware drives GPIO38")

#define BL808_MACHINE_AON_GPIO_PROPERTIES(_)                                        \
    _(aon_gpio9_level, 0, "aon-gpio9-level", "External AON GPIO9 input level")    \
    _(aon_gpio10_level, 1, "aon-gpio10-level", "External AON GPIO10 input level") \
    _(aon_gpio11_level, 2, "aon-gpio11-level", "External AON GPIO11 input level") \
    _(aon_gpio12_level, 3, "aon-gpio12-level", "External AON GPIO12 input level") \
    _(aon_gpio13_level, 4, "aon-gpio13-level", "External AON GPIO13 input level") \
    _(aon_gpio14_level, 5, "aon-gpio14-level", "External AON GPIO14 input level") \
    _(aon_gpio15_level, 6, "aon-gpio15-level", "External AON GPIO15 input level") \
    _(aon_gpio40_level, 7, "aon-gpio40-level", "External AON GPIO40 input level") \
    _(aon_gpio41_level, 8, "aon-gpio41-level", "External AON GPIO41 input level")

#define BL808_MACHINE_AON_GPIO_DRIVEN_PROPERTIES(_)                                         \
    _(aon_gpio9_driven, 0, "aon-gpio9-driven", "Whether external hardware drives AON GPIO9")    \
    _(aon_gpio10_driven, 1, "aon-gpio10-driven", "Whether external hardware drives AON GPIO10") \
    _(aon_gpio11_driven, 2, "aon-gpio11-driven", "Whether external hardware drives AON GPIO11") \
    _(aon_gpio12_driven, 3, "aon-gpio12-driven", "Whether external hardware drives AON GPIO12") \
    _(aon_gpio13_driven, 4, "aon-gpio13-driven", "Whether external hardware drives AON GPIO13") \
    _(aon_gpio14_driven, 5, "aon-gpio14-driven", "Whether external hardware drives AON GPIO14") \
    _(aon_gpio15_driven, 6, "aon-gpio15-driven", "Whether external hardware drives AON GPIO15") \
    _(aon_gpio40_driven, 7, "aon-gpio40-driven", "Whether external hardware drives AON GPIO40") \
    _(aon_gpio41_driven, 8, "aon-gpio41-driven", "Whether external hardware drives AON GPIO41")

#define BL808_DECLARE_STR_ACCESSOR(field, name, desc) \
    BL808_DEFINE_MACHINE_STR_ACCESSORS(field)
BL808_MACHINE_STRING_PROPERTIES(BL808_DECLARE_STR_ACCESSOR)
#undef BL808_DECLARE_STR_ACCESSOR

static void bl808_machine_finalize(Object *obj)
{
    BL808MachineState *s = BL808_MACHINE(obj);

    g_free(s->flash_image);
    g_free(s->bootrom_image);
    g_free(s->d0_firmware);
    g_free(s->lp_firmware);
    g_free(s->sd_image);
    g_free(s->usb_role);
    g_free(s->camera_source);
    g_free(s->display_sink);
    g_free(s->net_phy);
    g_free(s->wifi_backend);
    g_free(s->ble_backend);
    g_free(s->zigbee_backend);

    if (s->pds_wake_timer) {
        timer_free(s->pds_wake_timer);
    }
    if (s->pds_gpio_sample_timer) {
        timer_free(s->pds_gpio_sample_timer);
    }
    if (s->hbn_alarm_timer) {
        timer_free(s->hbn_alarm_timer);
    }
    if (s->hbn_alarm_rt_timer) {
        timer_free(s->hbn_alarm_rt_timer);
    }
    if (s->hbn_gpio_sample_timer) {
        timer_free(s->hbn_gpio_sample_timer);
    }
    if (s->hbn_gpio_delay_timer) {
        timer_free(s->hbn_gpio_delay_timer);
    }
    if (s->flash_blk) {
        blk_unref(s->flash_blk);
    }
    if (s->sd_blk) {
        blk_unref(s->sd_blk);
    }
    if (s->hbn_aon_level_irqs) {
        qemu_free_irqs(s->hbn_aon_level_irqs, BL808_HBN_AON_PINS);
    }
    if (s->pds_gpio_level_irqs) {
        qemu_free_irqs(s->pds_gpio_level_irqs, BL808_GLB_GPIO_PINS);
    }
    if (s->glb_pds_wakeup_irq) {
        qemu_free_irq(s->glb_pds_wakeup_irq);
    }
}

static bool bl808_get_strict_fidelity(Object *obj, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    return s->strict_fidelity;
}

static void bl808_set_strict_fidelity(Object *obj, bool value, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    s->strict_fidelity = value;
}

static bool bl808_get_boot_gpio39(Object *obj, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    return s->boot_gpio39;
}

static void bl808_set_boot_gpio39(Object *obj, bool value, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    s->boot_gpio39 = value;
}

static bool bl808_get_expose_core_id_shortcut(Object *obj, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    return s->expose_core_id_shortcut;
}

static void bl808_set_expose_core_id_shortcut(Object *obj, bool value,
                                              Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    s->expose_core_id_shortcut = value;
}

static bool bl808_get_attach_default_eeproms(Object *obj, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    return s->attach_default_eeproms;
}

static void bl808_set_attach_default_eeproms(Object *obj, bool value,
                                             Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    s->attach_default_eeproms = value;
}

static bool bl808_get_pds_gpio_level(Object *obj, Error **errp, unsigned pin)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    return s->gpio_level[pin];
}

static void bl808_set_pds_gpio_level(Object *obj, bool value, Error **errp,
                                     unsigned pin)
{
    BL808MachineState *s = BL808_MACHINE(obj);

    s->gpio_level[pin] = value;
    s->gpio_driven[pin] = true;
    if (s->soc.glb) {
        bl808_glb_set_gpio_input_state(s->soc.glb, pin, true, value);
    }
}

#define BL808_DEFINE_PDS_GPIO_ACCESSORS(field, index, name, desc)              \
static bool bl808_get_##field(Object *obj, Error **errp)                       \
{                                                                               \
    return bl808_get_pds_gpio_level(obj, errp, index);                         \
}                                                                               \
                                                                                \
static void bl808_set_##field(Object *obj, bool value, Error **errp)           \
{                                                                               \
    bl808_set_pds_gpio_level(obj, value, errp, index);                         \
}
BL808_MACHINE_PDS_GPIO_PROPERTIES(BL808_DEFINE_PDS_GPIO_ACCESSORS)
#undef BL808_DEFINE_PDS_GPIO_ACCESSORS

static bool bl808_get_pds_gpio_driven(Object *obj, Error **errp, unsigned pin)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    return s->gpio_driven[pin];
}

static void bl808_set_pds_gpio_driven(Object *obj, bool value, Error **errp,
                                      unsigned pin)
{
    BL808MachineState *s = BL808_MACHINE(obj);

    s->gpio_driven[pin] = value;
    if (s->soc.glb) {
        bl808_glb_set_gpio_input_state(s->soc.glb, pin,
                                       value, s->gpio_level[pin]);
    }
}

#define BL808_DEFINE_PDS_GPIO_DRIVEN_ACCESSORS(field, index, name, desc)       \
static bool bl808_get_##field(Object *obj, Error **errp)                        \
{                                                                                \
    return bl808_get_pds_gpio_driven(obj, errp, index);                         \
}                                                                                \
                                                                                 \
static void bl808_set_##field(Object *obj, bool value, Error **errp)            \
{                                                                                \
    bl808_set_pds_gpio_driven(obj, value, errp, index);                         \
}
BL808_MACHINE_PDS_GPIO_DRIVEN_PROPERTIES(BL808_DEFINE_PDS_GPIO_DRIVEN_ACCESSORS)
#undef BL808_DEFINE_PDS_GPIO_DRIVEN_ACCESSORS

static bool bl808_get_aon_gpio_level(Object *obj, Error **errp, unsigned index)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    return s->aon_gpio_level[index];
}

static void bl808_set_aon_gpio_level(Object *obj, bool value, Error **errp,
                                     unsigned index)
{
    BL808MachineState *s = BL808_MACHINE(obj);

    s->aon_gpio_level[index] = value;
    s->aon_gpio_driven[index] = true;
    if (s->soc.glb) {
        bl808_glb_set_gpio_input_state(s->soc.glb,
                                       bl808_hbn_aon_gpio_map[index],
                                       true, value);
    }
}

#define BL808_DEFINE_AON_GPIO_ACCESSORS(field, index, name, desc)              \
static bool bl808_get_##field(Object *obj, Error **errp)                       \
{                                                                               \
    return bl808_get_aon_gpio_level(obj, errp, index);                         \
}                                                                               \
                                                                                \
static void bl808_set_##field(Object *obj, bool value, Error **errp)           \
{                                                                               \
    bl808_set_aon_gpio_level(obj, value, errp, index);                         \
}
BL808_MACHINE_AON_GPIO_PROPERTIES(BL808_DEFINE_AON_GPIO_ACCESSORS)
#undef BL808_DEFINE_AON_GPIO_ACCESSORS

static bool bl808_get_aon_gpio_driven(Object *obj, Error **errp, unsigned index)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    return s->aon_gpio_driven[index];
}

static void bl808_set_aon_gpio_driven(Object *obj, bool value, Error **errp,
                                      unsigned index)
{
    BL808MachineState *s = BL808_MACHINE(obj);

    s->aon_gpio_driven[index] = value;
    if (s->soc.glb) {
        bl808_glb_set_gpio_input_state(s->soc.glb,
                                       bl808_hbn_aon_gpio_map[index],
                                       value, s->aon_gpio_level[index]);
    }
}

#define BL808_DEFINE_AON_GPIO_DRIVEN_ACCESSORS(field, index, name, desc)       \
static bool bl808_get_##field(Object *obj, Error **errp)                        \
{                                                                                \
    return bl808_get_aon_gpio_driven(obj, errp, index);                         \
}                                                                                \
                                                                                 \
static void bl808_set_##field(Object *obj, bool value, Error **errp)            \
{                                                                                \
    bl808_set_aon_gpio_driven(obj, value, errp, index);                         \
}
BL808_MACHINE_AON_GPIO_DRIVEN_PROPERTIES(BL808_DEFINE_AON_GPIO_DRIVEN_ACCESSORS)
#undef BL808_DEFINE_AON_GPIO_DRIVEN_ACCESSORS

static bool bl808_get_hbn_pir_level(Object *obj, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    return s->hbn_pir_level;
}

static void bl808_set_hbn_pir_level(Object *obj, bool value, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);

    s->hbn_pir_level = value;
    bl808_hbn_refresh_live_sources(s);
}

static bool bl808_get_hbn_bod_level(Object *obj, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    return s->hbn_bod_level;
}

static void bl808_set_hbn_bod_level(Object *obj, bool value, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);

    s->hbn_bod_level = value;
    bl808_hbn_refresh_live_sources(s);
}

static bool bl808_get_hbn_acomp0_level(Object *obj, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    return s->hbn_acomp0_level;
}

static void bl808_set_hbn_acomp0_level(Object *obj, bool value, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    bool old = s->hbn_acomp0_level;

    s->hbn_acomp0_level = value;
    bl808_hbn_note_acomp_transition(s, BL808_HBN_IRQ_ACOMP0_STAT,
                                    BL808_HBN_IRQ_ACOMP0_EN_SHIFT,
                                    old, value);
}

static bool bl808_get_hbn_acomp1_level(Object *obj, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    return s->hbn_acomp1_level;
}

static void bl808_set_hbn_acomp1_level(Object *obj, bool value, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    bool old = s->hbn_acomp1_level;

    s->hbn_acomp1_level = value;
    bl808_hbn_note_acomp_transition(s, BL808_HBN_IRQ_ACOMP1_STAT,
                                    BL808_HBN_IRQ_ACOMP1_EN_SHIFT,
                                    old, value);
}

static void bl808_get_irrx_data(Object *obj, Visitor *v,
                                const char *name, void *opaque,
                                Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    uint32_t value = s->irrx_inject_data;

    visit_type_uint32(v, name, &value, errp);
}

static void bl808_set_irrx_data(Object *obj, Visitor *v,
                                const char *name, void *opaque,
                                Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    uint32_t value;

    if (!visit_type_uint32(v, name, &value, errp)) {
        return;
    }
    s->irrx_inject_data = value;
}

static void bl808_get_irrx_data1(Object *obj, Visitor *v,
                                 const char *name, void *opaque,
                                 Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    uint32_t value = s->irrx_inject_data1;

    visit_type_uint32(v, name, &value, errp);
}

static void bl808_set_irrx_data1(Object *obj, Visitor *v,
                                 const char *name, void *opaque,
                                 Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    uint32_t value;

    if (!visit_type_uint32(v, name, &value, errp)) {
        return;
    }
    s->irrx_inject_data1 = value;
}

static void bl808_get_irrx_bitcount(Object *obj, Visitor *v,
                                    const char *name, void *opaque,
                                    Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    uint32_t value = s->irrx_inject_bits;

    visit_type_uint32(v, name, &value, errp);
}

static void bl808_set_irrx_bitcount(Object *obj, Visitor *v,
                                    const char *name, void *opaque,
                                    Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    uint32_t value;

    if (!visit_type_uint32(v, name, &value, errp)) {
        return;
    }
    if (value > 64) {
        error_setg(errp, "Property '%s.%s' must be 0..64 bits",
                   object_get_typename(obj), name);
        return;
    }
    s->irrx_inject_bits = value;
}

static bool bl808_get_irrx_inject(Object *obj, Error **errp)
{
    return false;
}

static void bl808_set_irrx_inject(Object *obj, bool value, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);

    if (!value) {
        return;
    }
    bl808_ir_inject_frame(s);
}

static bool bl808_get_wifi_wakeup_event(Object *obj, Error **errp)
{
    return false;
}

static bool bl808_get_m0_wifi_irq(Object *obj, Error **errp)
{
    return false;
}

static void bl808_set_m0_wifi_irq(Object *obj, bool value, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);

    if (!value) {
        return;
    }
    bl808_wifi_mac_raise_gen_bits(s, BL808_WIFI_MACHW_GEN_RX_COMPLETE);
}

static bool bl808_get_m0_bz_phy_irq(Object *obj, Error **errp)
{
    return false;
}

static void bl808_set_m0_bz_phy_irq(Object *obj, bool value, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);

    if (!value) {
        return;
    }
    bl808_pulse_irq(s->m0_bz_phy_irq);
}

static bool bl808_get_m0_ble_irq(Object *obj, Error **errp)
{
    return false;
}

static void bl808_set_m0_ble_irq(Object *obj, bool value, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);

    if (!value) {
        return;
    }
    bl808_ble_raise_bits(s, BL808_BLE_INT_FINE_TIMER);
}

static bool bl808_get_m0_wifi_ipc_pub_irq(Object *obj, Error **errp)
{
    return false;
}

static void bl808_set_m0_wifi_ipc_pub_irq(Object *obj, bool value, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);

    if (!value) {
        return;
    }
    s->wifi_ipc_pending_status2 |= BL808_WIFI_IPC_MSG_BIT;
    bl808_wifi_ipc_update_irq(s);
}

static bool bl808_get_d0_wl_all_irq(Object *obj, Error **errp)
{
    return false;
}

static void bl808_set_d0_wl_all_irq(Object *obj, bool value, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);

    if (!value) {
        return;
    }
    bl808_pulse_irq(s->d0_wl_all_irq);
}

static void bl808_get_wifi_ipc_status2_pending(Object *obj, Visitor *v,
                                               const char *name, void *opaque,
                                               Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    uint32_t value = s->wifi_ipc_pending_status2;

    visit_type_uint32(v, name, &value, errp);
}

static void bl808_set_wifi_ipc_status2_pending(Object *obj, Visitor *v,
                                               const char *name, void *opaque,
                                               Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    uint32_t value;

    if (!visit_type_uint32(v, name, &value, errp)) {
        return;
    }
    s->wifi_ipc_pending_status2 = value;
    bl808_wifi_ipc_update_irq(s);
}

static void bl808_get_ble_intrawstat_pending(Object *obj, Visitor *v,
                                             const char *name, void *opaque,
                                             Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    uint32_t value = bl808_ble_raw_status(s);

    visit_type_uint32(v, name, &value, errp);
}

static void bl808_set_ble_intrawstat_pending(Object *obj, Visitor *v,
                                             const char *name, void *opaque,
                                             Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);
    uint32_t value;

    if (!visit_type_uint32(v, name, &value, errp)) {
        return;
    }
    s->ble_regs[BL808_BLE_INTRAWSTAT_OFFSET / 4] = value & BL808_BLE_INT_MASK;
    bl808_ble_update_irq(s);
}

static bool bl808_get_wifi_ipc_msg_pending(Object *obj, Error **errp)
{
    return false;
}

static void bl808_set_wifi_ipc_msg_pending(Object *obj, bool value,
                                           Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);

    if (!value) {
        return;
    }
    s->wifi_ipc_pending_status2 |= BL808_WIFI_IPC_MSG_BIT;
    bl808_wifi_ipc_update_irq(s);
}

static bool bl808_get_wifi_mac_prim_tbtt(Object *obj, Error **errp)
{
    return false;
}

static void bl808_set_wifi_mac_prim_tbtt(Object *obj, bool value, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);

    if (!value) {
        return;
    }
    bl808_wifi_mac_raise_irq_bits(s, BL808_WIFI_MACHW_IRQ_PRIMARY_TBTT);
}

static bool bl808_get_wifi_mac_sec_tbtt(Object *obj, Error **errp)
{
    return false;
}

static void bl808_set_wifi_mac_sec_tbtt(Object *obj, bool value, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);

    if (!value) {
        return;
    }
    bl808_wifi_mac_raise_irq_bits(s, BL808_WIFI_MACHW_IRQ_SECONDARY_TBTT);
}

static bool bl808_get_wifi_mac_idle(Object *obj, Error **errp)
{
    return false;
}

static void bl808_set_wifi_mac_idle(Object *obj, bool value, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);

    if (!value) {
        return;
    }
    bl808_wifi_mac_raise_irq_bits(s, BL808_WIFI_MACHW_IRQ_IDLE);
}

static bool bl808_get_wifi_mac_gen_timer(Object *obj, Error **errp)
{
    return false;
}

static void bl808_set_wifi_mac_gen_timer(Object *obj, bool value, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);

    if (!value) {
        return;
    }
    bl808_wifi_mac_raise_gen_bits(s, BL808_WIFI_MACHW_GEN_TIMER);
}

static bool bl808_get_wifi_mac_gen_rx_timeout(Object *obj, Error **errp)
{
    return false;
}

static void bl808_set_wifi_mac_gen_rx_timeout(Object *obj, bool value,
                                              Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);

    if (!value) {
        return;
    }
    bl808_wifi_mac_raise_gen_bits(s, BL808_WIFI_MACHW_GEN_RX_TIMEOUT);
}

static bool bl808_get_wifi_mac_gen_rx_complete(Object *obj, Error **errp)
{
    return false;
}

static void bl808_set_wifi_mac_gen_rx_complete(Object *obj, bool value,
                                               Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);

    if (!value) {
        return;
    }
    bl808_wifi_mac_raise_gen_bits(s, BL808_WIFI_MACHW_GEN_RX_COMPLETE);
}

static void bl808_set_wifi_wakeup_event(Object *obj, bool value, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);

    if (!value) {
        return;
    }
    bl808_pds_trigger_wakeup(s, BL808_PDS_WAKEUP_SRC_WIFI_WKP);
}

static bool bl808_get_dm_sleep_irq(Object *obj, Error **errp)
{
    return false;
}

static void bl808_set_dm_sleep_irq(Object *obj, bool value, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);

    if (!value) {
        return;
    }
    bl808_pds_trigger_wakeup(s, BL808_PDS_WAKEUP_SRC_DM_SLP);
}

static bool bl808_get_wifi_tbtt_sleep(Object *obj, Error **errp)
{
    return false;
}

static void bl808_set_wifi_tbtt_sleep(Object *obj, bool value, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);

    if (!value) {
        return;
    }
    bl808_pds_trigger_wifi_tbtt(s, BL808_PDS_STATUS_WIFI_TBTT_SLEEP);
}

static bool bl808_get_wifi_tbtt_wakeup(Object *obj, Error **errp)
{
    return false;
}

static void bl808_set_wifi_tbtt_wakeup(Object *obj, bool value, Error **errp)
{
    BL808MachineState *s = BL808_MACHINE(obj);

    if (!value) {
        return;
    }
    bl808_pds_trigger_wifi_tbtt(s, BL808_PDS_STATUS_WIFI_TBTT_WAKEUP);
}

static void bl808_machine_instance_init(Object *obj)
{
    BL808MachineState *s = BL808_MACHINE(obj);

    s->irrx_inject_bits = 32;
    s->timer_glb_sys_cfg0 = 0x0003000F;
    s->timer_glb_sys_cfg1 = 0x00000000;
    s->timer_glb_dig_clk_cfg1 = 0x00000000;
    s->timer_glb_wifi_pll_cfg0 = 0x00000FFF;
    s->timer_glb_wifi_pll_cfg1 = 0x00010200;
    s->timer_glb_wifi_pll_cfg5 = 0x00001005;
    s->timer_glb_wifi_pll_cfg6 = 0x01800000;
    s->timer_glb_wifi_pll_cfg8 = 0x800000AE;
    s->glb_uart_cfg0 = 0x00000017;
    s->glb_i2c_cfg0 = 0x01FF0000;
    s->timer0_bclk_div_live = 3;
    s->timer1_mm_clk_ctrl_cpu = 0x00004005;
    s->timer1_mm_clk_cpu = 0x00000000;
    s->glb_swrst_cfg2 = 0x00000000;
    s->mm_sw_sys_reset = 0x00000000;
    s->mm_clk_ctrl_peri = 0x00810300;
    s->mm_clk_ctrl_peri3 = 0x00010300;
}

static void bl808_machine_class_init(ObjectClass *oc, void *data)
{
    MachineClass *mc = MACHINE_CLASS(oc);

    mc->desc = "Bouffalo Lab BL808 (Pine64 Ox64)";
    mc->init = bl808_machine_init;
#ifdef TARGET_RISCV64
    mc->max_cpus = 3;      /* M0 (E907) + D0 (C906) + LP (E902) */
    mc->default_cpus = 3;
#else
    mc->max_cpus = 1;      /* riscv32: M0 only (D0/LP need riscv64 target) */
    mc->default_cpus = 1;
#endif
    mc->min_cpus = 1;
    mc->default_cpu_type = TYPE_RISCV_CPU_THEAD_E907;

#define BL808_ADD_STR_PROPERTY(field, name, desc)          \
    object_class_property_add_str(oc, name,               \
        bl808_get_##field, bl808_set_##field);            \
    object_class_property_set_description(oc, name, desc);
    BL808_MACHINE_STRING_PROPERTIES(BL808_ADD_STR_PROPERTY)
#undef BL808_ADD_STR_PROPERTY

#define BL808_ADD_PDS_GPIO_PROPERTY(field, index, name, desc) \
    object_class_property_add_bool(oc, name,                  \
        bl808_get_##field, bl808_set_##field);                \
    object_class_property_set_description(oc, name, desc);
    BL808_MACHINE_PDS_GPIO_PROPERTIES(BL808_ADD_PDS_GPIO_PROPERTY)
#undef BL808_ADD_PDS_GPIO_PROPERTY

#define BL808_ADD_PDS_GPIO_DRIVEN_PROPERTY(field, index, name, desc) \
    object_class_property_add_bool(oc, name,                         \
        bl808_get_##field, bl808_set_##field);                       \
    object_class_property_set_description(oc, name, desc);
    BL808_MACHINE_PDS_GPIO_DRIVEN_PROPERTIES(BL808_ADD_PDS_GPIO_DRIVEN_PROPERTY)
#undef BL808_ADD_PDS_GPIO_DRIVEN_PROPERTY

#define BL808_ADD_AON_GPIO_PROPERTY(field, index, name, desc) \
    object_class_property_add_bool(oc, name,                  \
        bl808_get_##field, bl808_set_##field);                \
    object_class_property_set_description(oc, name, desc);
    BL808_MACHINE_AON_GPIO_PROPERTIES(BL808_ADD_AON_GPIO_PROPERTY)
#undef BL808_ADD_AON_GPIO_PROPERTY

#define BL808_ADD_AON_GPIO_DRIVEN_PROPERTY(field, index, name, desc) \
    object_class_property_add_bool(oc, name,                         \
        bl808_get_##field, bl808_set_##field);                       \
    object_class_property_set_description(oc, name, desc);
    BL808_MACHINE_AON_GPIO_DRIVEN_PROPERTIES(BL808_ADD_AON_GPIO_DRIVEN_PROPERTY)
#undef BL808_ADD_AON_GPIO_DRIVEN_PROPERTY

    object_class_property_add_bool(oc, "strict-fidelity",
        bl808_get_strict_fidelity, bl808_set_strict_fidelity);
    object_class_property_set_description(oc, "strict-fidelity",
        "Require flash boot, reject direct ELF injection, and only fail on "
        "requested board surfaces that still need non-BL808 shortcuts");
    object_class_property_add_bool(oc, "boot-gpio39",
        bl808_get_boot_gpio39, bl808_set_boot_gpio39);
    object_class_property_set_description(oc, "boot-gpio39",
        "Reset strap on GPIO39: off boots from flash, on enters download mode");
    object_class_property_add_bool(oc, "core-id-shortcut",
        bl808_get_expose_core_id_shortcut,
        bl808_set_expose_core_id_shortcut);
    object_class_property_set_description(oc, "core-id-shortcut",
        "Expose the non-hardware 0xF0000000 QEMU core-ID helper for "
        "firmware built specifically for emulation");
    object_class_property_add_bool(oc, "attach-default-eeproms",
        bl808_get_attach_default_eeproms,
        bl808_set_attach_default_eeproms);
    object_class_property_set_description(oc, "attach-default-eeproms",
        "Attach QEMU-only AT24C EEPROM helpers to the BL808 I2C buses");
    object_class_property_add_bool(oc, "hbn-pir-level",
        bl808_get_hbn_pir_level, bl808_set_hbn_pir_level);
    object_class_property_set_description(oc, "hbn-pir-level",
        "Current HBN PIR detector output level for HBN_OUT1 testing");
    object_class_property_add_bool(oc, "hbn-bod-level",
        bl808_get_hbn_bod_level, bl808_set_hbn_bod_level);
    object_class_property_set_description(oc, "hbn-bod-level",
        "Current HBN BOD detector output level for HBN_OUT1 testing");
    object_class_property_add_bool(oc, "hbn-acomp0-level",
        bl808_get_hbn_acomp0_level, bl808_set_hbn_acomp0_level);
    object_class_property_set_description(oc, "hbn-acomp0-level",
        "Current HBN ACOMP0 comparator output level for HBN_OUT1 testing");
    object_class_property_add_bool(oc, "hbn-acomp1-level",
        bl808_get_hbn_acomp1_level, bl808_set_hbn_acomp1_level);
    object_class_property_set_description(oc, "hbn-acomp1-level",
        "Current HBN ACOMP1 comparator output level for HBN_OUT1 testing");
    object_class_property_add(oc, "irrx-data", "uint32",
        bl808_get_irrx_data, bl808_set_irrx_data, NULL, NULL);
    object_class_property_set_description(oc, "irrx-data",
        "IR RX injector DATA_WORD0 payload");
    object_class_property_add(oc, "irrx-data1", "uint32",
        bl808_get_irrx_data1, bl808_set_irrx_data1, NULL, NULL);
    object_class_property_set_description(oc, "irrx-data1",
        "IR RX injector DATA_WORD1 payload");
    object_class_property_add(oc, "irrx-bitcount", "uint32",
        bl808_get_irrx_bitcount, bl808_set_irrx_bitcount, NULL, NULL);
    object_class_property_set_description(oc, "irrx-bitcount",
        "IR RX injector bit count; 0 keeps the 32-bit default");
    object_class_property_add_bool(oc, "irrx-inject",
        bl808_get_irrx_inject, bl808_set_irrx_inject);
    object_class_property_set_description(oc, "irrx-inject",
        "Pulse this property on to inject one IR RX frame");
    object_class_property_add(oc, "wifi-ipc-status2-pending", "uint32",
        bl808_get_wifi_ipc_status2_pending,
        bl808_set_wifi_ipc_status2_pending, NULL, NULL);
    object_class_property_set_description(oc, "wifi-ipc-status2-pending",
        "Raw pending bits presented by the native Wi-Fi embedded IPC status2 "
        "register at 0x4480011C");
    object_class_property_add(oc, "ble-intrawstat-pending", "uint32",
        bl808_get_ble_intrawstat_pending,
        bl808_set_ble_intrawstat_pending, NULL, NULL);
    object_class_property_set_description(oc, "ble-intrawstat-pending",
        "Raw pending bits presented by the native BLE controller INTRAWSTAT "
        "register at 0x28000014");
    object_class_property_add_bool(oc, "wifi-ipc-msg-pending",
        bl808_get_wifi_ipc_msg_pending, bl808_set_wifi_ipc_msg_pending);
    object_class_property_set_description(oc, "wifi-ipc-msg-pending",
        "Pulse this property on to raise the native Wi-Fi embedded IPC "
        "message-pending bit");
    object_class_property_add_bool(oc, "m0-wifi-irq",
        bl808_get_m0_wifi_irq, bl808_set_m0_wifi_irq);
    object_class_property_set_description(oc, "m0-wifi-irq",
        "Pulse this property on to inject one MAC RX-complete event through "
        "the native Wi-Fi MAC interrupt controller");
    object_class_property_add_bool(oc, "m0-bz-phy-irq",
        bl808_get_m0_bz_phy_irq, bl808_set_m0_bz_phy_irq);
    object_class_property_set_description(oc, "m0-bz-phy-irq",
        "Pulse this property on to inject one M0 BZ PHY IRQ");
    object_class_property_add_bool(oc, "m0-ble-irq",
        bl808_get_m0_ble_irq, bl808_set_m0_ble_irq);
    object_class_property_set_description(oc, "m0-ble-irq",
        "Pulse this property on to raise the native BLE fine-timer interrupt "
        "bit through the M0 BLE controller IRQ");
    object_class_property_add_bool(oc, "m0-wifi-ipc-pub-irq",
        bl808_get_m0_wifi_ipc_pub_irq, bl808_set_m0_wifi_ipc_pub_irq);
    object_class_property_set_description(oc, "m0-wifi-ipc-pub-irq",
        "Pulse this property on to raise the native Wi-Fi embedded IPC "
        "message-pending bit through the M0 Wi-Fi IPC PUB IRQ");
    object_class_property_add_bool(oc, "d0-wl-all-irq",
        bl808_get_d0_wl_all_irq, bl808_set_d0_wl_all_irq);
    object_class_property_set_description(oc, "d0-wl-all-irq",
        "Pulse this property on to inject one D0 WL_ALL PLIC IRQ");
    object_class_property_add_bool(oc, "wifi-mac-prim-tbtt",
        bl808_get_wifi_mac_prim_tbtt, bl808_set_wifi_mac_prim_tbtt);
    object_class_property_set_description(oc, "wifi-mac-prim-tbtt",
        "Pulse this property on to raise a primary TBTT event in the native "
        "Wi-Fi MAC interrupt controller");
    object_class_property_add_bool(oc, "wifi-mac-sec-tbtt",
        bl808_get_wifi_mac_sec_tbtt, bl808_set_wifi_mac_sec_tbtt);
    object_class_property_set_description(oc, "wifi-mac-sec-tbtt",
        "Pulse this property on to raise a secondary TBTT event in the "
        "native Wi-Fi MAC interrupt controller");
    object_class_property_add_bool(oc, "wifi-mac-idle",
        bl808_get_wifi_mac_idle, bl808_set_wifi_mac_idle);
    object_class_property_set_description(oc, "wifi-mac-idle",
        "Pulse this property on to raise a MAC idle event in the native "
        "Wi-Fi MAC interrupt controller");
    object_class_property_add_bool(oc, "wifi-mac-gen-timer",
        bl808_get_wifi_mac_gen_timer, bl808_set_wifi_mac_gen_timer);
    object_class_property_set_description(oc, "wifi-mac-gen-timer",
        "Pulse this property on to raise a MAC general timer event");
    object_class_property_add_bool(oc, "wifi-mac-gen-rx-timeout",
        bl808_get_wifi_mac_gen_rx_timeout,
        bl808_set_wifi_mac_gen_rx_timeout);
    object_class_property_set_description(oc, "wifi-mac-gen-rx-timeout",
        "Pulse this property on to raise a MAC general RX-timeout event");
    object_class_property_add_bool(oc, "wifi-mac-gen-rx-complete",
        bl808_get_wifi_mac_gen_rx_complete,
        bl808_set_wifi_mac_gen_rx_complete);
    object_class_property_set_description(oc, "wifi-mac-gen-rx-complete",
        "Pulse this property on to raise a MAC general RX-complete event");
    object_class_property_add_bool(oc, "wifi-wakeup-event",
        bl808_get_wifi_wakeup_event, bl808_set_wifi_wakeup_event);
    object_class_property_set_description(oc, "wifi-wakeup-event",
        "Pulse this property on to inject a PDS Wi-Fi wake event");
    object_class_property_add_bool(oc, "dm-sleep-irq",
        bl808_get_dm_sleep_irq, bl808_set_dm_sleep_irq);
    object_class_property_set_description(oc, "dm-sleep-irq",
        "Pulse this property on to inject a PDS DM sleep IRQ wake event");
    object_class_property_add_bool(oc, "wifi-tbtt-sleep",
        bl808_get_wifi_tbtt_sleep, bl808_set_wifi_tbtt_sleep);
    object_class_property_set_description(oc, "wifi-tbtt-sleep",
        "Pulse this property on to inject a PDS Wi-Fi TBTT sleep event");
    object_class_property_add_bool(oc, "wifi-tbtt-wakeup",
        bl808_get_wifi_tbtt_wakeup, bl808_set_wifi_tbtt_wakeup);
    object_class_property_set_description(oc, "wifi-tbtt-wakeup",
        "Pulse this property on to inject a PDS Wi-Fi TBTT wakeup event");
}

static const TypeInfo bl808_machine_info = {
    .name          = TYPE_BL808_MACHINE,
    .parent        = TYPE_MACHINE,
    .instance_size = sizeof(BL808MachineState),
    .instance_init = bl808_machine_instance_init,
    .instance_finalize = bl808_machine_finalize,
    .class_init    = bl808_machine_class_init,
};

static void bl808_register_types(void)
{
    type_register_static(&bl808_soc_info);
    type_register_static(&bl808_machine_info);
}

type_init(bl808_register_types)
