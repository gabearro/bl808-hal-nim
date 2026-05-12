/*
 * Bouffalo Lab BL808 GPIP emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qemu/main-loop.h"
#include "hw/misc/bl808_gpip.h"

#define GPIP_GPADC_CONFIG        0x000
#define GPIP_GPADC_DMA_RDATA     0x004
#define GPIP_GPADC_PIR_TRAIN     0x020
#define GPIP_GPDAC_CONFIG        0x040
#define GPIP_GPDAC_DMA_CONFIG    0x044
#define GPIP_GPDAC_DMA_WDATA     0x048
#define GPIP_GPDAC_TX_FIFO_STS   0x04c

#define GPIP_GPADC_DMA_EN        BIT(0)
#define GPIP_GPADC_FIFO_CLR      BIT(1)
#define GPIP_GPADC_FIFO_NE       BIT(2)
#define GPIP_GPADC_FIFO_FULL     BIT(3)
#define GPIP_GPADC_RDY           BIT(4)
#define GPIP_GPADC_FIFO_OVERRUN  BIT(5)
#define GPIP_GPADC_FIFO_UNDERRUN BIT(6)
#define GPIP_GPADC_RDY_CLR       BIT(8)
#define GPIP_GPADC_OVR_CLR       BIT(9)
#define GPIP_GPADC_UDR_CLR       BIT(10)
#define GPIP_GPADC_MASKS         (BIT(12) | BIT(13) | BIT(14))
#define GPIP_GPADC_FIFO_COUNT_SHIFT 16
#define GPIP_GPADC_FIFO_COUNT_MASK  (0x3fu << GPIP_GPADC_FIFO_COUNT_SHIFT)
#define GPIP_GPADC_FIFO_THL_MASK    (0x3u << 22)

#define GPIP_PIR_TRAIN_WRITABLE  0x0003001fu
#define GPIP_GPDAC_CONFIG_MASK   0x00ff0701u
#define GPIP_GPDAC_CONFIG_RESET  0x0d000000u
#define GPIP_GPDAC_DMA_CFG_MASK  0x000000f3u

#define GPIP_TX_FIFO_EMPTY       BIT(0)
#define GPIP_TX_FIFO_FULL        BIT(1)
#define GPIP_TX_FIFO_RDPTR_SHIFT 4
#define GPIP_TX_FIFO_WRPTR_SHIFT 8

static void bl808_gpip_update_dac_flush(BL808GPIPState *s);

static void bl808_gpip_reset_state(BL808GPIPState *s)
{
    s->gpadc_cfg = 0;
    s->gpadc_pir_train = 0x0000000fu;
    s->gpdac_config = GPIP_GPDAC_CONFIG_RESET;
    s->gpdac_dma_config = 0;
    s->gpdac_last_wdata = 0;
    s->adc_overrun = 0;
    s->adc_underrun = 0;
    s->adc_ready = 0;
    s->adc_head = 0;
    s->adc_tail = 0;
    s->adc_count = 0;
    s->dac_head = 0;
    s->dac_tail = 0;
    s->dac_count = 0;
    s->dac_scheduled = false;
    qemu_bh_cancel(s->dac_bh);
}

void bl808_gpip_adc_fifo_clear(BL808GPIPState *s)
{
    s->adc_head = 0;
    s->adc_tail = 0;
    s->adc_count = 0;
    s->adc_ready = 0;
}

void bl808_gpip_push_adc_sample(BL808GPIPState *s, uint32_t sample)
{
    if (s->adc_count >= BL808_GPIP_ADC_FIFO_DEPTH) {
        s->adc_overrun = GPIP_GPADC_FIFO_OVERRUN;
        return;
    }

    s->adc_fifo[s->adc_tail] = sample & 0x03ffffffu;
    s->adc_tail = (s->adc_tail + 1) % BL808_GPIP_ADC_FIFO_DEPTH;
    s->adc_count++;
    s->adc_ready = GPIP_GPADC_RDY;
}

static uint32_t bl808_gpip_adc_config_value(BL808GPIPState *s)
{
    uint32_t value = s->gpadc_cfg & (GPIP_GPADC_DMA_EN |
                                     GPIP_GPADC_MASKS |
                                     GPIP_GPADC_FIFO_THL_MASK);

    if (s->adc_count != 0) {
        value |= GPIP_GPADC_FIFO_NE | GPIP_GPADC_RDY;
    }
    if (s->adc_count >= BL808_GPIP_ADC_FIFO_DEPTH) {
        value |= GPIP_GPADC_FIFO_FULL;
    }
    value |= s->adc_overrun;
    value |= s->adc_underrun;
    value |= (s->adc_count << GPIP_GPADC_FIFO_COUNT_SHIFT) &
             GPIP_GPADC_FIFO_COUNT_MASK;
    return value;
}

static uint32_t bl808_gpip_dac_status_value(BL808GPIPState *s)
{
    uint32_t value = 0;

    if (s->dac_count == 0) {
        value |= GPIP_TX_FIFO_EMPTY;
        value |= 8u << GPIP_TX_FIFO_RDPTR_SHIFT;
    } else {
        value |= (uint32_t)(s->dac_head & 0xf) << GPIP_TX_FIFO_RDPTR_SHIFT;
    }
    if (s->dac_count >= BL808_GPIP_DAC_FIFO_DEPTH) {
        value |= GPIP_TX_FIFO_FULL;
    }
    value |= (uint32_t)(s->dac_tail & 0x3) << GPIP_TX_FIFO_WRPTR_SHIFT;
    return value;
}

static void bl808_gpip_dac_bh(void *opaque)
{
    BL808GPIPState *s = opaque;

    s->dac_scheduled = false;
    s->dac_head = 0;
    s->dac_tail = 0;
    s->dac_count = 0;
}

static void bl808_gpip_update_dac_flush(BL808GPIPState *s)
{
    bool can_drain = (s->gpdac_config & BIT(0)) ||
                     (s->gpdac_dma_config & BIT(0));

    if (can_drain && s->dac_count != 0 && !s->dac_scheduled) {
        s->dac_scheduled = true;
        qemu_bh_schedule(s->dac_bh);
    }
}

static void bl808_gpip_push_dac_sample(BL808GPIPState *s, uint32_t value)
{
    if (s->dac_count >= BL808_GPIP_DAC_FIFO_DEPTH) {
        return;
    }

    s->dac_fifo[s->dac_tail] = value;
    s->dac_tail = (s->dac_tail + 1) % BL808_GPIP_DAC_FIFO_DEPTH;
    s->dac_count++;
    s->gpdac_last_wdata = value;
    bl808_gpip_update_dac_flush(s);
}

bool bl808_gpip_dma_adc_can_read(BL808GPIPState *s, unsigned width_bytes)
{
    return width_bytes <= 4 &&
           (s->gpadc_cfg & GPIP_GPADC_DMA_EN) &&
           s->adc_count != 0;
}

uint32_t bl808_gpip_dma_adc_read(BL808GPIPState *s, unsigned width_bytes)
{
    uint32_t value;

    if (!bl808_gpip_dma_adc_can_read(s, width_bytes)) {
        s->adc_underrun = GPIP_GPADC_FIFO_UNDERRUN;
        return 0;
    }

    value = s->adc_fifo[s->adc_head];
    s->adc_head = (s->adc_head + 1) % BL808_GPIP_ADC_FIFO_DEPTH;
    s->adc_count--;
    if (s->adc_count == 0) {
        s->adc_ready = 0;
    }

    switch (width_bytes) {
    case 1:
        return value & 0xff;
    case 2:
        return value & 0xffff;
    default:
        return value;
    }
}

bool bl808_gpip_dma_dac_can_write(BL808GPIPState *s, unsigned width_bytes)
{
    return width_bytes <= 4 &&
           (s->gpdac_dma_config & BIT(0)) &&
           s->dac_count < BL808_GPIP_DAC_FIFO_DEPTH;
}

void bl808_gpip_dma_dac_write(BL808GPIPState *s, uint32_t value,
                              unsigned width_bytes)
{
    switch (width_bytes) {
    case 1:
        value &= 0xff;
        break;
    case 2:
        value &= 0xffff;
        break;
    default:
        break;
    }

    bl808_gpip_push_dac_sample(s, value);
}

static uint64_t bl808_gpip_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808GPIPState *s = opaque;

    if (size != 4) {
        return 0;
    }
    if ((offset & 3) || offset >= BL808_GPIP_REG_SIZE) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_gpip: bad read offset 0x%" HWADDR_PRIx "\n",
                      offset);
        return 0;
    }

    switch (offset) {
    case GPIP_GPADC_CONFIG:
        return bl808_gpip_adc_config_value(s);
    case GPIP_GPADC_DMA_RDATA:
        return bl808_gpip_dma_adc_read(s, 4);
    case GPIP_GPADC_PIR_TRAIN:
        return s->gpadc_pir_train;
    case GPIP_GPDAC_CONFIG:
        return s->gpdac_config;
    case GPIP_GPDAC_DMA_CONFIG:
        return s->gpdac_dma_config;
    case GPIP_GPDAC_DMA_WDATA:
        return 0;
    case GPIP_GPDAC_TX_FIFO_STS:
        return bl808_gpip_dac_status_value(s);
    default:
        return 0;
    }
}

static void bl808_gpip_write(void *opaque, hwaddr offset, uint64_t value,
                             unsigned size)
{
    BL808GPIPState *s = opaque;
    uint32_t val = (uint32_t)value;

    if (size != 4) {
        return;
    }
    if ((offset & 3) || offset >= BL808_GPIP_REG_SIZE) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_gpip: bad write offset 0x%" HWADDR_PRIx
                      " = 0x%" PRIx64 "\n", offset, value);
        return;
    }

    switch (offset) {
    case GPIP_GPADC_CONFIG:
        s->gpadc_cfg &= ~(GPIP_GPADC_DMA_EN | GPIP_GPADC_MASKS |
                          GPIP_GPADC_FIFO_THL_MASK);
        s->gpadc_cfg |= val & (GPIP_GPADC_DMA_EN | GPIP_GPADC_MASKS |
                               GPIP_GPADC_FIFO_THL_MASK);
        if (val & GPIP_GPADC_FIFO_CLR) {
            bl808_gpip_adc_fifo_clear(s);
        }
        if (val & GPIP_GPADC_RDY_CLR) {
            s->adc_ready = 0;
        }
        if (val & GPIP_GPADC_OVR_CLR) {
            s->adc_overrun = 0;
        }
        if (val & GPIP_GPADC_UDR_CLR) {
            s->adc_underrun = 0;
        }
        break;
    case GPIP_GPADC_DMA_RDATA:
        break;
    case GPIP_GPADC_PIR_TRAIN:
        s->gpadc_pir_train =
            (s->gpadc_pir_train & ~GPIP_PIR_TRAIN_WRITABLE) |
            (val & GPIP_PIR_TRAIN_WRITABLE);
        break;
    case GPIP_GPDAC_CONFIG:
        s->gpdac_config = GPIP_GPDAC_CONFIG_RESET |
                          (val & GPIP_GPDAC_CONFIG_MASK);
        bl808_gpip_update_dac_flush(s);
        break;
    case GPIP_GPDAC_DMA_CONFIG:
        s->gpdac_dma_config = val & GPIP_GPDAC_DMA_CFG_MASK;
        bl808_gpip_update_dac_flush(s);
        break;
    case GPIP_GPDAC_DMA_WDATA:
        bl808_gpip_push_dac_sample(s, val);
        break;
    case GPIP_GPDAC_TX_FIFO_STS:
        break;
    default:
        break;
    }
}

static const MemoryRegionOps bl808_gpip_ops = {
    .read = bl808_gpip_read,
    .write = bl808_gpip_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static void bl808_gpip_reset(DeviceState *dev)
{
    bl808_gpip_reset_state(BL808_GPIP(dev));
}

static void bl808_gpip_init(Object *obj)
{
    BL808GPIPState *s = BL808_GPIP(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    s->dac_bh = qemu_bh_new(bl808_gpip_dac_bh, s);
    memory_region_init_io(&s->iomem, obj, &bl808_gpip_ops, s,
                          TYPE_BL808_GPIP, BL808_GPIP_REG_SIZE);
    sysbus_init_mmio(sbd, &s->iomem);
}

static void bl808_gpip_finalize(Object *obj)
{
    BL808GPIPState *s = BL808_GPIP(obj);

    qemu_bh_delete(s->dac_bh);
}

static void bl808_gpip_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    device_class_set_legacy_reset(dc, bl808_gpip_reset);
}

static const TypeInfo bl808_gpip_info = {
    .name          = TYPE_BL808_GPIP,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(BL808GPIPState),
    .instance_init = bl808_gpip_init,
    .instance_finalize = bl808_gpip_finalize,
    .class_init    = bl808_gpip_class_init,
};

static void bl808_gpip_register_types(void)
{
    type_register_static(&bl808_gpip_info);
}

type_init(bl808_gpip_register_types)
