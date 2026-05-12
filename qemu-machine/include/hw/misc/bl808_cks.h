/*
 * Bouffalo Lab BL808 checksum engine emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_MISC_BL808_CKS_H
#define HW_MISC_BL808_CKS_H

#include <stdbool.h>

#include "hw/sysbus.h"
#include "qom/object.h"

#define TYPE_BL808_CKS "bl808-cks"
#define BL808_CKS_REG_SIZE 0x100

typedef struct BL808CKSState BL808CKSState;
OBJECT_DECLARE_SIMPLE_TYPE(BL808CKSState, BL808_CKS)

struct BL808CKSState {
    /*< private >*/
    SysBusDevice parent_obj;

    /*< public >*/
    MemoryRegion iomem;

    uint32_t config;
    uint16_t checksum;
    uint8_t pending_byte;
    bool pending_valid;
    bool clock_enabled;
    bool reset_asserted;
};

void bl808_cks_set_clock_enabled(BL808CKSState *s, bool enabled);
void bl808_cks_set_reset_asserted(BL808CKSState *s, bool asserted);

#endif /* HW_MISC_BL808_CKS_H */
