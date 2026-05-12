/*
 * Bouffalo Lab BL808 UART emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "hw/irq.h"
#include "hw/qdev-properties.h"
#include "hw/qdev-properties-system.h"
#include "hw/char/bl808_uart.h"

/* Register offsets */
#define UART_UTX_CONFIG      0x00
#define UART_URX_CONFIG      0x04
#define UART_BIT_PRD         0x08
#define UART_DATA_CONFIG     0x0C
#define UART_UTX_IR_POSITION 0x10
#define UART_URX_IR_POSITION 0x14
#define UART_URX_RTO_TIMER   0x18
#define UART_SW_MODE         0x1C
#define UART_INT_STS         0x20
#define UART_INT_MASK        0x24
#define UART_INT_CLEAR       0x28
#define UART_INT_EN          0x2C
#define UART_STATUS          0x30
#define UART_STS_URX_ABR_PRD 0x34
#define UART_URX_ABR_PRD_B01 0x38
#define UART_URX_ABR_PRD_B23 0x3C
#define UART_URX_ABR_PRD_B45 0x40
#define UART_URX_ABR_PRD_B67 0x44
#define UART_URX_ABR_PW_TOL  0x48
#define UART_URX_BCR_INT_CFG 0x50
#define UART_UTX_RS485_CFG   0x54
#define UART_FIFO_CONFIG_0   0x80
#define UART_FIFO_CONFIG_1   0x84
#define UART_FIFO_WDATA      0x88
#define UART_FIFO_RDATA      0x8C

#define UTX_EN           BIT(0)
#define UTX_FREERUN_EN   BIT(2)
#define UTX_LEN_SHIFT    16
#define URX_EN           BIT(0)
#define URX_LEN_SHIFT    16

#define INT_UTX_END      BIT(0)
#define INT_URX_END      BIT(1)
#define INT_UTX_FRDY     BIT(2)
#define INT_URX_FRDY     BIT(3)
#define INT_UTX_FER      BIT(6)
#define INT_URX_FER      BIT(7)

#define FIFO_DMA_TX_EN      BIT(0)
#define FIFO_DMA_RX_EN      BIT(1)
#define FIFO_TX_CLR         BIT(2)
#define FIFO_RX_CLR         BIT(3)
#define FIFO_TX_OVERFLOW    BIT(4)
#define FIFO_TX_UNDERFLOW   BIT(5)
#define FIFO_RX_OVERFLOW    BIT(6)
#define FIFO_RX_UNDERFLOW   BIT(7)

static bool bl808_uart_clock_active(const BL808UARTState *s)
{
    return s->clock_enabled && !s->reset_asserted;
}

static void bl808_uart_recompute_clock(BL808UARTState *s)
{
    s->clock_enabled = s->gate_enabled && s->module_clock_enabled;
}

static uint32_t bl808_uart_dynamic_ints(const BL808UARTState *s)
{
    uint32_t tx_free = BL808_UART_FIFO_DEPTH - s->tx_count;
    uint32_t tx_thresh = (s->fifo_config_1 >> 16) & 0x1f;
    uint32_t rx_thresh = (s->fifo_config_1 >> 24) & 0x1f;
    uint32_t dynamic = 0;

    if (tx_free > tx_thresh) {
        dynamic |= INT_UTX_FRDY;
    }
    if (s->rx_count >= rx_thresh && s->rx_count > 0) {
        dynamic |= INT_URX_FRDY;
    }
    if (s->fifo_config_0 & (FIFO_TX_OVERFLOW | FIFO_TX_UNDERFLOW)) {
        dynamic |= INT_UTX_FER;
    }
    if (s->fifo_config_0 & (FIFO_RX_OVERFLOW | FIFO_RX_UNDERFLOW)) {
        dynamic |= INT_URX_FER;
    }

    return dynamic;
}

static void bl808_uart_update_irq(BL808UARTState *s)
{
    uint32_t pending = (s->int_sts | bl808_uart_dynamic_ints(s)) &
                       s->int_en & ~s->int_mask;

    qemu_set_irq(s->irq, bl808_uart_clock_active(s) && pending != 0);
}

static int bl808_uart_can_receive(void *opaque)
{
    BL808UARTState *s = opaque;

    if (!bl808_uart_clock_active(s) || !(s->urx_config & URX_EN)) {
        return 0;
    }

    return BL808_UART_FIFO_DEPTH - s->rx_count;
}

static void bl808_uart_maybe_set_rx_end(BL808UARTState *s)
{
    uint32_t rx_len = s->urx_config >> URX_LEN_SHIFT;

    if (rx_len != 0 && s->rx_total >= rx_len) {
        s->int_sts |= INT_URX_END;
        s->rx_total = 0;
    }
}

