/*
 * Bouffalo Lab BL808 USB v2 emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_MISC_BL808_USB_H
#define HW_MISC_BL808_USB_H

#include "qemu/timer.h"
#include "hw/sysbus.h"
#include "qom/object.h"

#define TYPE_BL808_USB "bl808-usb"
#define BL808_USB_REG_SIZE 0x400
#define BL808_USB_FIFO_COUNT 4
#define BL808_USB_FIFO_CAPACITY 4096

typedef struct BL808USBState BL808USBState;
OBJECT_DECLARE_SIMPLE_TYPE(BL808USBState, BL808_USB)

struct BL808USBState {
    /*< private >*/
    SysBusDevice parent_obj;

    /*< public >*/
    MemoryRegion iomem;
    qemu_irq irq;
    uint32_t regs[BL808_USB_REG_SIZE / sizeof(uint32_t)];
    uint8_t cx_fifo[BL808_USB_FIFO_CAPACITY];
    size_t cx_fifo_len;
    uint8_t fifo[BL808_USB_FIFO_COUNT][BL808_USB_FIFO_CAPACITY];
    size_t fifo_len[BL808_USB_FIFO_COUNT];
    QEMUTimer *loopback_timer;
    unsigned autohost_step;
    bool autohost_started;
};

#endif /* HW_MISC_BL808_USB_H */
