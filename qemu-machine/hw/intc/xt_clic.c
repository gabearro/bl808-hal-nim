/*
 * RISC-V CLIC(Core Local Interrupt Controller) for QEMU.
 *
 * Copyright (c) 2024 Alibaba Group. All rights reserved.
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms and conditions of the GNU General Public License,
 * version 2 or later, as published by the Free Software Foundation.
 *
 * This program is distributed in the hope it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
 * more details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#include "qemu/osdep.h"
#include "qapi/error.h"
#include "qemu/log.h"
#include "hw/sysbus.h"
#include "target/riscv/cpu.h"
#include "hw/qdev-properties.h"
#include "hw/intc/xt_clic.h"

/*
 * Return the internal hart index (0-based) for the currently executing CPU.
 * Subtracts hartid_base so that e.g. LP (cpu_index=2) maps to internal 0
 * when hartid_base=2.
 */
static int xt_clic_get_hartid_internal(XTCLICState *clic)
{
    assert(current_cpu);
    return current_cpu->cpu_index - clic->hartid_base;
}

/* Legacy wrapper used by functions that have the clic pointer available */
#define xt_clic_get_hartid() xt_clic_get_hartid_internal(clic)

/*
 * The 2-bit trig WARL field specifies the trigger type and polarity for each
 * interrupt input. Bit 1, trig[0], is defined as "edge-triggered"
 * (0: level-triggered, 1: edge-triggered); while bit 2, trig[1], is defined as
 * "negative-edge" (0: positive-edge, 1: negative-edge). (Section 3.6)
 */

static inline TRIG_TYPE
xt_clic_get_trigger_type(XTCLICState *clic, size_t irq_offset)
{
    return (clic->clicintattr[irq_offset] >> 1) & 0x3;
}

static inline bool
xt_clic_is_edge_triggered(XTCLICState *clic, size_t irq_offset)
{
    return (clic->clicintattr[irq_offset] >> 1) & 0x1;
}

static inline bool
xt_clic_is_shv_interrupt(XTCLICState *clic, size_t irq_offset)
{
    return (clic->clicintattr[irq_offset] & 0x1) && clic->nvbits;
}

static uint8_t xt_clic_intctl_mask(XTCLICState *clic)
{
    if (clic->clicintctlbits == 0) {
        return 0;
    }
    if (clic->clicintctlbits >= 8) {
        return UINT8_MAX;
    }

    return UINT8_MAX << (8 - clic->clicintctlbits);
}

static uint8_t xt_clic_intctl_effective(XTCLICState *clic, uint8_t intctl)
{
    uint8_t mask = xt_clic_intctl_mask(clic);

    return (intctl & mask) | (UINT8_MAX & ~mask);
}

static uint8_t xt_clic_intctl_storage(XTCLICState *clic, uint8_t intctl)
{
    return intctl & xt_clic_intctl_mask(clic);
}

static bool xt_clic_intctl_priority_valid(XTCLICState *clic, uint8_t intctl)
{
    return (intctl & xt_clic_intctl_mask(clic)) != 0;
}

static uint8_t
xt_clic_get_interrupt_level(XTCLICState *clic, int hartid, uint8_t intctl)
{
    int nlbits = MIN(clic->nlbits[hartid], clic->clicintctlbits);

    if (nlbits == 0) {
        return UINT8_MAX;
    }

    uint8_t mask_il = ((1 << nlbits) - 1) << (8 - nlbits);
    uint8_t mask_padding = (1 << (8 - nlbits)) - 1;
    /* unused level bits are set to 1 */
    return (intctl & mask_il) | mask_padding;
}

static uint8_t
xt_clic_get_interrupt_priority(XTCLICState *clic, int hartid, uint8_t intctl)
{
    return intctl;
}

static void
xt_clic_intcfg_decode(XTCLICState *clic, int hartid, uint16_t intcfg,
                      uint8_t *mode,  uint8_t *level, uint8_t *priority)
{
    *mode = intcfg >> 8;
    *level = xt_clic_get_interrupt_level(clic, hartid, intcfg & 0xff);
    *priority = xt_clic_get_interrupt_priority(clic, hartid, intcfg & 0xff);
}

