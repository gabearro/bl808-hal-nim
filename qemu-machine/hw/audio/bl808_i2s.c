/*
 * Bouffalo Lab BL808 I2S controller emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qemu/main-loop.h"
#include "hw/audio/bl808_i2s.h"

#define I2S_CONFIG             0x00
#define I2S_INT_STS            0x04
#define I2S_BCLK_CONFIG        0x10
#define I2S_FIFO_CONFIG0       0x80
#define I2S_FIFO_CONFIG1       0x84
#define I2S_FIFO_WDATA         0x88
#define I2S_FIFO_RDATA         0x8C
#define I2S_IO_CONFIG          0xFC

#define I2S_CFG_MASTER_EN      BIT(0)
#define I2S_CFG_SLAVE_EN       BIT(1)
#define I2S_CFG_TX_EN          BIT(2)
#define I2S_CFG_RX_EN          BIT(3)

#define I2S_INT_TX_READY       BIT(0)
#define I2S_INT_RX_READY       BIT(1)
#define I2S_INT_FIFO_ERR       BIT(2)
#define I2S_INT_TX_MASK        BIT(8)
#define I2S_INT_RX_MASK        BIT(9)
#define I2S_INT_ERR_MASK       BIT(10)
#define I2S_INT_TX_EN          BIT(24)
#define I2S_INT_RX_EN          BIT(25)
#define I2S_INT_ERR_EN         BIT(26)
#define I2S_INT_CTRL_MASK      (I2S_INT_TX_MASK | I2S_INT_RX_MASK | \
                                I2S_INT_ERR_MASK | I2S_INT_TX_EN | \
                                I2S_INT_RX_EN | I2S_INT_ERR_EN)

#define I2S_FIFO_DMA_TX_EN     BIT(0)
#define I2S_FIFO_DMA_RX_EN     BIT(1)
#define I2S_FIFO_TX_CLR        BIT(2)
#define I2S_FIFO_RX_CLR        BIT(3)
#define I2S_FIFO_TX_OVERFLOW   BIT(4)
#define I2S_FIFO_TX_UNDERFLOW  BIT(5)
#define I2S_FIFO_RX_OVERFLOW   BIT(6)
#define I2S_FIFO_RX_UNDERFLOW  BIT(7)
#define I2S_FIFO_TX_TH_SHIFT   16
#define I2S_FIFO_RX_TH_SHIFT   24
#define I2S_FIFO_TH_MASK       0xFu

static bool bl808_i2s_clock_active(const BL808I2SState *s)
{
    return s->gate_enabled && s->module_clock_enabled &&
           s->clock_enabled && !s->reset_asserted;
}

static uint32_t bl808_i2s_tx_free(const BL808I2SState *s)
{
    return BL808_I2S_FIFO_DEPTH - s->tx_count;
}

static uint32_t bl808_i2s_rx_ready_count(const BL808I2SState *s)
{
    return s->rx_count;
}

static uint32_t bl808_i2s_tx_threshold(const BL808I2SState *s)
{
    return (s->fifo_config1 >> I2S_FIFO_TX_TH_SHIFT) & I2S_FIFO_TH_MASK;
}

static uint32_t bl808_i2s_rx_threshold(const BL808I2SState *s)
{
    return (s->fifo_config1 >> I2S_FIFO_RX_TH_SHIFT) & I2S_FIFO_TH_MASK;
}

static uint32_t bl808_i2s_dynamic_ints(const BL808I2SState *s)
{
    uint32_t pending = 0;

    if (bl808_i2s_tx_free(s) > bl808_i2s_tx_threshold(s)) {
        pending |= I2S_INT_TX_READY;
    }
    if (bl808_i2s_rx_ready_count(s) > bl808_i2s_rx_threshold(s)) {
        pending |= I2S_INT_RX_READY;
    }
    if (s->fifo_config0 & (I2S_FIFO_TX_OVERFLOW | I2S_FIFO_TX_UNDERFLOW |
                           I2S_FIFO_RX_OVERFLOW | I2S_FIFO_RX_UNDERFLOW)) {
        pending |= I2S_INT_FIFO_ERR;
    }

    return pending;
}

static void bl808_i2s_update_irq(BL808I2SState *s)
{
    uint32_t pending = 0;
    uint32_t dyn = bl808_i2s_dynamic_ints(s);

    if ((dyn & I2S_INT_TX_READY) &&
        (s->int_sts & I2S_INT_TX_EN) &&
        !(s->int_sts & I2S_INT_TX_MASK)) {
        pending |= I2S_INT_TX_READY;
    }
    if ((dyn & I2S_INT_RX_READY) &&
        (s->int_sts & I2S_INT_RX_EN) &&
        !(s->int_sts & I2S_INT_RX_MASK)) {
        pending |= I2S_INT_RX_READY;
    }
    if ((dyn & I2S_INT_FIFO_ERR) &&
        (s->int_sts & I2S_INT_ERR_EN) &&
        !(s->int_sts & I2S_INT_ERR_MASK)) {
        pending |= I2S_INT_FIFO_ERR;
    }

    qemu_set_irq(s->irq, bl808_i2s_clock_active(s) && pending != 0);
}

static void bl808_i2s_flush_fifo(BL808I2SState *s, bool tx)
{
    if (tx) {
        s->tx_head = 0;
        s->tx_tail = 0;
        s->tx_count = 0;
        s->fifo_config0 &= ~(I2S_FIFO_TX_OVERFLOW | I2S_FIFO_TX_UNDERFLOW);
    } else {
        s->rx_head = 0;
        s->rx_tail = 0;
        s->rx_count = 0;
        s->fifo_config0 &= ~(I2S_FIFO_RX_OVERFLOW | I2S_FIFO_RX_UNDERFLOW);
    }
}

static void bl808_i2s_tx_bh(void *opaque)
{
    BL808I2SState *s = opaque;

    s->tx_scheduled = false;
    if (!bl808_i2s_clock_active(s) || !(s->config & I2S_CFG_TX_EN)) {
        return;
    }

    /*
     * Model the serializer consuming queued samples once the block is running.
     * This keeps DMA/CPU FIFOs flowing without inventing a synthetic audio sink.
     */
    s->tx_head = 0;
    s->tx_tail = 0;
    s->tx_count = 0;
    bl808_i2s_update_irq(s);
}

