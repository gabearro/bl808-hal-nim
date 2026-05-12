/*
 * Bouffalo Lab BL808 MCU_MISC emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_MISC_BL808_MCU_MISC_H
#define HW_MISC_BL808_MCU_MISC_H

#include "hw/sysbus.h"
#include "qom/object.h"

#define TYPE_BL808_MCU_MISC "bl808-mcu-misc"
#define BL808_MCU_MISC_REG_SIZE 0x1000

typedef struct BL808MCUMiscState BL808MCUMiscState;
OBJECT_DECLARE_SIMPLE_TYPE(BL808MCUMiscState, BL808_MCU_MISC)

struct BL808MCUMiscState {
    /*< private >*/
    SysBusDevice parent_obj;

    /*< public >*/
    MemoryRegion iomem;
    uint32_t regs[BL808_MCU_MISC_REG_SIZE / sizeof(uint32_t)];
};

#endif /* HW_MISC_BL808_MCU_MISC_H */
