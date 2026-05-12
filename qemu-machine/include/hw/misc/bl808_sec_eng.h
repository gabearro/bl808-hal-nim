/*
 * Bouffalo Lab BL808 SEC_ENG emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_MISC_BL808_SEC_ENG_H
#define HW_MISC_BL808_SEC_ENG_H

#include "hw/sysbus.h"
#include "qom/object.h"

#define TYPE_BL808_SEC_ENG "bl808-sec-eng"
#define BL808_SEC_ENG_REG_SIZE 0x1000
#define BL808_SEC_ENG_IRQ_LINES 4

typedef struct BL808SecEngState BL808SecEngState;
OBJECT_DECLARE_SIMPLE_TYPE(BL808SecEngState, BL808_SEC_ENG)

struct BL808SecEngState {
    /*< private >*/
    SysBusDevice parent_obj;

    /*< public >*/
    MemoryRegion iomem;
    qemu_irq irq[BL808_SEC_ENG_IRQ_LINES];
    uint32_t regs[BL808_SEC_ENG_REG_SIZE / sizeof(uint32_t)];
    uint8_t *sha_accum;
    size_t sha_accum_len;
    size_t sha_accum_cap;
    uint64_t trng_state;
    uint32_t *efuse_shadow;
    size_t efuse_words;
};

#endif /* HW_MISC_BL808_SEC_ENG_H */