static void bl808_i2s_schedule_tx(BL808I2SState *s)
{
    if (!s->tx_scheduled && s->tx_count != 0 &&
        bl808_i2s_clock_active(s) && (s->config & I2S_CFG_TX_EN)) {
        s->tx_scheduled = true;
        qemu_bh_schedule(s->tx_bh);
    }
}

static void bl808_i2s_push_tx(BL808I2SState *s, uint32_t value)
{
    if (s->tx_count >= BL808_I2S_FIFO_DEPTH) {
        s->fifo_config0 |= I2S_FIFO_TX_OVERFLOW;
        bl808_i2s_update_irq(s);
        return;
    }

    s->tx_fifo[s->tx_tail] = value;
    s->tx_tail = (s->tx_tail + 1) % BL808_I2S_FIFO_DEPTH;
    s->tx_count++;
    bl808_i2s_schedule_tx(s);
    bl808_i2s_update_irq(s);
}

static uint32_t bl808_i2s_pop_rx(BL808I2SState *s)
{
    uint32_t value;

    if (s->rx_count == 0) {
        s->fifo_config0 |= I2S_FIFO_RX_UNDERFLOW;
        bl808_i2s_update_irq(s);
        return 0;
    }

    value = s->rx_fifo[s->rx_head];
    s->rx_head = (s->rx_head + 1) % BL808_I2S_FIFO_DEPTH;
    s->rx_count--;
    bl808_i2s_update_irq(s);
    return value;
}

