/*
 * Bouffalo Lab BL808 SPI controller emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qemu/main-loop.h"
#include "hw/qdev-properties.h"
#include "hw/ssi/ssi.h"
#include "hw/ssi/bl808_spi.h"

/* Register offsets */
#define SPI_CONFIG_REG        0x00
#define SPI_INT_STS           0x04
#define SPI_BUS_BUSY          0x08
#define SPI_PRD0              0x10
#define SPI_PRD1              0x14
#define SPI_RXD_IGNR          0x18
#define SPI_STO_VALUE         0x1C
#define SPI_FIFO_CONFIG0      0x80
#define SPI_FIFO_CONFIG1      0x84
#define SPI_FIFO_WDATA        0x88
#define SPI_FIFO_RDATA        0x8C

/* SPI_CONFIG bits */
#define SPI_MASTER_EN         BIT(0)
#define SPI_SLAVE_EN          BIT(1)
#define SPI_FRAME_SIZE_SHIFT  2
#define SPI_FRAME_SIZE_MASK   (3u << SPI_FRAME_SIZE_SHIFT)
#define SPI_RXD_IGNR_EN       BIT(8)

/* SPI_INT_STS bits */
#define SPI_INT_END           BIT(0)
#define SPI_INT_TX_FIFO       BIT(1)
#define SPI_INT_RX_FIFO       BIT(2)
#define SPI_INT_STO           BIT(3)
#define SPI_INT_TX_UNDER      BIT(4)
#define SPI_INT_FIFO_ERR      BIT(5)
#define SPI_INT_MASK_SHIFT    8
#define SPI_INT_CLEAR_SHIFT   16
#define SPI_INT_STATUS_MASK   0x3F

/* FIFO_CONFIG0 bits */
#define SPI_FIFO_DMA_RX_EN    BIT(0)
#define SPI_FIFO_DMA_TX_EN    BIT(1)
#define SPI_FIFO_TX_CLR       BIT(2)
#define SPI_FIFO_RX_CLR       BIT(3)
#define SPI_FIFO_TX_OVERFLOW  BIT(4)
#define SPI_FIFO_TX_UNDERFLOW BIT(5)
#define SPI_FIFO_RX_OVERFLOW  BIT(6)
#define SPI_FIFO_RX_UNDERFLOW BIT(7)
#define SPI_FIFO_STATUS_MASK  (SPI_FIFO_TX_OVERFLOW | SPI_FIFO_TX_UNDERFLOW | \
                               SPI_FIFO_RX_OVERFLOW | SPI_FIFO_RX_UNDERFLOW)

static bool bl808_spi_clock_active(const BL808SPIState *s)
{
    return s->clock_enabled && !s->reset_asserted;
}

static void bl808_spi_recompute_clock(BL808SPIState *s)
{
    s->clock_enabled = s->gate_enabled && s->module_clock_enabled;
}

static uint32_t bl808_spi_fifo_depth(const BL808SPIState *s)
{
    switch ((s->config & SPI_FRAME_SIZE_MASK) >> SPI_FRAME_SIZE_SHIFT) {
    case 0:
        return 32;
    case 1:
        return 16;
    default:
        return 8;
    }
}

static uint32_t bl808_spi_tx_free(const BL808SPIState *s)
{
    uint32_t depth = bl808_spi_fifo_depth(s);

    return s->tx_count < depth ? depth - s->tx_count : 0;
}

static uint32_t bl808_spi_frame_mask(const BL808SPIState *s)
{
    switch ((s->config & SPI_FRAME_SIZE_MASK) >> SPI_FRAME_SIZE_SHIFT) {
    case 0:
        return 0xFF;
    case 1:
        return 0xFFFF;
    case 2:
        return 0x00FFFFFF;
    default:
        return 0xFFFFFFFF;
    }
}

static bool bl808_spi_enabled(const BL808SPIState *s)
{
    return (s->config & (SPI_MASTER_EN | SPI_SLAVE_EN)) != 0;
}

