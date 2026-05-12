/*
 * Bouffalo Lab BL808 I2S controller emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_AUDIO_BL808_I2S_H
#define HW_AUDIO_BL808_I2S_H

#include <stdbool.h>

#include "hw/irq.h"
#include "hw/sysbus.h"
#include "qom/object.h"

#define TYPE_BL808_I2S "bl808-i2s"
#define BL808_I2S_FIFO_DEPTH 16
#define BL808_I2S_REG_SIZE   0x100

typedef struct BL808I2SState BL808I2SState;
OBJECT_DECLARE_SIMPLE_TYPE(BL808I2SState, BL808_I2S)

struct BL808I2SState {
    /*< private >*/
    SysBusDevice parent_obj;

    /*< public >*/
    MemoryRegion iomem;
    qemu_irq irq;
    QEMUBH *tx_bh;

    uint32_t config;
    uint32_t int_sts;
    uint32_t bclk_config;
    uint32_t fifo_config0;
    uint32_t fifo_config1;
    uint32_t io_config;

    uint32_t tx_fifo[BL808_I2S_FIFO_DEPTH];
    uint32_t rx_fifo[BL808_I2S_FIFO_DEPTH];
    uint32_t tx_head;
    uint32_t tx_tail;
    uint32_t tx_count;
    uint32_t rx_head;
    uint32_t rx_tail;
    uint32_t rx_count;

    bool tx_scheduled;
    bool gate_enabled;
    bool module_clock_enabled;
    bool clock_enabled;
    bool reset_asserted;
};

void bl808_i2s_set_clock_enabled(BL808I2SState *s, bool enabled);
void bl808_i2s_set_module_clock_enabled(BL808I2SState *s, bool enabled);
void bl808_i2s_set_reset_asserted(BL808I2SState *s, bool asserted);
bool bl808_i2s_dma_can_read(BL808I2SState *s, unsigned width_bytes);
bool bl808_i2s_dma_can_write(BL808I2SState *s, unsigned width_bytes);
uint32_t bl808_i2s_dma_read(BL808I2SState *s, unsigned width_bytes);
void bl808_i2s_dma_write(BL808I2SState *s, uint32_t value,
                         unsigned width_bytes);

#endif /* HW_AUDIO_BL808_I2S_H */
