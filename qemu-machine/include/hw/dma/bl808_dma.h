/*
 * Bouffalo Lab BL808 DMA controller emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_DMA_BL808_DMA_H
#define HW_DMA_BL808_DMA_H

#include <stdbool.h>

#include "hw/irq.h"
#include "hw/sysbus.h"
#include "qemu/typedefs.h"
#include "qom/object.h"

#define TYPE_BL808_DMA "bl808-dma"

#define BL808_DMA_CHANNELS        8
#define BL808_DMA_REQUEST_LINES   32
#define BL808_DMA_REG_SIZE        0x1000

typedef struct BL808DMAState BL808DMAState;
OBJECT_DECLARE_SIMPLE_TYPE(BL808DMAState, BL808_DMA)

typedef struct BL808DMARequestOps {
    bool (*can_read)(void *opaque, unsigned width_bytes);
    bool (*can_write)(void *opaque, unsigned width_bytes);
    uint32_t (*read)(void *opaque, unsigned width_bytes);
    void (*write)(void *opaque, uint32_t value, unsigned width_bytes);
} BL808DMARequestOps;

typedef struct BL808DMAChannel {
    uint32_t src_addr;
    uint32_t dst_addr;
    uint32_t lli;
    uint32_t control;
    uint32_t config;
    bool active;
} BL808DMAChannel;

typedef struct BL808DMARequestLine {
    const BL808DMARequestOps *ops;
    void *opaque;
} BL808DMARequestLine;

struct BL808DMAState {
    /*< private >*/
    SysBusDevice parent_obj;

    /*< public >*/
    MemoryRegion iomem;
    qemu_irq irq;
    qemu_irq ch_irq[BL808_DMA_CHANNELS];
    QEMUBH *run_bh;
    QEMUTimer *poll_timer;

    BL808DMAChannel channels[BL808_DMA_CHANNELS];
    BL808DMARequestLine requests[BL808_DMA_REQUEST_LINES];

    uint32_t raw_tc_status;
    uint32_t raw_err_status;
    uint32_t soft_breq;
    uint32_t soft_sreq;
    uint32_t soft_lbreq;
    uint32_t soft_lsreq;
    uint32_t top_config;
    uint32_t sync;

    uint8_t channel_count;
    bool supports_doubleword_width;
    bool clock_enabled;
    bool reset_asserted;
    bool run_scheduled;
};

void bl808_dma_register_request(BL808DMAState *s, unsigned request_id,
                                const BL808DMARequestOps *ops, void *opaque);
void bl808_dma_set_clock_enabled(BL808DMAState *s, bool enabled);
void bl808_dma_set_reset_asserted(BL808DMAState *s, bool asserted);

#endif /* HW_DMA_BL808_DMA_H */
