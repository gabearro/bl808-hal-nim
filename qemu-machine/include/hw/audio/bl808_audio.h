/*
 * Bouffalo Lab BL808 audio/PDM controller emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_AUDIO_BL808_AUDIO_H
#define HW_AUDIO_BL808_AUDIO_H

#include <stdbool.h>

#include "hw/irq.h"
#include "hw/sysbus.h"
#include "qom/object.h"

#define TYPE_BL808_AUDIO "bl808-audio"
#define BL808_AUDIO_FIFO_DEPTH 32
#define BL808_AUDIO_REG_SIZE   0x1000
#define BL808_AUADC_REG_SIZE   0x100

typedef struct BL808AudioState BL808AudioState;
OBJECT_DECLARE_SIMPLE_TYPE(BL808AudioState, BL808_AUDIO)

struct BL808AudioState {
    /*< private >*/
    SysBusDevice parent_obj;

    /*< public >*/
    MemoryRegion iomem;
    MemoryRegion auadc_iomem;
    qemu_irq irq;
    QEMUBH *tx_bh;

    uint32_t ctrl0;
    uint32_t status;
    uint32_t s0;
    uint32_t s0_misc;
    uint32_t zd0;
    uint32_t ctrl1;

    uint32_t auadc_ana_cfg1;
    uint32_t auadc_ana_cfg2;
    uint32_t auadc_cmd;
    uint32_t auadc_data;

    uint32_t tx_fifo_ctrl;
    uint32_t tx_fifo_sts;

    uint32_t pdm_top;
    uint32_t pdm_itf;
    uint32_t pdm_adc0;
    uint32_t pdm_adc1;
    uint32_t pdm_dac0;
    uint32_t pdm_pdm0;
    uint32_t adc_s0;
    uint32_t rx_fifo_ctrl;
    uint32_t rx_fifo_sts;

    uint32_t tx_fifo[BL808_AUDIO_FIFO_DEPTH];
    uint32_t rx_fifo[BL808_AUDIO_FIFO_DEPTH];
    uint32_t tx_head;
    uint32_t tx_tail;
    uint32_t tx_count;
    uint32_t rx_head;
    uint32_t rx_tail;
    uint32_t rx_count;

    bool tx_scheduled;
    bool clock_enabled;
    bool reset_asserted;
};

void bl808_audio_set_clock_enabled(BL808AudioState *s, bool enabled);
void bl808_audio_set_reset_asserted(BL808AudioState *s, bool asserted);
bool bl808_audio_dma_can_read(BL808AudioState *s, unsigned width_bytes);
bool bl808_audio_dma_can_write(BL808AudioState *s, unsigned width_bytes);
uint32_t bl808_audio_dma_read(BL808AudioState *s, unsigned width_bytes);
void bl808_audio_dma_write(BL808AudioState *s, uint32_t value,
                           unsigned width_bytes);

#endif /* HW_AUDIO_BL808_AUDIO_H */
