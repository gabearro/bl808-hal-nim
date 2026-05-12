/*
 * T-Head CLINT (Core Local Interruptor) for QEMU
 *
 * Provides real-time clock, timer and software interrupts with the
 * T-Head register layout matching BL808 E907/E902 hardware:
 *   +0x0000: MSIP[hartid]      (4 bytes each)
 *   +0x4000: MTIMECMP[hartid]  (8 bytes each)
 *   +0xBFF8: MTIME             (8 bytes, read-only global timer)
 *
 * Outputs 2 GPIO lines per hart:
 *   pirq[2*h + 0] = software interrupt (connect to CLIC IRQ 3)
 *   pirq[2*h + 1] = timer interrupt    (connect to CLIC IRQ 7)
 *
 * Based on XUANTIE-RV/qemu thead_clint.c
 * Copyright (c) 2024 Alibaba Group. All rights reserved.
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qapi/error.h"
#include "hw/sysbus.h"
#include "hw/irq.h"
#include "target/riscv/cpu.h"
#include "hw/qdev-properties.h"
#include "hw/intc/thead_clint.h"

static uint64_t thead_clint_read_rtc_raw(THEADCLINTState *s)
{
    return muldiv64(qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL),
                    s->timebase_freq, NANOSECONDS_PER_SECOND);
}

static uint64_t thead_clint_read_rtc(THEADCLINTState *s)
{
    return thead_clint_read_rtc_raw(s) + s->time_delta;
}

uint64_t thead_clint_read_rtc_cb(void *opaque)
{
    return thead_clint_read_rtc((THEADCLINTState *)opaque);
}

static void thead_clint_timer_cb(void *opaque)
{
    qemu_irq irq = *(qemu_irq *)opaque;
    qemu_set_irq(irq, 1);
}

static void thead_clint_write_timecmp(THEADCLINTState *s, int hartid,
                                      uint64_t value)
{
    uint64_t rtc = thead_clint_read_rtc(s);
    s->mtimecmp[hartid] = value;

    /* Lower timer IRQ first */
    qemu_set_irq(s->pirq[2 * hartid + 1], 0);

    if (value <= rtc) {
        /* Timer already expired — raise immediately */
        qemu_set_irq(s->pirq[2 * hartid + 1], 1);
    } else {
        /* Schedule future timer */
        uint64_t diff = value - rtc;
        uint64_t ns = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) +
                      muldiv64(diff, NANOSECONDS_PER_SECOND, s->timebase_freq);
        timer_mod(s->timer[hartid], ns);
    }
}

static uint64_t thead_clint_read(void *opaque, hwaddr addr, unsigned size)
{
    THEADCLINTState *s = opaque;

    if ((addr & 0x3) != 0 || size != 4) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "thead-clint: invalid read size %u: 0x%" HWADDR_PRIx "\n",
                      size, addr);
        return 0;
    }

    /* MSIP[hartid] at +0x0000 */
    if (addr < (uint64_t)s->num_harts * 4) {
        return s->msip[addr / 4];
    }

    /* MTIMECMP[hartid] lo/hi at +0x4000 */
    if (addr >= 0x4000 && addr < 0x4000 + (uint64_t)s->num_harts * 8) {
        int hartid = (addr - 0x4000) / 8;
        if ((addr & 0x7) == 0) {
            return (uint32_t)(s->mtimecmp[hartid] & 0xFFFFFFFF);
        } else {
            return (uint32_t)((s->mtimecmp[hartid] >> 32) & 0xFFFFFFFF);
        }
    }

    /* MTIME lo/hi at +0xBFF8 */
    if (addr == 0xBFF8) {
        return (uint32_t)(thead_clint_read_rtc(s) & 0xFFFFFFFF);
    }
    if (addr == 0xBFFC) {
        return (uint32_t)((thead_clint_read_rtc(s) >> 32) & 0xFFFFFFFF);
    }

    qemu_log_mask(LOG_GUEST_ERROR,
                  "thead-clint: invalid read: 0x%" HWADDR_PRIx "\n", addr);
    return 0;
}