void bl808_i2s_set_clock_enabled(BL808I2SState *s, bool enabled)
{
    s->clock_enabled = enabled;
    if (!enabled) {
        qemu_bh_cancel(s->tx_bh);
        s->tx_scheduled = false;
    } else {
        bl808_i2s_schedule_tx(s);
    }
    bl808_i2s_update_irq(s);
}

void bl808_i2s_set_module_clock_enabled(BL808I2SState *s, bool enabled)
{
    s->module_clock_enabled = enabled;
    if (!enabled) {
        qemu_bh_cancel(s->tx_bh);
        s->tx_scheduled = false;
    } else {
        bl808_i2s_schedule_tx(s);
    }
    bl808_i2s_update_irq(s);
}

void bl808_i2s_set_reset_asserted(BL808I2SState *s, bool asserted)
{
    s->reset_asserted = asserted;
    if (asserted) {
        device_cold_reset(DEVICE(s));
    } else {
        bl808_i2s_schedule_tx(s);
    }
    bl808_i2s_update_irq(s);
}

bool bl808_i2s_dma_can_read(BL808I2SState *s, unsigned width_bytes)
{
    return width_bytes <= 4 &&
           bl808_i2s_clock_active(s) &&
           (s->config & I2S_CFG_RX_EN) &&
           (s->fifo_config0 & I2S_FIFO_DMA_RX_EN) &&
           bl808_i2s_rx_ready_count(s) > bl808_i2s_rx_threshold(s);
}

bool bl808_i2s_dma_can_write(BL808I2SState *s, unsigned width_bytes)
{
    return width_bytes <= 4 &&
           bl808_i2s_clock_active(s) &&
           (s->config & I2S_CFG_TX_EN) &&
           (s->fifo_config0 & I2S_FIFO_DMA_TX_EN) &&
           bl808_i2s_tx_free(s) > bl808_i2s_tx_threshold(s);
}

uint32_t bl808_i2s_dma_read(BL808I2SState *s, unsigned width_bytes)
{
    return bl808_i2s_pop_rx(s);
}

void bl808_i2s_dma_write(BL808I2SState *s, uint32_t value,
                         unsigned width_bytes)
{
    bl808_i2s_push_tx(s, value);
}

static uint64_t bl808_i2s_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808I2SState *s = opaque;

    switch (offset) {
    case I2S_CONFIG:
        return s->config;
    case I2S_INT_STS:
        return (s->int_sts & I2S_INT_CTRL_MASK) | bl808_i2s_dynamic_ints(s);
    case I2S_BCLK_CONFIG:
        return s->bclk_config;
    case I2S_FIFO_CONFIG0:
        return s->fifo_config0;
    case I2S_FIFO_CONFIG1:
        return (s->fifo_config1 &
                ~((uint32_t)(I2S_FIFO_TH_MASK << I2S_FIFO_TX_TH_SHIFT) |
                  (uint32_t)(I2S_FIFO_TH_MASK << I2S_FIFO_RX_TH_SHIFT) |
                  0x1Fu | (0x1Fu << 8))) |
               (bl808_i2s_tx_free(s) & 0x1Fu) |
               ((bl808_i2s_rx_ready_count(s) & 0x1Fu) << 8);
    case I2S_FIFO_RDATA:
        return bl808_i2s_pop_rx(s);
    case I2S_IO_CONFIG:
        return s->io_config;
    default:
        return 0;
    }
}