static bool xt_clic_find_pending(XTCLICState *clic, int hartid,
                                 uint8_t threshold,
                                 bool non_shv_only,
                                 CLICActiveInterrupt *out,
                                 uint8_t *out_level)
{
    size_t hart_offset = hartid * clic->num_sources;
    CLICActiveInterrupt *active = &clic->active_list[hart_offset];
    size_t active_count = clic->active_count[hartid];
    uint8_t mode, level, priority;

    while (active_count) {
        size_t irq_offset;

        irq_offset = active->irq + hart_offset;
        if (!xt_clic_intctl_priority_valid(clic, clic->clicintctl[irq_offset])) {
            active_count--;
            active++;
            continue;
        }

        xt_clic_intcfg_decode(clic, hartid, active->intcfg, &mode, &level,
                              &priority);
        if (level <= threshold) {
            break;
        }

        if (clic->clicintip[irq_offset]) {
            if (non_shv_only && xt_clic_is_shv_interrupt(clic, irq_offset)) {
                return false;
            }
            *out = *active;
            *out_level = level;
            return true;
        }

        active_count--;
        active++;
    }

    return false;
}

static void xt_clic_next_interrupt(void *opaque, int hartid)
{
    /*
     * Scan active list for highest priority pending interrupts
     * comparing against this harts mintstatus register and interrupt
     * the core if we have a higher priority interrupt to deliver
     */
    XTCLICState *clic = (XTCLICState *)opaque;
    RISCVCPU *cpu = RISCV_CPU(qemu_get_cpu(hartid + clic->hartid_base));
    CPURISCVState *env = &cpu->env;
    uint8_t threshold = MAX(get_field(env->mintstatus, MINTSTATUS_MIL),
                            clic->mintthresh[hartid]);
    bool e902_wfi_wake = riscv_cpu_cfg(env)->ext_xthead_e902 &&
                         env->e902_wfi_active &&
                         (env->e902_mexstatus & E902_MEXSTATUS_WFE);
    CLICActiveInterrupt active;
    uint8_t level;

    if (xt_clic_find_pending(clic, hartid, threshold, false, &active, &level)) {
        cpu->env.exccode = active.irq | PRV_M << 12 | level << 14;
        env->e902_wfi_wake_only = false;
        cpu_interrupt(CPU(cpu), CPU_INTERRUPT_CLIC);
    } else if (e902_wfi_wake &&
               xt_clic_find_pending(clic, hartid, 0, false, &active, &level)) {
        cpu->env.exccode = active.irq | PRV_M << 12 | level << 14;
        env->e902_wfi_wake_only = true;
        cpu_interrupt(CPU(cpu), CPU_INTERRUPT_CLIC);
    } else {
        env->e902_wfi_wake_only = false;
        cpu_reset_interrupt(CPU(cpu), CPU_INTERRUPT_CLIC);
    }
}

/*
 * For level-triggered interrupts, software writes to pending bits are
 * ignored completely. (Section 3.4)
 */
static bool
xt_clic_validate_intip(XTCLICState *clic, int irq)
{
    return xt_clic_is_edge_triggered(clic, irq + clic->num_sources *
                                                 xt_clic_get_hartid());
}

static void
xt_clic_update_intip(XTCLICState *clic, int hartid, int irq, uint64_t value)
{
    size_t irq_offset = irq + clic->num_sources * hartid;
    clic->clicintip[irq_offset] = !!value;
    xt_clic_next_interrupt(clic, hartid);
}

static inline int xt_clic_encode_priority(const CLICActiveInterrupt *i)
{
    return ((i->intcfg & 0x3ff) << 12) | /* Highest mode+level+priority */
           (i->irq & 0xfff);             /* Highest irq number */
}

static int xt_clic_active_compare(const void *a, const void *b)
{
    return xt_clic_encode_priority(b) - xt_clic_encode_priority(a);
}

static void xt_clic_enable_irq(XTCLICState *clic, int irq)
{
    int hartid = xt_clic_get_hartid();
    size_t hart_offset = hartid * clic->num_sources;
    size_t irq_offset = irq + hart_offset;
    CLICActiveInterrupt *active_list = &clic->active_list[hart_offset];
    size_t *active_count = &clic->active_count[hartid];

    active_list[*active_count].intcfg = (PRV_M << 8) |
        xt_clic_intctl_effective(clic, clic->clicintctl[irq_offset]);
    active_list[*active_count].irq = irq;
    (*active_count)++;

    /* Sort list of active interrupts */
    qsort(active_list, *active_count,
          sizeof(CLICActiveInterrupt),
          xt_clic_active_compare);
}

