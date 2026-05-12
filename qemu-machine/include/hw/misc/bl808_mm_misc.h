/*
 * Bouffalo Lab BL808 MM_MISC emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_MISC_BL808_MM_MISC_H
#define HW_MISC_BL808_MM_MISC_H

#include <stdbool.h>

#include "hw/sysbus.h"
#include "qom/object.h"

#define TYPE_BL808_MM_MISC "bl808-mm-misc"
#define BL808_MM_MISC_REG_SIZE 0x1000

typedef struct BL808MMMiscState BL808MMMiscState;
OBJECT_DECLARE_SIMPLE_TYPE(BL808MMMiscState, BL808_MM_MISC)

struct BL808MMMiscState {
    /*< private >*/
    SysBusDevice parent_obj;

    /*< public >*/
    MemoryRegion iomem;
    uint32_t regs[BL808_MM_MISC_REG_SIZE / sizeof(uint32_t)];
    bool clock_enabled;
    bool reset_asserted;
};

void bl808_mm_misc_set_clock_enabled(BL808MMMiscState *s, bool enabled);
void bl808_mm_misc_set_reset_asserted(BL808MMMiscState *s, bool asserted);

#endif /* HW_MISC_BL808_MM_MISC_H */
