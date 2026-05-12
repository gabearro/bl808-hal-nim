/*
 * Bouffalo Lab BL808 PWM_V2 emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qemu/timer.h"
#include "hw/timer/bl808_pwm.h"

#define PWM_INT_CONFIG       0x00

#define PWM_MC_STRIDE        0x40
#define PWM_MC_BASE(mc)      (0x40 + ((mc) * PWM_MC_STRIDE))
#define PWM_MC_CONFIG0(mc)   (PWM_MC_BASE(mc) + 0x00)
#define PWM_MC_CONFIG1(mc)   (PWM_MC_BASE(mc) + 0x04)
#define PWM_MC_PERIOD(mc)    (PWM_MC_BASE(mc) + 0x08)
#define PWM_MC_DEAD_TIME(mc) (PWM_MC_BASE(mc) + 0x0C)
#define PWM_MC_CH0_THRE(mc)  (PWM_MC_BASE(mc) + 0x10)
#define PWM_MC_CH1_THRE(mc)  (PWM_MC_BASE(mc) + 0x14)
#define PWM_MC_CH2_THRE(mc)  (PWM_MC_BASE(mc) + 0x18)
#define PWM_MC_CH3_THRE(mc)  (PWM_MC_BASE(mc) + 0x1C)
#define PWM_MC_INT_STS(mc)   (PWM_MC_BASE(mc) + 0x20)
#define PWM_MC_INT_MASK(mc)  (PWM_MC_BASE(mc) + 0x24)
#define PWM_MC_INT_CLEAR(mc) (PWM_MC_BASE(mc) + 0x28)
#define PWM_MC_INT_EN(mc)    (PWM_MC_BASE(mc) + 0x2C)

/* PWM_MCx_CONFIG0 bits */
#define PWM_CLK_DIV_MASK     0xFFFF
#define PWM_STOP_ON_REPT     BIT(19)
#define PWM_SW_BREAK_EN      BIT(24)
#define PWM_EXT_BREAK_EN     BIT(25)
#define PWM_STOP_EN          BIT(27)
#define PWM_STOP_MODE        BIT(28)
#define PWM_STS_STOP         BIT(29)
#define PWM_CLK_SEL_SHIFT    30
#define PWM_CLK_SEL_MASK     (3u << PWM_CLK_SEL_SHIFT)

/* Interrupt bits */
#define PWM_INT_CH0L         BIT(0)
#define PWM_INT_CH0H         BIT(1)
#define PWM_INT_CH1L         BIT(2)
#define PWM_INT_CH1H         BIT(3)
#define PWM_INT_CH2L         BIT(4)
#define PWM_INT_CH2H         BIT(5)
#define PWM_INT_CH3L         BIT(6)
#define PWM_INT_CH3H         BIT(7)
#define PWM_INT_PRDE         BIT(8)
#define PWM_INT_BRK          BIT(9)
#define PWM_INT_REPT         BIT(10)
#define PWM_INT_ALL          ((1u << 11) - 1)

static uint32_t bl808_pwm_cfg0_read(const BL808PWMState *s, unsigned mc)
{
    uint32_t value = s->mc_config0[mc] & ~PWM_STS_STOP;

    if (s->reset_asserted || s->repeat_stop_active[mc] ||
        (s->mc_config0[mc] & PWM_STOP_EN)) {
        value |= PWM_STS_STOP;
    }
    return value;
}

static uint32_t bl808_pwm_int_config_read(const BL808PWMState *s)
{
    uint32_t value = s->int_config & ~0x3u;

    if (s->mc_int_sts[0] & PWM_INT_ALL) {
        value |= BIT(0);
    }
    if (s->mc_int_sts[1] & PWM_INT_ALL) {
        value |= BIT(1);
    }
    return value;
}

static void bl808_pwm_update_irq(BL808PWMState *s)
{
    uint32_t pending = 0;

    for (unsigned mc = 0; mc < BL808_PWM_MC_COUNT; mc++) {
        pending |= s->mc_int_sts[mc] & s->mc_int_en[mc] & ~s->mc_int_mask[mc];
    }

    qemu_set_irq(s->irq,
                 s->clock_enabled && !s->reset_asserted && pending != 0);
}

static bool bl808_pwm_running(const BL808PWMState *s, unsigned mc)
{
    return s->clock_enabled && !s->reset_asserted &&
           !s->repeat_stop_active[mc] &&
           !(s->mc_config0[mc] & PWM_STOP_EN);
}

static uint64_t bl808_pwm_base_hz(const BL808PWMState *s, unsigned mc)
{
    switch ((s->mc_config0[mc] & PWM_CLK_SEL_MASK) >> PWM_CLK_SEL_SHIFT) {
    case 0:
        return 40000000ULL; /* XTAL */
    case 1:
        return 32000000ULL; /* BCLK boot default */
    case 2:
        return 32000ULL;    /* F32K */
    default:
        return 32000000ULL;
    }
}