static uint32_t bl808_spi_idle_frame(const BL808SPIState *s)
{
    return bl808_spi_frame_mask(s);
}

static uint32_t bl808_spi_dynamic_ints(const BL808SPIState *s)
{
    uint32_t tx_free = bl808_spi_tx_free(s);
    uint32_t tx_thresh = (s->fifo_config1 >> 16) & 0x1f;
    uint32_t rx_thresh = (s->fifo_config1 >> 24) & 0x1f;
    uint32_t pending = 0;

    if (tx_free > tx_thresh) {
        pending |= SPI_INT_TX_FIFO;
    }
    if (s->rx_count > rx_thresh) {
        pending |= SPI_INT_RX_FIFO;
    }
    if (s->fifo_config0 & SPI_FIFO_TX_UNDERFLOW) {
        pending |= SPI_INT_TX_UNDER;
    }
    if (s->fifo_config0 & (SPI_FIFO_TX_OVERFLOW | SPI_FIFO_RX_OVERFLOW |
                           SPI_FIFO_RX_UNDERFLOW)) {
        pending |= SPI_INT_FIFO_ERR;
    }

    return pending;
}

static void bl808_spi_update_irq(BL808SPIState *s)
{
    uint32_t pending = (s->int_sts | bl808_spi_dynamic_ints(s)) &
                       s->int_enable & ~s->int_mask;
    qemu_set_irq(s->irq, bl808_spi_clock_active(s) && pending != 0);
}

static void bl808_spi_clear_tx_fifo(BL808SPIState *s)
{
    s->tx_head = 0;
    s->tx_tail = 0;
    s->tx_count = 0;
    s->fifo_config0 &= ~(SPI_FIFO_TX_OVERFLOW | SPI_FIFO_TX_UNDERFLOW);
}

static void bl808_spi_clear_rx_fifo(BL808SPIState *s)
{
    s->rx_head = 0;
    s->rx_tail = 0;
    s->rx_count = 0;
    s->rx_ignore_remaining = 0;
    s->fifo_config0 &= ~(SPI_FIFO_RX_OVERFLOW | SPI_FIFO_RX_UNDERFLOW);
}

static void bl808_spi_schedule_transfer(BL808SPIState *s)
{
    if (!s->clock_enabled || s->reset_asserted || !bl808_spi_enabled(s) ||
        s->transfer_scheduled || s->tx_count == 0) {
        return;
    }

    s->transfer_scheduled = true;
    qemu_bh_schedule(s->transfer_bh);
}

static void bl808_spi_push_rx(BL808SPIState *s, uint32_t value)
{
    if ((s->config & SPI_RXD_IGNR_EN) &&
        s->rx_ignore_remaining < (s->rxd_ignr & 0xFF)) {
        s->rx_ignore_remaining++;
        return;
    }

    if (s->rx_count >= bl808_spi_fifo_depth(s)) {
        s->fifo_config0 |= SPI_FIFO_RX_OVERFLOW;
        return;
    }

    s->rx_fifo[s->rx_tail] = value & bl808_spi_frame_mask(s);
    s->rx_tail = (s->rx_tail + 1) % BL808_SPI_FIFO_DEPTH;
    s->rx_count++;
}

bool bl808_spi_dma_can_read(BL808SPIState *s, unsigned width_bytes)
{
    if (!s->clock_enabled || s->reset_asserted ||
        !(s->fifo_config0 & SPI_FIFO_DMA_RX_EN)) {
        return false;
    }

    switch (width_bytes) {
    case 1:
    case 2:
    case 4:
        return s->rx_count > 0;
    default:
        return false;
    }
}

