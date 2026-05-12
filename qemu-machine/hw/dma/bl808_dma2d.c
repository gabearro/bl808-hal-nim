/*
 * Bouffalo Lab BL808 DMA2D emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/bswap.h"
#include "qemu/log.h"
#include "qemu/main-loop.h"
#include "hw/dma/bl808_dma2d.h"

#define DMA2D_INTSTATUS       0x000
#define DMA2D_INTTCSTATUS     0x004
#define DMA2D_INTTCCLEAR      0x008
#define DMA2D_ENBLDCHNS       0x00c
#define DMA2D_CONFIG          0x010
#define DMA2D_SYNC            0x014
#define DMA2D_SOFTBREQ        0x020
#define DMA2D_SOFTLBREQ       0x024
#define DMA2D_SOFTSREQ        0x028
#define DMA2D_SOFTLSREQ       0x02c
#define DMA2D_QOS             0x038

#define DMA2D_CH_BASE         0x100
#define DMA2D_CH_STRIDE       0x100

#define DMA2D_C_SRCADDR       0x00
#define DMA2D_C_DSTADDR       0x04
#define DMA2D_C_LLI           0x08
#define DMA2D_C_BUS           0x0c
#define DMA2D_C_SRC_CNT       0x10
#define DMA2D_C_SRC_XIC       0x14
#define DMA2D_C_SRC_YIC       0x18
#define DMA2D_C_DST_CNT       0x1c
#define DMA2D_C_DST_XIC       0x20
#define DMA2D_C_DST_YIC       0x24
#define DMA2D_C_KEY           0x74
#define DMA2D_C_KEY_EN        0x78
#define DMA2D_C_CFG           0x7c

#define DMA2D_E               BIT(0)
#define DMA2D_TRANSFERSIZE_MASK 0x0fffu
#define DMA2D_SRC_BURST_SHIFT 12
#define DMA2D_DST_BURST_SHIFT 15
#define DMA2D_SRC_SIZE_SHIFT  18
#define DMA2D_DST_SIZE_SHIFT  21
#define DMA2D_SI              BIT(26)
#define DMA2D_DI              BIT(27)
#define DMA2D_I               BIT(31)

#define DMA2D_CH_EN           BIT(0)
#define DMA2D_FIFO_EMPTY      BIT(16)
#define DMA2D_REG_2D_EN       BIT(31)

#define DMA2D_KEY_EN_BIT      BIT(0)
#define DMA2D_KEY_MODE_SHIFT  1
#define DMA2D_KEY_MODE_MASK   (0x3u << DMA2D_KEY_MODE_SHIFT)
#define DMA2D_KEY_STRB_SHIFT  4
#define DMA2D_KEY_STRB_MASK   (0xfu << DMA2D_KEY_STRB_SHIFT)

static bool bl808_dma2d_active(const BL808DMA2DState *s)
{
    return s->clock_enabled && !s->reset_asserted;
}

static unsigned bl808_dma2d_width_bytes(uint32_t bus, bool dst)
{
    uint32_t width = (bus >> (dst ? DMA2D_DST_SIZE_SHIFT : DMA2D_SRC_SIZE_SHIFT))
                     & 0x3;

    switch (width) {
    case 0:
        return 1;
    case 1:
        return 2;
    case 2:
        return 4;
    default:
        return 8;
    }
}

static uint64_t bl808_dma2d_read_mem(hwaddr addr, unsigned width_bytes)
{
    uint8_t tmp8;
    uint16_t tmp16;
    uint32_t tmp32;
    uint64_t tmp64;

    switch (width_bytes) {
    case 1:
        cpu_physical_memory_read(addr, &tmp8, 1);
        return tmp8;
    case 2:
        cpu_physical_memory_read(addr, &tmp16, 2);
        return le16_to_cpu(tmp16);
    case 4:
        cpu_physical_memory_read(addr, &tmp32, 4);
        return le32_to_cpu(tmp32);
    case 8:
        cpu_physical_memory_read(addr, &tmp64, 8);
        return le64_to_cpu(tmp64);
    default:
        return 0;
    }
}

static void bl808_dma2d_write_mem(hwaddr addr, uint64_t value,
                                  unsigned width_bytes)
{
    uint8_t tmp8;
    uint16_t tmp16;
    uint32_t tmp32;
    uint64_t tmp64;

    switch (width_bytes) {
    case 1:
        tmp8 = value;
        cpu_physical_memory_write(addr, &tmp8, 1);
        break;
    case 2:
        tmp16 = cpu_to_le16(value);
        cpu_physical_memory_write(addr, &tmp16, 2);
        break;
    case 4:
        tmp32 = cpu_to_le32(value);
        cpu_physical_memory_write(addr, &tmp32, 4);
        break;
    case 8:
        tmp64 = cpu_to_le64(value);
        cpu_physical_memory_write(addr, &tmp64, 8);
        break;
    default:
        break;
    }
}

static uint32_t bl808_dma2d_enabled_channels(BL808DMA2DState *s)
{
    uint32_t mask = 0;

    for (unsigned i = 0; i < BL808_DMA2D_CHANNELS; i++) {
        if (s->channels[i].cfg & DMA2D_CH_EN) {
            mask |= BIT(i);
        }
    }
    return mask;
}

static void bl808_dma2d_update_irq(BL808DMA2DState *s)
{
    for (unsigned i = 0; i < BL808_DMA2D_CHANNELS; i++) {
        qemu_set_irq(s->irq[i],
                     bl808_dma2d_active(s) && (s->int_status & BIT(i)) != 0);
    }
}

static bool bl808_dma2d_color_key_skip(BL808DMA2DChannel *ch, uint64_t value)
{
    uint32_t strobe;
    uint32_t masked_value = 0;
    uint32_t masked_key = 0;
    uint32_t key = ch->key;
    uint32_t v = (uint32_t)value;

    if (!(ch->key_en & DMA2D_KEY_EN_BIT)) {
        return false;
    }

    strobe = (ch->key_en & DMA2D_KEY_STRB_MASK) >> DMA2D_KEY_STRB_SHIFT;
    if (strobe & BIT(0)) {
        masked_value |= v & 0x000000ffu;
        masked_key |= key & 0x000000ffu;
    }
    if (strobe & BIT(1)) {
        masked_value |= v & 0x0000ff00u;
        masked_key |= key & 0x0000ff00u;
    }
    if (strobe & BIT(2)) {
        masked_value |= v & 0x00ff0000u;
        masked_key |= key & 0x00ff0000u;
    }
    if (strobe & BIT(3)) {
        masked_value |= v & 0xff000000u;
        masked_key |= key & 0xff000000u;
    }

    return masked_value == masked_key;
}

static void bl808_dma2d_complete_channel(BL808DMA2DState *s, unsigned chno)
{
    BL808DMA2DChannel *ch = &s->channels[chno];

    ch->active = false;
    ch->cfg &= ~DMA2D_CH_EN;
    ch->cfg |= DMA2D_FIFO_EMPTY;
    if (ch->bus & DMA2D_I) {
        s->int_tc_status |= BIT(chno);
        s->int_status |= BIT(chno);
    }
}

static void bl808_dma2d_run_linear(BL808DMA2DState *s, unsigned chno)
{
    BL808DMA2DChannel *ch = &s->channels[chno];
    uint32_t count = ch->bus & DMA2D_TRANSFERSIZE_MASK;
    unsigned src_width = bl808_dma2d_width_bytes(ch->bus, false);
    unsigned dst_width = bl808_dma2d_width_bytes(ch->bus, true);
    hwaddr src = ch->src_addr;
    hwaddr dst = ch->dst_addr;

    while (count-- > 0) {
        uint64_t value = bl808_dma2d_read_mem(src, src_width);

        if (!bl808_dma2d_color_key_skip(ch, value)) {
            bl808_dma2d_write_mem(dst, value, dst_width);
        }

        if (ch->bus & DMA2D_SI) {
            src += src_width;
        }
        if (ch->bus & DMA2D_DI) {
            dst += dst_width;
        }
    }

    ch->src_addr = src;
    ch->dst_addr = dst;
    bl808_dma2d_complete_channel(s, chno);
}

static void bl808_dma2d_run_2d(BL808DMA2DState *s, unsigned chno)
{
    BL808DMA2DChannel *ch = &s->channels[chno];
    unsigned width_bytes = bl808_dma2d_width_bytes(ch->bus, false);
    uint16_t xcount = ch->src_cnt & 0xffffu;
    uint16_t ycount = (ch->src_cnt >> 16) & 0xffffu;
    hwaddr row_src = ch->src_addr;
    hwaddr row_dst = ch->dst_addr;

    for (uint16_t y = 0; y < ycount; y++) {
        hwaddr src = row_src;
        hwaddr dst = row_dst;

        for (uint16_t x = 0; x < xcount; x++) {
            uint64_t value = bl808_dma2d_read_mem(src, width_bytes);

            if (!bl808_dma2d_color_key_skip(ch, value)) {
                bl808_dma2d_write_mem(dst, value, width_bytes);
            }
            src += (int32_t)ch->src_xic;
            dst += (int32_t)ch->dst_xic;
        }

        row_src = src + (int32_t)ch->src_yic;
        row_dst = dst + (int32_t)ch->dst_yic;
    }

    ch->src_addr = row_src;
    ch->dst_addr = row_dst;
    bl808_dma2d_complete_channel(s, chno);
}

static bool bl808_dma2d_run_channel(BL808DMA2DState *s, unsigned chno)
{
    BL808DMA2DChannel *ch = &s->channels[chno];

    if (!bl808_dma2d_active(s)) {
        ch->active = false;
        return false;
    }
    if (!(s->global_cfg & DMA2D_E) || !(ch->cfg & DMA2D_CH_EN)) {
        ch->active = false;
        return false;
    }

    ch->active = true;
    ch->cfg &= ~DMA2D_FIFO_EMPTY;
    if (ch->cfg & DMA2D_REG_2D_EN) {
        bl808_dma2d_run_2d(s, chno);
    } else {
        bl808_dma2d_run_linear(s, chno);
    }
    return true;
}

static void bl808_dma2d_schedule(BL808DMA2DState *s)
{
    if (!s->run_scheduled && bl808_dma2d_active(s) &&
        bl808_dma2d_enabled_channels(s) != 0 &&
        (s->global_cfg & DMA2D_E)) {
        s->run_scheduled = true;
        qemu_bh_schedule(s->run_bh);
    }
}

static void bl808_dma2d_run_bh(void *opaque)
{
    BL808DMA2DState *s = opaque;

    s->run_scheduled = false;
    for (unsigned i = 0; i < BL808_DMA2D_CHANNELS; i++) {
        bl808_dma2d_run_channel(s, i);
    }
    bl808_dma2d_update_irq(s);
}

static uint64_t bl808_dma2d_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808DMA2DState *s = opaque;
    unsigned chno;
    BL808DMA2DChannel *ch;
    hwaddr choff;

    if (size != 4) {
        return 0;
    }

    switch (offset) {
    case DMA2D_INTSTATUS:
        return s->int_status;
    case DMA2D_INTTCSTATUS:
        return s->int_tc_status;
    case DMA2D_INTTCCLEAR:
        return 0;
    case DMA2D_ENBLDCHNS:
        return bl808_dma2d_enabled_channels(s);
    case DMA2D_CONFIG:
        return s->global_cfg;
    case DMA2D_SYNC:
        return s->sync;
    case DMA2D_SOFTBREQ:
        return s->soft_breq;
    case DMA2D_SOFTLBREQ:
        return s->soft_lbreq;
    case DMA2D_SOFTSREQ:
        return s->soft_sreq;
    case DMA2D_SOFTLSREQ:
        return s->soft_lsreq;
    case DMA2D_QOS:
        return s->qos;
    default:
        break;
    }

    if (offset < DMA2D_CH_BASE ||
        offset >= DMA2D_CH_BASE + BL808_DMA2D_CHANNELS * DMA2D_CH_STRIDE) {
        return 0;
    }

    chno = (offset - DMA2D_CH_BASE) / DMA2D_CH_STRIDE;
    ch = &s->channels[chno];
    choff = (offset - DMA2D_CH_BASE) % DMA2D_CH_STRIDE;

    switch (choff) {
    case DMA2D_C_SRCADDR:
        return ch->src_addr;
    case DMA2D_C_DSTADDR:
        return ch->dst_addr;
    case DMA2D_C_LLI:
        return ch->lli;
    case DMA2D_C_BUS:
        return ch->bus;
    case DMA2D_C_SRC_CNT:
        return ch->src_cnt;
    case DMA2D_C_SRC_XIC:
        return ch->src_xic;
    case DMA2D_C_SRC_YIC:
        return ch->src_yic;
    case DMA2D_C_DST_CNT:
        return ch->dst_cnt;
    case DMA2D_C_DST_XIC:
        return ch->dst_xic;
    case DMA2D_C_DST_YIC:
        return ch->dst_yic;
    case DMA2D_C_KEY:
        return ch->key;
    case DMA2D_C_KEY_EN:
        return ch->key_en;
    case DMA2D_C_CFG:
        return ch->cfg;
    default:
        return 0;
    }
}

static void bl808_dma2d_write(void *opaque, hwaddr offset, uint64_t value,
                              unsigned size)
{
    BL808DMA2DState *s = opaque;
    unsigned chno;
    BL808DMA2DChannel *ch;
    hwaddr choff;
    uint32_t val = (uint32_t)value;

    if (size != 4) {
        return;
    }
    if (s->reset_asserted) {
        return;
    }

    switch (offset) {
    case DMA2D_INTTCCLEAR:
        s->int_tc_status &= ~val;
        s->int_status &= ~val;
        bl808_dma2d_update_irq(s);
        return;
    case DMA2D_CONFIG:
        s->global_cfg = val & 0x00ff0001u;
        bl808_dma2d_schedule(s);
        return;
    case DMA2D_SYNC:
        s->sync = val;
        return;
    case DMA2D_SOFTBREQ:
        s->soft_breq = val;
        return;
    case DMA2D_SOFTLBREQ:
        s->soft_lbreq = val;
        return;
    case DMA2D_SOFTSREQ:
        s->soft_sreq = val;
        return;
    case DMA2D_SOFTLSREQ:
        s->soft_lsreq = val;
        return;
    case DMA2D_QOS:
        s->qos = val & 0x3;
        return;
    default:
        break;
    }

    if (offset < DMA2D_CH_BASE ||
        offset >= DMA2D_CH_BASE + BL808_DMA2D_CHANNELS * DMA2D_CH_STRIDE) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_dma2d: bad write offset 0x%" HWADDR_PRIx
                      " = 0x%" PRIx64 "\n", offset, value);
        return;
    }

    chno = (offset - DMA2D_CH_BASE) / DMA2D_CH_STRIDE;
    ch = &s->channels[chno];
    choff = (offset - DMA2D_CH_BASE) % DMA2D_CH_STRIDE;

    switch (choff) {
    case DMA2D_C_SRCADDR:
        ch->src_addr = val;
        break;
    case DMA2D_C_DSTADDR:
        ch->dst_addr = val;
        break;
    case DMA2D_C_LLI:
        ch->lli = val;
        break;
    case DMA2D_C_BUS:
        ch->bus = val;
        break;
    case DMA2D_C_SRC_CNT:
        ch->src_cnt = val;
        break;
    case DMA2D_C_SRC_XIC:
        ch->src_xic = val;
        break;
    case DMA2D_C_SRC_YIC:
        ch->src_yic = val;
        break;
    case DMA2D_C_DST_CNT:
        ch->dst_cnt = val;
        break;
    case DMA2D_C_DST_XIC:
        ch->dst_xic = val;
        break;
    case DMA2D_C_DST_YIC:
        ch->dst_yic = val;
        break;
    case DMA2D_C_KEY:
        ch->key = val;
        break;
    case DMA2D_C_KEY_EN:
        ch->key_en = val & (DMA2D_KEY_EN_BIT |
                            DMA2D_KEY_MODE_MASK |
                            DMA2D_KEY_STRB_MASK);
        break;
    case DMA2D_C_CFG:
        ch->cfg = val & (DMA2D_CH_EN | DMA2D_REG_2D_EN | BIT(14));
        if (!(ch->cfg & DMA2D_CH_EN)) {
            ch->active = false;
            ch->cfg |= DMA2D_FIFO_EMPTY;
        }
        bl808_dma2d_schedule(s);
        break;
    default:
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_dma2d: bad channel write offset 0x%" HWADDR_PRIx
                      " = 0x%" PRIx64 "\n", choff, value);
        return;
    }
}

void bl808_dma2d_set_clock_enabled(BL808DMA2DState *s, bool enabled)
{
    s->clock_enabled = enabled;
    if (!enabled) {
        qemu_bh_cancel(s->run_bh);
        s->run_scheduled = false;
    } else {
        bl808_dma2d_schedule(s);
    }
    bl808_dma2d_update_irq(s);
}

void bl808_dma2d_set_reset_asserted(BL808DMA2DState *s, bool asserted)
{
    s->reset_asserted = asserted;
    if (asserted) {
        qemu_bh_cancel(s->run_bh);
        s->run_scheduled = false;
        device_cold_reset(DEVICE(s));
    } else {
        bl808_dma2d_schedule(s);
    }
    bl808_dma2d_update_irq(s);
}

static const MemoryRegionOps bl808_dma2d_ops = {
    .read = bl808_dma2d_read,
    .write = bl808_dma2d_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static void bl808_dma2d_reset(DeviceState *dev)
{
    BL808DMA2DState *s = BL808_DMA2D(dev);

    memset(s->channels, 0, sizeof(s->channels));
    s->int_status = 0;
    s->int_tc_status = 0;
    s->global_cfg = 0;
    s->sync = 0;
    s->soft_breq = 0;
    s->soft_lbreq = 0;
    s->soft_sreq = 0;
    s->soft_lsreq = 0;
    s->qos = 0;
    s->run_scheduled = false;
    qemu_bh_cancel(s->run_bh);
    for (unsigned i = 0; i < BL808_DMA2D_CHANNELS; i++) {
        s->channels[i].cfg = DMA2D_FIFO_EMPTY;
    }
    bl808_dma2d_update_irq(s);
}

static void bl808_dma2d_init(Object *obj)
{
    BL808DMA2DState *s = BL808_DMA2D(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    s->run_bh = qemu_bh_new(bl808_dma2d_run_bh, s);
    memory_region_init_io(&s->iomem, obj, &bl808_dma2d_ops, s,
                          TYPE_BL808_DMA2D, BL808_DMA2D_REG_SIZE);
    sysbus_init_mmio(sbd, &s->iomem);
    for (unsigned i = 0; i < BL808_DMA2D_CHANNELS; i++) {
        sysbus_init_irq(sbd, &s->irq[i]);
    }
    s->clock_enabled = false;
    s->reset_asserted = false;
}

static void bl808_dma2d_finalize(Object *obj)
{
    BL808DMA2DState *s = BL808_DMA2D(obj);

    qemu_bh_delete(s->run_bh);
}

static void bl808_dma2d_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    device_class_set_legacy_reset(dc, bl808_dma2d_reset);
}

static const TypeInfo bl808_dma2d_info = {
    .name          = TYPE_BL808_DMA2D,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(BL808DMA2DState),
    .instance_init = bl808_dma2d_init,
    .instance_finalize = bl808_dma2d_finalize,
    .class_init    = bl808_dma2d_class_init,
};

static void bl808_dma2d_register_types(void)
{
    type_register_static(&bl808_dma2d_info);
}

type_init(bl808_dma2d_register_types)