static uint64_t bl808_pwm_period_ns(const BL808PWMState *s, unsigned mc)
{
    uint64_t clk_div = (s->mc_config0[mc] & PWM_CLK_DIV_MASK) + 1;
    uint64_t period = (s->mc_period[mc] & 0xFFFF) + 1;
    uint64_t base_hz = bl808_pwm_base_hz(s, mc);
    uint64_t ticks = clk_div * period;

    return ((ticks * 1000000000ULL) + base_hz - 1) / base_hz;
}

static void bl808_pwm_reschedule(BL808PWMState *s, unsigned mc)
{
    if (!bl808_pwm_running(s, mc)) {
        timer_del(s->period_timer[mc]);
        return;
    }

    timer_mod(s->period_timer[mc],
              qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) +
              MAX((uint64_t)1, bl808_pwm_period_ns(s, mc)));
}

static void bl808_pwm_raise_threshold_irqs(BL808PWMState *s, unsigned mc)
{
    static const uint32_t low_bits[4] = {
        PWM_INT_CH0L, PWM_INT_CH1L, PWM_INT_CH2L, PWM_INT_CH3L,
    };
    static const uint32_t high_bits[4] = {
        PWM_INT_CH0H, PWM_INT_CH1H, PWM_INT_CH2H, PWM_INT_CH3H,
    };

    for (int ch = 0; ch < 4; ch++) {
        if (!(s->mc_config1[mc] & BIT(ch * 4))) {
            continue;
        }
        if ((s->mc_thre[mc][ch] & 0xFFFF) != 0) {
            s->mc_int_sts[mc] |= low_bits[ch];
        }
        if ((s->mc_thre[mc][ch] >> 16) != 0) {
            s->mc_int_sts[mc] |= high_bits[ch];
        }
    }
}

static void bl808_pwm_period_tick(BL808PWMState *s, unsigned mc)
{
    uint32_t repeat_target = s->mc_period[mc] >> 16;

    if (!bl808_pwm_running(s, mc)) {
        return;
    }

    s->mc_int_sts[mc] |= PWM_INT_PRDE;
    bl808_pwm_raise_threshold_irqs(s, mc);

    if (repeat_target != 0) {
        s->repeat_count[mc]++;
        if (s->repeat_count[mc] >= repeat_target) {
            s->repeat_count[mc] = 0;
            s->mc_int_sts[mc] |= PWM_INT_REPT;
            if (s->mc_config0[mc] & PWM_STOP_ON_REPT) {
                s->repeat_stop_active[mc] = true;
            }
        }
    }

    bl808_pwm_update_irq(s);
    bl808_pwm_reschedule(s, mc);
}

static void bl808_pwm_period_tick_mc0(void *opaque)
{
    bl808_pwm_period_tick(opaque, 0);
}

static void bl808_pwm_period_tick_mc1(void *opaque)
{
    bl808_pwm_period_tick(opaque, 1);
}

static bool bl808_pwm_decode_mc_offset(hwaddr offset, unsigned *mc_out,
                                       hwaddr *rel_out)
{
    for (unsigned mc = 0; mc < BL808_PWM_MC_COUNT; mc++) {
        hwaddr base = PWM_MC_BASE(mc);

        if (offset >= base && offset < base + 0x30) {
            *mc_out = mc;
            *rel_out = offset - base;
            return true;
        }
    }

    return false;
}

static uint64_t bl808_pwm_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808PWMState *s = opaque;
    unsigned mc;
    hwaddr rel;

    if (offset == PWM_INT_CONFIG) {
        return bl808_pwm_int_config_read(s);
    }

    if (!bl808_pwm_decode_mc_offset(offset, &mc, &rel)) {
        return 0;
    }

    switch (rel) {
    case 0x00:
        return bl808_pwm_cfg0_read(s, mc);
    case 0x04:
        return s->mc_config1[mc];
    case 0x08:
        return s->mc_period[mc];
    case 0x0C:
        return s->mc_dead_time[mc];
    case 0x10:
    case 0x14:
    case 0x18:
    case 0x1C:
        return s->mc_thre[mc][(rel - 0x10) / 4];
    case 0x20:
        return s->mc_int_sts[mc];
    case 0x24:
        return s->mc_int_mask[mc];
    case 0x2C:
        return s->mc_int_en[mc];
    default:
        return 0;
    }
}

static void bl808_pwm_clear_all(BL808PWMState *s, unsigned mc)
{
    s->mc_int_sts[mc] = 0;
    if (s->repeat_stop_active[mc]) {
        s->repeat_stop_active[mc] = false;
        bl808_pwm_reschedule(s, mc);
    }
}

