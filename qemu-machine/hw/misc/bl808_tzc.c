/*
 * Bouffalo Lab BL808 TZC emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "hw/misc/bl808_tzc.h"

#define TZC_ROM_CTRL             0x040
#define TZC_ROM_ADR_MASK         0x044
#define TZC_ROM_R0               0x048
#define TZC_ROM_R1               0x04c
#define TZC_ROM_R2               0x050
#define TZC_BMX_TZMID            0x100
#define TZC_BMX_TZMID_LOCK       0x104
#define TZC_BMX_S0               0x108
#define TZC_BMX_S1               0x10c
#define TZC_BMX_S2               0x110
#define TZC_BMX_S_LOCK           0x114
#define TZC_OCRAM_CTRL           0x140
#define TZC_OCRAM_ADR_MASK       0x144
#define TZC_OCRAM_R0             0x148
#define TZC_OCRAM_R1             0x14c
#define TZC_OCRAM_R2             0x150
#define TZC_WRAM_CTRL            0x180
#define TZC_WRAM_ADR_MASK        0x184
#define TZC_WRAM_R0              0x188
#define TZC_WRAM_R1              0x18c
#define TZC_WRAM_R2              0x190
#define TZC_PDM_CTRL             0x240
#define TZC_UART_CTRL            0x244
#define TZC_I2C_CTRL             0x248
#define TZC_TIMER_CTRL           0x24c
#define TZC_I2S_CTRL             0x250
#define TZC_SF_CTRL              0x280
#define TZC_SF_ADR_MASK          0x284
#define TZC_SF_R0                0x288
#define TZC_SF_R1                0x28c
#define TZC_SF_R2                0x290
#define TZC_SF_R3                0x294
#define TZC_SF_R_MSB             0x298
#define TZC_MM_BMX_TZMID         0x300
#define TZC_MM_BMX_TZMID_LOCK    0x304
#define TZC_MM_BMX_S0            0x308
#define TZC_MM_BMX_S1            0x30c
#define TZC_MM_BMX_S2            0x310
#define TZC_MM_BMX_S_LOCK0       0x314
#define TZC_MM_BMX_S_LOCK1       0x318
#define TZC_L2SRAM_CTRL          0x340
#define TZC_L2SRAM_ADR_MASK      0x344
#define TZC_L2SRAM_R0            0x348
#define TZC_L2SRAM_R1            0x34c
#define TZC_L2SRAM_R2            0x350
#define TZC_VRAM_CTRL            0x360
#define TZC_VRAM_ADR_MASK        0x364
#define TZC_VRAM_R0              0x368
#define TZC_VRAM_R1              0x36c
#define TZC_VRAM_R2              0x370
#define TZC_PSRAMA_CTRL          0x380
#define TZC_PSRAMA_ADR_MASK      0x384
#define TZC_PSRAMA_R0            0x388
#define TZC_PSRAMA_R1            0x38c
#define TZC_PSRAMA_R2            0x390
#define TZC_PSRAMB_CTRL          0x3a0
#define TZC_PSRAMB_ADR_MASK      0x3a4
#define TZC_PSRAMB_R0            0x3a8
#define TZC_PSRAMB_R1            0x3ac
#define TZC_PSRAMB_R2            0x3b0
#define TZC_XRAM_CTRL            0x3c0
#define TZC_XRAM_ADR_MASK        0x3c4
#define TZC_XRAM_R0              0x3c8
#define TZC_XRAM_R1              0x3cc
#define TZC_XRAM_R2              0x3d0
#define TZC_GLB_CTRL0            0xf00
#define TZC_GLB_CTRL1            0xf04
#define TZC_GLB_CTRL2            0xf08
#define TZC_MM_CTRL0             0xf20
#define TZC_MM_CTRL1             0xf24
#define TZC_MM_CTRL2             0xf28
#define TZC_SE_CTRL0             0xf40
#define TZC_SE_CTRL1             0xf44
#define TZC_SE_CTRL2             0xf48

static void bl808_tzc_reset_state(BL808TZCState *s)
{
    memset(s->regs, 0, sizeof(s->regs));

    s->regs[TZC_ROM_CTRL / 4] = 0x0000003fu;
    s->regs[TZC_ROM_R0 / 4] = 0x000003ffu;
    s->regs[TZC_ROM_R1 / 4] = 0x000003ffu;
    s->regs[TZC_ROM_R2 / 4] = 0x000003ffu;

    s->regs[TZC_BMX_TZMID / 4] = 0x07ff0000u;
    s->regs[TZC_BMX_S0 / 4] = 0x00000fffu;
    s->regs[TZC_BMX_S1 / 4] = 0x000000ffu;
    s->regs[TZC_BMX_S2 / 4] = 0x000000ffu;

    s->regs[TZC_OCRAM_CTRL / 4] = 0x0000003fu;
    s->regs[TZC_OCRAM_R0 / 4] = 0x000003ffu;
    s->regs[TZC_OCRAM_R1 / 4] = 0x000003ffu;
    s->regs[TZC_OCRAM_R2 / 4] = 0x000003ffu;

    s->regs[TZC_WRAM_CTRL / 4] = 0x0000003fu;
    s->regs[TZC_WRAM_R0 / 4] = 0x000003ffu;
    s->regs[TZC_WRAM_R1 / 4] = 0x000003ffu;
    s->regs[TZC_WRAM_R2 / 4] = 0x000003ffu;

    s->regs[TZC_PDM_CTRL / 4] = 0x00000001u;
    s->regs[TZC_UART_CTRL / 4] = 0x0000000fu;
    s->regs[TZC_I2C_CTRL / 4] = 0x0000000fu;
    s->regs[TZC_TIMER_CTRL / 4] = 0x0000001fu;
    s->regs[TZC_I2S_CTRL / 4] = 0x00000003u;

    s->regs[TZC_SF_CTRL / 4] = 0x0000003fu;
    s->regs[TZC_SF_R0 / 4] = 0x000003ffu;
    s->regs[TZC_SF_R1 / 4] = 0x000003ffu;
    s->regs[TZC_SF_R2 / 4] = 0x000003ffu;
    s->regs[TZC_SF_R3 / 4] = 0x000003ffu;

    s->regs[TZC_MM_BMX_TZMID / 4] = 0x00070000u;
    s->regs[TZC_MM_BMX_S0 / 4] = 0x0000003fu;
    s->regs[TZC_MM_BMX_S1 / 4] = 0x0000003fu;
    s->regs[TZC_MM_BMX_S2 / 4] = 0x00000003u;

    s->regs[TZC_L2SRAM_CTRL / 4] = 0x0000000fu;
    s->regs[TZC_L2SRAM_R0 / 4] = 0x000007ffu;
    s->regs[TZC_L2SRAM_R1 / 4] = 0x000007ffu;
    s->regs[TZC_L2SRAM_R2 / 4] = 0x000007ffu;

    s->regs[TZC_VRAM_CTRL / 4] = 0x0000000fu;
    s->regs[TZC_VRAM_R0 / 4] = 0x0000001fu;
    s->regs[TZC_VRAM_R1 / 4] = 0x0000001fu;
    s->regs[TZC_VRAM_R2 / 4] = 0x0000001fu;

    s->regs[TZC_PSRAMA_CTRL / 4] = 0x0000000fu;
    s->regs[TZC_PSRAMA_R0 / 4] = 0x000000ffu;
    s->regs[TZC_PSRAMA_R1 / 4] = 0x000000ffu;
    s->regs[TZC_PSRAMA_R2 / 4] = 0x000000ffu;

    s->regs[TZC_PSRAMB_CTRL / 4] = 0x0000000fu;
    s->regs[TZC_PSRAMB_R0 / 4] = 0x000000ffu;
    s->regs[TZC_PSRAMB_R1 / 4] = 0x000000ffu;
    s->regs[TZC_PSRAMB_R2 / 4] = 0x000000ffu;

    s->regs[TZC_XRAM_CTRL / 4] = 0x0000000fu;
    s->regs[TZC_XRAM_R0 / 4] = 0x00000003u;
    s->regs[TZC_XRAM_R1 / 4] = 0x00000003u;
    s->regs[TZC_XRAM_R2 / 4] = 0x00000003u;

    s->regs[TZC_GLB_CTRL0 / 4] = 0x0fffffffu;
    s->regs[TZC_GLB_CTRL1 / 4] = 0x000000ffu;
    s->regs[TZC_GLB_CTRL2 / 4] = 0x00000003u;
    s->regs[TZC_MM_CTRL0 / 4] = 0x0fffffffu;
    s->regs[TZC_MM_CTRL1 / 4] = 0x000000ffu;
    s->regs[TZC_MM_CTRL2 / 4] = 0x00000003u;
    s->regs[TZC_SE_CTRL0 / 4] = 0x000fffffu;
    s->regs[TZC_SE_CTRL1 / 4] = 0x0000ffffu;
    s->regs[TZC_SE_CTRL2 / 4] = 0x00000003u;
}

static uint64_t bl808_tzc_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808TZCState *s = opaque;

    if (size != 4) {
        return 0;
    }
    if ((offset & 3) || offset >= BL808_TZC_REG_SIZE) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_tzc(%s): bad read offset 0x%" HWADDR_PRIx "\n",
                      s->secure ? "sec" : "nsec", offset);
        return 0;
    }

    return s->regs[offset / 4];
}

static void bl808_tzc_write(void *opaque, hwaddr offset, uint64_t value,
                            unsigned size)
{
    BL808TZCState *s = opaque;

    if (size != 4) {
        return;
    }
    if ((offset & 3) || offset >= BL808_TZC_REG_SIZE) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_tzc(%s): bad write offset 0x%" HWADDR_PRIx
                      " = 0x%" PRIx64 "\n",
                      s->secure ? "sec" : "nsec", offset, value);
        return;
    }

    s->regs[offset / 4] = (uint32_t)value;
}

static const MemoryRegionOps bl808_tzc_ops = {
    .read = bl808_tzc_read,
    .write = bl808_tzc_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static void bl808_tzc_reset(DeviceState *dev)
{
    bl808_tzc_reset_state(BL808_TZC(dev));
}

static void bl808_tzc_init(Object *obj)
{
    BL808TZCState *s = BL808_TZC(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    memory_region_init_io(&s->iomem, obj, &bl808_tzc_ops, s,
                          TYPE_BL808_TZC, BL808_TZC_REG_SIZE);
    sysbus_init_mmio(sbd, &s->iomem);
}

static void bl808_tzc_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    device_class_set_legacy_reset(dc, bl808_tzc_reset);
}

static const TypeInfo bl808_tzc_info = {
    .name          = TYPE_BL808_TZC,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(BL808TZCState),
    .instance_init = bl808_tzc_init,
    .class_init    = bl808_tzc_class_init,
};

static void bl808_tzc_register_types(void)
{
    type_register_static(&bl808_tzc_info);
}

type_init(bl808_tzc_register_types)
