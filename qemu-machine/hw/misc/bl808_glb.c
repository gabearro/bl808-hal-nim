/*
 * BL808 GLB/MM_GLB control block emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qemu/timer.h"
#include "hw/qdev-properties.h"
#include "hw/irq.h"
#include "hw/misc/bl808_glb.h"
#include "system/runstate.h"

#define GLB_REG_COUNT          2048
#define GLB_GPIO_CFG_BASE      0x8C4
#define GLB_GPIO_PINS          BL808_GLB_GPIO_PINS
#define GLB_MAX_HOOKS          48
#define GLB_INVALID_OFFSET     ((hwaddr)-1)
#define GLB_F32K_HZ            32768ULL
#define GLB_F32K_PERIOD_NS     ((1000000000ULL + GLB_F32K_HZ - 1) / GLB_F32K_HZ)

#define GPIO_IE                BIT(0)
#define GPIO_SMT               BIT(1)
#define GPIO_PU                BIT(4)
#define GPIO_PD                BIT(5)
#define GPIO_OE                BIT(6)
#define GPIO_INT_CLR           BIT(20)
#define GPIO_INT_STAT          BIT(21)
#define GPIO_INT_MASK          BIT(22)
#define GPIO_O                 BIT(24)
#define GPIO_SET               BIT(25)
#define GPIO_CLR               BIT(26)
#define GPIO_I                 BIT(28)
#define GPIO_FUNC_SHIFT        8
#define GPIO_FUNC_MASK         0x1Fu
#define GPIO_INT_MODE_SHIFT    16
#define GPIO_INT_MODE_MASK     0xFu
#define GPIO_SWGPIO_FUNC       11

#define GLB_UART_CFG0          0x150
#define GLB_DMA_CFG0           0x130
#define GLB_EMI_CFG0           0x0E0
#define GLB_I2C_CFG0           0x180
#define GLB_SPI_CFG0           0x1B0
#define GLB_SYS_CFG0           0x090
#define GLB_SYS_CFG1           0x094
#define GLB_DIG_CLK_CFG1       0x254
#define GLB_WIFI_PLL_CFG0      0x810
#define GLB_WIFI_PLL_CFG1      0x814
#define GLB_WIFI_PLL_CFG5      0x824
#define GLB_WIFI_PLL_CFG6      0x828
#define GLB_WIFI_PLL_CFG8      0x830
#define GLB_SWRST_CFG1         0x544
#define GLB_SWRST_CFG2         0x548
#define GLB_CGEN_CFG1          0x584
#define GLB_CGEN_CFG2          0x588

#define MM_CLK_CTRL_CPU        0x00
#define MM_CLK_CPU             0x04
#define MM_CLK_CTRL_PERI       0x10
#define MM_CLK_CTRL_PERI3      0x18
#define MM_SW_RESET_PERI       0x44

#define GLB_REG_BCLK_DIV_ACT_PULSE  BIT(0)
#define GLB_STS_BCLK_PROT_DONE      BIT(2)
#define GLB_REG_PICO_CLK_DIV_ACT_PULSE BIT(16)
#define GLB_STS_PICO_CLK_PROT_DONE  BIT(18)

#define MM_GLB_REG_BCLK2X_DIV_ACT_PULSE BIT(18)
#define MM_GLB_STS_BCLK2X_PROT_DONE BIT(20)

#define GLB_SWRST_CFG2_CHIP_RESET BIT(5)

typedef struct BL808GLBHook BL808GLBHook;

struct BL808GLBHook {
    bool in_use;
    hwaddr gate_offset;
    uint32_t gate_mask;
    hwaddr reset_offset;
    uint32_t reset_mask;
    hwaddr config_offset;
    BL808GLBClockNotify clock_enable;
    BL808GLBResetNotify reset_assert;
    BL808GLBClockConfigNotify clock_config_update;
    void *opaque;
};

struct BL808GLBState {
    SysBusDevice parent_obj;
    MemoryRegion iomem;
    qemu_irq irq[3];
    qemu_irq gpio_out[GLB_GPIO_PINS];
    qemu_irq gpio_level[GLB_GPIO_PINS];
    QEMUTimer *gpio_sample_timer;
    uint32_t regs[GLB_REG_COUNT];
    BL808GLBHook hooks[GLB_MAX_HOOKS];
    uint8_t gpio_sample_history[GLB_GPIO_PINS];
    bool gpio_input[GLB_GPIO_PINS];
    bool gpio_input_driven[GLB_GPIO_PINS];
    bool gpio_output[GLB_GPIO_PINS];
    bool aon_hw_ctrl[GLB_GPIO_PINS];
    bool aon_hw_oe[GLB_GPIO_PINS];
    bool aon_hw_pu[GLB_GPIO_PINS];
    bool aon_hw_pd[GLB_GPIO_PINS];
    bool aon_retained_output[GLB_GPIO_PINS];
    bool aon_retained_oe[GLB_GPIO_PINS];
    bool aon_iso_mode;
    bool aon_hw_pupd_enable;
    bool mm_domain;
};

static bool bl808_glb_gpio_is_aon(unsigned pin)
{
    return (pin >= 9 && pin <= 15) || pin == 40 || pin == 41;
}

static bool bl808_glb_gpio_is_swgpio(uint32_t value)
{
    return ((value >> GPIO_FUNC_SHIFT) & GPIO_FUNC_MASK) == GPIO_SWGPIO_FUNC;
}

static bool bl808_glb_gpio_is_xtal32k(const BL808GLBState *s, unsigned pin,
                                      uint32_t value)
{
    bool oe_active;

    if (pin != 40 && pin != 41) {
        return false;
    }

    if (s->aon_iso_mode && s->aon_retained_oe[pin]) {
        return false;
    }

    oe_active = (bl808_glb_gpio_is_aon(pin) && s->aon_hw_ctrl[pin] &&
                 s->aon_hw_oe[pin]) ||
                (bl808_glb_gpio_is_swgpio(value) && (value & GPIO_OE));
    return !(value & GPIO_IE) && !oe_active;
}

static void bl808_glb_update_irq(BL808GLBState *s)
{
    bool pending = false;

    if (!s->mm_domain) {
        for (unsigned pin = 0; pin < GLB_GPIO_PINS; pin++) {
            uint32_t value = s->regs[(GLB_GPIO_CFG_BASE / 4) + pin];

            if ((value & GPIO_INT_STAT) && !(value & GPIO_INT_MASK)) {
                pending = true;
                break;
            }
        }
    }

    qemu_set_irq(s->irq[0], pending);
    qemu_set_irq(s->irq[1], pending);
    qemu_set_irq(s->irq[2], pending);
}

static unsigned bl808_glb_gpio_int_mode(uint32_t value)
{
    return (value >> GPIO_INT_MODE_SHIFT) & GPIO_INT_MODE_MASK;
}

static bool bl808_glb_gpio_irq_enabled(const BL808GLBState *s, unsigned pin,
                                       uint32_t value)
{
    return !s->mm_domain && pin < GLB_GPIO_PINS &&
           bl808_glb_gpio_is_swgpio(value) && (value & GPIO_IE) &&
           !(value & GPIO_INT_MASK);
}

static bool bl808_glb_gpio_output_level(const BL808GLBState *s, unsigned pin)
{
    if (bl808_glb_gpio_is_aon(pin) && s->aon_iso_mode &&
        s->aon_retained_oe[pin]) {
        return s->aon_retained_output[pin];
    }

    return s->gpio_output[pin];
}

static bool bl808_glb_gpio_output_enabled(const BL808GLBState *s, unsigned pin,
                                          uint32_t value)
{
    if (bl808_glb_gpio_is_aon(pin) && s->aon_iso_mode &&
        s->aon_retained_oe[pin]) {
        return true;
    }
    if (bl808_glb_gpio_is_aon(pin) && s->aon_hw_ctrl[pin] &&
        s->aon_hw_oe[pin]) {
        return true;
    }

    return bl808_glb_gpio_is_swgpio(value) && (value & GPIO_OE);
}

static bool bl808_glb_gpio_effective_level(const BL808GLBState *s, unsigned pin,
                                           uint32_t value)
{
    if (bl808_glb_gpio_output_enabled(s, pin, value)) {
        return bl808_glb_gpio_output_level(s, pin);
    }
    if (bl808_glb_gpio_is_xtal32k(s, pin, value)) {
        return false;
    }
    if (!s->gpio_input_driven[pin]) {
        if (bl808_glb_gpio_is_aon(pin) && s->aon_hw_ctrl[pin]) {
            if (!s->aon_iso_mode && s->aon_hw_pupd_enable &&
                (s->aon_hw_pu[pin] ^ s->aon_hw_pd[pin])) {
                return s->aon_hw_pu[pin];
            }
        } else if ((value & GPIO_PU) ^ (value & GPIO_PD)) {
            return (value & GPIO_PU) != 0;
        }
    }

    return s->gpio_input[pin];
}

static bool bl808_glb_gpio_drive_level(const BL808GLBState *s, unsigned pin,
                                       uint32_t value)
{
    return bl808_glb_gpio_output_enabled(s, pin, value) &&
           bl808_glb_gpio_output_level(s, pin);
}

static void bl808_glb_gpio_reset_history(BL808GLBState *s, unsigned pin,
                                         bool level)
{
    s->gpio_sample_history[pin] = level ? 0x7 : 0x0;
}

static bool bl808_glb_gpio_irq_immediate(unsigned mode, bool old_level,
                                         bool new_level)
{
    switch (mode) {
    case 5: /* async falling */
        return old_level && !new_level;
    case 6: /* async rising */
        return !old_level && new_level;
    default:
        return false;
    }
}

