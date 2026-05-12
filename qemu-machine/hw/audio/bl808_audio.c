/*
 * Bouffalo Lab BL808 audio/PDM controller emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qemu/main-loop.h"
#include "hw/audio/bl808_audio.h"

#define AUDAC_CTRL0            0x00
#define AUDAC_STATUS           0x04
#define AUDAC_S0               0x08
#define AUDAC_S0_MISC          0x0C
#define AUDAC_ZD0              0x10
#define AUDAC_CTRL1            0x14
#define AUADC_ANA_CFG1         0x60
#define AUADC_ANA_CFG2         0x64
#define AUADC_CMD              0x68
#define AUADC_DATA             0x6C
#define AUADC_RX_FIFO_CTRL     0x80
#define AUADC_RX_FIFO_STS      0x84
#define AUADC_RX_FIFO_DATA     0x88
#define AUDAC_TX_FIFO_CTRL     0x8C
#define AUDAC_TX_FIFO_STS      0x90
#define AUDAC_TX_FIFO_DATA     0x94

#define PDM_TOP                0x800
#define PDM_ITF                0x804
#define PDM_ADC0               0x808
#define PDM_ADC1               0x80C
#define PDM_DAC0               0x810
#define PDM_PDM0               0x81C
#define PDM_VOL                0x838
#define PDM_RX_FIFO_CTRL       0x880
#define PDM_RX_FIFO_STS        0x884
#define PDM_RX_FIFO_DATA       0x888

#define AUDAC_CTRL0_DAC_EN     BIT(0)
#define AUDAC_CTRL0_ITF_EN     BIT(1)
#define AUDAC_CTRL0_CLK_EN     BIT(27)

#define AUADC_DATA_READY       BIT(24)
#define AUADC_SOFT_RST         BIT(29)

#define AUDIO_FIFO_FLUSH       BIT(0)
#define AUDIO_FIFO_OVR_INT_EN  BIT(1)
#define AUDIO_FIFO_UDR_INT_EN  BIT(2)
#define AUDIO_FIFO_AVAIL_INT_EN BIT(3)
#define AUDIO_FIFO_DRQ_EN      BIT(4)
#define AUDIO_FIFO_RES_20BIT   BIT(5)
#define AUDIO_TX_CH_EN_MASK    (0x3u << 8)
#define AUDIO_RX_CH_EN_MASK    (0x7u << 8)
#define AUDIO_FIFO_DRQ_CNT_MASK (0x3u << 14)
#define AUDIO_FIFO_TRG_MASK    (0x3Fu << 16)

#define AUDIO_FIFO_STATUS_OVR  BIT(1)
#define AUDIO_FIFO_STATUS_UDR  BIT(2)
#define AUDIO_FIFO_STATUS_AVAIL BIT(4)
#define AUDIO_FIFO_STATUS_COUNT_MASK (0x3Fu << 16)

#define PDM_ITF_ENABLE         BIT(30)

static bool bl808_audio_clock_active(const BL808AudioState *s)
{
    return s->clock_enabled && !s->reset_asserted;
}

static bool bl808_audio_tx_enabled(const BL808AudioState *s)
{
    return bl808_audio_clock_active(s) &&
           (s->ctrl0 & AUDAC_CTRL0_DAC_EN) &&
           (s->ctrl0 & AUDAC_CTRL0_ITF_EN) &&
           (s->ctrl0 & AUDAC_CTRL0_CLK_EN) &&
           (s->tx_fifo_ctrl & AUDIO_TX_CH_EN_MASK);
}

static bool bl808_audio_rx_enabled(const BL808AudioState *s)
{
    return bl808_audio_clock_active(s) &&
           (s->pdm_itf & PDM_ITF_ENABLE) &&
           (s->rx_fifo_ctrl & AUDIO_RX_CH_EN_MASK);
}

static uint32_t bl808_audio_tx_free(const BL808AudioState *s)
{
    return BL808_AUDIO_FIFO_DEPTH - s->tx_count;
}

static uint32_t bl808_audio_rx_count(const BL808AudioState *s)
{
    return s->rx_count;
}

static uint32_t bl808_audio_threshold(uint32_t fifo_ctrl)
{
    return (fifo_ctrl >> 16) & 0x3Fu;
}

static uint32_t bl808_audio_update_rx_sts(BL808AudioState *s)
{
    uint32_t sts = s->rx_fifo_sts & ~(AUDIO_FIFO_STATUS_COUNT_MASK |
                                      AUDIO_FIFO_STATUS_AVAIL);

    sts |= (bl808_audio_rx_count(s) & 0x3Fu) << 16;
    if (bl808_audio_rx_count(s) > bl808_audio_threshold(s->rx_fifo_ctrl)) {
        sts |= AUDIO_FIFO_STATUS_AVAIL;
    }
    s->rx_fifo_sts = sts;
    return sts;
}

static uint32_t bl808_audio_update_tx_sts(BL808AudioState *s)
{
    uint32_t sts = s->tx_fifo_sts & ~(AUDIO_FIFO_STATUS_COUNT_MASK |
                                      AUDIO_FIFO_STATUS_AVAIL);

    sts |= (bl808_audio_tx_free(s) & 0x3Fu) << 16;
    if (bl808_audio_tx_free(s) > bl808_audio_threshold(s->tx_fifo_ctrl)) {
        sts |= AUDIO_FIFO_STATUS_AVAIL;
    }
    s->tx_fifo_sts = sts;
    return sts;
}

static void bl808_audio_update_irq(BL808AudioState *s)
{
    bool tx_irq = false;
    bool rx_irq = false;

    bl808_audio_update_tx_sts(s);
    bl808_audio_update_rx_sts(s);

    if ((s->tx_fifo_ctrl & AUDIO_FIFO_AVAIL_INT_EN) &&
        (s->tx_fifo_sts & AUDIO_FIFO_STATUS_AVAIL)) {
        tx_irq = true;
    }
    if ((s->tx_fifo_ctrl & AUDIO_FIFO_UDR_INT_EN) &&
        (s->tx_fifo_sts & AUDIO_FIFO_STATUS_UDR)) {
        tx_irq = true;
    }
    if ((s->tx_fifo_ctrl & AUDIO_FIFO_OVR_INT_EN) &&
        (s->tx_fifo_sts & AUDIO_FIFO_STATUS_OVR)) {
        tx_irq = true;
    }

    if ((s->rx_fifo_ctrl & AUDIO_FIFO_AVAIL_INT_EN) &&
        (s->rx_fifo_sts & AUDIO_FIFO_STATUS_AVAIL)) {
        rx_irq = true;
    }
    if ((s->rx_fifo_ctrl & AUDIO_FIFO_UDR_INT_EN) &&
        (s->rx_fifo_sts & AUDIO_FIFO_STATUS_UDR)) {
        rx_irq = true;
    }
    if ((s->rx_fifo_ctrl & AUDIO_FIFO_OVR_INT_EN) &&
        (s->rx_fifo_sts & AUDIO_FIFO_STATUS_OVR)) {
        rx_irq = true;
    }

    s->status = 0;
    if (tx_irq || rx_irq) {
        s->status |= BIT(0);
    }

    qemu_set_irq(s->irq, bl808_audio_clock_active(s) && (tx_irq || rx_irq));
}

static void bl808_audio_flush_tx(BL808AudioState *s)
{
    s->tx_head = 0;
    s->tx_tail = 0;
    s->tx_count = 0;
    s->tx_fifo_sts &= ~(AUDIO_FIFO_STATUS_UDR | AUDIO_FIFO_STATUS_OVR);
}

static void bl808_audio_flush_rx(BL808AudioState *s)
{
    s->rx_head = 0;
    s->rx_tail = 0;
    s->rx_count = 0;
    s->rx_fifo_sts &= ~(AUDIO_FIFO_STATUS_UDR | AUDIO_FIFO_STATUS_OVR);
}

static void bl808_audio_tx_bh(void *opaque)
{
    BL808AudioState *s = opaque;

    s->tx_scheduled = false;
    if (!bl808_audio_tx_enabled(s)) {
        return;
    }

    s->tx_head = 0;
    s->tx_tail = 0;
    s->tx_count = 0;
    bl808_audio_update_irq(s);
}

static void bl808_audio_schedule_tx(BL808AudioState *s)
{
    if (!s->tx_scheduled && s->tx_count != 0 && bl808_audio_tx_enabled(s)) {
        s->tx_scheduled = true;
        qemu_bh_schedule(s->tx_bh);
    }
}

static void bl808_audio_push_tx(BL808AudioState *s, uint32_t value)
{
    if (s->tx_count >= BL808_AUDIO_FIFO_DEPTH) {
        s->tx_fifo_sts |= AUDIO_FIFO_STATUS_OVR;
        bl808_audio_update_irq(s);
        return;
    }

    s->tx_fifo[s->tx_tail] = value;
    s->tx_tail = (s->tx_tail + 1) % BL808_AUDIO_FIFO_DEPTH;
    s->tx_count++;
    bl808_audio_schedule_tx(s);
    bl808_audio_update_irq(s);
}

static uint32_t bl808_audio_pop_rx(BL808AudioState *s)
{
    uint32_t value;

    if (s->rx_count == 0) {
        s->rx_fifo_sts |= AUDIO_FIFO_STATUS_UDR;
        bl808_audio_update_irq(s);
        return 0;
    }

    value = s->rx_fifo[s->rx_head];
    s->rx_head = (s->rx_head + 1) % BL808_AUDIO_FIFO_DEPTH;
    s->rx_count--;
    bl808_audio_update_irq(s);
    return value;
}

void bl808_audio_set_clock_enabled(BL808AudioState *s, bool enabled)
{
    s->clock_enabled = enabled;
    if (!enabled) {
        qemu_bh_cancel(s->tx_bh);
        s->tx_scheduled = false;
    } else {
        bl808_audio_schedule_tx(s);
    }
    bl808_audio_update_irq(s);
}

void bl808_audio_set_reset_asserted(BL808AudioState *s, bool asserted)
{
    s->reset_asserted = asserted;
    if (asserted) {
        device_cold_reset(DEVICE(s));
    } else {
        bl808_audio_schedule_tx(s);
    }
    bl808_audio_update_irq(s);
}

bool bl808_audio_dma_can_read(BL808AudioState *s, unsigned width_bytes)
{
    return width_bytes <= 4 &&
           bl808_audio_rx_enabled(s) &&
           (s->rx_fifo_ctrl & AUDIO_FIFO_DRQ_EN) &&
           bl808_audio_rx_count(s) > bl808_audio_threshold(s->rx_fifo_ctrl);
}

bool bl808_audio_dma_can_write(BL808AudioState *s, unsigned width_bytes)
{
    return width_bytes <= 4 &&
           bl808_audio_tx_enabled(s) &&
           (s->tx_fifo_ctrl & AUDIO_FIFO_DRQ_EN) &&
           bl808_audio_tx_free(s) > bl808_audio_threshold(s->tx_fifo_ctrl);
}

uint32_t bl808_audio_dma_read(BL808AudioState *s, unsigned width_bytes)
{
    return bl808_audio_pop_rx(s);
}

void bl808_audio_dma_write(BL808AudioState *s, uint32_t value,
                           unsigned width_bytes)
{
    bl808_audio_push_tx(s, value);
}

static uint64_t bl808_audio_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808AudioState *s = opaque;

    switch (offset) {
    case AUDAC_CTRL0:
        return s->ctrl0;
    case AUDAC_STATUS:
        bl808_audio_update_irq(s);
        return s->status;
    case AUDAC_S0:
        return s->s0;
    case AUDAC_S0_MISC:
        return s->s0_misc;
    case AUDAC_ZD0:
        return s->zd0;
    case AUDAC_CTRL1:
        return s->ctrl1;
    case AUADC_ANA_CFG1:
        return s->auadc_ana_cfg1;
    case AUADC_ANA_CFG2:
        return s->auadc_ana_cfg2;
    case AUADC_CMD:
        return s->auadc_cmd;
    case AUADC_DATA:
        if (s->rx_count != 0) {
            s->auadc_data = (s->rx_fifo[s->rx_head] & 0x00FFFFFFu) |
                            AUADC_DATA_READY;
        } else {
            s->auadc_data &= ~AUADC_DATA_READY;
        }
        return s->auadc_data;
    case AUADC_RX_FIFO_CTRL:
    case PDM_RX_FIFO_CTRL:
        return s->rx_fifo_ctrl;
    case AUADC_RX_FIFO_STS:
    case PDM_RX_FIFO_STS:
        return bl808_audio_update_rx_sts(s);
    case AUADC_RX_FIFO_DATA:
    case PDM_RX_FIFO_DATA:
        return bl808_audio_pop_rx(s);
    case AUDAC_TX_FIFO_CTRL:
        return s->tx_fifo_ctrl;
    case AUDAC_TX_FIFO_STS:
        return bl808_audio_update_tx_sts(s);
    case PDM_TOP:
        return s->pdm_top;
    case PDM_ITF:
        return s->pdm_itf;
    case PDM_ADC0:
        return s->pdm_adc0;
    case PDM_ADC1:
        return s->pdm_adc1;
    case PDM_DAC0:
        return s->pdm_dac0;
    case PDM_PDM0:
        return s->pdm_pdm0;
    case PDM_VOL:
        return s->adc_s0;
    default:
        return 0;
    }
}

static void bl808_audio_write(void *opaque, hwaddr offset, uint64_t value,
                              unsigned size)
{
    BL808AudioState *s = opaque;
    uint32_t next = (uint32_t)value;

    if (s->reset_asserted) {
        return;
    }

    switch (offset) {
    case AUDAC_CTRL0:
        s->ctrl0 = next;
        bl808_audio_schedule_tx(s);
        break;
    case AUDAC_S0:
        s->s0 = next;
        s->status |= BIT(2);
        break;
    case AUDAC_S0_MISC:
        s->s0_misc = next;
        break;
    case AUDAC_ZD0:
        s->zd0 = next;
        break;
    case AUDAC_CTRL1:
        s->ctrl1 = next;
        break;
    case AUADC_ANA_CFG1:
        s->auadc_ana_cfg1 = next;
        break;
    case AUADC_ANA_CFG2:
        s->auadc_ana_cfg2 = next;
        break;
    case AUADC_CMD:
        s->auadc_cmd = next;
        if (next & AUADC_SOFT_RST) {
            bl808_audio_flush_rx(s);
            s->auadc_data = 0;
        }
        break;
    case AUADC_RX_FIFO_CTRL:
    case PDM_RX_FIFO_CTRL:
        if (next & AUDIO_FIFO_FLUSH) {
            bl808_audio_flush_rx(s);
        }
        s->rx_fifo_ctrl = (next & ~AUDIO_FIFO_FLUSH) |
                          (s->rx_fifo_ctrl & 0);
        break;
    case AUDAC_TX_FIFO_CTRL:
        if (next & AUDIO_FIFO_FLUSH) {
            bl808_audio_flush_tx(s);
        }
        s->tx_fifo_ctrl = next & ~AUDIO_FIFO_FLUSH;
        bl808_audio_schedule_tx(s);
        break;
    case AUDAC_TX_FIFO_DATA:
        bl808_audio_push_tx(s, next);
        return;
    case PDM_TOP:
        s->pdm_top = next;
        break;
    case PDM_ITF:
        s->pdm_itf = next;
        break;
    case PDM_ADC0:
        s->pdm_adc0 = next;
        break;
    case PDM_ADC1:
        s->pdm_adc1 = next;
        break;
    case PDM_DAC0:
        s->pdm_dac0 = next;
        break;
    case PDM_PDM0:
        s->pdm_pdm0 = next;
        break;
    case PDM_VOL:
        s->adc_s0 = next;
        s->status |= BIT(1);
        break;
    default:
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_audio: write to unknown offset 0x%" HWADDR_PRIx
                      " = 0x%" PRIx64 "\n", offset, value);
        return;
    }

    bl808_audio_update_irq(s);
}

static const MemoryRegionOps bl808_audio_ops = {
    .read = bl808_audio_read,
    .write = bl808_audio_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static uint64_t bl808_audio_auadc_read(void *opaque, hwaddr offset,
                                       unsigned size)
{
    BL808AudioState *s = opaque;

    switch (offset) {
    case 0x00:
        return s->pdm_top;
    case 0x04:
        return s->pdm_itf;
    case 0x08:
        return s->pdm_adc0;
    case 0x0c:
        return s->pdm_adc1;
    case 0x10:
        return s->pdm_dac0;
    case 0x1c:
        return s->pdm_pdm0;
    case 0x38:
        return s->adc_s0;
    case AUADC_ANA_CFG1:
        return s->auadc_ana_cfg1;
    case AUADC_ANA_CFG2:
        return s->auadc_ana_cfg2;
    case AUADC_CMD:
        return s->auadc_cmd;
    case AUADC_DATA:
        if (s->rx_count != 0) {
            s->auadc_data = (s->rx_fifo[s->rx_head] & 0x00FFFFFFu) |
                            AUADC_DATA_READY;
        } else {
            s->auadc_data &= ~AUADC_DATA_READY;
        }
        return s->auadc_data;
    case AUADC_RX_FIFO_CTRL:
        return s->rx_fifo_ctrl;
    case AUADC_RX_FIFO_STS:
        return bl808_audio_update_rx_sts(s);
    case AUADC_RX_FIFO_DATA:
        return bl808_audio_pop_rx(s);
    default:
        return 0;
    }
}

static void bl808_audio_auadc_write(void *opaque, hwaddr offset,
                                    uint64_t value, unsigned size)
{
    BL808AudioState *s = opaque;
    uint32_t next = (uint32_t)value;

    if (s->reset_asserted) {
        return;
    }

    switch (offset) {
    case 0x00:
        s->pdm_top = next;
        break;
    case 0x04:
        s->pdm_itf = next;
        break;
    case 0x08:
        s->pdm_adc0 = next;
        break;
    case 0x0c:
        s->pdm_adc1 = next;
        break;
    case 0x10:
        s->pdm_dac0 = next;
        break;
    case 0x1c:
        s->pdm_pdm0 = next;
        break;
    case 0x38:
        s->adc_s0 = next;
        s->status |= BIT(1);
        break;
    case AUADC_ANA_CFG1:
        s->auadc_ana_cfg1 = next;
        break;
    case AUADC_ANA_CFG2:
        s->auadc_ana_cfg2 = next;
        break;
    case AUADC_CMD:
        s->auadc_cmd = next;
        if (next & AUADC_SOFT_RST) {
            bl808_audio_flush_rx(s);
            s->auadc_data = 0;
        }
        break;
    case AUADC_RX_FIFO_CTRL:
        if (next & AUDIO_FIFO_FLUSH) {
            bl808_audio_flush_rx(s);
        }
        s->rx_fifo_ctrl = next & ~AUDIO_FIFO_FLUSH;
        break;
    default:
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_audio: write to unknown AUADC offset 0x%"
                      HWADDR_PRIx " = 0x%" PRIx64 "\n",
                      offset, value);
        return;
    }

    bl808_audio_update_irq(s);
}

static const MemoryRegionOps bl808_audio_auadc_ops = {
    .read = bl808_audio_auadc_read,
    .write = bl808_audio_auadc_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static void bl808_audio_reset(DeviceState *dev)
{
    BL808AudioState *s = BL808_AUDIO(dev);

    s->ctrl0 = 0;
    s->status = 0;
    s->s0 = 0;
    s->s0_misc = 0;
    s->zd0 = 0;
    s->ctrl1 = 0;
    s->auadc_ana_cfg1 = 0;
    s->auadc_ana_cfg2 = 0;
    s->auadc_cmd = 0;
    s->auadc_data = 0;
    s->tx_fifo_ctrl = 0;
    s->tx_fifo_sts = 0;
    s->pdm_top = 0;
    s->pdm_itf = 0;
    s->pdm_adc0 = 0;
    s->pdm_adc1 = 0;
    s->pdm_dac0 = 0;
    s->pdm_pdm0 = 0;
    s->adc_s0 = 0;
    s->rx_fifo_ctrl = 0;
    s->rx_fifo_sts = 0;
    s->tx_head = 0;
    s->tx_tail = 0;
    s->tx_count = 0;
    s->rx_head = 0;
    s->rx_tail = 0;
    s->rx_count = 0;
    s->tx_scheduled = false;
    qemu_bh_cancel(s->tx_bh);
    bl808_audio_update_irq(s);
}

static void bl808_audio_init(Object *obj)
{
    BL808AudioState *s = BL808_AUDIO(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    memory_region_init_io(&s->iomem, obj, &bl808_audio_ops, s,
                          TYPE_BL808_AUDIO, BL808_AUDIO_REG_SIZE);
    sysbus_init_mmio(sbd, &s->iomem);
    memory_region_init_io(&s->auadc_iomem, obj, &bl808_audio_auadc_ops, s,
                          TYPE_BL808_AUDIO "-auadc", BL808_AUADC_REG_SIZE);
    sysbus_init_mmio(sbd, &s->auadc_iomem);
    sysbus_init_irq(sbd, &s->irq);
    s->tx_bh = qemu_bh_new(bl808_audio_tx_bh, s);
    s->clock_enabled = true;
}

static void bl808_audio_finalize(Object *obj)
{
    BL808AudioState *s = BL808_AUDIO(obj);

    qemu_bh_delete(s->tx_bh);
}

static void bl808_audio_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    device_class_set_legacy_reset(dc, bl808_audio_reset);
}

static const TypeInfo bl808_audio_info = {
    .name          = TYPE_BL808_AUDIO,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(BL808AudioState),
    .instance_init = bl808_audio_init,
    .instance_finalize = bl808_audio_finalize,
    .class_init    = bl808_audio_class_init,
};

static void bl808_audio_register_types(void)
{
    type_register_static(&bl808_audio_info);
}

type_init(bl808_audio_register_types)
