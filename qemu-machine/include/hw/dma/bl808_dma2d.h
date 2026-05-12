/*
 * Bouffalo Lab BL808 DMA2D emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_DMA_BL808_DMA2D_H
#define HW_DMA_BL808_DMA2D_H

#include <stdbool.h>

#include "hw/irq.h"
#include "hw/sysbus.h"
#include "qom/object.h"

#define TYPE_BL808_DMA2D "bl808-dma2d"
#define BL808_DMA2D_CHANNELS 2
#define BL808_DMA2D_REG_SIZE 0x1000

typedef struct BL808DMA2DState BL808DMA2DState;
OBJECT_DECLARE_SIMPLE_TYPE(BL808DMA2DState, BL808_DMA2D)

typedef struct BL808DMA2DChannel {
    uint32_t src_addr;
    uint32_t dst_addr;
    uint32_t lli;
    uint32_t bus;
    uint32_t src_cnt;
    uint32_t src_xic;
    uint32_t src_yic;
    uint32_t dst_cnt;
    uint32_t dst_xic;
    uint32_t dst_yic;
    uint32_t key;
    uint32_t key_en;
    uint32_t cfg;
    bool active;
} BL808DMA2DChannel;

struct BL808DMA2DState {
    /*< private >*/
    SysBusDevice parent_obj;

    /*< public >*/
    MemoryRegion iomem;
    qemu_irq irq[BL808_DMA2D_CHANNELS];
    QEMUBH *run_bh;

    BL808DMA2DChannel channels[BL808_DMA2D_CHANNELS];

    uint32_t int_status;
    uint32_t int_tc_status;
    uint32_t global_cfg;
    uint32_t sync;
    uint32_t soft_breq;
    uint32_t soft_lbreq;
    uint32_t soft_sreq;
    uint32_t soft_lsreq;
    uint32_t qos;
    bool run_scheduled;
    bool clock_enabled;
    bool reset_asserted;
};

void bl808_dma2d_set_clock_enabled(BL808DMA2DState *s, bool enabled);
void bl808_dma2d_set_reset_asserted(BL808DMA2DState *s, bool asserted);

#endif /* HW_DMA_BL808_DMA2D_H */