static void bl808_i2s_write(void *opaque, hwaddr offset, uint64_t value,
                            unsigned size)
{
    BL808I2SState *s = opaque;
    uint32_t next = (uint32_t)value;

    if (s->reset_asserted) {
        return;
    }

    switch (offset) {
    case I2S_CONFIG:
        s->config = next & 0x001FFFFFu;
        bl808_i2s_schedule_tx(s);
        break;
    case I2S_INT_STS:
        s->int_sts = (s->int_sts & ~I2S_INT_CTRL_MASK) |
                     (next & I2S_INT_CTRL_MASK);
        break;
    case I2S_BCLK_CONFIG:
        s->bclk_config = next & 0x0FFF0FFFu;
        break;
    case I2S_FIFO_CONFIG0:
        if (next & I2S_FIFO_TX_CLR) {
            bl808_i2s_flush_fifo(s, true);
        }
        if (next & I2S_FIFO_RX_CLR) {
            bl808_i2s_flush_fifo(s, false);
        }
        s->fifo_config0 = (s->fifo_config0 &
                           (I2S_FIFO_TX_OVERFLOW | I2S_FIFO_TX_UNDERFLOW |
                            I2S_FIFO_RX_OVERFLOW | I2S_FIFO_RX_UNDERFLOW)) |
                          (next & ~(I2S_FIFO_TX_CLR | I2S_FIFO_RX_CLR |
                                    I2S_FIFO_TX_OVERFLOW |
                                    I2S_FIFO_TX_UNDERFLOW |
                                    I2S_FIFO_RX_OVERFLOW |
                                    I2S_FIFO_RX_UNDERFLOW));
        break;
    case I2S_FIFO_CONFIG1:
        s->fifo_config1 = next &
                          ((I2S_FIFO_TH_MASK << I2S_FIFO_TX_TH_SHIFT) |
                           (I2S_FIFO_TH_MASK << I2S_FIFO_RX_TH_SHIFT));
        break;
    case I2S_FIFO_WDATA:
        bl808_i2s_push_tx(s, next);
        return;
    case I2S_IO_CONFIG:
        s->io_config = next & 0xFFu;
        break;
    default:
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_i2s: write to unknown offset 0x%" HWADDR_PRIx
                      " = 0x%" PRIx64 "\n", offset, value);
        return;
    }

    bl808_i2s_update_irq(s);
}

static const MemoryRegionOps bl808_i2s_ops = {
    .read = bl808_i2s_read,
    .write = bl808_i2s_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static void bl808_i2s_reset(DeviceState *dev)
{
    BL808I2SState *s = BL808_I2S(dev);

    s->config = 0;
    s->int_sts = I2S_INT_TX_MASK | I2S_INT_RX_MASK | I2S_INT_ERR_MASK |
                 I2S_INT_TX_EN | I2S_INT_RX_EN | I2S_INT_ERR_EN;
    s->bclk_config = 0x00010001u;
    s->fifo_config0 = 0;
    s->fifo_config1 = 0;
    s->io_config = 0;
    s->tx_head = 0;
    s->tx_tail = 0;
    s->tx_count = 0;
    s->rx_head = 0;
    s->rx_tail = 0;
    s->rx_count = 0;
    s->tx_scheduled = false;
    qemu_bh_cancel(s->tx_bh);
    bl808_i2s_update_irq(s);
}

static void bl808_i2s_init(Object *obj)
{
    BL808I2SState *s = BL808_I2S(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    memory_region_init_io(&s->iomem, obj, &bl808_i2s_ops, s,
                          TYPE_BL808_I2S, BL808_I2S_REG_SIZE);
    sysbus_init_mmio(sbd, &s->iomem);
    sysbus_init_irq(sbd, &s->irq);
    s->tx_bh = qemu_bh_new(bl808_i2s_tx_bh, s);
    s->gate_enabled = true;
    s->module_clock_enabled = true;
    s->clock_enabled = true;
}

static void bl808_i2s_finalize(Object *obj)
{
    BL808I2SState *s = BL808_I2S(obj);

    qemu_bh_delete(s->tx_bh);
}

static void bl808_i2s_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    device_class_set_legacy_reset(dc, bl808_i2s_reset);
}

static const TypeInfo bl808_i2s_info = {
    .name          = TYPE_BL808_I2S,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(BL808I2SState),
    .instance_init = bl808_i2s_init,
    .instance_finalize = bl808_i2s_finalize,
    .class_init    = bl808_i2s_class_init,
};

static void bl808_i2s_register_types(void)
{
    type_register_static(&bl808_i2s_info);
}

type_init(bl808_i2s_register_types)