static bool bl808_glb_gpio_irq_sampled(unsigned mode, uint8_t history)
{
    switch (mode) {
    case 0: /* sync falling: HLL */
        return history == 0x4;
    case 1: /* sync rising: LHH */
        return history == 0x3;
    case 2: /* sync low: LLL */
    case 7: /* async low: LLL */
        return history == 0x0;
    case 3: /* sync high: HHH */
    case 8: /* async high: HHH */
        return history == 0x7;
    case 4: /* sync both: HLL or LHH */
        return history == 0x4 || history == 0x3;
    default:
        return false;
    }
}

static void bl808_glb_gpio_sample_tick(void *opaque)
{
    BL808GLBState *s = opaque;

    if (!s->mm_domain) {
        for (unsigned pin = 0; pin < GLB_GPIO_PINS; pin++) {
            uint32_t idx = (GLB_GPIO_CFG_BASE / 4) + pin;
            uint32_t value = s->regs[idx];
            bool level = bl808_glb_gpio_effective_level(s, pin, value);

            s->gpio_sample_history[pin] =
                ((s->gpio_sample_history[pin] << 1) | (level ? 1 : 0)) & 0x7;

            if (bl808_glb_gpio_irq_enabled(s, pin, value) &&
                bl808_glb_gpio_irq_sampled(bl808_glb_gpio_int_mode(value),
                                           s->gpio_sample_history[pin])) {
                s->regs[idx] |= GPIO_INT_STAT;
            }
        }
        bl808_glb_update_irq(s);
    }

    timer_mod(s->gpio_sample_timer,
              qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) + GLB_F32K_PERIOD_NS);
}

