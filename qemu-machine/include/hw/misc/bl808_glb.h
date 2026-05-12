/*
 * Bouffalo Lab BL808 GLB/MM_GLB control blocks
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_MISC_BL808_GLB_H
#define HW_MISC_BL808_GLB_H

#include <stdbool.h>

#include "hw/sysbus.h"
#include "qom/object.h"

#define TYPE_BL808_GLB "bl808-glb"

typedef struct BL808GLBState BL808GLBState;
OBJECT_DECLARE_SIMPLE_TYPE(BL808GLBState, BL808_GLB)

typedef void (*BL808GLBClockNotify)(void *opaque, bool enabled);
typedef void (*BL808GLBResetNotify)(void *opaque, bool asserted);
typedef void (*BL808GLBClockConfigNotify)(void *opaque, hwaddr offset,
                                          uint32_t value);

#define BL808_GLB_GPIO_PINS 46

void bl808_glb_register_device(DeviceState *dev,
                               hwaddr gate_offset, uint32_t gate_mask,
                               hwaddr reset_offset, uint32_t reset_mask,
                               hwaddr config_offset,
                               BL808GLBClockNotify clock_enable,
                               BL808GLBResetNotify reset_assert,
                               BL808GLBClockConfigNotify clock_config_update,
                               void *opaque);
void bl808_glb_set_gpio_input_state(DeviceState *dev, unsigned pin,
                                    bool driven, bool level);
void bl808_glb_set_aon_pad_ctrl(DeviceState *dev, unsigned pin,
                                bool hw_ctrl, bool hw_pupd_enable,
                                bool oe, bool pu, bool pd);
void bl808_glb_set_aon_iso_mode(DeviceState *dev, bool iso_mode);

#endif /* HW_MISC_BL808_GLB_H */