bool bl808_spi_dma_can_write(BL808SPIState *s, unsigned width_bytes)
{
    if (!s->clock_enabled || s->reset_asserted ||
        !(s->fifo_config0 & SPI_FIFO_DMA_TX_EN)) {
        return false;
    }

    switch (width_bytes) {
    case 1:
    case 2:
    case 4:
        return s->tx_count < bl808_spi_fifo_depth(s);
    default:
        return false;
    }
}

uint32_t bl808_spi_dma_read(BL808SPIState *s, unsigned width_bytes)
{
    if (s->rx_count == 0) {
        s->fifo_config0 |= SPI_FIFO_RX_UNDERFLOW;
        bl808_spi_update_irq(s);
        return bl808_spi_idle_frame(s);
    }

    {
        uint32_t value = s->rx_fifo[s->rx_head];

        s->rx_head = (s->rx_head + 1) % BL808_SPI_FIFO_DEPTH;
        s->rx_count--;
        bl808_spi_update_irq(s);

        switch (width_bytes) {
        case 1:
            return value & 0xFF;
        case 2:
            return value & 0xFFFF;
        default:
            return value;
        }
    }
}

void bl808_spi_dma_write(BL808SPIState *s, uint32_t value,
                         unsigned width_bytes)
{
    uint32_t masked;

    if (s->tx_count >= bl808_spi_fifo_depth(s)) {
        s->fifo_config0 |= SPI_FIFO_TX_OVERFLOW;
        bl808_spi_update_irq(s);
        return;
    }
    if (s->tx_count == 0) {
        s->rx_ignore_remaining = 0;
    }

    switch (width_bytes) {
    case 1:
        masked = value & 0xFF;
        break;
    case 2:
        masked = value & 0xFFFF;
        break;
    default:
        masked = value;
        break;
    }

    s->tx_fifo[s->tx_tail] = masked & bl808_spi_frame_mask(s);
    s->tx_tail = (s->tx_tail + 1) % BL808_SPI_FIFO_DEPTH;
    s->tx_count++;
    s->int_sts &= ~SPI_INT_END;
    bl808_spi_schedule_transfer(s);
    bl808_spi_update_irq(s);
}

static void bl808_spi_transfer_bh(void *opaque)
{
    BL808SPIState *s = opaque;
    bool transferred = false;

    s->transfer_scheduled = false;
    if (!s->clock_enabled || s->reset_asserted || !bl808_spi_enabled(s)) {
        bl808_spi_update_irq(s);
        return;
    }

    s->transfer_active = true;
    if (!s->loopback) {
        qemu_set_irq(s->cs, 0);
    }
    while (s->tx_count > 0) {
        uint32_t tx = s->tx_fifo[s->tx_head];
        uint32_t rx;

        if (s->loopback) {
            rx = tx;
        } else if (s->bus) {
            rx = ssi_transfer(s->bus, tx);
        } else {
            rx = bl808_spi_idle_frame(s);
        }

        s->tx_head = (s->tx_head + 1) % BL808_SPI_FIFO_DEPTH;
        s->tx_count--;
        bl808_spi_push_rx(s, rx & bl808_spi_frame_mask(s));
        transferred = true;
    }
    if (!s->loopback) {
        qemu_set_irq(s->cs, 1);
    }
    s->transfer_active = false;

    if (transferred) {
        s->int_sts |= SPI_INT_END;
    }
    bl808_spi_update_irq(s);
}

static uint32_t bl808_spi_fifo_config1(const BL808SPIState *s)
{
    uint32_t value = s->fifo_config1 &
                     ~((uint32_t)0x3F | (0x3FU << 8));

    value |= bl808_spi_tx_free(s) & 0x3F;
    value |= (MIN(s->rx_count, bl808_spi_fifo_depth(s)) & 0x3F) << 8;
    return value;
}