static void thead_clint_write(void *opaque, hwaddr addr, uint64_t value,
                              unsigned size)
{
    THEADCLINTState *s = opaque;
    uint64_t rtc_raw;
    uint64_t rtc;

    if ((addr & 0x3) != 0 || size != 4) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "thead-clint: invalid write size %u: 0x%" HWADDR_PRIx "\n",
                      size, addr);
        return;
    }

    /* MSIP[hartid] at +0x0000 */
    if (addr < (uint64_t)s->num_harts * 4) {
        int hartid = addr / 4;
        s->msip[hartid] = value & 1;
        if (value & 1) {
            qemu_irq_raise(s->pirq[hartid * 2]);
        } else {
            qemu_irq_lower(s->pirq[hartid * 2]);
        }
        return;
    }

    /* MTIMECMP[hartid] lo/hi at +0x4000 */
    if (addr >= 0x4000 && addr < 0x4000 + (uint64_t)s->num_harts * 8) {
        int hartid = (addr - 0x4000) / 8;
        if ((addr & 0x7) == 0) {
            /* Write lo, preserve hi */
            uint64_t hi = s->mtimecmp[hartid] & 0xFFFFFFFF00000000ULL;
            thead_clint_write_timecmp(s, hartid, hi | (value & 0xFFFFFFFF));
        } else {
            /* Write hi, preserve lo */
            uint64_t lo = s->mtimecmp[hartid] & 0xFFFFFFFF;
            thead_clint_write_timecmp(s, hartid, (value << 32) | lo);
        }
        return;
    }

    /* MTIME is read-only */
    if (addr == 0xBFF8 || addr == 0xBFFC) {
        rtc_raw = thead_clint_read_rtc_raw(s);
        rtc = thead_clint_read_rtc(s);

        if (addr == 0xBFF8) {
            s->time_delta = ((rtc & ~0xFFFFFFFFULL) | (value & 0xFFFFFFFFULL)) -
                            rtc_raw;
        } else {
            s->time_delta = (((value & 0xFFFFFFFFULL) << 32) |
                             (rtc & 0xFFFFFFFFULL)) - rtc_raw;
        }

        for (int hartid = 0; hartid < s->num_harts; hartid++) {
            thead_clint_write_timecmp(s, hartid, s->mtimecmp[hartid]);
        }
        return;
    }

    qemu_log_mask(LOG_GUEST_ERROR,
                  "thead-clint: invalid write: 0x%" HWADDR_PRIx "\n", addr);
}

static const MemoryRegionOps thead_clint_ops = {
    .read = thead_clint_read,
    .write = thead_clint_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 4, .max_access_size = 4 },
};

static void thead_clint_init(Object *obj)
{
    THEADCLINTState *s = THEAD_CLINT(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    memory_region_init_io(&s->mmio, obj, &thead_clint_ops, s,
                          TYPE_THEAD_CLINT, 0x10000);
    sysbus_init_mmio(sbd, &s->mmio);
}

static void thead_clint_realize(DeviceState *dev, Error **errp)
{
    THEADCLINTState *s = THEAD_CLINT(dev);

    s->mtimecmp = g_new0(uint64_t, s->num_harts);
    s->msip = g_new0(uint32_t, s->num_harts);
    s->pirq = g_new0(qemu_irq, 2 * s->num_harts);
    s->timer = g_new0(QEMUTimer *, s->num_harts);

    /* 2 GPIO outputs per hart: [2*h] = soft IRQ, [2*h+1] = timer IRQ */
    qdev_init_gpio_out(dev, s->pirq, 2 * s->num_harts);

    for (int i = 0; i < s->num_harts; i++) {
        s->timer[i] = timer_new_ns(QEMU_CLOCK_VIRTUAL,
                                   &thead_clint_timer_cb,
                                   &s->pirq[2 * i + 1]);
        /* Prevent spurious timer interrupt at boot */
        s->mtimecmp[i] = UINT64_MAX;
    }
}

static const Property thead_clint_properties[] = {
    DEFINE_PROP_INT64("num-harts", THEADCLINTState, num_harts, 0),
    DEFINE_PROP_UINT32("timebase-freq", THEADCLINTState, timebase_freq,
                       1000000),
};

static void thead_clint_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    device_class_set_props(dc, thead_clint_properties);
    dc->realize = thead_clint_realize;
}

static const TypeInfo thead_clint_info = {
    .name          = TYPE_THEAD_CLINT,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(THEADCLINTState),
    .instance_init = thead_clint_init,
    .class_init    = thead_clint_class_init,
};

static void thead_clint_register_types(void)
{
    type_register_static(&thead_clint_info);
}

type_init(thead_clint_register_types)

/*
 * thead_clint_create: convenience function
 *
 * Creates a CLINT, maps it at @addr, and sets up rdtime for each hart.
 * The caller must connect the GPIO outputs to the CLIC after this returns.
 */
DeviceState *thead_clint_create(hwaddr addr, uint32_t timebase_freq,
                                int64_t num_harts)
{
    DeviceState *dev = qdev_new(TYPE_THEAD_CLINT);

    qdev_prop_set_uint64(dev, "num-harts", num_harts);
    qdev_prop_set_uint32(dev, "timebase-freq", timebase_freq);
    sysbus_realize_and_unref(SYS_BUS_DEVICE(dev), &error_fatal);
    sysbus_mmio_map(SYS_BUS_DEVICE(dev), 0, addr);

    return dev;
}