/* Notice this irq must be enabled before call this function */
static void xt_clic_disable_irq(XTCLICState *clic, int irq)
{
    int hartid = xt_clic_get_hartid();
    size_t hart_offset = hartid * clic->num_sources;
    size_t irq_offset = irq + hart_offset;
    CLICActiveInterrupt *active_list = &clic->active_list[hart_offset];
    size_t *active_count = &clic->active_count[hartid];

    CLICActiveInterrupt key = {
        (PRV_M << 8) |
        xt_clic_intctl_effective(clic, clic->clicintctl[irq_offset]), irq
    };
    CLICActiveInterrupt *result = bsearch(&key,
                                          active_list, *active_count,
                                          sizeof(CLICActiveInterrupt),
                                          xt_clic_active_compare);
    assert(result);
    size_t elem = (result - active_list);
    size_t sz = (--(*active_count) - elem) * sizeof(CLICActiveInterrupt);
    memmove(&result[0], &result[1], sz);

    /* Sort list of active interrupts */
    qsort(active_list, *active_count,
          sizeof(CLICActiveInterrupt),
          xt_clic_active_compare);
}

static void xt_clic_update_intctl(XTCLICState *clic,
                                  int irq, uint64_t new_intctl)
{
    int hartid = xt_clic_get_hartid();
    size_t hart_offset = hartid * clic->num_sources;
    size_t irq_offset = irq + hart_offset;
    CLICActiveInterrupt *active_list = &clic->active_list[hart_offset];
    size_t *active_count = &clic->active_count[hartid];

    CLICActiveInterrupt key = {
        (PRV_M << 8) |
        xt_clic_intctl_effective(clic, clic->clicintctl[irq_offset]), irq
    };
    CLICActiveInterrupt *result = bsearch(&key,
                                          active_list, *active_count,
                                          sizeof(CLICActiveInterrupt),
                                          xt_clic_active_compare);

    if (result) {
        result->intcfg = (PRV_M << 8) |
                         xt_clic_intctl_effective(clic, new_intctl);
        qsort(active_list, *active_count,
              sizeof(CLICActiveInterrupt),
              xt_clic_active_compare);
    }
    clic->clicintctl[irq_offset] = new_intctl;
    xt_clic_next_interrupt(clic, hartid);
}

static void
xt_clic_update_intie(XTCLICState *clic, int irq, uint64_t new_intie)
{
    int hartid = xt_clic_get_hartid();
    size_t irq_offset = irq + clic->num_sources * hartid;


    uint8_t old_intie = clic->clicintie[irq_offset];
    clic->clicintie[irq_offset] = !!new_intie;

    /* Add to or remove from list of active interrupts */
    if (new_intie && !old_intie) {
        xt_clic_enable_irq(clic, irq);
    } else if (!new_intie && old_intie) {
        xt_clic_disable_irq(clic, irq);
    }

    xt_clic_next_interrupt(clic, hartid);
}

/*
 * BL808 T-Head CLIC register layout (matches vendor SDK headers):
 *
 *   +0x000: cliccfg      — 1 byte (global config)
 *   +0x004: clicinfo     — 32-bit capability register
 *   +0x008: mintthresh   — 1 byte threshold register
 *   +0x1000 + 4*i + 0: clicintip[i]
 *   +0x1000 + 4*i + 1: clicintie[i]
 *   +0x1000 + 4*i + 2: clicintattr[i]
 *   +0x1000 + 4*i + 3: clicintctl[i]
 */

#define BL808_CLIC_CFG_OFF         0x000
#define BL808_CLIC_INFO_OFF        0x004
#define BL808_CLIC_MINTTHRESH_OFF  0x008
#define BL808_CLIC_INT_OFF         0x1000
#define BL808_CLIC_INT_STRIDE      0x4
#define BL808_CLIC_APERTURE_SIZE   0x5000
#define BL808_CLIC_INT_IP          0x0
#define BL808_CLIC_INT_IE          0x1
#define BL808_CLIC_INT_ATTR        0x2
#define BL808_CLIC_INT_CTL         0x3

static bool xt_clic_decode_int_reg(XTCLICState *clic, hwaddr addr,
                                   size_t *irq, size_t *field)
{
    hwaddr rel;

    if (addr < BL808_CLIC_INT_OFF) {
        return false;
    }

    rel = addr - BL808_CLIC_INT_OFF;
    *irq = rel / BL808_CLIC_INT_STRIDE;
    *field = rel % BL808_CLIC_INT_STRIDE;
    return *irq < clic->num_sources;
}

