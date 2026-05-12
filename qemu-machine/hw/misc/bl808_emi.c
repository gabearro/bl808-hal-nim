/*
 * Bouffalo Lab BL808 EMI/XRAM controller emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "hw/misc/bl808_emi.h"

#define EMI_CTRL        0x00
#define EMI_CLK_CFG     0x04
#define EMI_RAM_CFG     0x08
#define EMI_PROT        0x0C
#define EMI_INT_STS     0x10
#define EMI_INT_MASK    0x14
#define EMI_INT_CLR     0x18

#define EMI_CTRL_EN         BIT(0)
#define EMI_CTRL_ARB_SHIFT  4
#define EMI_CTRL_ARB_MASK   (0x3u << EMI_CTRL_ARB_SHIFT)

static void bl808_emi_reset_state(BL808EMIState *s)
{
    /*
     * XRAM is available very early in boot flows, so keep the controller
     * enabled after reset and expose round-robin arbitration by default.
     */
    s->ctrl = EMI_CTRL_EN | (1u << EMI_CTRL_ARB_SHIFT);
    s->clk_cfg = 0;
    s->ram_cfg = 0;
    s->prot = 0;
    s->int_sts = 0;
    s->int_mask = 0;
}

void bl808_emi_set_clock_enabled(BL808EMIState *s, bool enabled)
{
    s->clock_enabled = enabled;
}

void bl808_emi_set_reset_asserted(BL808EMIState *s, bool asserted)
{
    s->reset_asserted = asserted;
    if (asserted) {
        device_cold_reset(DEVICE(s));
    }
}

static uint64_t bl808_emi_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808EMIState *s = opaque;

    switch (offset) {
    case EMI_CTRL:
        return s->ctrl;
    case EMI_CLK_CFG:
        return s->clk_cfg;
    case EMI_RAM_CFG:
        return s->ram_cfg;
    case EMI_PROT:
        return s->prot;
    case EMI_INT_STS:
        return s->int_sts;
    case EMI_INT_MASK:
        return s->int_mask;
    case EMI_INT_CLR:
        return 0;
    default:
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_emi: bad read offset 0x%" HWADDR_PRIx "\n",
                      offset);
        return 0;
    }
}

static void bl808_emi_write(void *opaque, hwaddr offset, uint64_t value,
                            unsigned size)
{
    BL808EMIState *s = opaque;
    uint32_t val = (uint32_t)value;

    switch (offset) {
    case EMI_CTRL:
        s->ctrl = val & (EMI_CTRL_EN | EMI_CTRL_ARB_MASK);
        break;
    case EMI_CLK_CFG:
        s->clk_cfg = val;
        break;
    case EMI_RAM_CFG:
        s->ram_cfg = val;
        break;
    case EMI_PROT:
        s->prot = val;
        break;
    case EMI_INT_STS:
    case EMI_INT_CLR:
        s->int_sts &= ~val;
        break;
    case EMI_INT_MASK:
        s->int_mask = val;
        break;
    default:
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_emi: bad write offset 0x%" HWADDR_PRIx
                      " = 0x%" PRIx64 "\n", offset, value);
        break;
    }
}

static const MemoryRegionOps bl808_emi_ops = {
    .read = bl808_emi_read,
    .write = bl808_emi_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static void bl808_emi_reset(DeviceState *dev)
{
    bl808_emi_reset_state(BL808_EMI(dev));
}

static void bl808_emi_init(Object *obj)
{
    BL808EMIState *s = BL808_EMI(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    memory_region_init_io(&s->iomem, obj, &bl808_emi_ops, s,
                          TYPE_BL808_EMI, BL808_EMI_REG_SIZE);
    sysbus_init_mmio(sbd, &s->iomem);
    s->clock_enabled = true;
}

static void bl808_emi_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    device_class_set_legacy_reset(dc, bl808_emi_reset);
}

static const TypeInfo bl808_emi_info = {
    .name          = TYPE_BL808_EMI,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(BL808EMIState),
    .instance_init = bl808_emi_init,
    .class_init    = bl808_emi_class_init,
};

static void bl808_emi_register_types(void)
{
    type_register_static(&bl808_emi_info);
}

type_init(bl808_emi_register_types)
