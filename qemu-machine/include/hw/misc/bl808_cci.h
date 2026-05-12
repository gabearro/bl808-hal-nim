/*
 * Bouffalo Lab BL808 CCI emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_MISC_BL808_CCI_H
#define HW_MISC_BL808_CCI_H

#include <stdbool.h>

#include "hw/sysbus.h"
#include "qom/object.h"

#define TYPE_BL808_CCI "bl808-cci"
#define BL808_CCI_REG_SIZE 0x1000
#define BL808_CCI_MAX_CONFIG_HOOKS 8

typedef struct BL808CCIState BL808CCIState;
OBJECT_DECLARE_SIMPLE_TYPE(BL808CCIState, BL808_CCI)

typedef void (*BL808CCIConfigNotify)(void *opaque, hwaddr offset,
                                     uint32_t value);

typedef struct BL808CCIHook {
    bool in_use;
    hwaddr offset;
    BL808CCIConfigNotify config_update;
    void *opaque;
} BL808CCIHook;

struct BL808CCIState {
    /*< private >*/
    SysBusDevice parent_obj;

    /*< public >*/
    MemoryRegion iomem;
    uint32_t regs[BL808_CCI_REG_SIZE / sizeof(uint32_t)];
    BL808CCIHook hooks[BL808_CCI_MAX_CONFIG_HOOKS];
};

void bl808_cci_register_config_notify(DeviceState *dev, hwaddr offset,
                                      BL808CCIConfigNotify config_update,
                                      void *opaque);

#endif /* HW_MISC_BL808_CCI_H */
