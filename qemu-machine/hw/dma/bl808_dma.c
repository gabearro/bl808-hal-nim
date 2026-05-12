/*
 * Bouffalo Lab BL808 DMA controller emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/bitops.h"
#include "qemu/bswap.h"
#include "qemu/log.h"
#include "qemu/main-loop.h"
#include "qemu/timer.h"
#include "hw/qdev-properties.h"
#include "hw/dma/bl808_dma.h"

#define DMA_INT_STATUS       0x00
#define DMA_INT_TC_STATUS    0x04
#define DMA_INT_TC_CLEAR     0x08
#define DMA_INT_ERR_STATUS   0x0C
#define DMA_INT_ERR_CLEAR    0x10
#define DMA_RAW_INT_TC       0x14
#define DMA_RAW_INT_ERR      0x18
#define DMA_ENABLED_CHNS     0x1C
#define DMA_SOFT_BREQ        0x20
#define DMA_SOFT_SREQ        0x24
#define DMA_SOFT_LBREQ       0x28
#define DMA_SOFT_LSREQ       0x2C
#define DMA_TOP_CONFIG       0x30
#define DMA_SYNC             0x34

#define DMA_CH_BASE          0x100
#define DMA_CH_STRIDE        0x100
#define DMA_CH_SRC_ADDR      0x00
#define DMA_CH_DST_ADDR      0x04
#define DMA_CH_LLI           0x08
#define DMA_CH_CONTROL       0x0C
#define DMA_CH_CONFIG        0x10

#define DMA_CTRL_XFER_MASK   0x0FFFu
#define DMA_CTRL_SB_SHIFT    12
#define DMA_CTRL_DB_SHIFT    15
#define DMA_CTRL_SW_SHIFT    18
#define DMA_CTRL_DW_SHIFT    21
#define DMA_CTRL_SRC_INC     BIT(26)
#define DMA_CTRL_DST_INC     BIT(27)
#define DMA_CTRL_TC_IRQ_EN   BIT(31)

#define DMA_CFG_ENABLE       BIT(0)
#define DMA_CFG_SRC_SHIFT    1
#define DMA_CFG_DST_SHIFT    6
#define DMA_CFG_FLOW_SHIFT   11
#define DMA_CFG_FLOW_MASK    (7u << DMA_CFG_FLOW_SHIFT)
#define DMA_CFG_ERR_IRQ_EN   BIT(14)
#define DMA_CFG_TC_IRQ_EN    BIT(15)
#define DMA_CFG_LOCK         BIT(16)
#define DMA_CFG_ACTIVE       BIT(17)
#define DMA_CFG_HALT         BIT(18)

#define DMA_TOP_ENABLE       BIT(0)

#define DMA_FLOW_M2M         0
#define DMA_FLOW_M2P         1
#define DMA_FLOW_P2M         2
#define DMA_FLOW_P2P         3
#define DMA_FLOW_P2P_DST     4
#define DMA_FLOW_M2P_PERI    5
#define DMA_FLOW_P2M_PERI    6
#define DMA_FLOW_P2P_SRC     7

#define DMA_MAX_STEPS_PER_RUN 64

static unsigned bl808_dma_channel_count(const BL808DMAState *s)
{
    return MIN(MAX((unsigned)s->channel_count, 1U), BL808_DMA_CHANNELS);
}

static unsigned bl808_dma_width_bytes(const BL808DMAState *s,
                                      uint32_t control, bool dst)
{
    uint32_t width = (control >> (dst ? DMA_CTRL_DW_SHIFT : DMA_CTRL_SW_SHIFT))
                     & 0x3;

    switch (width) {
    case 0:
        return 1;
    case 1:
        return 2;
    case 2:
        return 4;
    default:
        return s->supports_doubleword_width ? 8 : 0;
    }
}

static unsigned bl808_dma_burst_len(uint32_t control, bool dst)
{
    uint32_t burst = (control >> (dst ? DMA_CTRL_DB_SHIFT : DMA_CTRL_SB_SHIFT))
                     & 0x3;

    switch (burst) {
    case 0:
        return 1;
    case 1:
        return 4;
    case 2:
        return 8;
    case 3:
        return 16;
    default:
        return 1;
    }
}

static unsigned bl808_dma_src_request(uint32_t config)
{
    return (config >> DMA_CFG_SRC_SHIFT) & 0x1F;
}

static unsigned bl808_dma_dst_request(uint32_t config)
{
    return (config >> DMA_CFG_DST_SHIFT) & 0x1F;
}

static unsigned bl808_dma_flow(uint32_t config)
{
    return (config & DMA_CFG_FLOW_MASK) >> DMA_CFG_FLOW_SHIFT;
}

static uint32_t bl808_dma_tc_mask(BL808DMAState *s)
{
    uint32_t mask = 0;

    for (unsigned i = 0; i < bl808_dma_channel_count(s); i++) {
        BL808DMAChannel *ch = &s->channels[i];

        if ((ch->config & DMA_CFG_TC_IRQ_EN) &&
            (ch->control & DMA_CTRL_TC_IRQ_EN)) {
            mask |= BIT(i);
        }
    }
    return mask;
}

static uint32_t bl808_dma_err_mask(BL808DMAState *s)
{
    uint32_t mask = 0;

    for (unsigned i = 0; i < bl808_dma_channel_count(s); i++) {
        if (s->channels[i].config & DMA_CFG_ERR_IRQ_EN) {
            mask |= BIT(i);
        }
    }
    return mask;
}

static uint32_t bl808_dma_visible_tc_status(BL808DMAState *s)
{
    return s->raw_tc_status & bl808_dma_tc_mask(s);
}

static uint32_t bl808_dma_visible_err_status(BL808DMAState *s)
{
    return s->raw_err_status & bl808_dma_err_mask(s);
}

static void bl808_dma_update_irq(BL808DMAState *s)
{
    uint32_t pending = bl808_dma_visible_tc_status(s) |
                       bl808_dma_visible_err_status(s);
    unsigned channels = bl808_dma_channel_count(s);

    qemu_set_irq(s->irq,
                 s->clock_enabled && !s->reset_asserted && pending != 0);

    for (unsigned i = 0; i < BL808_DMA_CHANNELS; i++) {
        qemu_set_irq(s->ch_irq[i],
                     i < channels &&
                     s->clock_enabled && !s->reset_asserted &&
                     (pending & BIT(i)) != 0);
    }
}

static bool bl808_dma_has_active_channels(BL808DMAState *s)
{
    for (unsigned i = 0; i < bl808_dma_channel_count(s); i++) {
        if (s->channels[i].active) {
            return true;
        }
    }
    return false;
}

static bool bl808_dma_can_run(BL808DMAState *s)
{
    return s->clock_enabled && !s->reset_asserted &&
           (s->top_config & DMA_TOP_ENABLE) != 0;
}

static void bl808_dma_cancel_work(BL808DMAState *s)
{
    qemu_bh_cancel(s->run_bh);
    timer_del(s->poll_timer);
    s->run_scheduled = false;
}

static void bl808_dma_schedule(BL808DMAState *s)
{
    if (!bl808_dma_can_run(s) || !bl808_dma_has_active_channels(s) ||
        s->run_scheduled) {
        return;
    }

    s->run_scheduled = true;
    qemu_bh_schedule(s->run_bh);
}

static void bl808_dma_reschedule_poll(BL808DMAState *s)
{
    if (!bl808_dma_can_run(s) || !bl808_dma_has_active_channels(s)) {
        return;
    }

    timer_mod(s->poll_timer, qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) + 1);
}

static uint32_t bl808_dma_enabled_channels(BL808DMAState *s)
{
    uint32_t mask = 0;

    for (unsigned i = 0; i < bl808_dma_channel_count(s); i++) {
        if (s->channels[i].config & DMA_CFG_ENABLE) {
            mask |= BIT(i);
        }
    }
    return mask;
}

static uint64_t bl808_dma_read_mem_value(hwaddr addr, unsigned width_bytes)
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

static void bl808_dma_write_mem_value(hwaddr addr, uint64_t value,
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

static bool bl808_dma_load_lli(BL808DMAChannel *ch)
{
    uint32_t src;
    uint32_t dst;
    uint32_t next;
    uint32_t control;

    if (ch->lli == 0) {
        return false;
    }

    cpu_physical_memory_read(ch->lli + 0, &src, 4);
    cpu_physical_memory_read(ch->lli + 4, &dst, 4);
    cpu_physical_memory_read(ch->lli + 8, &next, 4);
    cpu_physical_memory_read(ch->lli + 12, &control, 4);

    ch->src_addr = le32_to_cpu(src);
    ch->dst_addr = le32_to_cpu(dst);
    ch->lli = le32_to_cpu(next);
    ch->control = le32_to_cpu(control);
    return true;
}

static void bl808_dma_complete_channel(BL808DMAState *s, unsigned chno)
{
    BL808DMAChannel *ch = &s->channels[chno];

    ch->active = false;
    ch->config &= ~(DMA_CFG_ENABLE | DMA_CFG_HALT);
    ch->control &= ~DMA_CTRL_XFER_MASK;

    if ((ch->control & DMA_CTRL_TC_IRQ_EN) != 0) {
        s->raw_tc_status |= BIT(chno);
    }
}

static void bl808_dma_error_channel(BL808DMAState *s, unsigned chno,
                                    const char *detail)
{
    BL808DMAChannel *ch = &s->channels[chno];

    qemu_log_mask(LOG_GUEST_ERROR, "bl808_dma: channel %u error: %s\n",
                  chno, detail);
    ch->active = false;
    ch->config &= ~(DMA_CFG_ENABLE | DMA_CFG_HALT);
    s->raw_err_status |= BIT(chno);
}

static bool bl808_dma_request_can_read(BL808DMAState *s, unsigned req_id,
                                       unsigned width_bytes)
{
    BL808DMARequestLine *req;

    if (req_id >= BL808_DMA_REQUEST_LINES) {
        return false;
    }
    req = &s->requests[req_id];
    return req->ops && req->ops->can_read &&
           req->ops->can_read(req->opaque, width_bytes);
}

static bool bl808_dma_request_can_write(BL808DMAState *s, unsigned req_id,
                                        unsigned width_bytes)
{
    BL808DMARequestLine *req;

    if (req_id >= BL808_DMA_REQUEST_LINES) {
        return false;
    }
    req = &s->requests[req_id];
    return req->ops && req->ops->can_write &&
           req->ops->can_write(req->opaque, width_bytes);
}

static uint32_t bl808_dma_request_read(BL808DMAState *s, unsigned req_id,
                                       unsigned width_bytes)
{
    BL808DMARequestLine *req = &s->requests[req_id];

    return req->ops->read(req->opaque, width_bytes);
}

static void bl808_dma_request_write(BL808DMAState *s, unsigned req_id,
                                    uint32_t value, unsigned width_bytes)
{
    BL808DMARequestLine *req = &s->requests[req_id];

    req->ops->write(req->opaque, value, width_bytes);
}

static bool bl808_dma_step_channel(BL808DMAState *s, unsigned chno)
{
    BL808DMAChannel *ch = &s->channels[chno];
    unsigned flow = bl808_dma_flow(ch->config);
    unsigned src_width = bl808_dma_width_bytes(s, ch->control, false);
    unsigned dst_width = bl808_dma_width_bytes(s, ch->control, true);
    unsigned src_req = bl808_dma_src_request(ch->config);
    unsigned dst_req = bl808_dma_dst_request(ch->config);
    uint32_t remaining = ch->control & DMA_CTRL_XFER_MASK;
    unsigned burst = MAX(bl808_dma_burst_len(ch->control, false),
                         bl808_dma_burst_len(ch->control, true));
    unsigned limit;
    bool made_progress = false;

    if (!ch->active || !(ch->config & DMA_CFG_ENABLE) ||
        (ch->config & DMA_CFG_HALT)) {
        ch->active = false;
        return false;
    }
    if (src_width == 0 || dst_width == 0) {
        bl808_dma_error_channel(s, chno, "unsupported transfer width");
        return true;
    }
    if ((src_width > 4 || dst_width > 4) && flow != DMA_FLOW_M2M) {
        bl808_dma_error_channel(s, chno,
                                "64-bit transfers are only modeled for "
                                "memory-to-memory flows");
        return true;
    }
    if (remaining == 0) {
        if (bl808_dma_load_lli(ch)) {
            return true;
        }
        bl808_dma_complete_channel(s, chno);
        return true;
    }

    limit = MIN(remaining, DMA_MAX_STEPS_PER_RUN);
    if (flow != DMA_FLOW_M2M) {
        limit = MIN(limit, MAX(1u, burst));
    }

    while (limit-- > 0 && remaining > 0) {
        uint64_t value = 0;

        switch (flow) {
        case DMA_FLOW_M2M:
        case DMA_FLOW_M2P:
        case DMA_FLOW_M2P_PERI:
            value = bl808_dma_read_mem_value(ch->src_addr, src_width);
            break;
        case DMA_FLOW_P2M:
        case DMA_FLOW_P2M_PERI:
        case DMA_FLOW_P2P:
        case DMA_FLOW_P2P_DST:
        case DMA_FLOW_P2P_SRC:
            if (!bl808_dma_request_can_read(s, src_req, src_width)) {
                goto out;
            }
            value = bl808_dma_request_read(s, src_req, src_width);
            break;
        default:
            bl808_dma_error_channel(s, chno, "unsupported flow control");
            return true;
        }

        switch (flow) {
        case DMA_FLOW_M2M:
        case DMA_FLOW_P2M:
        case DMA_FLOW_P2M_PERI:
            bl808_dma_write_mem_value(ch->dst_addr, value, dst_width);
            break;
        case DMA_FLOW_M2P:
        case DMA_FLOW_M2P_PERI:
        case DMA_FLOW_P2P:
        case DMA_FLOW_P2P_DST:
        case DMA_FLOW_P2P_SRC:
            if (!bl808_dma_request_can_write(s, dst_req, dst_width)) {
                goto out;
            }
            bl808_dma_request_write(s, dst_req, (uint32_t)value, dst_width);
            break;
        default:
            bl808_dma_error_channel(s, chno, "unsupported flow control");
            return true;
        }

        if (ch->control & DMA_CTRL_SRC_INC) {
            ch->src_addr += src_width;
        }
        if (ch->control & DMA_CTRL_DST_INC) {
            ch->dst_addr += dst_width;
        }

        remaining--;
        ch->control = (ch->control & ~DMA_CTRL_XFER_MASK) | remaining;
        made_progress = true;
    }

out:
    if (remaining == 0) {
        if (bl808_dma_load_lli(ch)) {
            return true;
        }
        bl808_dma_complete_channel(s, chno);
        return true;
    }

    if (!made_progress) {
        if ((flow == DMA_FLOW_M2P || flow == DMA_FLOW_M2P_PERI) &&
            !s->requests[dst_req].ops) {
            bl808_dma_error_channel(s, chno, "unsupported destination requester");
            return true;
        }
        if ((flow == DMA_FLOW_P2M || flow == DMA_FLOW_P2M_PERI ||
             flow == DMA_FLOW_P2P || flow == DMA_FLOW_P2P_DST ||
             flow == DMA_FLOW_P2P_SRC) &&
            !s->requests[src_req].ops) {
            bl808_dma_error_channel(s, chno, "unsupported source requester");
            return true;
        }
    }

    return made_progress;
}

static void bl808_dma_run_bh(void *opaque)
{
    BL808DMAState *s = opaque;
    bool progress = false;

    s->run_scheduled = false;
    if (!bl808_dma_can_run(s)) {
        bl808_dma_update_irq(s);
        return;
    }

    for (unsigned i = 0; i < bl808_dma_channel_count(s); i++) {
        progress |= bl808_dma_step_channel(s, i);
    }

    bl808_dma_update_irq(s);

    if (!bl808_dma_has_active_channels(s)) {
        return;
    }

    if (progress) {
        bl808_dma_schedule(s);
    } else {
        bl808_dma_reschedule_poll(s);
    }
}

static void bl808_dma_poll_timer_cb(void *opaque)
{
    BL808DMAState *s = opaque;

    if (!s->run_scheduled) {
        bl808_dma_schedule(s);
    }
}

static uint64_t bl808_dma_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808DMAState *s = opaque;
    unsigned chno;
    BL808DMAChannel *ch;
    hwaddr choff;

    if (size != 4) {
        return 0;
    }

    switch (offset) {
    case DMA_INT_STATUS:
        return bl808_dma_visible_tc_status(s) | bl808_dma_visible_err_status(s);
    case DMA_INT_TC_STATUS:
        return bl808_dma_visible_tc_status(s);
    case DMA_INT_ERR_STATUS:
        return bl808_dma_visible_err_status(s);
    case DMA_RAW_INT_TC:
        return s->raw_tc_status;
    case DMA_RAW_INT_ERR:
        return s->raw_err_status;
    case DMA_ENABLED_CHNS:
        return bl808_dma_enabled_channels(s);
    case DMA_SOFT_BREQ:
        return s->soft_breq;
    case DMA_SOFT_SREQ:
        return s->soft_sreq;
    case DMA_SOFT_LBREQ:
        return s->soft_lbreq;
    case DMA_SOFT_LSREQ:
        return s->soft_lsreq;
    case DMA_TOP_CONFIG:
        return s->top_config;
    case DMA_SYNC:
        return s->sync;
    default:
        break;
    }

    if (offset < DMA_CH_BASE ||
        offset >= DMA_CH_BASE + BL808_DMA_CHANNELS * DMA_CH_STRIDE) {
        return 0;
    }

    chno = (offset - DMA_CH_BASE) / DMA_CH_STRIDE;
    if (chno >= bl808_dma_channel_count(s)) {
        return 0;
    }
    ch = &s->channels[chno];
    choff = (offset - DMA_CH_BASE) % DMA_CH_STRIDE;

    switch (choff) {
    case DMA_CH_SRC_ADDR:
        return ch->src_addr;
    case DMA_CH_DST_ADDR:
        return ch->dst_addr;
    case DMA_CH_LLI:
        return ch->lli;
    case DMA_CH_CONTROL:
        return ch->control;
    case DMA_CH_CONFIG:
        return ch->config | (ch->active ? DMA_CFG_ACTIVE : 0);
    default:
        return 0;
    }
}

static void bl808_dma_write_channel_config(BL808DMAState *s, unsigned chno,
                                           uint32_t value)
{
    BL808DMAChannel *ch = &s->channels[chno];
    bool was_enabled = (ch->config & DMA_CFG_ENABLE) != 0;
    bool enable = (value & DMA_CFG_ENABLE) != 0;

    ch->config = value & ~DMA_CFG_ACTIVE;

    if (!enable) {
        ch->active = false;
        ch->config &= ~DMA_CFG_ENABLE;
        return;
    }

    if (!was_enabled || !ch->active) {
        ch->active = true;
    }

    bl808_dma_schedule(s);
}

static void bl808_dma_write(void *opaque, hwaddr offset, uint64_t value,
                            unsigned size)
{
    BL808DMAState *s = opaque;
    unsigned chno;
    BL808DMAChannel *ch;
    hwaddr choff;

    if (size != 4) {
        return;
    }
    if (s->reset_asserted) {
        return;
    }

    switch (offset) {
    case DMA_INT_TC_CLEAR:
        s->raw_tc_status &= ~(uint32_t)value;
        bl808_dma_update_irq(s);
        return;
    case DMA_INT_ERR_CLEAR:
        s->raw_err_status &= ~(uint32_t)value;
        bl808_dma_update_irq(s);
        return;
    case DMA_SOFT_BREQ:
        s->soft_breq = (uint32_t)value;
        bl808_dma_schedule(s);
        return;
    case DMA_SOFT_SREQ:
        s->soft_sreq = (uint32_t)value;
        bl808_dma_schedule(s);
        return;
    case DMA_SOFT_LBREQ:
        s->soft_lbreq = (uint32_t)value;
        bl808_dma_schedule(s);
        return;
    case DMA_SOFT_LSREQ:
        s->soft_lsreq = (uint32_t)value;
        bl808_dma_schedule(s);
        return;
    case DMA_TOP_CONFIG:
        s->top_config = (uint32_t)value & DMA_TOP_ENABLE;
        if (s->top_config & DMA_TOP_ENABLE) {
            bl808_dma_schedule(s);
        } else {
            bl808_dma_cancel_work(s);
        }
        return;
    case DMA_SYNC:
        s->sync = (uint32_t)value;
        return;
    default:
        break;
    }

    if (offset < DMA_CH_BASE ||
        offset >= DMA_CH_BASE + BL808_DMA_CHANNELS * DMA_CH_STRIDE) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_dma: write beyond register window @ 0x%"
                      HWADDR_PRIx " = 0x%" PRIx64 "\n", offset, value);
        return;
    }

    chno = (offset - DMA_CH_BASE) / DMA_CH_STRIDE;
    if (chno >= bl808_dma_channel_count(s)) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_dma: write to unavailable channel %u = 0x%"
                      PRIx64 "\n", chno, value);
        return;
    }
    ch = &s->channels[chno];
    choff = (offset - DMA_CH_BASE) % DMA_CH_STRIDE;

    switch (choff) {
    case DMA_CH_SRC_ADDR:
        ch->src_addr = (uint32_t)value;
        break;
    case DMA_CH_DST_ADDR:
        ch->dst_addr = (uint32_t)value;
        break;
    case DMA_CH_LLI:
        ch->lli = (uint32_t)value;
        break;
    case DMA_CH_CONTROL:
        ch->control = (uint32_t)value;
        break;
    case DMA_CH_CONFIG:
        bl808_dma_write_channel_config(s, chno, (uint32_t)value);
        break;
    default:
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_dma: write to undefined channel offset 0x%"
                      HWADDR_PRIx " = 0x%" PRIx64 "\n", choff, value);
        return;
    }

    bl808_dma_update_irq(s);
}

static const MemoryRegionOps bl808_dma_ops = {
    .read = bl808_dma_read,
    .write = bl808_dma_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

void bl808_dma_register_request(BL808DMAState *s, unsigned request_id,
                                const BL808DMARequestOps *ops, void *opaque)
{
    if (request_id >= BL808_DMA_REQUEST_LINES) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_dma: invalid request line %u\n", request_id);
        return;
    }

    s->requests[request_id].ops = ops;
    s->requests[request_id].opaque = opaque;
}

void bl808_dma_set_clock_enabled(BL808DMAState *s, bool enabled)
{
    s->clock_enabled = enabled;
    if (!enabled) {
        bl808_dma_cancel_work(s);
    } else {
        bl808_dma_schedule(s);
    }
    bl808_dma_update_irq(s);
}

void bl808_dma_set_reset_asserted(BL808DMAState *s, bool asserted)
{
    s->reset_asserted = asserted;
    if (asserted) {
        device_cold_reset(DEVICE(s));
    } else {
        bl808_dma_schedule(s);
    }
    bl808_dma_update_irq(s);
}

static void bl808_dma_init(Object *obj)
{
    BL808DMAState *s = BL808_DMA(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    memory_region_init_io(&s->iomem, obj, &bl808_dma_ops, s,
                          TYPE_BL808_DMA, BL808_DMA_REG_SIZE);
    sysbus_init_mmio(sbd, &s->iomem);
    sysbus_init_irq(sbd, &s->irq);
    for (unsigned i = 0; i < BL808_DMA_CHANNELS; i++) {
        sysbus_init_irq(sbd, &s->ch_irq[i]);
    }
    s->run_bh = qemu_bh_new(bl808_dma_run_bh, s);
    s->poll_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL,
                                 bl808_dma_poll_timer_cb, s);
    s->channel_count = BL808_DMA_CHANNELS;
    s->supports_doubleword_width = false;
    s->clock_enabled = false;
}

static void bl808_dma_finalize(Object *obj)
{
    BL808DMAState *s = BL808_DMA(obj);

    qemu_bh_delete(s->run_bh);
    timer_free(s->poll_timer);
}

static void bl808_dma_reset(DeviceState *dev)
{
    BL808DMAState *s = BL808_DMA(dev);

    memset(s->channels, 0, sizeof(s->channels));
    s->raw_tc_status = 0;
    s->raw_err_status = 0;
    s->soft_breq = 0;
    s->soft_sreq = 0;
    s->soft_lbreq = 0;
    s->soft_lsreq = 0;
    s->top_config = 0;
    s->sync = 0;
    bl808_dma_cancel_work(s);
    bl808_dma_update_irq(s);
}

static const Property bl808_dma_properties[] = {
    DEFINE_PROP_UINT8("channel-count", BL808DMAState, channel_count,
                      BL808_DMA_CHANNELS),
    DEFINE_PROP_BOOL("supports-doubleword-width", BL808DMAState,
                     supports_doubleword_width, false),
};

static void bl808_dma_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    device_class_set_legacy_reset(dc, bl808_dma_reset);
    device_class_set_props(dc, bl808_dma_properties);
}

static const TypeInfo bl808_dma_info = {
    .name          = TYPE_BL808_DMA,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(BL808DMAState),
    .instance_init = bl808_dma_init,
    .instance_finalize = bl808_dma_finalize,
    .class_init    = bl808_dma_class_init,
};

static void bl808_dma_register_types(void)
{
    type_register_static(&bl808_dma_info);
}

type_init(bl808_dma_register_types)