static void bl808_uart_flush_tx(BL808UARTState *s)
{
    if (!bl808_uart_clock_active(s) || !(s->utx_config & UTX_EN)) {
        return;
    }

    while (s->tx_count > 0) {
        uint8_t ch = s->tx_fifo[s->tx_head];
        uint32_t tx_len = s->utx_config >> UTX_LEN_SHIFT;

        s->tx_head = (s->tx_head + 1) % BL808_UART_FIFO_DEPTH;
        s->tx_count--;

        qemu_chr_fe_write_all(&s->chr, &ch, 1);
        s->tx_total++;

        if (!(s->utx_config & UTX_FREERUN_EN) && tx_len != 0 &&
            s->tx_total >= tx_len) {
            s->int_sts |= INT_UTX_END;
            s->utx_config &= ~UTX_EN;
            s->tx_total = 0;
            break;
        }
    }
}

static void bl808_uart_receive(void *opaque, const uint8_t *buf, int size)
{
    BL808UARTState *s = opaque;

    if (!bl808_uart_clock_active(s) || !(s->urx_config & URX_EN)) {
        return;
    }

    for (int i = 0; i < size; i++) {
        if (s->rx_count >= BL808_UART_FIFO_DEPTH) {
            s->fifo_config_0 |= FIFO_RX_OVERFLOW;
            break;
        }

        s->rx_fifo[s->rx_tail] = buf[i];
        s->rx_tail = (s->rx_tail + 1) % BL808_UART_FIFO_DEPTH;
        s->rx_count++;
        s->rx_total++;
    }

    bl808_uart_maybe_set_rx_end(s);
    bl808_uart_update_irq(s);
}

static uint32_t bl808_uart_status(const BL808UARTState *s)
{
    uint32_t status = 0;

    if (s->tx_count > 0) {
        status |= BIT(0);
    }
    if (s->rx_count > 0) {
        status |= BIT(1);
    }
    return status;
}

static uint32_t bl808_uart_fifo_config_1(const BL808UARTState *s)
{
    uint32_t value = s->fifo_config_1 &
                     ~((uint32_t)0x3f | (0x3fU << 8));

    value |= (BL808_UART_FIFO_DEPTH - s->tx_count) & 0x3f;
    value |= (s->rx_count & 0x3f) << 8;
    return value;
}

bool bl808_uart_dma_can_read(BL808UARTState *s, unsigned width_bytes)
{
    if (!bl808_uart_clock_active(s) ||
        !(s->fifo_config_0 & FIFO_DMA_RX_EN) ||
        width_bytes != 1) {
        return false;
    }

    return s->rx_count > 0;
}

bool bl808_uart_dma_can_write(BL808UARTState *s, unsigned width_bytes)
{
    if (!bl808_uart_clock_active(s) ||
        !(s->fifo_config_0 & FIFO_DMA_TX_EN) ||
        width_bytes != 1) {
        return false;
    }

    return s->tx_count < BL808_UART_FIFO_DEPTH;
}

uint32_t bl808_uart_dma_read(BL808UARTState *s, unsigned width_bytes)
{
    uint8_t ch;

    if (width_bytes != 1) {
        return 0;
    }
    if (s->rx_count == 0) {
        s->fifo_config_0 |= FIFO_RX_UNDERFLOW;
        bl808_uart_update_irq(s);
        return 0xFF;
    }

    ch = s->rx_fifo[s->rx_head];
    s->rx_head = (s->rx_head + 1) % BL808_UART_FIFO_DEPTH;
    s->rx_count--;
    bl808_uart_update_irq(s);
    return ch;
}

void bl808_uart_dma_write(BL808UARTState *s, uint32_t value,
                          unsigned width_bytes)
{
    if (width_bytes != 1) {
        return;
    }
    if (s->tx_count >= BL808_UART_FIFO_DEPTH) {
        s->fifo_config_0 |= FIFO_TX_OVERFLOW;
        bl808_uart_update_irq(s);
        return;
    }
    if (!(s->utx_config & UTX_EN)) {
        s->fifo_config_0 |= FIFO_TX_UNDERFLOW;
        bl808_uart_update_irq(s);
        return;
    }

    s->tx_fifo[s->tx_tail] = (uint8_t)value;
    s->tx_tail = (s->tx_tail + 1) % BL808_UART_FIFO_DEPTH;
    s->tx_count++;
    bl808_uart_flush_tx(s);
    bl808_uart_update_irq(s);
}

