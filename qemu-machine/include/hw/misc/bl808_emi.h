/*
 * Bouffalo Lab BL808 EMI/XRAM controller emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_MISC_BL808_EMI_H
#define HW_MISC_BL808_EMI_H

#include <stdbool.h>

#include "hw/sysbus.h"
#include "qom/object.h"

#define TYPE_BL808_EMI "bl808-emi"
#define BL808_EMI_REG_SIZE 0x2000

typedef struct BL808EMIState BL808EMIState;
OBJECT_DECLARE_SIMPLE_TYPE(BL808EMIState, BL808_EMI)

struct BL808EMIState {
    /*< private >*/
    SysBusDevice parent_obj;

    /*< public >*/
    MemoryRegion iomem;

    uint32_t ctrl;
    uint32_t clk_cfg;
    uint32_t ram_cfg;
    uint32_t prot;
    uint32_t int_sts;
    uint32_t int_mask;

    bool clock_enabled;
    bool reset_asserted;
};

void bl808_emi_set_clock_enabled(BL808EMIState *s, bool enabled);
void bl808_emi_set_reset_asserted(BL808EMIState *s, bool asserted);

#endif /* HW_MISC_BL808_EMI_H */
