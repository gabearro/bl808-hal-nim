/*
 * T-Head CLINT (Core Local Interruptor)
 *
 * Provides MSIP (software interrupt), MTIMECMP, and MTIME registers
 * in the T-Head layout:
 *   +0x0000: MSIP[0], +0x0004: MSIP[1]
 *   +0x4000: MTIMECMP[0] lo/hi, +0x4008: MTIMECMP[1] lo/hi
 *   +0xBFF8: MTIME lo, +0xBFFC: MTIME hi
 *
 * Outputs: 2 GPIO lines per hart (software IRQ, timer IRQ)
 *   pirq[2*hartid + 0] = software interrupt
 *   pirq[2*hartid + 1] = timer interrupt
 *
 * Copyright (c) 2024 Alibaba Group. All rights reserved.
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef THEAD_CLINT_H
#define THEAD_CLINT_H

#include "hw/sysbus.h"
#include "qemu/timer.h"

#define TYPE_THEAD_CLINT "thead-clint"

typedef struct THEADCLINTState THEADCLINTState;
OBJECT_DECLARE_SIMPLE_TYPE(THEADCLINTState, THEAD_CLINT)

struct THEADCLINTState {
    /*< private >*/
    SysBusDevice parent_obj;

    /*< public >*/
    uint32_t *msip;
    uint64_t *mtimecmp;
    int64_t time_delta;
    int64_t num_harts;
    uint32_t timebase_freq;
    QEMUTimer **timer;
    MemoryRegion mmio;
    qemu_irq *pirq;
};

DeviceState *thead_clint_create(hwaddr addr, uint32_t timebase_freq,
                                int64_t num_harts);
uint64_t thead_clint_read_rtc_cb(void *opaque);

#endif /* THEAD_CLINT_H */