static uint8_t xt_clic_read_int_field(XTCLICState *clic, int hartid,
                                      size_t irq, size_t field)
{
    size_t irq_offset = irq + clic->num_sources * hartid;

    switch (field) {
    case BL808_CLIC_INT_IP:
        return clic->clicintip[irq_offset];
    case BL808_CLIC_INT_IE:
        return clic->clicintie[irq_offset];
    case BL808_CLIC_INT_ATTR:
        return clic->clicintattr[irq_offset] | (PRV_M << 6);
    case BL808_CLIC_INT_CTL:
        return xt_clic_intctl_effective(clic, clic->clicintctl[irq_offset]);
    default:
        g_assert_not_reached();
    }
}

static void xt_clic_write_int_field(XTCLICState *clic, int hartid,
                                    size_t irq, size_t field, uint8_t value)
{
    size_t irq_offset = irq + clic->num_sources * hartid;

    switch (field) {
    case BL808_CLIC_INT_IP:
        if (xt_clic_validate_intip(clic, irq) &&
            value != clic->clicintip[irq_offset]) {
            xt_clic_update_intip(clic, hartid, irq, value);
        }
        break;
    case BL808_CLIC_INT_IE:
        if (clic->clicintie[irq_offset] != value) {
            xt_clic_update_intie(clic, irq, value);
        }
        break;
    case BL808_CLIC_INT_ATTR:
        clic->clicintattr[irq_offset] = (value & 0x7) | (PRV_M << 6);
        xt_clic_next_interrupt(clic, hartid);
        break;
    case BL808_CLIC_INT_CTL:
        value = xt_clic_intctl_storage(clic, value);
        if (value != clic->clicintctl[irq_offset]) {
            xt_clic_update_intctl(clic, irq, value);
        }
        break;
    default:
        g_assert_not_reached();
    }
}

static void
xt_clic_write(void *opaque, hwaddr addr, uint64_t value, unsigned size)
{
    XTCLICState *clic = opaque;
    int hartid = xt_clic_get_hartid();
    size_t irq;
    size_t field;

    if (addr == BL808_CLIC_CFG_OFF) {
        uint8_t nlbits = extract32(value, 1, 4);

        if (nlbits <= 8) {
            clic->nlbits[hartid] = MIN(nlbits, clic->clicintctlbits);
        }
        clic->nmbits[hartid] = 0;
        xt_clic_next_interrupt(clic, hartid);
    } else if (addr == BL808_CLIC_MINTTHRESH_OFF) {
        clic->mintthresh[hartid] = (uint8_t)value;
        xt_clic_next_interrupt(clic, hartid);
    } else if (xt_clic_decode_int_reg(clic, addr, &irq, &field)) {
        if (field + size > BL808_CLIC_INT_STRIDE) {
            qemu_log_mask(LOG_GUEST_ERROR,
                          "clic: invalid write at 0x%" HWADDR_PRIx
                          " size %u\n", addr, size);
            return;
        }

        for (unsigned i = 0; i < size; i++) {
            xt_clic_write_int_field(clic, hartid, irq, field + i,
                                    value >> (i * 8));
        }
    } else {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "clic: invalid write at 0x%" HWADDR_PRIx "\n", addr);
    }
}

static uint64_t xt_clic_read(void *opaque, hwaddr addr, unsigned size)
{
    XTCLICState *clic = opaque;
    int hartid = xt_clic_get_hartid();
    size_t irq;
    size_t field;

    if (addr == BL808_CLIC_CFG_OFF) {
        return clic->nvbits |
               (clic->nlbits[hartid] << 1) |
               (clic->nmbits[hartid] << 5);
    } else if (addr == BL808_CLIC_INFO_OFF) {
        return (clic->num_sources & 0x1fff) |
               (0x80 << 13) |
               ((clic->clicintctlbits & 0xf) << 21);
    } else if (addr == BL808_CLIC_MINTTHRESH_OFF) {
        return clic->mintthresh[hartid];
    } else if (xt_clic_decode_int_reg(clic, addr, &irq, &field)) {
        uint64_t ret = 0;

        if (field + size > BL808_CLIC_INT_STRIDE) {
            qemu_log_mask(LOG_GUEST_ERROR,
                          "clic: invalid read at 0x%" HWADDR_PRIx
                          " size %u\n", addr, size);
            return 0;
        }

        for (unsigned i = 0; i < size; i++) {
            ret |= (uint64_t)xt_clic_read_int_field(clic, hartid, irq,
                                                    field + i) << (i * 8);
        }
        return ret;
    }

    qemu_log_mask(LOG_GUEST_ERROR,
                  "clic: invalid read at 0x%" HWADDR_PRIx "\n", addr);
    return 0;
}

