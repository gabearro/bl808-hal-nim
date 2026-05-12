/*
 * Bouffalo Lab BL808 I2C controller emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "hw/irq.h"
#include "hw/qdev-properties.h"
#include "hw/nvram/eeprom_at24c.h"
#include "hw/sysbus.h"
#include "hw/i2c/bl808_i2c.h"

#define REG_CONFIG        0x00
#define REG_INT_STS       0x04
#define REG_SUB_ADDR      0x08
#define REG_BUS_BUSY      0x0C
#define REG_PRD_START     0x10
#define REG_PRD_STOP      0x14
#define REG_PRD_DATA      0x18
#define REG_FIFO_CONFIG0  0x80
#define REG_FIFO_CONFIG1  0x84
#define REG_FIFO_WDATA    0x88
#define REG_FIFO_RDATA    0x8C

#define CFG_MASTER_EN         BIT(0)
#define CFG_PKT_DIR           BIT(1)
#define CFG_SUB_ADDR_EN       BIT(4)
#define CFG_SUB_ADDR_BC_SHIFT 5
#define CFG_SUB_ADDR_BC_MASK  (0x3u << CFG_SUB_ADDR_BC_SHIFT)
#define CFG_10B_ADDR_EN       BIT(7)
#define CFG_SLV_ADDR_SHIFT    8
#define CFG_SLV_ADDR_MASK     (0x7Fu << CFG_SLV_ADDR_SHIFT)
#define CFG_PKT_LEN_SHIFT     16
#define CFG_PKT_LEN_MASK      (0xFFu << CFG_PKT_LEN_SHIFT)

#define INT_END               BIT(0)
#define INT_TX_FIFO           BIT(1)
#define INT_RX_FIFO           BIT(2)
#define INT_NAK               BIT(3)
#define INT_ARB               BIT(4)
#define INT_FIFO_ERR          BIT(5)
#define INT_MASK_SHIFT        8
#define INT_CLEAR_SHIFT       16

#define FIFO_DMA_RX_EN        BIT(0)
#define FIFO_DMA_TX_EN        BIT(1)
#define FIFO_TX_CLR           BIT(2)
#define FIFO_RX_CLR           BIT(3)

static bool bl808_i2c_clock_active(const BL808I2CState *s)
{
    return s->clock_enabled && !s->reset_asserted;
}

static void bl808_i2c_recompute_clock(BL808I2CState *s)
{
    s->clock_enabled = s->gate_enabled && s->module_clock_enabled;
}

static void bl808_i2c_update_irq(BL808I2CState *s)
{
    uint32_t status = s->int_sts & 0x3F;
    uint32_t mask = (s->int_sts >> INT_MASK_SHIFT) & 0x3F;
    bool level = bl808_i2c_clock_active(s) && (status & ~mask) != 0;

    qemu_set_irq(s->irq, level);
}

static void bl808_i2c_set_int(BL808I2CState *s, uint32_t bits)
{
    s->int_sts |= bits & 0x3F;
    bl808_i2c_update_irq(s);
}

static void tx_fifo_clear(BL808I2CState *s)
{
    s->tx_head = 0;
    s->tx_count = 0;
}

static void rx_fifo_clear(BL808I2CState *s)
{
    s->rx_head = 0;
    s->rx_count = 0;
}

static void bl808_i2c_finish_transfer(BL808I2CState *s)
{
    if (s->transfer_active && s->bus) {
        i2c_end_transfer(s->bus);
    }
    s->transfer_active = false;
    s->config &= ~CFG_MASTER_EN;
}

static void bl808_i2c_abort_transfer(BL808I2CState *s, uint32_t status_bits)
{
    bl808_i2c_finish_transfer(s);
    if (status_bits) {
        bl808_i2c_set_int(s, status_bits);
    }
}

static void tx_fifo_push(BL808I2CState *s, uint8_t val)
{
    if (s->tx_count >= BL808_I2C_FIFO_DEPTH) {
        bl808_i2c_set_int(s, INT_FIFO_ERR);
        return;
    }

    s->tx_fifo[(s->tx_head + s->tx_count) % BL808_I2C_FIFO_DEPTH] = val;
    s->tx_count++;
}

static uint8_t tx_fifo_pop(BL808I2CState *s)
{
    uint8_t val;

    if (s->tx_count == 0) {
        bl808_i2c_set_int(s, INT_FIFO_ERR);
        return 0xFF;
    }

    val = s->tx_fifo[s->tx_head];
    s->tx_head = (s->tx_head + 1) % BL808_I2C_FIFO_DEPTH;
    s->tx_count--;
    return val;
}

static void rx_fifo_push(BL808I2CState *s, uint8_t val)
{
    if (s->rx_count >= BL808_I2C_FIFO_DEPTH) {
        bl808_i2c_set_int(s, INT_FIFO_ERR);
        return;
    }

    s->rx_fifo[(s->rx_head + s->rx_count) % BL808_I2C_FIFO_DEPTH] = val;
    s->rx_count++;
}

static uint8_t rx_fifo_pop(BL808I2CState *s)
{
    uint8_t val;

    if (s->rx_count == 0) {
        bl808_i2c_set_int(s, INT_FIFO_ERR);
        return 0xFF;
    }

    val = s->rx_fifo[s->rx_head];
    s->rx_head = (s->rx_head + 1) % BL808_I2C_FIFO_DEPTH;
    s->rx_count--;
    return val;
}

static uint8_t bl808_i2c_slave_addr(const BL808I2CState *s)
{
    return (s->config & CFG_SLV_ADDR_MASK) >> CFG_SLV_ADDR_SHIFT;
}

static unsigned bl808_i2c_subaddr_len(const BL808I2CState *s)
{
    return ((s->config & CFG_SUB_ADDR_BC_MASK) >> CFG_SUB_ADDR_BC_SHIFT) + 1;
}

static int bl808_i2c_start_bus_send(BL808I2CState *s)
{
    return i2c_start_send(s->bus, bl808_i2c_slave_addr(s));
}

static int bl808_i2c_send_subaddr(BL808I2CState *s)
{
    unsigned len;

    if (!(s->config & CFG_SUB_ADDR_EN)) {
        return 0;
    }

    len = bl808_i2c_subaddr_len(s);
    while (len-- > 0) {
        uint8_t byte = (s->sub_addr >> (len * 8)) & 0xFF;

        if (i2c_send(s->bus, byte) < 0) {
            return -1;
        }
    }

    return 0;
}

static void bl808_i2c_fill_rx(BL808I2CState *s)
{
    while (s->rx_count < BL808_I2C_FIFO_DEPTH && s->xfer_remaining > 0) {
        rx_fifo_push(s, i2c_recv(s->bus));
        s->xfer_remaining--;
    }
}

static int bl808_i2c_drain_tx(BL808I2CState *s)
{
    while (s->tx_count > 0 && s->xfer_remaining > 0) {
        if (i2c_send(s->bus, tx_fifo_pop(s)) < 0) {
            return -1;
        }
        s->xfer_remaining--;
    }

    return 0;
}

static void bl808_i2c_check_complete(BL808I2CState *s)
{
    if (s->xfer_remaining == 0) {
        bl808_i2c_finish_transfer(s);
        bl808_i2c_set_int(s, INT_END);
        return;
    }

    if (s->xfer_is_read) {
        if (s->rx_count > 0) {
            bl808_i2c_set_int(s, INT_RX_FIFO);
        }
    } else if (s->tx_count < BL808_I2C_FIFO_DEPTH) {
        bl808_i2c_set_int(s, INT_TX_FIFO);
    }
}

static void bl808_i2c_start_transfer(BL808I2CState *s)
{
    bool is_read = (s->config & CFG_PKT_DIR) != 0;
    unsigned pkt_len = ((s->config & CFG_PKT_LEN_MASK) >> CFG_PKT_LEN_SHIFT) + 1;

    if (!bl808_i2c_clock_active(s)) {
        bl808_i2c_abort_transfer(s, 0);
        return;
    }
    if (s->config & CFG_10B_ADDR_EN) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_i2c: 10-bit slave addressing is not implemented\n");
        bl808_i2c_abort_transfer(s, INT_NAK | INT_END);
        return;
    }

    s->int_sts &= ~(INT_END | INT_TX_FIFO | INT_RX_FIFO | INT_NAK |
                    INT_ARB | INT_FIFO_ERR);
    s->xfer_is_read = is_read;
    s->xfer_remaining = pkt_len;
    s->transfer_active = true;

    if (is_read) {
        if (bl808_i2c_start_bus_send(s) != 0 ||
            bl808_i2c_send_subaddr(s) < 0) {
            bl808_i2c_abort_transfer(s, INT_NAK | INT_END);
            return;
        }
        i2c_end_transfer(s->bus);
        if (i2c_start_recv(s->bus, bl808_i2c_slave_addr(s)) != 0) {
            bl808_i2c_abort_transfer(s, INT_NAK | INT_END);
            return;
        }
        bl808_i2c_fill_rx(s);
    } else {
        if (bl808_i2c_start_bus_send(s) != 0 ||
            bl808_i2c_send_subaddr(s) < 0) {
            bl808_i2c_abort_transfer(s, INT_NAK | INT_END);
            return;
        }
        if (bl808_i2c_drain_tx(s) < 0) {
            bl808_i2c_abort_transfer(s, INT_NAK | INT_END);
            return;
        }
    }

    bl808_i2c_check_complete(s);
}

bool bl808_i2c_dma_can_read(BL808I2CState *s, unsigned width_bytes)
{
    if (!bl808_i2c_clock_active(s) ||
        !(s->fifo_config0 & FIFO_DMA_RX_EN) ||
        width_bytes != 1) {
        return false;
    }

    return s->rx_count > 0;
}

bool bl808_i2c_dma_can_write(BL808I2CState *s, unsigned width_bytes)
{
    if (!bl808_i2c_clock_active(s) ||
        !(s->fifo_config0 & FIFO_DMA_TX_EN) ||
        width_bytes != 1) {
        return false;
    }

    return s->tx_count < BL808_I2C_FIFO_DEPTH;
}

uint32_t bl808_i2c_dma_read(BL808I2CState *s, unsigned width_bytes)
{
    uint8_t val;

    if (width_bytes != 1) {
        return 0;
    }

    val = rx_fifo_pop(s);
    if (s->transfer_active && s->xfer_is_read) {
        bl808_i2c_fill_rx(s);
        bl808_i2c_check_complete(s);
    }
    return val;
}

void bl808_i2c_dma_write(BL808I2CState *s, uint32_t value,
                         unsigned width_bytes)
{
    if (width_bytes != 1) {
        return;
    }

    tx_fifo_push(s, (uint8_t)value);
    if (s->transfer_active && !s->xfer_is_read) {
        if (bl808_i2c_drain_tx(s) < 0) {
            bl808_i2c_abort_transfer(s, INT_NAK | INT_END);
            return;
        }
        bl808_i2c_check_complete(s);
    }
}

static uint32_t bl808_i2c_fifo_config1(const BL808I2CState *s)
{
    return (BL808_I2C_FIFO_DEPTH - s->tx_count) |
           (s->rx_count << 8);
}

static uint64_t bl808_i2c_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808I2CState *s = opaque;

    switch (offset) {
    case REG_CONFIG:
        return s->config;
    case REG_INT_STS:
        return s->int_sts;
    case REG_SUB_ADDR:
        return s->sub_addr;
    case REG_BUS_BUSY:
        return s->transfer_active || (s->bus && i2c_bus_busy(s->bus));
    case REG_PRD_START:
        return s->prd_start;
    case REG_PRD_STOP:
        return s->prd_stop;
    case REG_PRD_DATA:
        return s->prd_data;
    case REG_FIFO_CONFIG0:
        return s->fifo_config0;
    case REG_FIFO_CONFIG1:
        return bl808_i2c_fifo_config1(s);
    case REG_FIFO_RDATA:
    {
        uint8_t val = rx_fifo_pop(s);

        if (s->transfer_active && s->xfer_is_read) {
            bl808_i2c_fill_rx(s);
            bl808_i2c_check_complete(s);
        }
        return val;
    }
    default:
        return 0;
    }
}

static void bl808_i2c_write(void *opaque, hwaddr offset, uint64_t value,
                            unsigned size)
{
    BL808I2CState *s = opaque;

    if (s->reset_asserted) {
        return;
    }

    switch (offset) {
    case REG_CONFIG:
    {
        uint32_t old = s->config;

        s->config = (uint32_t)value;
        if (!(old & CFG_MASTER_EN) && (s->config & CFG_MASTER_EN)) {
            bl808_i2c_start_transfer(s);
        } else if ((old & CFG_MASTER_EN) && !(s->config & CFG_MASTER_EN)) {
            bl808_i2c_abort_transfer(s, 0);
        }
        break;
    }
    case REG_INT_STS:
    {
        uint32_t mask_bits = (uint32_t)value & (0x3F << INT_MASK_SHIFT);
        uint32_t clear_bits = ((uint32_t)value >> INT_CLEAR_SHIFT) & 0x3F;

        s->int_sts = (s->int_sts & ~(0x3F << INT_MASK_SHIFT)) | mask_bits;
        s->int_sts &= ~clear_bits;
        bl808_i2c_update_irq(s);
        break;
    }
    case REG_SUB_ADDR:
        s->sub_addr = (uint32_t)value;
        break;
    case REG_PRD_START:
        s->prd_start = (uint32_t)value;
        break;
    case REG_PRD_STOP:
        s->prd_stop = (uint32_t)value;
        break;
    case REG_PRD_DATA:
        s->prd_data = (uint32_t)value;
        break;
    case REG_FIFO_CONFIG0:
        s->fifo_config0 = (uint32_t)value & (FIFO_DMA_RX_EN | FIFO_DMA_TX_EN);
        if (value & FIFO_TX_CLR) {
            tx_fifo_clear(s);
        }
        if (value & FIFO_RX_CLR) {
            rx_fifo_clear(s);
        }
        bl808_i2c_update_irq(s);
        break;
    case REG_FIFO_WDATA:
        tx_fifo_push(s, (uint8_t)value);
        if (s->transfer_active && !s->xfer_is_read) {
            if (bl808_i2c_drain_tx(s) < 0) {
                bl808_i2c_abort_transfer(s, INT_NAK | INT_END);
                break;
            }
            bl808_i2c_check_complete(s);
        }
        break;
    default:
        break;
    }
}

static const MemoryRegionOps bl808_i2c_ops = {
    .read = bl808_i2c_read,
    .write = bl808_i2c_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static void bl808_i2c_reset_hold(BL808I2CState *s)
{
    if (s->transfer_active && s->bus) {
        i2c_end_transfer(s->bus);
    }

    s->config = 0;
    s->int_sts = 0x3F00;
    s->sub_addr = 0;
    s->prd_start = 0x0f0f0f0f;
    s->prd_stop = 0x0f0f0f0f;
    s->prd_data = 0x0f0f0f0f;
    s->fifo_config0 = 0;
    tx_fifo_clear(s);
    rx_fifo_clear(s);
    s->transfer_active = false;
    s->xfer_remaining = 0;
    s->xfer_is_read = false;
    bl808_i2c_update_irq(s);
}

void bl808_i2c_set_clock_enabled(BL808I2CState *s, bool enabled)
{
    s->gate_enabled = enabled;
    bl808_i2c_recompute_clock(s);
    if (!bl808_i2c_clock_active(s) && s->transfer_active) {
        bl808_i2c_abort_transfer(s, 0);
    }
    bl808_i2c_update_irq(s);
}

void bl808_i2c_set_module_clock_enabled(BL808I2CState *s, bool enabled)
{
    s->module_clock_enabled = enabled;
    bl808_i2c_recompute_clock(s);
    if (!bl808_i2c_clock_active(s) && s->transfer_active) {
        bl808_i2c_abort_transfer(s, 0);
    }
    bl808_i2c_update_irq(s);
}

void bl808_i2c_set_reset_asserted(BL808I2CState *s, bool asserted)
{
    s->reset_asserted = asserted;
    if (asserted) {
        bl808_i2c_reset_hold(s);
    } else {
        bl808_i2c_update_irq(s);
    }
}

static void bl808_i2c_reset(DeviceState *dev)
{
    BL808I2CState *s = BL808_I2C(dev);

    bl808_i2c_recompute_clock(s);
    bl808_i2c_reset_hold(s);
}

static void bl808_i2c_init(Object *obj)
{
    BL808I2CState *s = BL808_I2C(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    memory_region_init_io(&s->iomem, obj, &bl808_i2c_ops, s,
                          TYPE_BL808_I2C, BL808_I2C_REG_SIZE);
    sysbus_init_mmio(sbd, &s->iomem);
    sysbus_init_irq(sbd, &s->irq);

    s->bus = i2c_init_bus(DEVICE(obj), TYPE_BL808_I2C ".bus");
    s->attach_default_eeprom = true;
    s->gate_enabled = true;
    s->module_clock_enabled = true;
    s->reset_asserted = false;
    bl808_i2c_recompute_clock(s);
}

static void bl808_i2c_realize(DeviceState *dev, Error **errp)
{
    BL808I2CState *s = BL808_I2C(dev);

    if (s->attach_default_eeprom) {
        uint8_t init_rom[BL808_I2C_EEPROM_SIZE];

        memset(init_rom, 0xFF, sizeof(init_rom));
        at24c_eeprom_init_rom(s->bus, BL808_I2C_EEPROM_ADDR,
                              sizeof(init_rom), init_rom,
                              sizeof(init_rom));
    }
}

static const Property bl808_i2c_props[] = {
    DEFINE_PROP_BOOL("attach-default-eeprom", BL808I2CState,
                     attach_default_eeprom, true),
};

static void bl808_i2c_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    dc->realize = bl808_i2c_realize;
    device_class_set_props(dc, bl808_i2c_props);
    device_class_set_legacy_reset(dc, bl808_i2c_reset);
}

static const TypeInfo bl808_i2c_info = {
    .name          = TYPE_BL808_I2C,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(BL808I2CState),
    .instance_init = bl808_i2c_init,
    .class_init    = bl808_i2c_class_init,
};

static void bl808_i2c_register_types(void)
{
    type_register_static(&bl808_i2c_info);
}

type_init(bl808_i2c_register_types)
