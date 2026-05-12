/*
 * Bouffalo Lab BL808 MM_MISC emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "hw/misc/bl808_mm_misc.h"

#define MM_MISC_CPU0_BOOT         0x000
#define MM_MISC_CPU_CFG           0x008
#define MM_MISC_CPU_STS1          0x00c
#define MM_MISC_CPU_STS2          0x010
#define MM_MISC_CPU_RTC           0x018
#define MM_MISC_TZC_MMSYS_MISC    0x01c
#define MM_MISC_PERI_APB_CTRL     0x020
#define MM_MISC_MM_INFRA_QOS_CTRL 0x02c
#define MM_MISC_DMA_CLK_CTRL      0x040
#define MM_MISC_VRAM_CTRL         0x050
#define MM_MISC_SRAM_PARM         0x060
#define MM_MISC_MM_INT_STA0       0x0a0
#define MM_MISC_MM_INT_MASK0      0x0a4
#define MM_MISC_MM_INT_CLR0       0x0a8
#define MM_MISC_MM_INT_STA1       0x0ac
#define MM_MISC_MM_INT_MASK1      0x0b0
#define MM_MISC_MM_INT_CLR1       0x0b4
#define MM_MISC_DEBUG_SEL         0x0f0
#define MM_MISC_MISC_DUMMY        0x0fc
#define MM_MISC_DDR_DEBUG         0x100
#define MM_MISC_BERR_CFG0         0x140
#define MM_MISC_BERR_CFG1         0x144
#define MM_MISC_BERR_CFG2         0x148
#define MM_MISC_BERR_CFG3         0x14c
#define MM_MISC_BERR_CFG4         0x150
#define MM_MISC_BERR_CFG5         0x154
#define MM_MISC_BERR_CFG6         0x158
#define MM_MISC_BERR_CFG7         0x15c

static uint32_t bl808_mm_misc_write_mask(hwaddr offset)
{
    switch (offset) {
    case MM_MISC_CPU0_BOOT:
        return 0xffffffffu;
    case MM_MISC_CPU_CFG:
        return 0x30001fffu;
    case MM_MISC_CPU_RTC:
        return 0xc00003ffu;
    case MM_MISC_PERI_APB_CTRL:
        return 0xffff010fu;
    case MM_MISC_MM_INFRA_QOS_CTRL:
        return 0x03ff000cu;
    case MM_MISC_DMA_CLK_CTRL:
        return 0x000000ffu;
    case MM_MISC_VRAM_CTRL:
        return 0x000000d6u;
    case MM_MISC_SRAM_PARM:
        return 0x3f3f3f3fu;
    case MM_MISC_MM_INT_MASK0:
    case MM_MISC_MM_INT_MASK1:
        return 0xffffffffu;
    case MM_MISC_DEBUG_SEL:
        return 0x0000000fu;
    case MM_MISC_MISC_DUMMY:
        return 0xffffffffu;
    case MM_MISC_BERR_CFG0:
        return 0x1f010707u;
    case MM_MISC_BERR_CFG1:
        return 0x00000f0fu;
    default:
        return 0;
    }
}

static bool bl808_mm_misc_read_only(hwaddr offset)
{
    switch (offset) {
    case MM_MISC_CPU_STS1:
    case MM_MISC_CPU_STS2:
    case MM_MISC_TZC_MMSYS_MISC:
    case MM_MISC_MM_INT_STA0:
    case MM_MISC_MM_INT_STA1:
    case MM_MISC_DDR_DEBUG:
    case MM_MISC_BERR_CFG2:
    case MM_MISC_BERR_CFG3:
    case MM_MISC_BERR_CFG4:
    case MM_MISC_BERR_CFG5:
    case MM_MISC_BERR_CFG6:
    case MM_MISC_BERR_CFG7:
        return true;
    default:
        return false;
    }
}

static void bl808_mm_misc_reset_state(BL808MMMiscState *s)
{
    memset(s->regs, 0, sizeof(s->regs));

    s->regs[MM_MISC_CPU0_BOOT / 4] = 0x3eff0000u;
    s->regs[MM_MISC_CPU_CFG / 4] = 0x0000001cu;
    s->regs[MM_MISC_CPU_RTC / 4] = 0x0000000au;
    s->regs[MM_MISC_DMA_CLK_CTRL / 4] = 0x000000ffu;
    s->regs[MM_MISC_SRAM_PARM / 4] = 0x0c0c0c0cu;
    s->regs[MM_MISC_MISC_DUMMY / 4] = 0xfff00000u;
    s->regs[MM_MISC_BERR_CFG0 / 4] = 0x1f010707u;
}

void bl808_mm_misc_set_clock_enabled(BL808MMMiscState *s, bool enabled)
{
    s->clock_enabled = enabled;
}

void bl808_mm_misc_set_reset_asserted(BL808MMMiscState *s, bool asserted)
{
    s->reset_asserted = asserted;
    if (asserted) {
        device_cold_reset(DEVICE(s));
    }
}

static uint64_t bl808_mm_misc_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808MMMiscState *s = opaque;

    if ((offset & 3) || offset >= BL808_MM_MISC_REG_SIZE) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_mm_misc: bad read offset 0x%" HWADDR_PRIx "\n",
                      offset);
        return 0;
    }

    return s->regs[offset / 4];
}

static void bl808_mm_misc_write(void *opaque, hwaddr offset, uint64_t value,
                                unsigned size)
{
    BL808MMMiscState *s = opaque;
    uint32_t val = (uint32_t)value;
    uint32_t *reg;
    uint32_t mask;

    if ((offset & 3) || offset >= BL808_MM_MISC_REG_SIZE) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_mm_misc: bad write offset 0x%" HWADDR_PRIx
                      " = 0x%" PRIx64 "\n", offset, value);
        return;
    }
    if (s->reset_asserted) {
        return;
    }

    if (bl808_mm_misc_read_only(offset)) {
        return;
    }

    reg = &s->regs[offset / 4];
    mask = bl808_mm_misc_write_mask(offset);

    switch (offset) {
    case MM_MISC_VRAM_CTRL:
        *reg = (*reg & ~mask) | (val & mask);
        *reg &= ~BIT(0);
        break;
    case MM_MISC_MM_INT_CLR0:
        s->regs[MM_MISC_MM_INT_STA0 / 4] &= ~val;
        break;
    case MM_MISC_MM_INT_CLR1:
        s->regs[MM_MISC_MM_INT_STA1 / 4] &= ~val;
        break;
    case MM_MISC_BERR_CFG1:
        *reg = (*reg & ~mask) | (val & mask);
        if (val & BIT(0)) {
            *reg &= ~BIT(16);
        }
        if (val & BIT(1)) {
            *reg &= ~BIT(17);
        }
        if (val & BIT(2)) {
            *reg &= ~BIT(18);
        }
        if (val & BIT(3)) {
            *reg &= ~BIT(19);
        }
        break;
    default:
        *reg = (*reg & ~mask) | (val & mask);
        break;
    }
}

static const MemoryRegionOps bl808_mm_misc_ops = {
    .read = bl808_mm_misc_read,
    .write = bl808_mm_misc_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static void bl808_mm_misc_reset(DeviceState *dev)
{
    bl808_mm_misc_reset_state(BL808_MM_MISC(dev));
}

static void bl808_mm_misc_init(Object *obj)
{
    BL808MMMiscState *s = BL808_MM_MISC(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    memory_region_init_io(&s->iomem, obj, &bl808_mm_misc_ops, s,
                          TYPE_BL808_MM_MISC, BL808_MM_MISC_REG_SIZE);
    sysbus_init_mmio(sbd, &s->iomem);
    s->clock_enabled = false;
    s->reset_asserted = false;
}

static void bl808_mm_misc_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    device_class_set_legacy_reset(dc, bl808_mm_misc_reset);
}

static const TypeInfo bl808_mm_misc_info = {
    .name          = TYPE_BL808_MM_MISC,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(BL808MMMiscState),
    .instance_init = bl808_mm_misc_init,
    .class_init    = bl808_mm_misc_class_init,
};

static void bl808_mm_misc_register_types(void)
{
    type_register_static(&bl808_mm_misc_info);
}

type_init(bl808_mm_misc_register_types)