static void bl808_glb_gpio_commit_with_old_level(BL808GLBState *s, unsigned pin,
                                                 uint32_t old_value,
                                                 uint32_t new_value,
                                                 bool old_level)
{
    uint32_t idx = (GLB_GPIO_CFG_BASE / 4) + pin;

    s->gpio_output[pin] = (new_value & GPIO_O) != 0;

    bool new_level = bl808_glb_gpio_effective_level(s, pin, new_value);

    if (bl808_glb_gpio_irq_enabled(s, pin, new_value) &&
        bl808_glb_gpio_irq_immediate(bl808_glb_gpio_int_mode(new_value),
                                     old_level, new_level)) {
        new_value |= GPIO_INT_STAT;
    }

    if ((old_value ^ new_value) &
        (GPIO_IE | GPIO_INT_MASK |
         (GPIO_FUNC_MASK << GPIO_FUNC_SHIFT) |
         (GPIO_INT_MODE_MASK << GPIO_INT_MODE_SHIFT))) {
        bl808_glb_gpio_reset_history(s, pin, new_level);
    }

    if (new_level) {
        new_value |= GPIO_I;
    } else {
        new_value &= ~GPIO_I;
    }

    s->regs[idx] = new_value;
    qemu_set_irq(s->gpio_out[pin],
                 bl808_glb_gpio_drive_level(s, pin, new_value));
    qemu_set_irq(s->gpio_level[pin], new_level);
    bl808_glb_update_irq(s);
}

