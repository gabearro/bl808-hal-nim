/*
 * Bouffalo Lab BL808 CCI emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "hw/misc/bl808_cci.h"

#define CCI_CFG             0x000
#define CCI_ADDR            0x004
#define CCI_WDATA           0x008
#define CCI_RDATA           0x00c
#define CCI_CTL             0x010
#define CCI_AUDIO_PLL_CFG0  0x750
#define CCI_AUDIO_PLL_CFG1  0x754
#define CCI_AUDIO_PLL_CFG2  0x758
#define CCI_AUDIO_PLL_CFG3  0x75c
#define CCI_AUDIO_PLL_CFG4  0x760
#define CCI_AUDIO_PLL_CFG5  0x764
#define CCI_AUDIO_PLL_CFG6  0x768
#define CCI_AUDIO_PLL_CFG7  0x76c
#define CCI_AUDIO_PLL_CFG8  0x770
#define CCI_CPU_PLL_CFG0    0x7d0
#define CCI_CPU_PLL_CFG1    0x7d4
#define CCI_CPU_PLL_CFG2    0x7d8
#define CCI_CPU_PLL_CFG3    0x7dc
#define CCI_CPU_PLL_CFG4    0x7e0
#define CCI_CPU_PLL_CFG5    0x7e4
#define CCI_CPU_PLL_CFG6    0x7e8
#define CCI_CPU_PLL_CFG7    0x7ec
#define CCI_CPU_PLL_CFG8    0x7f0

static void bl808_cci_notify_clients(BL808CCIState *s, hwaddr offset,
                                     uint32_t value)
{
    for (size_t i = 0; i < ARRAY_SIZE(s->hooks); i++) {
        BL808CCIHook *hook = &s->hooks[i];

        if (!hook->in_use || hook->offset != offset || !hook->config_update) {
            continue;
        }

        hook->config_update(hook->opaque, offset, value);
    }
}

static uint32_t bl808_cci_write_mask(hwaddr offset)
{
    switch (offset) {
    case CCI_CFG:
        return 0x000003ffu;
    case CCI_ADDR:
    case CCI_WDATA:
        return 0xffffffffu;
    case CCI_AUDIO_PLL_CFG0:
        return 0x00000fffu;
    case CCI_AUDIO_PLL_CFG1:
        return 0x03330f7fu;
    case CCI_AUDIO_PLL_CFG2:
        return 0x000007f1u;
    case CCI_AUDIO_PLL_CFG3:
        return 0x0007f131u;
    case CCI_AUDIO_PLL_CFG4:
        return 0x00000133u;
    case CCI_AUDIO_PLL_CFG5:
        return 0x00000007u;
    case CCI_AUDIO_PLL_CFG6:
        return 0x0107ffffu;
    case CCI_AUDIO_PLL_CFG7:
        return 0x00030001u;
    case CCI_AUDIO_PLL_CFG8:
        return 0x000003ffu;
    case CCI_CPU_PLL_CFG0:
        return 0x00000fffu;
    case CCI_CPU_PLL_CFG1:
        return 0x03330f7fu;
    case CCI_CPU_PLL_CFG2:
        return 0x000007f1u;
    case CCI_CPU_PLL_CFG3:
        return 0x0007f131u;
    case CCI_CPU_PLL_CFG4:
        return 0x00000133u;
    case CCI_CPU_PLL_CFG5:
        return 0x00000007u;
    case CCI_CPU_PLL_CFG6:
        return 0x0107ffffu;
    case CCI_CPU_PLL_CFG7:
        return 0x00030001u;
    case CCI_CPU_PLL_CFG8:
        return 0x000001ffu;
    default:
        return 0xffffffffu;
    }
}

static bool bl808_cci_read_only(hwaddr offset)
{
    return offset == CCI_RDATA || offset == CCI_CTL;
}

static void bl808_cci_reset_state(BL808CCIState *s)
{
    memset(s->regs, 0, sizeof(s->regs));

    s->regs[CCI_CFG / 4] = 0x00000221u;
    s->regs[CCI_AUDIO_PLL_CFG0 / 4] = 0x00000fffu;
    s->regs[CCI_AUDIO_PLL_CFG1 / 4] = 0x01100412u;
    s->regs[CCI_AUDIO_PLL_CFG2 / 4] = 0x00000741u;
    s->regs[CCI_AUDIO_PLL_CFG3 / 4] = 0x0005a021u;
    s->regs[CCI_AUDIO_PLL_CFG4 / 4] = 0x00000111u;
    s->regs[CCI_AUDIO_PLL_CFG5 / 4] = 0x00000003u;
    s->regs[CCI_AUDIO_PLL_CFG6 / 4] = 0x000161e5u;
    s->regs[CCI_AUDIO_PLL_CFG7 / 4] = 0x00000001u;
    s->regs[CCI_AUDIO_PLL_CFG8 / 4] = 0x00000067u;
    s->regs[CCI_CPU_PLL_CFG0 / 4] = 0x00000fffu;
    s->regs[CCI_CPU_PLL_CFG1 / 4] = 0x01100400u;
    s->regs[CCI_CPU_PLL_CFG2 / 4] = 0x00000741u;
    s->regs[CCI_CPU_PLL_CFG3 / 4] = 0x0005a021u;
    s->regs[CCI_CPU_PLL_CFG4 / 4] = 0x00000111u;
    s->regs[CCI_CPU_PLL_CFG5 / 4] = 0x00000003u;
    s->regs[CCI_CPU_PLL_CFG6 / 4] = 0x00014000u;
    s->regs[CCI_CPU_PLL_CFG7 / 4] = 0x00000001u;
    s->regs[CCI_CPU_PLL_CFG8 / 4] = 0x00000037u;
}

void bl808_cci_register_config_notify(DeviceState *dev, hwaddr offset,
                                      BL808CCIConfigNotify config_update,
                                      void *opaque)
{
    BL808CCIState *s = BL808_CCI(dev);

    for (size_t i = 0; i < ARRAY_SIZE(s->hooks); i++) {
        BL808CCIHook *hook = &s->hooks[i];

        if (hook->in_use) {
            continue;
        }

        hook->in_use = true;
        hook->offset = offset;
        hook->config_update = config_update;
        hook->opaque = opaque;
        return;
    }

    qemu_log_mask(LOG_GUEST_ERROR,
                  "bl808_cci: no free config hook slots for offset 0x%"
                  HWADDR_PRIx "\n", offset);
}

static uint64_t bl808_cci_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808CCIState *s = opaque;

    if ((offset & 3) || offset >= BL808_CCI_REG_SIZE) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_cci: bad read offset 0x%" HWADDR_PRIx "\n",
                      offset);
        return 0;
    }

    return s->regs[offset / 4];
}

static void bl808_cci_write(void *opaque, hwaddr offset, uint64_t value,
                            unsigned size)
{
    BL808CCIState *s = opaque;
    uint32_t val = (uint32_t)value;
    uint32_t old;
    uint32_t *reg;

    if ((offset & 3) || offset >= BL808_CCI_REG_SIZE) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_cci: bad write offset 0x%" HWADDR_PRIx
                      " = 0x%" PRIx64 "\n", offset, value);
        return;
    }

    if (bl808_cci_read_only(offset)) {
        return;
    }

    reg = &s->regs[offset / 4];
    old = *reg;
    *reg = val & bl808_cci_write_mask(offset);
    if (*reg != old) {
        bl808_cci_notify_clients(s, offset, *reg);
    }
}

static const MemoryRegionOps bl808_cci_ops = {
    .read = bl808_cci_read,
    .write = bl808_cci_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static void bl808_cci_reset(DeviceState *dev)
{
    bl808_cci_reset_state(BL808_CCI(dev));
}

static void bl808_cci_init(Object *obj)
{
    BL808CCIState *s = BL808_CCI(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    memory_region_init_io(&s->iomem, obj, &bl808_cci_ops, s,
                          TYPE_BL808_CCI, BL808_CCI_REG_SIZE);
    sysbus_init_mmio(sbd, &s->iomem);
}

static void bl808_cci_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    device_class_set_legacy_reset(dc, bl808_cci_reset);
}

static const TypeInfo bl808_cci_info = {
    .name          = TYPE_BL808_CCI,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(BL808CCIState),
    .instance_init = bl808_cci_init,
    .class_init    = bl808_cci_class_init,
};

static void bl808_cci_register_types(void)
{
    type_register_static(&bl808_cci_info);
}

type_init(bl808_cci_register_types)
