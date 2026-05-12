/*
 * Bouffalo Lab BL808 TZC emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_MISC_BL808_TZC_H
#define HW_MISC_BL808_TZC_H

#include <stdbool.h>

#include "hw/sysbus.h"
#include "qom/object.h"

#define TYPE_BL808_TZC "bl808-tzc"
#define BL808_TZC_REG_SIZE 0x1000

typedef struct BL808TZCState BL808TZCState;
OBJECT_DECLARE_SIMPLE_TYPE(BL808TZCState, BL808_TZC)

struct BL808TZCState {
    /*< private >*/
    SysBusDevice parent_obj;

    /*< public >*/
    MemoryRegion iomem;
    bool secure;
    uint32_t regs[BL808_TZC_REG_SIZE / sizeof(uint32_t)];
};

#endif /* HW_MISC_BL808_TZC_H */
