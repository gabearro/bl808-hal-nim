/*
 * Bouffalo Lab BL808 GPIP emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_MISC_BL808_GPIP_H
#define HW_MISC_BL808_GPIP_H

#include "hw/sysbus.h"
#include "qom/object.h"

#define TYPE_BL808_GPIP "bl808-gpip"
#define BL808_GPIP_REG_SIZE 0x400
#define BL808_GPIP_ADC_FIFO_DEPTH 64
#define BL808_GPIP_DAC_FIFO_DEPTH 8

typedef struct BL808GPIPState BL808GPIPState;
OBJECT_DECLARE_SIMPLE_TYPE(BL808GPIPState, BL808_GPIP)

struct BL808GPIPState {
    /*< private >*/
    SysBusDevice parent_obj;

    /*< public >*/
    MemoryRegion iomem;
    QEMUBH *dac_bh;

    uint32_t gpadc_cfg;
    uint32_t gpadc_pir_train;
    uint32_t gpdac_config;
    uint32_t gpdac_dma_config;
    uint32_t gpdac_last_wdata;

    uint32_t adc_fifo[BL808_GPIP_ADC_FIFO_DEPTH];
    uint32_t dac_fifo[BL808_GPIP_DAC_FIFO_DEPTH];
    uint32_t adc_overrun;
    uint32_t adc_underrun;
    uint32_t adc_ready;
    uint8_t adc_head;
    uint8_t adc_tail;
    uint8_t adc_count;
    uint8_t dac_head;
    uint8_t dac_tail;
    uint8_t dac_count;
    bool dac_scheduled;
};

void bl808_gpip_adc_fifo_clear(BL808GPIPState *s);
void bl808_gpip_push_adc_sample(BL808GPIPState *s, uint32_t sample);
bool bl808_gpip_dma_adc_can_read(BL808GPIPState *s, unsigned width_bytes);
uint32_t bl808_gpip_dma_adc_read(BL808GPIPState *s, unsigned width_bytes);
bool bl808_gpip_dma_dac_can_write(BL808GPIPState *s, unsigned width_bytes);
void bl808_gpip_dma_dac_write(BL808GPIPState *s, uint32_t value,
                              unsigned width_bytes);

#endif /* HW_MISC_BL808_GPIP_H */