static void bl808_glb_gpio_commit(BL808GLBState *s, unsigned pin,
                                  uint32_t old_value, uint32_t new_value)
{
    bl808_glb_gpio_commit_with_old_level(
        s, pin, old_value, new_value,
        bl808_glb_gpio_effective_level(s, pin, old_value));
}

static void bl808_glb_gpio_input_set(void *opaque, int pin, int level)
{
    BL808GLBState *s = opaque;
    uint32_t idx;
    uint32_t old_value;
    bool old_level;

    if (pin < 0 || pin >= GLB_GPIO_PINS) {
        return;
    }

    idx = (GLB_GPIO_CFG_BASE / 4) + pin;
    old_value = s->regs[idx];
    old_level = bl808_glb_gpio_effective_level(s, pin, old_value);
    s->gpio_input_driven[pin] = true;
    s->gpio_input[pin] = level != 0;
    bl808_glb_gpio_commit_with_old_level(s, pin, old_value, old_value,
                                         old_level);
}

static bool bl808_glb_is_gpio_cfg(hwaddr offset, unsigned *pin_out)
{
    if (offset < GLB_GPIO_CFG_BASE ||
        offset >= GLB_GPIO_CFG_BASE + GLB_GPIO_PINS * 4) {
        return false;
    }

    if (pin_out) {
        *pin_out = (offset - GLB_GPIO_CFG_BASE) / 4;
    }
    return true;
}

static uint32_t bl808_glb_gpio_read(BL808GLBState *s, unsigned pin)
{
    uint32_t value = s->regs[(GLB_GPIO_CFG_BASE / 4) + pin];

    if (bl808_glb_gpio_effective_level(s, pin, value)) {
        value |= GPIO_I;
    } else {
        value &= ~GPIO_I;
    }
    return value;
}

static void bl808_glb_gpio_write(BL808GLBState *s, unsigned pin, uint32_t value)
{
    uint32_t idx = (GLB_GPIO_CFG_BASE / 4) + pin;
    uint32_t old = s->regs[idx];
    uint32_t next = value;

    /*
     * GPIO_CFGxx embeds atomic set/clear and W1C interrupt-clear bits. These
     * are commands, not persistent state bits.
     */
    next &= ~GPIO_I;
    next |= old & GPIO_INT_STAT;
    if (value & GPIO_SET) {
        next |= GPIO_O;
    }
    if (value & GPIO_CLR) {
        next &= ~GPIO_O;
    }
    if (value & GPIO_INT_CLR) {
        next &= ~GPIO_INT_STAT;
    }

    next &= ~(GPIO_SET | GPIO_CLR | GPIO_INT_CLR);

    bl808_glb_gpio_commit(s, pin, old, next);
}

static void bl808_glb_update_clients(BL808GLBState *s, hwaddr offset,
                                     uint32_t old_value, uint32_t new_value)
{
    for (size_t i = 0; i < ARRAY_SIZE(s->hooks); i++) {
        BL808GLBHook *hook = &s->hooks[i];

        if (!hook->in_use) {
            continue;
        }

        if (hook->gate_offset == offset && hook->clock_enable &&
            ((old_value ^ new_value) & hook->gate_mask)) {
            hook->clock_enable(hook->opaque, (new_value & hook->gate_mask) != 0);
        }
        if (hook->reset_offset == offset && hook->reset_assert &&
            ((old_value ^ new_value) & hook->reset_mask)) {
            hook->reset_assert(hook->opaque, (new_value & hook->reset_mask) != 0);
        }
        if (hook->config_offset == offset && hook->clock_config_update) {
            hook->clock_config_update(hook->opaque, offset, new_value);
        }
    }
}