static void xt_clic_set_irq(void *opaque, int irq, int level)
{
    XTCLICState *clic = opaque;
    TRIG_TYPE type;
    int hartid;
    size_t irq_offset;

    hartid = irq / clic->num_sources;
    irq = irq % clic->num_sources;
    irq_offset = irq + clic->num_sources * hartid;
    type = xt_clic_get_trigger_type(clic, irq_offset);

    /*
     * In general, the edge-triggered interrupt state should be kept in pending
     * bit, while the level-triggered interrupt should be kept in the level
     * state of the incoming wire.
     *
     * For CLIC, model the level-triggered interrupt by read-only pending bit.
     */
    if (level) {
        switch (type) {
        case POSITIVE_LEVEL:
        case POSITIVE_EDGE:
            xt_clic_update_intip(clic, hartid, irq, level);
            break;
        case NEG_LEVEL:
            xt_clic_update_intip(clic, hartid, irq, !level);
            break;
        case NEG_EDGE:
            break;
        }
    } else {
        switch (type) {
        case POSITIVE_LEVEL:
            xt_clic_update_intip(clic, hartid, irq, level);
            break;
        case POSITIVE_EDGE:
            break;
        case NEG_LEVEL:
        case NEG_EDGE:
            xt_clic_update_intip(clic, hartid, irq, !level);
            break;
        }
    }
}

static const MemoryRegionOps xt_clic_ops = {
    .read = xt_clic_read,
    .write = xt_clic_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = {
        .min_access_size = 1,
        .max_access_size = 4
    }
};

static void xt_clic_realize(DeviceState *dev, Error **errp)
{
    XTCLICState *clic = XT_CLIC(dev);
    int irqs = clic->num_harts * clic->num_sources;
    /*
     * E902 documents a 20 KiB CLIC aperture. Keep the full window mapped even
     * when the BL808 integration exposes fewer interrupt sources.
     */
    clic->clic_size = MAX(BL808_CLIC_APERTURE_SIZE,
                          BL808_CLIC_INT_OFF +
                          clic->num_sources * BL808_CLIC_INT_STRIDE);
    memory_region_init_io(&clic->mmio, OBJECT(dev), &xt_clic_ops, clic,
                          TYPE_XT_CLIC, clic->clic_size);


    clic->nmbits = g_new0(uint8_t, clic->num_harts);
    clic->nlbits = g_new0(uint8_t, clic->num_harts);
    clic->clicinfo = g_new0(uint32_t, clic->num_harts);

    clic->clicintip = g_new0(uint8_t, irqs);
    clic->clicintie = g_new0(uint8_t, irqs);
    clic->clicintattr = g_new0(uint8_t, irqs);
    clic->clicintctl = g_new0(uint8_t, irqs);

    clic->mintthresh = g_new0(uint32_t, clic->num_harts);
    clic->active_list = g_new0(CLICActiveInterrupt, irqs);
    clic->active_count = g_new0(size_t, clic->num_harts);
    sysbus_init_mmio(SYS_BUS_DEVICE(dev), &clic->mmio);

    /* Allocate irq through gpio, so that we can use qtest */
    qdev_init_gpio_in(dev, xt_clic_set_irq, irqs);
    for (int i = 0; i < clic->num_harts; i++) {
        CPUState *cs = qemu_get_cpu(i + clic->hartid_base);
        if (cs) {
            RISCVCPU *cpu = RISCV_CPU(cs);
            cpu->env.clic = clic;
            cpu->env.mclicbase = clic->mclicbase;
        }
    }
}

static const Property xt_clic_properties[] = {
    DEFINE_PROP_BOOL("vector", XTCLICState, nvbits, false),
    DEFINE_PROP_UINT32("num-sources", XTCLICState, num_sources, 0),
    DEFINE_PROP_UINT32("num-harts", XTCLICState, num_harts, 0),
    DEFINE_PROP_UINT32("hartid-base", XTCLICState, hartid_base, 0),
    DEFINE_PROP_UINT32("clicintctlbits", XTCLICState, clicintctlbits, 0),
    DEFINE_PROP_UINT64("mclicbase", XTCLICState, mclicbase, 0),
};

static void xt_clic_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    dc->realize = xt_clic_realize;
    device_class_set_props(dc, xt_clic_properties);
}

