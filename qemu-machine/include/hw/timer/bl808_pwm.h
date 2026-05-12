/*
 * Bouffalo Lab BL808 PWM_V2 emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_TIMER_BL808_PWM_H
#define HW_TIMER_BL808_PWM_H

#include <stdbool.h>

#include "hw/irq.h"
#include "hw/sysbus.h"
#include "qemu/typedefs.h"
#include "qom/object.h"

#define TYPE_BL808_PWM "bl808-pwm-v2"
#define BL808_PWM_REG_SIZE 0x100
#define BL808_PWM_MC_COUNT 2

typedef struct BL808PWMState BL808PWMState;
OBJECT_DECLARE_SIMPLE_TYPE(BL808PWMState, BL808_PWM)

struct BL808PWMState {
    /*< private >*/
    SysBusDevice parent_obj;

    /*< public >*/
    MemoryRegion iomem;
    qemu_irq irq;
    QEMUTimer *period_timer[BL808_PWM_MC_COUNT];

    uint32_t int_config;
    uint32_t mc_config0[BL808_PWM_MC_COUNT];
    uint32_t mc_config1[BL808_PWM_MC_COUNT];
    uint32_t mc_period[BL808_PWM_MC_COUNT];
    uint32_t mc_dead_time[BL808_PWM_MC_COUNT];
    uint32_t mc_thre[BL808_PWM_MC_COUNT][4];
    uint32_t mc_int_sts[BL808_PWM_MC_COUNT];
    uint32_t mc_int_mask[BL808_PWM_MC_COUNT];
    uint32_t mc_int_en[BL808_PWM_MC_COUNT];
    uint32_t repeat_count[BL808_PWM_MC_COUNT];

    bool clock_enabled;
    bool reset_asserted;
    bool repeat_stop_active[BL808_PWM_MC_COUNT];
};

void bl808_pwm_set_clock_enabled(BL808PWMState *s, bool enabled);
void bl808_pwm_set_reset_asserted(BL808PWMState *s, bool asserted);

#endif /* HW_TIMER_BL808_PWM_H */
