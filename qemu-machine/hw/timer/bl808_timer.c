/*
 * Bouffalo Lab BL808 timer/watchdog emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/timer.h"
#include "hw/timer/bl808_timer.h"
#include "system/runstate.h"

#define TIMER_TCCR         0x00
#define TIMER_TMR2_0       0x10
#define TIMER_TMR2_1       0x14
#define TIMER_TMR2_2       0x18
#define TIMER_TMR3_0       0x1C
#define TIMER_TMR3_1       0x20
#define TIMER_TMR3_2       0x24
#define TIMER_TCR2         0x2C
#define TIMER_TCR3         0x30
#define TIMER_TSR2         0x38
#define TIMER_TSR3         0x3C
#define TIMER_TIER2        0x44
#define TIMER_TIER3        0x48
#define TIMER_TPLVR2       0x50
#define TIMER_TPLVR3       0x54
#define TIMER_TPLCR2       0x5C
#define TIMER_TPLCR3       0x60
#define TIMER_WMER         0x64
#define TIMER_WMR          0x68
#define TIMER_WVR          0x6C
#define TIMER_WSR          0x70
#define TIMER_TICR2        0x78
#define TIMER_TICR3        0x7C
#define TIMER_WICR         0x80
#define TIMER_TCER         0x84
#define TIMER_TCMR         0x88
#define TIMER_TILR2        0x90
#define TIMER_TILR3        0x94
#define TIMER_WCR          0x98
#define TIMER_WFAR         0x9C
#define TIMER_WSAR         0xA0
#define TIMER_TCVWR2       0xA8
#define TIMER_TCVWR3       0xAC
#define TIMER_TCVSYN2      0xB4
#define TIMER_TCVSYN3      0xB8
#define TIMER_TCDR         0xBC
#define TIMER_TCDR_FORCE   0xCC

#define TCCR_CLK2_SRC_SHIFT 0
#define TCCR_CLK2_SRC_MASK 0x0F
#define TCCR_CLK3_SRC_SHIFT 4
#define TCCR_CLK3_SRC_MASK (0x0F << 4)
#define TCCR_WDT_SRC_SHIFT 8
#define TCCR_WDT_SRC_MASK  (0x0F << 8)
#define TCCR_WRITABLE_MASK (TCCR_CLK2_SRC_MASK | TCCR_CLK3_SRC_MASK | \
                            TCCR_WDT_SRC_MASK)
#define TCCR_RESET_VALUE   ((1u << TCCR_WDT_SRC_SHIFT) | \
                            (5u << TCCR_CLK3_SRC_SHIFT) | 5u)
#define TCCR_ID_VALUE      0xA5u
#define TMR_RESET_VALUE    0xFFFFFFFFu

#define TCER_TIMER2_EN     BIT(1)
#define TCER_TIMER3_EN     BIT(2)
#define TCER_TIMER2_CLR    BIT(5)
#define TCER_TIMER3_CLR    BIT(6)

#define TCMR_TIMER2_MODE   BIT(1)
#define TCMR_TIMER3_MODE   BIT(2)
#define TCMR_TIMER2_ALIGN  BIT(5)
#define TCMR_TIMER3_ALIGN  BIT(6)

#define WMER_WDT_EN        BIT(0)
#define WMER_WDT_RST       BIT(1)
#define WMR_WDT_ALIGN      BIT(16)
#define WMR_WDT_MATCH_MASK 0xFFFFu

#define TCDR_TIMER2_SHIFT        8
#define TCDR_TIMER3_SHIFT        16
#define TCDR_WDT_SHIFT           24
#define TCDR_TIMER2_MASK         (0xFFu << TCDR_TIMER2_SHIFT)
#define TCDR_TIMER3_MASK         (0xFFu << TCDR_TIMER3_SHIFT)
#define TCDR_WDT_MASK            (0xFFu << TCDR_WDT_SHIFT)
#define TCDR_FORCE_TIMER2        BIT(1)
#define TCDR_FORCE_TIMER3        BIT(2)
#define TCDR_FORCE_WDT           BIT(4)
#define TCDR_FORCE_WRITABLE_MASK (TCDR_FORCE_TIMER2 | TCDR_FORCE_TIMER3 | \
                                  TCDR_FORCE_WDT)

#define WFAR_MAGIC         0xBABAu
#define WSAR_MAGIC         0xEB10u

static uint64_t bl808_timer_clock_base_hz(const BL808TimerState *s,
                                          uint32_t sel)
{
    switch (sel) {
    case 0:
        return s->bclk_hz;
    case 1:
        return s->f32k_hz;
    case 2:
        return 1000ULL;
    case 3:
        return s->xtal_hz;
    case 4:
    case 5:
    default:
        return 0;
    }
}

static uint32_t bl808_timer_channel_divider_mask(unsigned ch)
{
    return ch == 0 ? TCDR_TIMER2_MASK : TCDR_TIMER3_MASK;
}

static uint32_t bl808_timer_channel_divider_shift(unsigned ch)
{
    return ch == 0 ? TCDR_TIMER2_SHIFT : TCDR_TIMER3_SHIFT;
}

static uint64_t bl808_timer_source_hz(const BL808TimerState *s, unsigned ch)
{
    uint32_t sel = ch == 0 ? ((s->tccr & TCCR_CLK2_SRC_MASK) >>
                              TCCR_CLK2_SRC_SHIFT) :
                             ((s->tccr & TCCR_CLK3_SRC_MASK) >>
                              TCCR_CLK3_SRC_SHIFT);
    uint32_t divider = (s->tcdr_live & bl808_timer_channel_divider_mask(ch)) >>
                       bl808_timer_channel_divider_shift(ch);
    uint64_t base_hz = bl808_timer_clock_base_hz(s, sel);

    if (base_hz == 0) {
        return 0;
    }

    return base_hz / (divider + 1);
}

static bool bl808_timer_channel_enabled(const BL808TimerState *s, unsigned ch)
{
    uint32_t bit = ch == 0 ? TCER_TIMER2_EN : TCER_TIMER3_EN;

    return s->clock_enabled && !s->reset_asserted && (s->tcer & bit);
}

static bool bl808_timer_channel_preload(const BL808TimerState *s, unsigned ch)
{
    uint32_t bit = ch == 0 ? TCMR_TIMER2_MODE : TCMR_TIMER3_MODE;

    return !(s->tcmr & bit);
}

static bool bl808_timer_channel_align_enabled(const BL808TimerState *s,
                                              unsigned ch)
{
    return (s->tcmr & (ch == 0 ? TCMR_TIMER2_ALIGN : TCMR_TIMER3_ALIGN)) != 0;
}

static uint32_t bl808_timer_channel_initial_count(const BL808TimerState *s,
                                                  unsigned ch)
{
    return bl808_timer_channel_preload(s, ch) ? s->tplvr_live[ch] : 0;
}

static bool bl808_timer_channel_reload_match(const BL808TimerState *s,
                                             unsigned ch, uint32_t *match)
{
    uint32_t tplcr = s->tplcr_live[ch] & 0x3;

    if (!bl808_timer_channel_preload(s, ch) || tplcr == 0) {
        return false;
    }

    *match = s->tmr_live[ch][tplcr - 1];
    return true;
}

static uint32_t bl808_timer_channel_now(const BL808TimerState *s, unsigned ch,
                                        uint64_t now_ns)
{
    uint64_t rate = bl808_timer_source_hz(s, ch);
    uint64_t elapsed_ticks;

    if (!bl808_timer_channel_enabled(s, ch) || rate == 0) {
        return s->channel_count[ch];
    }

    elapsed_ticks = ((now_ns - s->channel_base_ns[ch]) * rate) / 1000000000ULL;
    return s->channel_count[ch] + (uint32_t)elapsed_ticks;
}

static void bl808_timer_channel_commit_now(BL808TimerState *s, unsigned ch,
                                           uint32_t count, uint64_t now_ns)
{
    s->channel_count[ch] = count;
    s->channel_base_ns[ch] = now_ns;
}

static void bl808_timer_channel_sync(BL808TimerState *s, unsigned ch)
{
    uint64_t now_ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);

    bl808_timer_channel_commit_now(s, ch,
                                   bl808_timer_channel_now(s, ch, now_ns),
                                   now_ns);
}

static void bl808_timer_channel_load_live_config(BL808TimerState *s,
                                                 unsigned ch)
{
    memcpy(s->tmr_live[ch], s->tmr[ch], sizeof(s->tmr_live[ch]));
    s->tplvr_live[ch] = s->tplvr[ch];
    s->tplcr_live[ch] = s->tplcr[ch] & 0x3;
    s->channel_update_pending[ch] = false;
}

static void bl808_timer_channel_clear_compare_state(BL808TimerState *s,
                                                    unsigned ch)
{
    memset(s->channel_compare_fired[ch], 0,
           sizeof(s->channel_compare_fired[ch]));
}

static void bl808_timer_channel_mark_passed_compares(BL808TimerState *s,
                                                     unsigned ch,
                                                     uint32_t current)
{
    for (unsigned i = 0; i < 3; i++) {
        s->channel_compare_fired[ch][i] = s->tmr_live[ch][i] <= current;
    }
}

static bool bl808_timer_channel_divider_pending(const BL808TimerState *s,
                                                unsigned ch)
{
    uint32_t mask = bl808_timer_channel_divider_mask(ch);

    return (s->tcdr & mask) != (s->tcdr_live & mask);
}

static void bl808_timer_channel_copy_programmed_divider(BL808TimerState *s,
                                                        unsigned ch)
{
    uint32_t mask = bl808_timer_channel_divider_mask(ch);

    s->tcdr_live = (s->tcdr_live & ~mask) | (s->tcdr & mask);
}

static void bl808_timer_channel_commit_divider(BL808TimerState *s, unsigned ch,
                                               uint64_t now_ns)
{
    bl808_timer_channel_commit_now(s, ch,
                                   bl808_timer_channel_now(s, ch, now_ns),
                                   now_ns);
    bl808_timer_channel_copy_programmed_divider(s, ch);
}

static bool bl808_timer_channel_level_irq_pending(const BL808TimerState *s,
                                                  unsigned ch)
{
    return (s->tsr[ch] & s->tier[ch] & ~s->tilr[ch] & 0x7) != 0;
}

static void bl808_timer_channel_pulse_irq(BL808TimerState *s, unsigned ch)
{
    if (!s->clock_enabled || s->reset_asserted) {
        return;
    }

    qemu_set_irq(s->irq[ch], 1);
    qemu_set_irq(s->irq[ch], 0);
}

static void bl808_timer_update_irq(BL808TimerState *s)
{
    for (unsigned ch = 0; ch < BL808_TIMER_CHANNELS; ch++) {
        qemu_set_irq(s->irq[ch],
                     s->clock_enabled && !s->reset_asserted &&
                     bl808_timer_channel_level_irq_pending(s, ch));
    }

    qemu_set_irq(s->irq[2],
                 s->clock_enabled && !s->reset_asserted && (s->wsr & 1) != 0);
}

static void bl808_timer_channel_reschedule(BL808TimerState *s, unsigned ch)
{
    uint32_t current;
    uint32_t next = UINT32_MAX;
    uint32_t reload_match = 0;
    bool reload_enabled;
    uint64_t now_ns;
    uint64_t rate;

    if (!bl808_timer_channel_enabled(s, ch)) {
        timer_del(s->channel_timer[ch]);
        return;
    }

    now_ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);
    current = bl808_timer_channel_now(s, ch, now_ns);
    rate = bl808_timer_source_hz(s, ch);

    if (rate == 0) {
        timer_del(s->channel_timer[ch]);
        return;
    }

    reload_enabled = bl808_timer_channel_reload_match(s, ch, &reload_match);
    for (int i = 0; i < 3; i++) {
        uint32_t cmp = s->tmr_live[ch][i];

        if (s->channel_compare_fired[ch][i] || cmp < current) {
            continue;
        }
        if (reload_enabled && cmp > reload_match) {
            continue;
        }
        next = MIN(next, cmp);
    }

    if (next == UINT32_MAX) {
        timer_del(s->channel_timer[ch]);
        return;
    }

    if (next <= current) {
        timer_mod(s->channel_timer[ch], now_ns + 1);
    } else {
        uint64_t delta_ticks = next - current;
        uint64_t delta_ns = MAX(1ULL, (delta_ticks * 1000000000ULL + rate - 1) /
                                      rate);

        timer_mod(s->channel_timer[ch], now_ns + delta_ns);
    }
}

static void bl808_timer_channel_event(BL808TimerState *s, unsigned ch)
{
    uint64_t now_ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);
    uint32_t current = bl808_timer_channel_now(s, ch, now_ns);
    uint32_t new_status = 0;
    uint32_t reload_match = 0;
    bool had_level_irq = bl808_timer_channel_level_irq_pending(s, ch);
    bool reload = bl808_timer_channel_reload_match(s, ch, &reload_match);
    bool reload_event = reload && current == reload_match;

    for (int i = 0; i < 3; i++) {
        if (!s->channel_compare_fired[ch][i] && s->tmr_live[ch][i] == current) {
            s->tsr[ch] |= BIT(i);
            s->channel_compare_fired[ch][i] = true;
            new_status |= BIT(i);
        }
    }

    if (reload_event) {
        if (s->channel_update_pending[ch]) {
            bl808_timer_channel_load_live_config(s, ch);
        }
        if (bl808_timer_channel_divider_pending(s, ch)) {
            bl808_timer_channel_copy_programmed_divider(s, ch);
        }
        bl808_timer_channel_clear_compare_state(s, ch);
        bl808_timer_channel_commit_now(s, ch,
                                       bl808_timer_channel_initial_count(s, ch),
                                       now_ns);
    } else {
        bl808_timer_channel_commit_now(s, ch, current, now_ns);
        if (s->channel_update_pending[ch] &&
            bl808_timer_channel_align_enabled(s, ch) &&
            new_status != 0) {
            bl808_timer_channel_load_live_config(s, ch);
            bl808_timer_channel_mark_passed_compares(s, ch, current);
        }
    }

    if ((new_status & s->tier[ch] & s->tilr[ch] & 0x7) != 0 &&
        !had_level_irq &&
        !bl808_timer_channel_level_irq_pending(s, ch)) {
        bl808_timer_channel_pulse_irq(s, ch);
    }

    bl808_timer_update_irq(s);
    bl808_timer_channel_reschedule(s, ch);
}

static void bl808_timer_channel0_cb(void *opaque)
{
    bl808_timer_channel_event(opaque, 0);
}

static void bl808_timer_channel1_cb(void *opaque)
{
    bl808_timer_channel_event(opaque, 1);
}

static uint64_t bl808_timer_wdt_hz(const BL808TimerState *s)
{
    uint32_t sel = (s->tccr & TCCR_WDT_SRC_MASK) >> TCCR_WDT_SRC_SHIFT;
    uint32_t divider = (s->tcdr_live & TCDR_WDT_MASK) >> TCDR_WDT_SHIFT;
    uint64_t base_hz = bl808_timer_clock_base_hz(s, sel);

    if (base_hz == 0) {
        return 0;
    }

    return base_hz / (divider + 1);
}

static bool bl808_timer_wdt_enabled(const BL808TimerState *s)
{
    return s->clock_enabled && !s->reset_asserted && (s->wmer & WMER_WDT_EN);
}

static uint32_t bl808_timer_wdt_now(const BL808TimerState *s, uint64_t now_ns)
{
    uint64_t rate = bl808_timer_wdt_hz(s);
    uint64_t elapsed_ticks;

    if (!bl808_timer_wdt_enabled(s) || rate == 0) {
        return s->wdt_count;
    }

    elapsed_ticks = ((now_ns - s->wdt_base_ns) * rate) / 1000000000ULL;
    return (s->wdt_count + (uint32_t)elapsed_ticks) & WMR_WDT_MATCH_MASK;
}

static void bl808_timer_wdt_commit_now(BL808TimerState *s, uint32_t count,
                                       uint64_t now_ns)
{
    s->wdt_count = count & WMR_WDT_MATCH_MASK;
    s->wdt_base_ns = now_ns;
}

static bool bl808_timer_wdt_align_enabled(const BL808TimerState *s)
{
    return (s->wmr & WMR_WDT_ALIGN) != 0;
}

static uint32_t bl808_timer_wdt_match_value(const BL808TimerState *s)
{
    return s->wmr_live & WMR_WDT_MATCH_MASK;
}

static bool bl808_timer_wdt_divider_pending(const BL808TimerState *s)
{
    return (s->tcdr & TCDR_WDT_MASK) != (s->tcdr_live & TCDR_WDT_MASK);
}

static void bl808_timer_wdt_copy_programmed_divider(BL808TimerState *s)
{
    s->tcdr_live = (s->tcdr_live & ~TCDR_WDT_MASK) | (s->tcdr & TCDR_WDT_MASK);
}

static void bl808_timer_wdt_commit_divider(BL808TimerState *s, uint64_t now_ns)
{
    bl808_timer_wdt_commit_now(s, bl808_timer_wdt_now(s, now_ns), now_ns);
    bl808_timer_wdt_copy_programmed_divider(s);
}

static void bl808_timer_wdt_apply_programmed(BL808TimerState *s)
{
    s->wmr_live = s->wmr & (WMR_WDT_ALIGN | WMR_WDT_MATCH_MASK);
    s->wdt_update_pending = false;
}

static bool bl808_timer_wdt_take_unlock(BL808TimerState *s)
{
    bool unlocked = s->wdt_unlocked;

    s->wdt_unlocked = false;
    return unlocked;
}

static void bl808_timer_wdt_reschedule(BL808TimerState *s)
{
    uint64_t now_ns;
    uint64_t rate;
    uint32_t current;

    if (!bl808_timer_wdt_enabled(s) || bl808_timer_wdt_match_value(s) == 0) {
        timer_del(s->wdt_timer);
        return;
    }

    now_ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);
    current = bl808_timer_wdt_now(s, now_ns);
    rate = bl808_timer_wdt_hz(s);

    if (current >= bl808_timer_wdt_match_value(s)) {
        timer_mod(s->wdt_timer, now_ns + 1);
        return;
    }

    timer_mod(s->wdt_timer,
              now_ns + MAX(1ULL, (((uint64_t)(bl808_timer_wdt_match_value(s) -
                                              current) *
                                   1000000000ULL) + rate - 1) / rate));
}

static void bl808_timer_wdt_fire(void *opaque)
{
    BL808TimerState *s = opaque;
    uint64_t now_ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);

    bl808_timer_wdt_commit_now(s, bl808_timer_wdt_match_value(s), now_ns);
    s->wsr |= 1;
    if (s->wdt_update_pending && bl808_timer_wdt_align_enabled(s)) {
        bl808_timer_wdt_apply_programmed(s);
    }
    bl808_timer_update_irq(s);

    if (s->wmer & WMER_WDT_RST) {
        qemu_system_reset_request(SHUTDOWN_CAUSE_GUEST_RESET);
        return;
    }

    bl808_timer_wdt_reschedule(s);
}

static void bl808_timer_sync_counters(BL808TimerState *s, uint64_t now_ns)
{
    for (unsigned ch = 0; ch < BL808_TIMER_CHANNELS; ch++) {
        bl808_timer_channel_commit_now(s, ch,
                                       bl808_timer_channel_now(s, ch, now_ns),
                                       now_ns);
    }

    bl808_timer_wdt_commit_now(s, bl808_timer_wdt_now(s, now_ns), now_ns);
}

static void bl808_timer_reset_hold(BL808TimerState *s)
{
    uint64_t now_ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);

    s->tccr = TCCR_RESET_VALUE;
    for (unsigned ch = 0; ch < BL808_TIMER_CHANNELS; ch++) {
        for (unsigned i = 0; i < 3; i++) {
            s->tmr[ch][i] = TMR_RESET_VALUE;
            s->tmr_live[ch][i] = TMR_RESET_VALUE;
        }
    }
    memset(s->tcr, 0, sizeof(s->tcr));
    memset(s->tsr, 0, sizeof(s->tsr));
    memset(s->tier, 0, sizeof(s->tier));
    memset(s->tplvr, 0, sizeof(s->tplvr));
    memset(s->tplvr_live, 0, sizeof(s->tplvr_live));
    memset(s->tplcr, 0, sizeof(s->tplcr));
    memset(s->tplcr_live, 0, sizeof(s->tplcr_live));
    memset(s->tilr, 0, sizeof(s->tilr));
    memset(s->channel_compare_fired, 0, sizeof(s->channel_compare_fired));
    memset(s->channel_update_pending, 0, sizeof(s->channel_update_pending));
    memset(s->tcvwr, 0, sizeof(s->tcvwr));
    s->tcvwr_read_mask = 0;
    s->tcer = 0;
    s->tcmr = 0;
    s->tcdr = 0;
    s->tcdr_live = 0;
    s->wmer = 0;
    s->wmr = WMR_WDT_MATCH_MASK;
    s->wmr_live = WMR_WDT_MATCH_MASK;
    s->wsr = 0;
    s->wcr = 0;
    s->tcdr_force = 0;
    s->wfar_seen = false;
    s->wdt_unlocked = false;
    s->wdt_update_pending = false;

    for (unsigned ch = 0; ch < BL808_TIMER_CHANNELS; ch++) {
        s->channel_count[ch] = 0;
        s->channel_base_ns[ch] = now_ns;
        timer_del(s->channel_timer[ch]);
    }

    s->wdt_count = 0;
    s->wdt_base_ns = now_ns;
    timer_del(s->wdt_timer);
    bl808_timer_update_irq(s);
}

void bl808_timer_set_clock_enabled(BL808TimerState *s, bool enabled)
{
    uint64_t now_ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);

    if (!s->channel_timer[0] || !s->channel_timer[1] || !s->wdt_timer) {
        s->clock_enabled = enabled;
        return;
    }

    bl808_timer_sync_counters(s, now_ns);
    s->clock_enabled = enabled;

    for (unsigned ch = 0; ch < BL808_TIMER_CHANNELS; ch++) {
        bl808_timer_channel_reschedule(s, ch);
    }
    bl808_timer_wdt_reschedule(s);
    bl808_timer_update_irq(s);
}

void bl808_timer_set_reset_asserted(BL808TimerState *s, bool asserted)
{
    s->reset_asserted = asserted;
    if (!s->channel_timer[0] || !s->channel_timer[1] || !s->wdt_timer) {
        return;
    }

    if (asserted) {
        bl808_timer_reset_hold(s);
    } else {
        bl808_timer_update_irq(s);
    }
}

void bl808_timer_set_clock_inputs(BL808TimerState *s, uint64_t bclk_hz,
                                  uint64_t xtal_hz, uint64_t f32k_hz)
{
    uint64_t now_ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);

    if (!s->channel_timer[0] || !s->channel_timer[1] || !s->wdt_timer) {
        s->bclk_hz = bclk_hz;
        s->xtal_hz = xtal_hz;
        s->f32k_hz = f32k_hz;
        return;
    }

    bl808_timer_sync_counters(s, now_ns);

    s->bclk_hz = bclk_hz;
    s->xtal_hz = xtal_hz;
    s->f32k_hz = f32k_hz;

    bl808_timer_channel_reschedule(s, 0);
    bl808_timer_channel_reschedule(s, 1);
    bl808_timer_wdt_reschedule(s);
    bl808_timer_update_irq(s);
}

static uint32_t bl808_timer_tcvwr_read(BL808TimerState *s, unsigned ch,
                                       uint64_t now_ns)
{
    if (s->tcvwr_read_mask == 0) {
        s->tcvwr[0] = bl808_timer_channel_now(s, 0, now_ns);
        s->tcvwr[1] = bl808_timer_channel_now(s, 1, now_ns);
    }

    s->tcvwr_read_mask |= BIT(ch);
    if ((s->tcvwr_read_mask & ((1u << BL808_TIMER_CHANNELS) - 1)) ==
        ((1u << BL808_TIMER_CHANNELS) - 1)) {
        s->tcvwr_read_mask = 0;
    }

    return s->tcvwr[ch];
}

static uint64_t bl808_timer_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808TimerState *s = opaque;
    uint64_t now_ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);

    switch (offset) {
    case TIMER_TCCR:
        return (TCCR_ID_VALUE << 24) | s->tccr;
    case TIMER_TMR2_0:
    case TIMER_TMR2_1:
    case TIMER_TMR2_2:
        return s->tmr[0][(offset - TIMER_TMR2_0) / 4];
    case TIMER_TMR3_0:
    case TIMER_TMR3_1:
    case TIMER_TMR3_2:
        return s->tmr[1][(offset - TIMER_TMR3_0) / 4];
    case TIMER_TCR2:
        return bl808_timer_channel_now(s, 0, now_ns);
    case TIMER_TCR3:
        return bl808_timer_channel_now(s, 1, now_ns);
    case TIMER_TSR2:
        return s->tsr[0];
    case TIMER_TSR3:
        return s->tsr[1];
    case TIMER_TIER2:
        return s->tier[0];
    case TIMER_TIER3:
        return s->tier[1];
    case TIMER_TPLVR2:
        return s->tplvr[0];
    case TIMER_TPLVR3:
        return s->tplvr[1];
    case TIMER_TPLCR2:
        return s->tplcr[0];
    case TIMER_TPLCR3:
        return s->tplcr[1];
    case TIMER_WMER:
        return s->wmer;
    case TIMER_WMR:
        return s->wmr & (WMR_WDT_ALIGN | WMR_WDT_MATCH_MASK);
    case TIMER_WVR:
        return bl808_timer_wdt_now(s, now_ns) & WMR_WDT_MATCH_MASK;
    case TIMER_WSR:
        return s->wsr;
    case TIMER_TCER:
        return s->tcer;
    case TIMER_TCMR:
        return s->tcmr;
    case TIMER_TILR2:
        return s->tilr[0];
    case TIMER_TILR3:
        return s->tilr[1];
    case TIMER_WCR:
        return s->wcr;
    case TIMER_TCVWR2:
        return bl808_timer_tcvwr_read(s, 0, now_ns);
    case TIMER_TCVWR3:
        return bl808_timer_tcvwr_read(s, 1, now_ns);
    case TIMER_TCVSYN2:
        return bl808_timer_channel_now(s, 0, now_ns);
    case TIMER_TCVSYN3:
        return bl808_timer_channel_now(s, 1, now_ns);
    case TIMER_TCDR:
        return s->tcdr;
    case TIMER_TCDR_FORCE:
        return s->tcdr_force;
    default:
        return 0;
    }
}

static void bl808_timer_write(void *opaque, hwaddr offset, uint64_t value,
                              unsigned size)
{
    BL808TimerState *s = opaque;
    uint64_t now_ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);

    switch (offset) {
    case TIMER_TCCR:
        bl808_timer_sync_counters(s, now_ns);
        s->tccr = (uint32_t)value & TCCR_WRITABLE_MASK;
        bl808_timer_channel_reschedule(s, 0);
        bl808_timer_channel_reschedule(s, 1);
        bl808_timer_wdt_reschedule(s);
        break;
    case TIMER_TMR2_0:
    case TIMER_TMR2_1:
    case TIMER_TMR2_2:
        bl808_timer_channel_sync(s, 0);
        s->tmr[0][(offset - TIMER_TMR2_0) / 4] = (uint32_t)value;
        if (bl808_timer_channel_enabled(s, 0) &&
            bl808_timer_channel_align_enabled(s, 0)) {
            s->channel_update_pending[0] = true;
        } else {
            bl808_timer_channel_load_live_config(s, 0);
            bl808_timer_channel_clear_compare_state(s, 0);
            bl808_timer_channel_reschedule(s, 0);
        }
        break;
    case TIMER_TMR3_0:
    case TIMER_TMR3_1:
    case TIMER_TMR3_2:
        bl808_timer_channel_sync(s, 1);
        s->tmr[1][(offset - TIMER_TMR3_0) / 4] = (uint32_t)value;
        if (bl808_timer_channel_enabled(s, 1) &&
            bl808_timer_channel_align_enabled(s, 1)) {
            s->channel_update_pending[1] = true;
        } else {
            bl808_timer_channel_load_live_config(s, 1);
            bl808_timer_channel_clear_compare_state(s, 1);
            bl808_timer_channel_reschedule(s, 1);
        }
        break;
    case TIMER_TCR2:
    case TIMER_TCR3:
        break;
    case TIMER_TIER2:
        s->tier[0] = (uint32_t)value & 0x7;
        bl808_timer_update_irq(s);
        break;
    case TIMER_TIER3:
        s->tier[1] = (uint32_t)value & 0x7;
        bl808_timer_update_irq(s);
        break;
    case TIMER_TPLVR2:
        bl808_timer_channel_sync(s, 0);
        s->tplvr[0] = (uint32_t)value;
        if (bl808_timer_channel_enabled(s, 0) &&
            bl808_timer_channel_align_enabled(s, 0)) {
            s->channel_update_pending[0] = true;
        } else {
            bl808_timer_channel_load_live_config(s, 0);
            bl808_timer_channel_mark_passed_compares(s, 0, s->channel_count[0]);
            bl808_timer_channel_reschedule(s, 0);
        }
        break;
    case TIMER_TPLVR3:
        bl808_timer_channel_sync(s, 1);
        s->tplvr[1] = (uint32_t)value;
        if (bl808_timer_channel_enabled(s, 1) &&
            bl808_timer_channel_align_enabled(s, 1)) {
            s->channel_update_pending[1] = true;
        } else {
            bl808_timer_channel_load_live_config(s, 1);
            bl808_timer_channel_mark_passed_compares(s, 1, s->channel_count[1]);
            bl808_timer_channel_reschedule(s, 1);
        }
        break;
    case TIMER_TPLCR2:
        bl808_timer_channel_sync(s, 0);
        s->tplcr[0] = (uint32_t)value & 0x3;
        if (bl808_timer_channel_enabled(s, 0) &&
            bl808_timer_channel_align_enabled(s, 0)) {
            s->channel_update_pending[0] = true;
        } else {
            bl808_timer_channel_load_live_config(s, 0);
            bl808_timer_channel_mark_passed_compares(s, 0, s->channel_count[0]);
            bl808_timer_channel_reschedule(s, 0);
        }
        break;
    case TIMER_TPLCR3:
        bl808_timer_channel_sync(s, 1);
        s->tplcr[1] = (uint32_t)value & 0x3;
        if (bl808_timer_channel_enabled(s, 1) &&
            bl808_timer_channel_align_enabled(s, 1)) {
            s->channel_update_pending[1] = true;
        } else {
            bl808_timer_channel_load_live_config(s, 1);
            bl808_timer_channel_mark_passed_compares(s, 1, s->channel_count[1]);
            bl808_timer_channel_reschedule(s, 1);
        }
        break;
    case TIMER_WMER:
    {
        uint32_t old_wmer;

        if (!bl808_timer_wdt_take_unlock(s)) {
            break;
        }
        bl808_timer_wdt_commit_now(s, bl808_timer_wdt_now(s, now_ns), now_ns);
        old_wmer = s->wmer;
        s->wmer = (uint32_t)value & (WMER_WDT_EN | WMER_WDT_RST);
        if ((old_wmer & WMER_WDT_EN) != (s->wmer & WMER_WDT_EN)) {
            if (bl808_timer_wdt_divider_pending(s)) {
                bl808_timer_wdt_copy_programmed_divider(s);
            }
            bl808_timer_wdt_apply_programmed(s);
        }
        bl808_timer_wdt_reschedule(s);
        break;
    }
    case TIMER_WMR:
        if (!bl808_timer_wdt_take_unlock(s)) {
            break;
        }
        bl808_timer_wdt_commit_now(s, bl808_timer_wdt_now(s, now_ns), now_ns);
        s->wmr = (s->wmr & ~((uint32_t)WMR_WDT_ALIGN | WMR_WDT_MATCH_MASK)) |
                 ((uint32_t)value & (WMR_WDT_ALIGN | WMR_WDT_MATCH_MASK));
        if (bl808_timer_wdt_enabled(s) && bl808_timer_wdt_align_enabled(s)) {
            s->wdt_update_pending = true;
        } else {
            bl808_timer_wdt_apply_programmed(s);
            bl808_timer_wdt_reschedule(s);
        }
        break;
    case TIMER_TICR2:
        s->tsr[0] &= ~((uint32_t)value & 0x7);
        bl808_timer_update_irq(s);
        break;
    case TIMER_TICR3:
        s->tsr[1] &= ~((uint32_t)value & 0x7);
        bl808_timer_update_irq(s);
        break;
    case TIMER_WICR:
        if (!bl808_timer_wdt_take_unlock(s)) {
            break;
        }
        if (value & 1) {
            s->wsr &= ~1u;
            bl808_timer_update_irq(s);
        }
        break;
    case TIMER_TCER:
    {
        uint32_t old_tcer;
        uint32_t new_tcer;

        bl808_timer_channel_sync(s, 0);
        bl808_timer_channel_sync(s, 1);
        old_tcer = s->tcer;
        new_tcer = (uint32_t)value & (TCER_TIMER2_EN | TCER_TIMER3_EN);
        s->tcer = new_tcer;
        if ((value & TCER_TIMER2_CLR) ||
            (!(old_tcer & TCER_TIMER2_EN) && (new_tcer & TCER_TIMER2_EN)) ||
            ((old_tcer & TCER_TIMER2_EN) && !(new_tcer & TCER_TIMER2_EN))) {
            bl808_timer_channel_load_live_config(s, 0);
            bl808_timer_channel_copy_programmed_divider(s, 0);
            bl808_timer_channel_clear_compare_state(s, 0);
            bl808_timer_channel_commit_now(s, 0,
                                           bl808_timer_channel_initial_count(s, 0),
                                           now_ns);
        }
        if ((value & TCER_TIMER3_CLR) ||
            (!(old_tcer & TCER_TIMER3_EN) && (new_tcer & TCER_TIMER3_EN)) ||
            ((old_tcer & TCER_TIMER3_EN) && !(new_tcer & TCER_TIMER3_EN))) {
            bl808_timer_channel_load_live_config(s, 1);
            bl808_timer_channel_copy_programmed_divider(s, 1);
            bl808_timer_channel_clear_compare_state(s, 1);
            bl808_timer_channel_commit_now(s, 1,
                                           bl808_timer_channel_initial_count(s, 1),
                                           now_ns);
        }
        bl808_timer_channel_reschedule(s, 0);
        bl808_timer_channel_reschedule(s, 1);
        break;
    }
    case TIMER_TCMR:
    {
        uint32_t old_tcmr;

        bl808_timer_channel_sync(s, 0);
        bl808_timer_channel_sync(s, 1);
        old_tcmr = s->tcmr;
        s->tcmr = (uint32_t)value;
        if ((old_tcmr ^ s->tcmr) & TCMR_TIMER2_MODE) {
            bl808_timer_channel_clear_compare_state(s, 0);
        }
        if ((old_tcmr ^ s->tcmr) & TCMR_TIMER3_MODE) {
            bl808_timer_channel_clear_compare_state(s, 1);
        }
        if (s->channel_update_pending[0] &&
            !bl808_timer_channel_align_enabled(s, 0)) {
            bl808_timer_channel_load_live_config(s, 0);
            bl808_timer_channel_mark_passed_compares(s, 0, s->channel_count[0]);
        }
        if (s->channel_update_pending[1] &&
            !bl808_timer_channel_align_enabled(s, 1)) {
            bl808_timer_channel_load_live_config(s, 1);
            bl808_timer_channel_mark_passed_compares(s, 1, s->channel_count[1]);
        }
        bl808_timer_channel_reschedule(s, 0);
        bl808_timer_channel_reschedule(s, 1);
        break;
    }
    case TIMER_TILR2:
        s->tilr[0] = (uint32_t)value;
        break;
    case TIMER_TILR3:
        s->tilr[1] = (uint32_t)value;
        break;
    case TIMER_WSR:
        if ((((uint32_t)value) & 1u) == 0) {
            s->wsr &= ~1u;
            bl808_timer_update_irq(s);
        }
        break;
    case TIMER_WCR:
        if (!bl808_timer_wdt_take_unlock(s)) {
            break;
        }
        s->wcr = (uint32_t)value & 1u;
        if (s->wcr) {
            if (bl808_timer_wdt_divider_pending(s)) {
                bl808_timer_wdt_copy_programmed_divider(s);
            }
            bl808_timer_wdt_apply_programmed(s);
            bl808_timer_wdt_commit_now(s, 0, now_ns);
            bl808_timer_wdt_reschedule(s);
        }
        break;
    case TIMER_WFAR:
        s->wfar_seen = (((uint32_t)value) & 0xFFFFu) == WFAR_MAGIC;
        s->wdt_unlocked = false;
        break;
    case TIMER_WSAR:
        if (s->wfar_seen && ((((uint32_t)value) & 0xFFFFu) == WSAR_MAGIC)) {
            s->wfar_seen = false;
            s->wdt_unlocked = true;
        } else {
            s->wfar_seen = false;
            s->wdt_unlocked = false;
        }
        break;
    case TIMER_TCDR:
        bl808_timer_channel_sync(s, 0);
        bl808_timer_channel_sync(s, 1);
        bl808_timer_wdt_commit_now(s, bl808_timer_wdt_now(s, now_ns), now_ns);
        s->tcdr = (uint32_t)value;
        if (!bl808_timer_channel_enabled(s, 0)) {
            bl808_timer_channel_copy_programmed_divider(s, 0);
        }
        if (!bl808_timer_channel_enabled(s, 1)) {
            bl808_timer_channel_copy_programmed_divider(s, 1);
        }
        if (!bl808_timer_wdt_enabled(s)) {
            bl808_timer_wdt_copy_programmed_divider(s);
        }
        break;
    case TIMER_TCDR_FORCE:
        s->tcdr_force = (uint32_t)value & TCDR_FORCE_WRITABLE_MASK;
        if (s->tcdr_force & TCDR_FORCE_TIMER2) {
            bl808_timer_channel_commit_divider(s, 0, now_ns);
            bl808_timer_channel_reschedule(s, 0);
        }
        if (s->tcdr_force & TCDR_FORCE_TIMER3) {
            bl808_timer_channel_commit_divider(s, 1, now_ns);
            bl808_timer_channel_reschedule(s, 1);
        }
        if (s->tcdr_force & TCDR_FORCE_WDT) {
            bl808_timer_wdt_commit_divider(s, now_ns);
            bl808_timer_wdt_reschedule(s);
        }
        break;
    default:
        break;
    }
}

static const MemoryRegionOps bl808_timer_ops = {
    .read = bl808_timer_read,
    .write = bl808_timer_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static void bl808_timer_reset(DeviceState *dev)
{
    BL808TimerState *s = BL808_TIMER(dev);

    s->clock_enabled = true;
    s->reset_asserted = false;
    bl808_timer_reset_hold(s);
}

static void bl808_timer_init(Object *obj)
{
    BL808TimerState *s = BL808_TIMER(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    memory_region_init_io(&s->iomem, obj, &bl808_timer_ops, s,
                          TYPE_BL808_TIMER, BL808_TIMER_REG_SIZE);
    sysbus_init_mmio(sbd, &s->iomem);
    sysbus_init_irq(sbd, &s->irq[0]);
    sysbus_init_irq(sbd, &s->irq[1]);
    sysbus_init_irq(sbd, &s->irq[2]);
    s->channel_timer[0] = timer_new_ns(QEMU_CLOCK_VIRTUAL,
                                       bl808_timer_channel0_cb, s);
    s->channel_timer[1] = timer_new_ns(QEMU_CLOCK_VIRTUAL,
                                       bl808_timer_channel1_cb, s);
    s->wdt_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL, bl808_timer_wdt_fire, s);
    s->clock_enabled = true;
    s->bclk_hz = 80000000ULL;
    s->xtal_hz = 40000000ULL;
    s->f32k_hz = 32768ULL;
}

static void bl808_timer_finalize(Object *obj)
{
    BL808TimerState *s = BL808_TIMER(obj);

    for (unsigned ch = 0; ch < BL808_TIMER_CHANNELS; ch++) {
        timer_free(s->channel_timer[ch]);
    }
    timer_free(s->wdt_timer);
}

static void bl808_timer_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    dc->realize = NULL;
    device_class_set_legacy_reset(dc, bl808_timer_reset);
}

static const TypeInfo bl808_timer_info = {
    .name          = TYPE_BL808_TIMER,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(BL808TimerState),
    .instance_init = bl808_timer_init,
    .instance_finalize = bl808_timer_finalize,
    .class_init    = bl808_timer_class_init,
};

static void bl808_timer_register_types(void)
{
    type_register_static(&bl808_timer_info);
}

type_init(bl808_timer_register_types)