static void bl808_glb_apply_defaults(BL808GLBState *s)
{
    memset(s->regs, 0, sizeof(s->regs));
    memset(s->gpio_sample_history, 0, sizeof(s->gpio_sample_history));
    memset(s->gpio_input, 0, sizeof(s->gpio_input));
    memset(s->gpio_input_driven, 0, sizeof(s->gpio_input_driven));
    memset(s->gpio_output, 0, sizeof(s->gpio_output));
    memset(s->aon_hw_ctrl, 0, sizeof(s->aon_hw_ctrl));
    memset(s->aon_hw_oe, 0, sizeof(s->aon_hw_oe));
    memset(s->aon_hw_pu, 0, sizeof(s->aon_hw_pu));
    memset(s->aon_hw_pd, 0, sizeof(s->aon_hw_pd));
    s->aon_hw_pupd_enable = false;
    if (!s->aon_iso_mode) {
        memset(s->aon_retained_output, 0, sizeof(s->aon_retained_output));
        memset(s->aon_retained_oe, 0, sizeof(s->aon_retained_oe));
    }

    if (s->mm_domain) {
        s->regs[MM_CLK_CTRL_CPU / 4] = 0x00004005;
        s->regs[MM_CLK_CPU / 4] = 0x00000000;
        s->regs[MM_CLK_CTRL_PERI / 4] = 0x00810300;
        s->regs[MM_CLK_CTRL_PERI3 / 4] = 0x00010300;
        s->regs[MM_SW_RESET_PERI / 4] = 0x00000000;
    } else {
        s->regs[GLB_SYS_CFG0 / 4] = 0x0003000F;
        s->regs[GLB_DIG_CLK_CFG1 / 4] = 0x00000000;
        s->regs[GLB_WIFI_PLL_CFG0 / 4] = 0x00000FFF;
        s->regs[GLB_WIFI_PLL_CFG1 / 4] = 0x00010200;
        s->regs[GLB_WIFI_PLL_CFG5 / 4] = 0x00001005;
        s->regs[GLB_WIFI_PLL_CFG6 / 4] = 0x01800000;
        s->regs[GLB_WIFI_PLL_CFG8 / 4] = 0x800000AE;
        s->regs[GLB_UART_CFG0 / 4] = 0x00000017;
        s->regs[GLB_DMA_CFG0 / 4] = 0xFF000000;
        s->regs[GLB_EMI_CFG0 / 4] = 0x00000000;
        s->regs[GLB_I2C_CFG0 / 4] = 0x01FF0000;
        s->regs[GLB_SWRST_CFG1 / 4] = 0x00000000;
        s->regs[GLB_CGEN_CFG1 / 4] = 0xFFFFFFFF;
        s->regs[GLB_CGEN_CFG2 / 4] = 0xFFFFFFFF;
        s->regs[GLB_SPI_CFG0 / 4] = 0x00000103;
    }
}

void bl808_glb_set_gpio_input_state(DeviceState *dev, unsigned pin,
                                    bool driven, bool level)
{
    BL808GLBState *s = BL808_GLB(dev);
    uint32_t idx;
    uint32_t old_value;
    bool old_level;

    if (pin >= GLB_GPIO_PINS) {
        return;
    }

    idx = (GLB_GPIO_CFG_BASE / 4) + pin;
    old_value = s->regs[idx];
    old_level = bl808_glb_gpio_effective_level(s, pin, old_value);
    s->gpio_input_driven[pin] = driven;
    s->gpio_input[pin] = level;
    bl808_glb_gpio_commit_with_old_level(s, pin, old_value, old_value,
                                         old_level);
}

void bl808_glb_set_aon_pad_ctrl(DeviceState *dev, unsigned pin,
                                bool hw_ctrl, bool hw_pupd_enable,
                                bool oe, bool pu, bool pd)
{
    BL808GLBState *s = BL808_GLB(dev);
    uint32_t idx;
    uint32_t old_value;

    if (pin >= GLB_GPIO_PINS || !bl808_glb_gpio_is_aon(pin)) {
        return;
    }

    idx = (GLB_GPIO_CFG_BASE / 4) + pin;
    old_value = s->regs[idx];
    s->aon_hw_ctrl[pin] = hw_ctrl;
    s->aon_hw_pupd_enable = hw_pupd_enable;
    s->aon_hw_oe[pin] = oe;
    s->aon_hw_pu[pin] = pu;
    s->aon_hw_pd[pin] = pd;
    bl808_glb_gpio_commit(s, pin, old_value, old_value);
}

void bl808_glb_set_aon_iso_mode(DeviceState *dev, bool iso_mode)
{
    BL808GLBState *s = BL808_GLB(dev);

    if (!s->aon_iso_mode && iso_mode) {
        for (unsigned pin = 0; pin < GLB_GPIO_PINS; pin++) {
            uint32_t value = s->regs[(GLB_GPIO_CFG_BASE / 4) + pin];

            if (!bl808_glb_gpio_is_aon(pin)) {
                continue;
            }

            s->aon_retained_output[pin] = s->gpio_output[pin];
            s->aon_retained_oe[pin] =
                (s->aon_hw_ctrl[pin] && s->aon_hw_oe[pin]) ||
                (bl808_glb_gpio_is_swgpio(value) && (value & GPIO_OE));
        }
    }

    s->aon_iso_mode = iso_mode;
    for (unsigned pin = 0; pin < GLB_GPIO_PINS; pin++) {
        uint32_t value = s->regs[(GLB_GPIO_CFG_BASE / 4) + pin];

        if (!bl808_glb_gpio_is_aon(pin)) {
            continue;
        }
        bl808_glb_gpio_commit(s, pin, value, value);
    }
}