static void bl808_pwm_write(void *opaque, hwaddr offset, uint64_t value,
                            unsigned size)
{
    BL808PWMState *s = opaque;
    unsigned mc;
    hwaddr rel;

    if (s->reset_asserted) {
        return;
    }

    if (offset == PWM_INT_CONFIG) {
        if (value & BIT(8)) {
            bl808_pwm_clear_all(s, 0);
        }
        if (value & BIT(9)) {
            bl808_pwm_clear_all(s, 1);
        }
        s->int_config = 0;
        bl808_pwm_update_irq(s);
        return;
    }

    if (!bl808_pwm_decode_mc_offset(offset, &mc, &rel)) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_pwm: write to undefined offset 0x%" HWADDR_PRIx
                      " = 0x%" PRIx64 "\n", offset, value);
        return;
    }

    switch (rel) {
    case 0x00:
        s->mc_config0[mc] = (uint32_t)value & ~PWM_STS_STOP;
        s->repeat_count[mc] = 0;
        bl808_pwm_reschedule(s, mc);
        break;
    case 0x04:
        s->mc_config1[mc] = (uint32_t)value;
        break;
    case 0x08:
        s->mc_period[mc] = (uint32_t)value;
        s->repeat_count[mc] = 0;
        bl808_pwm_reschedule(s, mc);
        break;
    case 0x0C:
        s->mc_dead_time[mc] = (uint32_t)value;
        break;
    case 0x10:
    case 0x14:
    case 0x18:
    case 0x1C:
        s->mc_thre[mc][(rel - 0x10) / 4] = (uint32_t)value;
        break;
    case 0x24:
        s->mc_int_mask[mc] = (uint32_t)value & PWM_INT_ALL;
        break;
    case 0x28:
    {
        uint32_t cleared = (uint32_t)value & PWM_INT_ALL;

        s->mc_int_sts[mc] &= ~cleared;
        if ((cleared & PWM_INT_REPT) && s->repeat_stop_active[mc]) {
            s->repeat_stop_active[mc] = false;
            bl808_pwm_reschedule(s, mc);
        }
        break;
    }
    case 0x2C:
        s->mc_int_en[mc] = (uint32_t)value & PWM_INT_ALL;
        break;
    default:
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_pwm: write to undefined offset 0x%" HWADDR_PRIx
                      " = 0x%" PRIx64 "\n", offset, value);
        return;
    }

    bl808_pwm_update_irq(s);
}

static const MemoryRegionOps bl808_pwm_ops = {
    .read = bl808_pwm_read,
    .write = bl808_pwm_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static void bl808_pwm_reset(DeviceState *dev)
{
    BL808PWMState *s = BL808_PWM(dev);

    s->int_config = 0;
    for (unsigned mc = 0; mc < BL808_PWM_MC_COUNT; mc++) {
        s->mc_config0[mc] = PWM_STOP_MODE | (0xFu << 20);
        s->mc_config1[mc] = 0x00FF8888;
        s->mc_period[mc] = 0;
        s->mc_dead_time[mc] = 0;
        memset(s->mc_thre[mc], 0, sizeof(s->mc_thre[mc]));
        s->mc_int_sts[mc] = 0;
        s->mc_int_mask[mc] = PWM_INT_ALL;
        s->mc_int_en[mc] = PWM_INT_ALL;
        s->repeat_count[mc] = 0;
        s->repeat_stop_active[mc] = false;
        timer_del(s->period_timer[mc]);
    }
    bl808_pwm_update_irq(s);
}

void bl808_pwm_set_clock_enabled(BL808PWMState *s, bool enabled)
{
    s->clock_enabled = enabled;
    for (unsigned mc = 0; mc < BL808_PWM_MC_COUNT; mc++) {
        bl808_pwm_reschedule(s, mc);
    }
    bl808_pwm_update_irq(s);
}

void bl808_pwm_set_reset_asserted(BL808PWMState *s, bool asserted)
{
    s->reset_asserted = asserted;
    if (asserted) {
        device_cold_reset(DEVICE(s));
    } else {
        for (unsigned mc = 0; mc < BL808_PWM_MC_COUNT; mc++) {
            bl808_pwm_reschedule(s, mc);
        }
    }
    bl808_pwm_update_irq(s);
}

static void bl808_pwm_init(Object *obj)
{
    BL808PWMState *s = BL808_PWM(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    memory_region_init_io(&s->iomem, obj, &bl808_pwm_ops, s,
                          TYPE_BL808_PWM, BL808_PWM_REG_SIZE);
    sysbus_init_mmio(sbd, &s->iomem);
    sysbus_init_irq(sbd, &s->irq);
    s->period_timer[0] = timer_new_ns(QEMU_CLOCK_VIRTUAL,
                                      bl808_pwm_period_tick_mc0, s);
    s->period_timer[1] = timer_new_ns(QEMU_CLOCK_VIRTUAL,
                                      bl808_pwm_period_tick_mc1, s);
    s->clock_enabled = true;
}

static void bl808_pwm_finalize(Object *obj)
{
    BL808PWMState *s = BL808_PWM(obj);

    for (unsigned mc = 0; mc < BL808_PWM_MC_COUNT; mc++) {
        timer_free(s->period_timer[mc]);
    }
}

static void bl808_pwm_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    device_class_set_legacy_reset(dc, bl808_pwm_reset);
}

static const TypeInfo bl808_pwm_info = {
    .name          = TYPE_BL808_PWM,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(BL808PWMState),
    .instance_init = bl808_pwm_init,
    .instance_finalize = bl808_pwm_finalize,
    .class_init    = bl808_pwm_class_init,
};

static void bl808_pwm_register_types(void)
{
    type_register_static(&bl808_pwm_info);
}

type_init(bl808_pwm_register_types)
