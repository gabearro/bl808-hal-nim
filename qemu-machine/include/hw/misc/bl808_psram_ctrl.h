/*
 * Bouffalo Lab BL808 PSRAM controller emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_MISC_BL808_PSRAM_CTRL_H
#define HW_MISC_BL808_PSRAM_CTRL_H

#include <stdbool.h>

#include "hw/sysbus.h"
#include "qom/object.h"

#define TYPE_BL808_PSRAM_CTRL "bl808-psram-ctrl"
#define BL808_PSRAM_CTRL_REG_SIZE 0x1000
#define BL808_PSRAM_UHS_REG_SIZE  0x1000

typedef struct BL808PSRAMCtrlState BL808PSRAMCtrlState;
OBJECT_DECLARE_SIMPLE_TYPE(BL808PSRAMCtrlState, BL808_PSRAM_CTRL)

struct BL808PSRAMCtrlState {
    /*< private >*/
    SysBusDevice parent_obj;

    /*< public >*/
    MemoryRegion ctrl_iomem;
    MemoryRegion uhs_iomem;

    uint32_t cfg0;
    uint32_t cfg1;
    uint32_t cfg2;
    uint32_t cfg3;
    uint32_t cfg4;
    uint32_t status;
    uint32_t int_sts;
    uint32_t int_mask;

    uint32_t uhs_regs[BL808_PSRAM_UHS_REG_SIZE / sizeof(uint32_t)];

    bool clock_enabled;
    bool reset_asserted;
};

void bl808_psram_ctrl_set_clock_enabled(BL808PSRAMCtrlState *s, bool enabled);
void bl808_psram_ctrl_set_reset_asserted(BL808PSRAMCtrlState *s,
                                         bool asserted);
bool bl808_psram_ctrl_memory_enabled(const BL808PSRAMCtrlState *s);

#endif /* HW_MISC_BL808_PSRAM_CTRL_H */