static uint64_t bl808_uart_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808UARTState *s = opaque;

    switch (offset) {
    case UART_UTX_CONFIG:
        return s->utx_config;
    case UART_URX_CONFIG:
        return s->urx_config;
    case UART_BIT_PRD:
        return s->bit_prd;
    case UART_DATA_CONFIG:
        return s->data_config;
    case UART_UTX_IR_POSITION:
        return s->utx_ir_position;
    case UART_URX_IR_POSITION:
        return s->urx_ir_position;
    case UART_URX_RTO_TIMER:
        return s->urx_rto_timer;
    case UART_SW_MODE:
        return s->uart_sw_mode;
    case UART_INT_STS:
        return s->int_sts | bl808_uart_dynamic_ints(s);
    case UART_INT_MASK:
        return s->int_mask;
    case UART_INT_EN:
        return s->int_en;
    case UART_STATUS:
        return bl808_uart_status(s);
    case UART_STS_URX_ABR_PRD:
        return s->sts_urx_abr_prd;
    case UART_URX_ABR_PRD_B01:
        return s->urx_abr_prd_b01;
    case UART_URX_ABR_PRD_B23:
        return s->urx_abr_prd_b23;
    case UART_URX_ABR_PRD_B45:
        return s->urx_abr_prd_b45;
    case UART_URX_ABR_PRD_B67:
        return s->urx_abr_prd_b67;
    case UART_URX_ABR_PW_TOL:
        return s->urx_abr_pw_tol;
    case UART_URX_BCR_INT_CFG:
        return s->urx_bcr_int_cfg;
    case UART_UTX_RS485_CFG:
        return s->utx_rs485_cfg;
    case UART_FIFO_CONFIG_0:
        return s->fifo_config_0;
    case UART_FIFO_CONFIG_1:
        return bl808_uart_fifo_config_1(s);
    case UART_FIFO_RDATA:
        if (s->rx_count > 0) {
            uint8_t ch = s->rx_fifo[s->rx_head];

            s->rx_head = (s->rx_head + 1) % BL808_UART_FIFO_DEPTH;
            s->rx_count--;
            bl808_uart_update_irq(s);
            return ch;
        }
        s->fifo_config_0 |= FIFO_RX_UNDERFLOW;
        bl808_uart_update_irq(s);
        return 0xFF;
    default:
        return 0;
    }
}

static void bl808_uart_write(void *opaque, hwaddr offset, uint64_t value,
                             unsigned size)
{
    BL808UARTState *s = opaque;

    if (s->reset_asserted) {
        return;
    }

    switch (offset) {
    case UART_UTX_CONFIG:
    {
        uint32_t old = s->utx_config;

        s->utx_config = value;
        if (!(old & UTX_EN) && (s->utx_config & UTX_EN)) {
            bl808_uart_flush_tx(s);
        }
        break;
    }
    case UART_URX_CONFIG:
        s->urx_config = value;
        break;
    case UART_BIT_PRD:
        s->bit_prd = value;
        break;
    case UART_DATA_CONFIG:
        s->data_config = value;
        break;
    case UART_UTX_IR_POSITION:
        s->utx_ir_position = value;
        break;
    case UART_URX_IR_POSITION:
        s->urx_ir_position = value;
        break;
    case UART_URX_RTO_TIMER:
        s->urx_rto_timer = value & 0xff;
        break;
    case UART_SW_MODE:
        s->uart_sw_mode = value & 0xf;
        break;
    case UART_INT_MASK:
        s->int_mask = value;
        bl808_uart_update_irq(s);
        break;
    case UART_INT_CLEAR:
        s->int_sts &= ~value;
        bl808_uart_update_irq(s);
        break;
    case UART_INT_EN:
        s->int_en = value;
        bl808_uart_update_irq(s);
        break;
    case UART_URX_ABR_PW_TOL:
        s->urx_abr_pw_tol = value & 0xff;
        break;
    case UART_URX_BCR_INT_CFG:
        s->urx_bcr_int_cfg = value & 0xffff;
        break;
    case UART_UTX_RS485_CFG:
        s->utx_rs485_cfg = value;
        break;
    case UART_FIFO_CONFIG_0:
        s->fifo_config_0 &= ~(FIFO_TX_CLR | FIFO_RX_CLR);
        s->fifo_config_0 = (s->fifo_config_0 &
                            ~(FIFO_DMA_TX_EN | FIFO_DMA_RX_EN)) |
                           (value & (FIFO_DMA_TX_EN | FIFO_DMA_RX_EN));
        if (value & FIFO_TX_CLR) {
            s->fifo_config_0 &= ~(FIFO_TX_OVERFLOW | FIFO_TX_UNDERFLOW);
            s->tx_head = s->tx_tail = s->tx_count = 0;
        }
        if (value & FIFO_RX_CLR) {
            s->fifo_config_0 &= ~(FIFO_RX_OVERFLOW | FIFO_RX_UNDERFLOW);
            s->rx_head = s->rx_tail = s->rx_count = 0;
        }
        bl808_uart_update_irq(s);
        break;
    case UART_FIFO_CONFIG_1:
        s->fifo_config_1 = value & ((0x1fU << 16) | (0x1fU << 24));
        bl808_uart_update_irq(s);
        break;
    case UART_FIFO_WDATA:
        if (s->utx_config & UTX_EN) {
            if (s->tx_count >= BL808_UART_FIFO_DEPTH) {
                s->fifo_config_0 |= FIFO_TX_OVERFLOW;
            } else {
                s->tx_fifo[s->tx_tail] = (uint8_t)value;
                s->tx_tail = (s->tx_tail + 1) % BL808_UART_FIFO_DEPTH;
                s->tx_count++;
                bl808_uart_flush_tx(s);
            }
        } else {
            s->fifo_config_0 |= FIFO_TX_UNDERFLOW;
        }
        bl808_uart_update_irq(s);
        break;
    default:
        break;
    }
}

