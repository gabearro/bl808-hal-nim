/*
 * Bouffalo Lab BL808 timer/watchdog emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_TIMER_BL808_TIMER_H
#define HW_TIMER_BL808_TIMER_H

#include <stdbool.h>

#include "hw/irq.h"
#include "hw/sysbus.h"
#include "qemu/typedefs.h"
#include "qom/object.h"

#define TYPE_BL808_TIMER "bl808-timer"
#define BL808_TIMER_REG_SIZE 0xD0
#define BL808_TIMER_CHANNELS 2

typedef struct BL808TimerState BL808TimerState;
OBJECT_DECLARE_SIMPLE_TYPE(BL808TimerState, BL808_TIMER)

struct BL808TimerState {
    /*< private >*/
    SysBusDevice parent_obj;

    /*< public >*/
    MemoryRegion iomem;
    qemu_irq irq[3];
    QEMUTimer *channel_timer[BL808_TIMER_CHANNELS];
    QEMUTimer *wdt_timer;

    uint32_t tccr;
    uint32_t tmr[BL808_TIMER_CHANNELS][3];
    uint32_t tcr[BL808_TIMER_CHANNELS];
    uint32_t tsr[BL808_TIMER_CHANNELS];
    uint32_t tier[BL808_TIMER_CHANNELS];
    uint32_t tplvr[BL808_TIMER_CHANNELS];
    uint32_t tplcr[BL808_TIMER_CHANNELS];
    uint32_t tilr[BL808_TIMER_CHANNELS];
    uint32_t tcer;
    uint32_t tcmr;
    uint32_t tcdr;
    uint32_t wmer;
    uint32_t wmr;
    uint32_t wsr;
    uint32_t wcr;
    uint32_t tcdr_force;

    uint64_t bclk_hz;
    uint64_t xtal_hz;
    uint64_t f32k_hz;

    uint32_t tmr_live[BL808_TIMER_CHANNELS][3];
    uint32_t tplvr_live[BL808_TIMER_CHANNELS];
    uint32_t tplcr_live[BL808_TIMER_CHANNELS];
    uint32_t tcdr_live;
    uint32_t wmr_live;
    uint32_t tcvwr[BL808_TIMER_CHANNELS];
    uint32_t channel_count[BL808_TIMER_CHANNELS];
    uint64_t channel_base_ns[BL808_TIMER_CHANNELS];
    bool channel_compare_fired[BL808_TIMER_CHANNELS][3];
    bool channel_update_pending[BL808_TIMER_CHANNELS];
    uint8_t tcvwr_read_mask;

    uint32_t wdt_count;
    uint64_t wdt_base_ns;
    bool wfar_seen;
    bool wdt_unlocked;
    bool wdt_update_pending;

    bool clock_enabled;
    bool reset_asserted;
};

void bl808_timer_set_clock_enabled(BL808TimerState *s, bool enabled);
void bl808_timer_set_reset_asserted(BL808TimerState *s, bool asserted);
void bl808_timer_set_clock_inputs(BL808TimerState *s, uint64_t bclk_hz,
                                  uint64_t xtal_hz, uint64_t f32k_hz);

#endif /* HW_TIMER_BL808_TIMER_H */