static const TypeInfo xt_clic_info = {
    .name          = TYPE_XT_CLIC,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(XTCLICState),
    .class_init    = xt_clic_class_init,
};

static void xt_clic_register_types(void)
{
    type_register_static(&xt_clic_info);
}

type_init(xt_clic_register_types)

/*
 * xt_clic_create:
 *
 * @addr: base address of M-Mode CLIC memory-mapped registers
 * @vector: the selective interrupt hardware vectoring is implemented or not
 * @num_sources: number of interrupts supporting by each aperture
 * @clicintctlbits: bits are actually implemented in the clicintctl registers
 *
 * Returns: the device object
 */
DeviceState *xt_clic_create(hwaddr addr, bool vector,
                            uint32_t hartid_base, uint32_t num_harts,
                            uint32_t num_sources,
                            uint8_t clicintctlbits)
{
    DeviceState *dev = qdev_new(TYPE_XT_CLIC);

    assert(num_sources <= 4096);
    assert(clicintctlbits <= 8);

    qdev_prop_set_bit(dev, "vector", vector);
    qdev_prop_set_uint32(dev, "num-sources", num_sources);
    qdev_prop_set_uint32(dev, "num-harts", num_harts);
    qdev_prop_set_uint32(dev, "hartid-base", hartid_base);
    qdev_prop_set_uint32(dev, "clicintctlbits", clicintctlbits);
    qdev_prop_set_uint64(dev, "mclicbase", addr);

    sysbus_realize_and_unref(SYS_BUS_DEVICE(dev), &error_fatal);
    sysbus_mmio_map(SYS_BUS_DEVICE(dev), 0, addr);
    return dev;
}

void xt_clic_get_next_interrupt(void *opaque)
{
    XTCLICState *clic = opaque;
    xt_clic_next_interrupt(clic, current_cpu->cpu_index - clic->hartid_base);
}

bool xt_clic_shv_interrupt(void *opaque, int irq)
{
    XTCLICState *clic = opaque;
    size_t irq_offset = irq + clic->num_sources *
                              xt_clic_get_hartid();
    return xt_clic_is_shv_interrupt(clic, irq_offset);
}

bool xt_clic_edge_triggered(void *opaque, int irq)
{
    XTCLICState *clic = opaque;
    size_t irq_offset = irq + clic->num_sources *
                              xt_clic_get_hartid();
    return xt_clic_is_edge_triggered(clic, irq_offset);
}

void xt_clic_clean_pending(void *opaque, int irq)
{
    XTCLICState *clic = opaque;
    int hartid = xt_clic_get_hartid();
    size_t irq_offset = irq + clic->num_sources * hartid;
    clic->clicintip[irq_offset] = 0;
    xt_clic_next_interrupt(clic, hartid);
}

target_ulong xt_clic_mnxti_read(void *opaque, CPURISCVState *env, bool ack)
{
    XTCLICState *clic = opaque;
    int hartid = xt_clic_get_hartid_internal(clic);
    CLICActiveInterrupt active;
    uint8_t level;
    size_t irq_offset;
    uint8_t threshold;

    if (env->priv != PRV_M) {
        return 0;
    }

    threshold = get_field(env->mcause, MCAUSE_MPIL);
    if (!xt_clic_find_pending(clic, hartid, threshold, true,
                              &active, &level)) {
        return 0;
    }

    irq_offset = active.irq + clic->num_sources * hartid;
    env->mintstatus = set_field(env->mintstatus, MINTSTATUS_MIL, level);
    env->mcause = (env->mcause & ~0xfffULL) | active.irq;

    if (ack && xt_clic_is_edge_triggered(clic, irq_offset)) {
        clic->clicintip[irq_offset] = 0;
        xt_clic_next_interrupt(clic, hartid);
    }

    return (env->mtvt & ~0x3fULL) + 4 * active.irq;
}

/*
 * The new CLIC interrupt-handling mode is encoded as a new state in
 * the existing WARL xtvec register, where the low two bits of  are 11.
 */
bool xt_clic_is_clic_mode(CPURISCVState *env)
{
    target_ulong xtvec = (env->priv == PRV_M) ? env->mtvec : env->stvec;
    return env->clic && ((xtvec & 0x3) == 3);
}

void xt_clic_decode_exccode(uint32_t exccode, int *mode,
                            int *il, int *irq)
{
    *irq = extract32(exccode, 0, 12);
    *mode = extract32(exccode, 12, 2);
    *il = extract32(exccode, 14, 8);
}