void bl808_glb_register_device(DeviceState *dev,
                               hwaddr gate_offset, uint32_t gate_mask,
                               hwaddr reset_offset, uint32_t reset_mask,
                               hwaddr config_offset,
                               BL808GLBClockNotify clock_enable,
                               BL808GLBResetNotify reset_assert,
                               BL808GLBClockConfigNotify clock_config_update,
                               void *opaque)
{
    BL808GLBState *s = BL808_GLB(dev);

    for (size_t i = 0; i < ARRAY_SIZE(s->hooks); i++) {
        BL808GLBHook *hook = &s->hooks[i];

        if (hook->in_use) {
            continue;
        }

        hook->in_use = true;
        hook->gate_offset = gate_offset;
        hook->gate_mask = gate_mask;
        hook->reset_offset = reset_offset;
        hook->reset_mask = reset_mask;
        hook->config_offset = config_offset;
        hook->clock_enable = clock_enable;
        hook->reset_assert = reset_assert;
        hook->clock_config_update = clock_config_update;
        hook->opaque = opaque;

        if (clock_enable && gate_offset != GLB_INVALID_OFFSET) {
            clock_enable(opaque, (s->regs[gate_offset / 4] & gate_mask) != 0);
        }
        if (reset_assert && reset_offset != GLB_INVALID_OFFSET) {
            reset_assert(opaque, (s->regs[reset_offset / 4] & reset_mask) != 0);
        }
        if (clock_config_update && config_offset != GLB_INVALID_OFFSET) {
            clock_config_update(opaque, config_offset, s->regs[config_offset / 4]);
        }
        return;
    }

    qemu_log_mask(LOG_GUEST_ERROR,
                  "bl808_glb: exhausted device hook slots for %s\n",
                  object_get_typename(OBJECT(dev)));
}

static uint64_t bl808_glb_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808GLBState *s = opaque;
    unsigned pin;
    uint32_t idx = offset / 4;

    if (bl808_glb_is_gpio_cfg(offset, &pin)) {
        return bl808_glb_gpio_read(s, pin);
    }
    if (idx < GLB_REG_COUNT) {
        return s->regs[idx];
    }
    return 0;
}

static void bl808_glb_write(void *opaque, hwaddr offset, uint64_t value,
                            unsigned size)
{
    BL808GLBState *s = opaque;
    unsigned pin;
    uint32_t idx = offset / 4;
    uint32_t old_value;
    uint32_t next_value;
    bool chip_reset_requested;

    if (bl808_glb_is_gpio_cfg(offset, &pin)) {
        bl808_glb_gpio_write(s, pin, (uint32_t)value);
        return;
    }
    if (idx >= GLB_REG_COUNT) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_glb: write beyond register window @ 0x%"
                      HWADDR_PRIx " = 0x%" PRIx64 "\n", offset, value);
        return;
    }

    old_value = s->regs[idx];
    next_value = (uint32_t)value;
    chip_reset_requested = !s->mm_domain && offset == GLB_SWRST_CFG2 &&
        !(old_value & GLB_SWRST_CFG2_CHIP_RESET) &&
        (next_value & GLB_SWRST_CFG2_CHIP_RESET);
    if (!s->mm_domain && offset == GLB_SYS_CFG1) {
        next_value &= ~(GLB_STS_BCLK_PROT_DONE | GLB_STS_PICO_CLK_PROT_DONE);
        if (next_value & GLB_REG_BCLK_DIV_ACT_PULSE) {
            next_value |= GLB_STS_BCLK_PROT_DONE;
        }
        if (next_value & GLB_REG_PICO_CLK_DIV_ACT_PULSE) {
            next_value |= GLB_STS_PICO_CLK_PROT_DONE;
        }
    } else if (s->mm_domain && offset == MM_CLK_CTRL_CPU) {
        next_value &= ~MM_GLB_STS_BCLK2X_PROT_DONE;
        if (next_value & MM_GLB_REG_BCLK2X_DIV_ACT_PULSE) {
            next_value |= MM_GLB_STS_BCLK2X_PROT_DONE;
        }
    }
    s->regs[idx] = next_value;
    bl808_glb_update_clients(s, offset, old_value, next_value);
    if (chip_reset_requested) {
        qemu_system_reset_request(SHUTDOWN_CAUSE_GUEST_RESET);
    }
}