static uint64_t bl808_spi_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808SPIState *s = opaque;

    switch (offset) {
    case SPI_CONFIG_REG:
        return s->config;
    case SPI_INT_STS:
        return (s->int_sts | bl808_spi_dynamic_ints(s)) |
               (s->int_mask << SPI_INT_MASK_SHIFT) |
               (s->int_enable << 24);
    case SPI_BUS_BUSY:
        return s->transfer_active || s->transfer_scheduled;
    case SPI_PRD0:
        return s->prd0;
    case SPI_PRD1:
        return s->prd1;
    case SPI_RXD_IGNR:
        return s->rxd_ignr;
    case SPI_STO_VALUE:
        return s->sto_value;
    case SPI_FIFO_CONFIG0:
        return s->fifo_config0;
    case SPI_FIFO_CONFIG1:
        return bl808_spi_fifo_config1(s);
    case SPI_FIFO_RDATA:
        if (s->rx_count == 0) {
            s->fifo_config0 |= SPI_FIFO_RX_UNDERFLOW;
            bl808_spi_update_irq(s);
            return bl808_spi_idle_frame(s);
        }
        {
            uint32_t value = s->rx_fifo[s->rx_head];

            s->rx_head = (s->rx_head + 1) % BL808_SPI_FIFO_DEPTH;
            s->rx_count--;
            bl808_spi_update_irq(s);
            return value;
        }
    default:
        return 0;
    }
}

static void bl808_spi_write(void *opaque, hwaddr offset, uint64_t value,
                            unsigned size)
{
    BL808SPIState *s = opaque;

    if (s->reset_asserted) {
        return;
    }

    switch (offset) {
    case SPI_CONFIG_REG:
        s->config = (uint32_t)value;
        if (!bl808_spi_enabled(s)) {
            s->transfer_active = false;
        } else {
            bl808_spi_schedule_transfer(s);
        }
        break;
    case SPI_INT_STS:
        s->int_enable = ((uint32_t)value >> 24) & SPI_INT_STATUS_MASK;
        s->int_mask = ((uint32_t)value >> SPI_INT_MASK_SHIFT) &
                      SPI_INT_STATUS_MASK;
        s->int_sts &= ~(((uint32_t)value >> SPI_INT_CLEAR_SHIFT) &
                        SPI_INT_STATUS_MASK);
        break;
    case SPI_PRD0:
        s->prd0 = (uint32_t)value;
        break;
    case SPI_PRD1:
        s->prd1 = (uint32_t)value;
        break;
    case SPI_RXD_IGNR:
        s->rxd_ignr = (uint32_t)value;
        s->rx_ignore_remaining = 0;
        break;
    case SPI_STO_VALUE:
        s->sto_value = (uint32_t)value;
        break;
    case SPI_FIFO_CONFIG0:
        s->fifo_config0 &= ~SPI_FIFO_STATUS_MASK;
        s->fifo_config0 |= (uint32_t)value &
                           (SPI_FIFO_DMA_RX_EN | SPI_FIFO_DMA_TX_EN);
        if (value & SPI_FIFO_TX_CLR) {
            bl808_spi_clear_tx_fifo(s);
            s->int_sts &= ~SPI_INT_END;
        }
        if (value & SPI_FIFO_RX_CLR) {
            bl808_spi_clear_rx_fifo(s);
        }
        break;
    case SPI_FIFO_CONFIG1:
        s->fifo_config1 = (uint32_t)value &
                          ((0x1FU << 16) | (0x1FU << 24));
        break;
    case SPI_FIFO_WDATA:
        if (s->tx_count >= bl808_spi_fifo_depth(s)) {
            s->fifo_config0 |= SPI_FIFO_TX_OVERFLOW;
            break;
        }
        if (s->tx_count == 0) {
            s->rx_ignore_remaining = 0;
        }
        s->tx_fifo[s->tx_tail] = (uint32_t)value & bl808_spi_frame_mask(s);
        s->tx_tail = (s->tx_tail + 1) % BL808_SPI_FIFO_DEPTH;
        s->tx_count++;
        s->int_sts &= ~SPI_INT_END;
        bl808_spi_schedule_transfer(s);
        break;
    default:
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_spi: write to undefined offset 0x%" HWADDR_PRIx
                      " = 0x%" PRIx64 "\n", offset, value);
        return;
    }

    bl808_spi_update_irq(s);
}

