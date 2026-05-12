/*
 * Bouffalo Lab BL808 MCU_MISC emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "hw/misc/bl808_mcu_misc.h"

#define MCU_MISC_MCU_BUS_CFG0   0x000
#define MCU_MISC_MCU_BUS_CFG1   0x004
#define MCU_MISC_MCU_E907_RTC   0x014
#define MCU_MISC_MCU_CFG1       0x100
#define MCU_MISC_MCU1_LOG1      0x110
#define MCU_MISC_MCU1_LOG2      0x114
#define MCU_MISC_MCU1_LOG3      0x118
#define MCU_MISC_MCU1_LOG4      0x11c
#define MCU_MISC_MCU1_LOG5      0x120
#define MCU_MISC_IROM1_MISR0    0x208
#define MCU_MISC_IROM1_MISR1    0x20c

static uint32_t bl808_mcu_misc_write_mask(hwaddr offset)
{
    switch (offset) {
    case MCU_MISC_MCU_BUS_CFG0:
        return 0x00000003u;
    case MCU_MISC_MCU_BUS_CFG1:
        return 0x0001018fu;
    case MCU_MISC_MCU_E907_RTC:
        return 0xc00003ffu;
    case MCU_MISC_MCU_CFG1:
        return 0x30010031u;
    default:
        return 0;
    }
}

static bool bl808_mcu_misc_read_only(hwaddr offset)
{
    switch (offset) {
    case MCU_MISC_MCU1_LOG1:
    case MCU_MISC_MCU1_LOG2:
    case MCU_MISC_MCU1_LOG3:
    case MCU_MISC_MCU1_LOG4:
    case MCU_MISC_MCU1_LOG5:
    case MCU_MISC_IROM1_MISR0:
    case MCU_MISC_IROM1_MISR1:
        return true;
    default:
        return false;
    }
}

static void bl808_mcu_misc_reset_state(BL808MCUMiscState *s)
{
    memset(s->regs, 0, sizeof(s->regs));

    s->regs[MCU_MISC_MCU_E907_RTC / 4] = 0x8000000au;
    s->regs[MCU_MISC_MCU_CFG1 / 4] = 0x00000030u;
}

static uint64_t bl808_mcu_misc_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808MCUMiscState *s = opaque;

    if ((offset & 3) || offset >= BL808_MCU_MISC_REG_SIZE) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_mcu_misc: bad read offset 0x%" HWADDR_PRIx "\n",
                      offset);
        return 0;
    }

    return s->regs[offset / 4];
}

static void bl808_mcu_misc_write(void *opaque, hwaddr offset, uint64_t value,
                                 unsigned size)
{
    BL808MCUMiscState *s = opaque;
    uint32_t val = (uint32_t)value;
    uint32_t *reg;
    uint32_t mask;

    if ((offset & 3) || offset >= BL808_MCU_MISC_REG_SIZE) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_mcu_misc: bad write offset 0x%" HWADDR_PRIx
                      " = 0x%" PRIx64 "\n", offset, value);
        return;
    }

    if (bl808_mcu_misc_read_only(offset)) {
        return;
    }

    reg = &s->regs[offset / 4];
    mask = bl808_mcu_misc_write_mask(offset);

    switch (offset) {
    case MCU_MISC_MCU_BUS_CFG0:
        *reg = (*reg & ~mask) | (val & mask);
        if (val & BIT(1)) {
            *reg &= ~BIT(16);
        }
        break;
    default:
        *reg = (*reg & ~mask) | (val & mask);
        break;
    }
}

static const MemoryRegionOps bl808_mcu_misc_ops = {
    .read = bl808_mcu_misc_read,
    .write = bl808_mcu_misc_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static void bl808_mcu_misc_reset(DeviceState *dev)
{
    bl808_mcu_misc_reset_state(BL808_MCU_MISC(dev));
}

static void bl808_mcu_misc_init(Object *obj)
{
    BL808MCUMiscState *s = BL808_MCU_MISC(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    memory_region_init_io(&s->iomem, obj, &bl808_mcu_misc_ops, s,
                          TYPE_BL808_MCU_MISC, BL808_MCU_MISC_REG_SIZE);
    sysbus_init_mmio(sbd, &s->iomem);
}

static void bl808_mcu_misc_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    device_class_set_legacy_reset(dc, bl808_mcu_misc_reset);
}

static const TypeInfo bl808_mcu_misc_info = {
    .name          = TYPE_BL808_MCU_MISC,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(BL808MCUMiscState),
    .instance_init = bl808_mcu_misc_init,
    .class_init    = bl808_mcu_misc_class_init,
};

static void bl808_mcu_misc_register_types(void)
{
    type_register_static(&bl808_mcu_misc_info);
}

type_init(bl808_mcu_misc_register_types)