static const MemoryRegionOps bl808_glb_ops = {
    .read = bl808_glb_read,
    .write = bl808_glb_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static void bl808_glb_init(Object *obj)
{
    BL808GLBState *s = BL808_GLB(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    memory_region_init_io(&s->iomem, obj, &bl808_glb_ops, s,
                          TYPE_BL808_GLB, GLB_REG_COUNT * 4);
    sysbus_init_mmio(sbd, &s->iomem);
    sysbus_init_irq(sbd, &s->irq[0]);
    sysbus_init_irq(sbd, &s->irq[1]);
    sysbus_init_irq(sbd, &s->irq[2]);
    qdev_init_gpio_in_named(DEVICE(obj), bl808_glb_gpio_input_set,
                            "gpio-in", GLB_GPIO_PINS);
    qdev_init_gpio_out_named(DEVICE(obj), s->gpio_out,
                             "gpio-out", GLB_GPIO_PINS);
    qdev_init_gpio_out_named(DEVICE(obj), s->gpio_level,
                             "gpio-level", GLB_GPIO_PINS);
    s->gpio_sample_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL,
                                        bl808_glb_gpio_sample_tick, s);
}

static void bl808_glb_finalize(Object *obj)
{
    BL808GLBState *s = BL808_GLB(obj);

    timer_free(s->gpio_sample_timer);
}

static void bl808_glb_reset(DeviceState *dev)
{
    BL808GLBState *s = BL808_GLB(dev);

    bl808_glb_apply_defaults(s);
    for (unsigned pin = 0; pin < GLB_GPIO_PINS; pin++) {
        uint32_t value = s->regs[(GLB_GPIO_CFG_BASE / 4) + pin];

        bl808_glb_gpio_commit(s, pin, value, value);
        bl808_glb_gpio_reset_history(s, pin,
                                     bl808_glb_gpio_effective_level(s, pin,
                                                                    value));
    }
    for (size_t i = 0; i < ARRAY_SIZE(s->hooks); i++) {
        BL808GLBHook *hook = &s->hooks[i];

        if (!hook->in_use) {
            continue;
        }
        if (hook->clock_enable && hook->gate_offset != GLB_INVALID_OFFSET) {
            hook->clock_enable(hook->opaque,
                               (s->regs[hook->gate_offset / 4] &
                                hook->gate_mask) != 0);
        }
        if (hook->reset_assert && hook->reset_offset != GLB_INVALID_OFFSET) {
            hook->reset_assert(hook->opaque,
                               (s->regs[hook->reset_offset / 4] &
                                hook->reset_mask) != 0);
        }
        if (hook->clock_config_update &&
            hook->config_offset != GLB_INVALID_OFFSET) {
            hook->clock_config_update(hook->opaque, hook->config_offset,
                                      s->regs[hook->config_offset / 4]);
        }
    }
    bl808_glb_update_irq(s);
    if (s->mm_domain) {
        timer_del(s->gpio_sample_timer);
    } else {
        timer_mod(s->gpio_sample_timer,
                  qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) +
                  GLB_F32K_PERIOD_NS);
    }
}

static const Property bl808_glb_props[] = {
    DEFINE_PROP_BOOL("mm-domain", BL808GLBState, mm_domain, false),
};

static void bl808_glb_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    device_class_set_props(dc, bl808_glb_props);
    device_class_set_legacy_reset(dc, bl808_glb_reset);
}

static const TypeInfo bl808_glb_info = {
    .name          = TYPE_BL808_GLB,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(BL808GLBState),
    .instance_init = bl808_glb_init,
    .instance_finalize = bl808_glb_finalize,
    .class_init    = bl808_glb_class_init,
};

static void bl808_glb_register_types(void)
{
    type_register_static(&bl808_glb_info);
}

type_init(bl808_glb_register_types)