static const MemoryRegionOps bl808_spi_ops = {
    .read = bl808_spi_read,
    .write = bl808_spi_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static void bl808_spi_reset(DeviceState *dev)
{
    BL808SPIState *s = BL808_SPI(dev);

    s->config = 0;
    s->int_sts = 0;
    s->int_enable = SPI_INT_STATUS_MASK;
    s->int_mask = SPI_INT_STATUS_MASK;
    s->prd0 = 0x0F0F0F0F;
    s->prd1 = 0x0F;
    s->rxd_ignr = 0;
    s->sto_value = 0x0FFF;
    s->fifo_config0 = 0;
    s->fifo_config1 = 0;
    bl808_spi_clear_tx_fifo(s);
    bl808_spi_clear_rx_fifo(s);
    s->transfer_scheduled = false;
    s->transfer_active = false;
    qemu_bh_cancel(s->transfer_bh);
    qemu_set_irq(s->cs, 1);
    bl808_spi_update_irq(s);
}

void bl808_spi_set_clock_enabled(BL808SPIState *s, bool enabled)
{
    s->gate_enabled = enabled;
    bl808_spi_recompute_clock(s);
    if (!bl808_spi_clock_active(s)) {
        qemu_bh_cancel(s->transfer_bh);
        s->transfer_scheduled = false;
        s->transfer_active = false;
        qemu_set_irq(s->cs, 1);
    } else {
        bl808_spi_schedule_transfer(s);
    }
    bl808_spi_update_irq(s);
}

void bl808_spi_set_module_clock_enabled(BL808SPIState *s, bool enabled)
{
    s->module_clock_enabled = enabled;
    bl808_spi_set_clock_enabled(s, s->gate_enabled);
}

void bl808_spi_set_reset_asserted(BL808SPIState *s, bool asserted)
{
    s->reset_asserted = asserted;
    if (asserted) {
        device_cold_reset(DEVICE(s));
    } else {
        bl808_spi_schedule_transfer(s);
    }
    bl808_spi_update_irq(s);
}

static void bl808_spi_init(Object *obj)
{
    BL808SPIState *s = BL808_SPI(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    memory_region_init_io(&s->iomem, obj, &bl808_spi_ops, s,
                          TYPE_BL808_SPI, BL808_SPI_REG_SIZE);
    sysbus_init_mmio(sbd, &s->iomem);
    sysbus_init_irq(sbd, &s->irq);
    qdev_init_gpio_out_named(DEVICE(obj), &s->cs, SSI_GPIO_CS, 1);
    s->bus = ssi_create_bus(DEVICE(obj), "ssi");
    s->transfer_bh = qemu_bh_new(bl808_spi_transfer_bh, s);
    s->gate_enabled = true;
    s->module_clock_enabled = true;
    s->reset_asserted = false;
    bl808_spi_recompute_clock(s);
}

static void bl808_spi_finalize(Object *obj)
{
    BL808SPIState *s = BL808_SPI(obj);

    qemu_bh_delete(s->transfer_bh);
}

static const Property bl808_spi_props[] = {
    DEFINE_PROP_BOOL("loopback", BL808SPIState, loopback, false),
};

static void bl808_spi_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    device_class_set_props(dc, bl808_spi_props);
    device_class_set_legacy_reset(dc, bl808_spi_reset);
}

static const TypeInfo bl808_spi_info = {
    .name          = TYPE_BL808_SPI,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(BL808SPIState),
    .instance_init = bl808_spi_init,
    .instance_finalize = bl808_spi_finalize,
    .class_init    = bl808_spi_class_init,
};

static void bl808_spi_register_types(void)
{
    type_register_static(&bl808_spi_info);
}

type_init(bl808_spi_register_types)