static const MemoryRegionOps bl808_uart_ops = {
    .read = bl808_uart_read,
    .write = bl808_uart_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static void bl808_uart_init(Object *obj)
{
    BL808UARTState *s = BL808_UART(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    memory_region_init_io(&s->iomem, obj, &bl808_uart_ops, s,
                          TYPE_BL808_UART, BL808_UART_REG_SIZE);
    sysbus_init_mmio(sbd, &s->iomem);
    sysbus_init_irq(sbd, &s->irq);

    s->gate_enabled = true;
    s->module_clock_enabled = true;
    s->reset_asserted = false;
    bl808_uart_recompute_clock(s);
}

static void bl808_uart_realize(DeviceState *dev, Error **errp)
{
    BL808UARTState *s = BL808_UART(dev);

    qemu_chr_fe_set_handlers(&s->chr, bl808_uart_can_receive,
                             bl808_uart_receive, NULL, NULL, s, NULL, true);
}

static void bl808_uart_reset(DeviceState *dev)
{
    BL808UARTState *s = BL808_UART(dev);

    s->utx_config = (4u << 13) | (1u << 11) | (7u << 8);
    s->urx_config = 7u << 8;
    s->bit_prd = 0x00FF00FF;
    s->data_config = 0;
    s->utx_ir_position = (159u << 16) | 112u;
    s->urx_ir_position = 111u;
    s->urx_rto_timer = 15u;
    s->uart_sw_mode = 0;
    s->int_sts = 0;
    s->int_mask = 0x0FFF;
    s->int_en = 0x0FFF;
    s->fifo_config_0 = 0;
    s->fifo_config_1 = 0;
    s->sts_urx_abr_prd = 0;
    s->urx_abr_prd_b01 = 0;
    s->urx_abr_prd_b23 = 0;
    s->urx_abr_prd_b45 = 0;
    s->urx_abr_prd_b67 = 0;
    s->urx_abr_pw_tol = 3;
    s->urx_bcr_int_cfg = 0xFFFF;
    s->utx_rs485_cfg = 0x2;
    s->tx_head = s->tx_tail = s->tx_count = 0;
    s->rx_head = s->rx_tail = s->rx_count = 0;
    s->tx_total = s->rx_total = 0;
    bl808_uart_recompute_clock(s);
    bl808_uart_update_irq(s);
}

void bl808_uart_set_clock_enabled(BL808UARTState *s, bool enabled)
{
    s->gate_enabled = enabled;
    bl808_uart_recompute_clock(s);
    if (bl808_uart_clock_active(s)) {
        bl808_uart_flush_tx(s);
    }
    bl808_uart_update_irq(s);
}

void bl808_uart_set_module_clock_enabled(BL808UARTState *s, bool enabled)
{
    s->module_clock_enabled = enabled;
    bl808_uart_recompute_clock(s);
    if (bl808_uart_clock_active(s)) {
        bl808_uart_flush_tx(s);
    }
    bl808_uart_update_irq(s);
}

void bl808_uart_set_reset_asserted(BL808UARTState *s, bool asserted)
{
    s->reset_asserted = asserted;
    if (asserted) {
        device_cold_reset(DEVICE(s));
    }
    bl808_uart_update_irq(s);
}

static const Property bl808_uart_properties[] = {
    DEFINE_PROP_CHR("chardev", BL808UARTState, chr),
};

static void bl808_uart_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    dc->realize = bl808_uart_realize;
    device_class_set_legacy_reset(dc, bl808_uart_reset);
    device_class_set_props(dc, bl808_uart_properties);
}

static const TypeInfo bl808_uart_info = {
    .name          = TYPE_BL808_UART,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(BL808UARTState),
    .instance_init = bl808_uart_init,
    .class_init    = bl808_uart_class_init,
};

static void bl808_uart_register_types(void)
{
    type_register_static(&bl808_uart_info);
}

type_init(bl808_uart_register_types)
