/*
 * Bouffalo Lab BL808 PSRAM controller emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "hw/misc/bl808_psram_ctrl.h"

#define PSRAM_CTRL_CFG0       0x00
#define PSRAM_CTRL_CFG1       0x04
#define PSRAM_CTRL_CFG2       0x08
#define PSRAM_CTRL_CFG3       0x0C
#define PSRAM_CTRL_CFG4       0x10
#define PSRAM_CTRL_STATUS     0x14
#define PSRAM_CTRL_INT_STS    0x18
#define PSRAM_CTRL_INT_MASK   0x1C
#define PSRAM_CTRL_INT_CLR    0x20

#define PSRAM_UHS_BASIC       0x00
#define PSRAM_UHS_CMD         0x04
#define PSRAM_UHS_FIFO_THRE   0x08
#define PSRAM_UHS_MANUAL      0x0C
#define PSRAM_UHS_PSRAM_CFG   0x20

#define PSRAM_CFG_ENABLE      BIT(0)
#define PSRAM_CFG_W_PULSE     BIT(12)
#define PSRAM_CFG_R_PULSE     BIT(13)
#define PSRAM_CFG_W_DONE      BIT(14)
#define PSRAM_CFG_R_DONE      BIT(15)
#define PSRAM_CFG_REQ         BIT(16)
#define PSRAM_CFG_GRANT       BIT(17)

#define PSRAM_STATUS_READY    BIT(0)
#define PSRAM_STATUS_ACTIVE   BIT(1)
#define PSRAM_INT_CFG_DONE    BIT(0)

#define PSRAM_UHS_BASIC_CONFIG_REQ  BIT(2)
#define PSRAM_UHS_BASIC_CONFIG_GNT  BIT(3)
#define PSRAM_UHS_BASIC_MODE_REG_SHIFT 8

#define PSRAM_UHS_CMD_GLBR_PULSE    BIT(0)
#define PSRAM_UHS_CMD_SRFI_PULSE    BIT(1)
#define PSRAM_UHS_CMD_SRFO_PULSE    BIT(2)
#define PSRAM_UHS_CMD_REGW_PULSE    BIT(3)
#define PSRAM_UHS_CMD_REGR_PULSE    BIT(4)
#define PSRAM_UHS_STS_GLBR_DONE     BIT(8)
#define PSRAM_UHS_STS_SRFI_DONE     BIT(9)
#define PSRAM_UHS_STS_SRFO_DONE     BIT(10)
#define PSRAM_UHS_STS_REGW_DONE     BIT(11)
#define PSRAM_UHS_STS_REGR_DONE     BIT(12)
#define PSRAM_UHS_STS_INIT_DONE     BIT(13)
#define PSRAM_UHS_STS_CONFIG_READ_SHIFT 24

#define PSRAM_UHS_CFG_LATENCY_MASK  0x7u
#define PSRAM_UHS_CFG_DRIVE_SHIFT   4
#define PSRAM_UHS_CFG_DRIVE_MASK    0xfu
#define PSRAM_UHS_CFG_BL16_BIT      8
#define PSRAM_UHS_CFG_BL32_BIT      9
#define PSRAM_UHS_CFG_BL64_BIT      10

static uint32_t bl808_psram_uhs_reg(const BL808PSRAMCtrlState *s, hwaddr offset)
{
    return s->uhs_regs[offset / 4];
}

static void bl808_psram_uhs_set_reg(BL808PSRAMCtrlState *s, hwaddr offset,
                                    uint32_t value)
{
    s->uhs_regs[offset / 4] = value;
}

static uint8_t bl808_psram_uhs_mode_reg_readback(const BL808PSRAMCtrlState *s)
{
    uint32_t basic = bl808_psram_uhs_reg(s, PSRAM_UHS_BASIC);
    uint32_t cfg = bl808_psram_uhs_reg(s, PSRAM_UHS_PSRAM_CFG);
    uint32_t mode = (basic >> PSRAM_UHS_BASIC_MODE_REG_SHIFT) & 0xffu;

    switch (mode) {
    case 0:
        return ((cfg >> PSRAM_UHS_CFG_DRIVE_SHIFT) & PSRAM_UHS_CFG_DRIVE_MASK)
               << 3 | (cfg & PSRAM_UHS_CFG_LATENCY_MASK);
    case 1:
        return 0;
    case 2:
        return (((cfg >> PSRAM_UHS_CFG_BL16_BIT) & 0x1u) << 3) |
               (((cfg >> PSRAM_UHS_CFG_BL32_BIT) & 0x1u) << 4) |
               (((cfg >> PSRAM_UHS_CFG_BL64_BIT) & 0x1u) << 5);
    case 4:
        return 0;
    default:
        return 0;
    }
}

static uint32_t bl808_psram_ctrl_cfg0_value(const BL808PSRAMCtrlState *s)
{
    uint32_t value = s->cfg0;

    if (value & PSRAM_CFG_REQ) {
        value |= PSRAM_CFG_GRANT;
    }
    return value;
}

static void bl808_psram_ctrl_refresh_status(BL808PSRAMCtrlState *s)
{
    if (bl808_psram_ctrl_memory_enabled(s)) {
        s->status = PSRAM_STATUS_READY | PSRAM_STATUS_ACTIVE;
    } else {
        s->status = 0;
    }
}

static void bl808_psram_ctrl_reset_state(BL808PSRAMCtrlState *s)
{
    s->cfg0 = 0;
    s->cfg1 = 0;
    s->cfg2 = 0;
    s->cfg3 = 0;
    s->cfg4 = 0;
    s->status = 0;
    s->int_sts = 0;
    s->int_mask = 0;
    memset(s->uhs_regs, 0, sizeof(s->uhs_regs));
    bl808_psram_ctrl_refresh_status(s);
}

bool bl808_psram_ctrl_memory_enabled(const BL808PSRAMCtrlState *s)
{
    return s->clock_enabled && !s->reset_asserted &&
           (s->cfg0 & PSRAM_CFG_ENABLE);
}

void bl808_psram_ctrl_set_clock_enabled(BL808PSRAMCtrlState *s, bool enabled)
{
    s->clock_enabled = enabled;
    bl808_psram_ctrl_refresh_status(s);
}

void bl808_psram_ctrl_set_reset_asserted(BL808PSRAMCtrlState *s,
                                         bool asserted)
{
    s->reset_asserted = asserted;
    if (asserted) {
        device_cold_reset(DEVICE(s));
    } else {
        bl808_psram_ctrl_refresh_status(s);
    }
}

static uint64_t bl808_psram_ctrl_read(void *opaque, hwaddr offset,
                                      unsigned size)
{
    BL808PSRAMCtrlState *s = opaque;

    switch (offset) {
    case PSRAM_CTRL_CFG0:
        return bl808_psram_ctrl_cfg0_value(s);
    case PSRAM_CTRL_CFG1:
        return s->cfg1;
    case PSRAM_CTRL_CFG2:
        return s->cfg2;
    case PSRAM_CTRL_CFG3:
        return s->cfg3;
    case PSRAM_CTRL_CFG4:
        return s->cfg4;
    case PSRAM_CTRL_STATUS:
        return s->status;
    case PSRAM_CTRL_INT_STS:
        return s->int_sts;
    case PSRAM_CTRL_INT_MASK:
        return s->int_mask;
    case PSRAM_CTRL_INT_CLR:
        return 0;
    default:
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_psram_ctrl: bad read offset 0x%" HWADDR_PRIx
                      "\n", offset);
        return 0;
    }
}

static void bl808_psram_ctrl_write(void *opaque, hwaddr offset, uint64_t value,
                                   unsigned size)
{
    BL808PSRAMCtrlState *s = opaque;
    uint32_t val = (uint32_t)value;

    switch (offset) {
    case PSRAM_CTRL_CFG0:
        s->cfg0 = val & ~(PSRAM_CFG_GRANT | PSRAM_CFG_W_DONE |
                          PSRAM_CFG_R_DONE | PSRAM_CFG_W_PULSE |
                          PSRAM_CFG_R_PULSE);
        if (val & (PSRAM_CFG_W_PULSE | PSRAM_CFG_R_PULSE)) {
            s->int_sts |= PSRAM_INT_CFG_DONE;
        }
        if (val & PSRAM_CFG_W_PULSE) {
            s->cfg0 |= PSRAM_CFG_W_DONE;
        }
        if (val & PSRAM_CFG_R_PULSE) {
            s->cfg0 |= PSRAM_CFG_R_DONE;
        }
        bl808_psram_ctrl_refresh_status(s);
        break;
    case PSRAM_CTRL_CFG1:
        s->cfg1 = val;
        break;
    case PSRAM_CTRL_CFG2:
        s->cfg2 = val;
        break;
    case PSRAM_CTRL_CFG3:
        s->cfg3 = val;
        break;
    case PSRAM_CTRL_CFG4:
        s->cfg4 = val;
        break;
    case PSRAM_CTRL_STATUS:
        /* Read-only summary register. */
        break;
    case PSRAM_CTRL_INT_STS:
    case PSRAM_CTRL_INT_CLR:
        s->int_sts &= ~val;
        break;
    case PSRAM_CTRL_INT_MASK:
        s->int_mask = val;
        break;
    default:
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_psram_ctrl: bad write offset 0x%" HWADDR_PRIx
                      " = 0x%" PRIx64 "\n", offset, value);
        break;
    }
}

static uint64_t bl808_psram_uhs_read(void *opaque, hwaddr offset,
                                     unsigned size)
{
    BL808PSRAMCtrlState *s = opaque;
    uint32_t value;

    if (offset >= BL808_PSRAM_UHS_REG_SIZE || (offset & 0x3)) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_psram_uhs: bad read offset 0x%" HWADDR_PRIx
                      "\n", offset);
        return 0;
    }

    value = bl808_psram_uhs_reg(s, offset);
    if (offset == PSRAM_UHS_BASIC) {
        if (value & PSRAM_UHS_BASIC_CONFIG_REQ) {
            value |= PSRAM_UHS_BASIC_CONFIG_GNT;
        } else {
            value &= ~PSRAM_UHS_BASIC_CONFIG_GNT;
        }
    }
    return value;
}

static void bl808_psram_uhs_write(void *opaque, hwaddr offset, uint64_t value,
                                  unsigned size)
{
    BL808PSRAMCtrlState *s = opaque;
    uint32_t val = (uint32_t)value;
    uint32_t cmd;

    if (offset >= BL808_PSRAM_UHS_REG_SIZE || (offset & 0x3)) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_psram_uhs: bad write offset 0x%" HWADDR_PRIx
                      " = 0x%" PRIx64 "\n", offset, value);
        return;
    }

    switch (offset) {
    case PSRAM_UHS_BASIC:
        if (val & PSRAM_UHS_BASIC_CONFIG_REQ) {
            val |= PSRAM_UHS_BASIC_CONFIG_GNT;
        } else {
            val &= ~PSRAM_UHS_BASIC_CONFIG_GNT;
        }
        bl808_psram_uhs_set_reg(s, offset, val);
        if (val & BIT(0)) {
            cmd = bl808_psram_uhs_reg(s, PSRAM_UHS_CMD) |
                  PSRAM_UHS_STS_INIT_DONE;
            bl808_psram_uhs_set_reg(s, PSRAM_UHS_CMD, cmd);
        }
        bl808_psram_ctrl_refresh_status(s);
        break;
    case PSRAM_UHS_CMD:
        cmd = val;
        if (val & PSRAM_UHS_CMD_GLBR_PULSE) {
            cmd |= PSRAM_UHS_STS_GLBR_DONE;
        }
        if (val & PSRAM_UHS_CMD_SRFI_PULSE) {
            cmd |= PSRAM_UHS_STS_SRFI_DONE;
        }
        if (val & PSRAM_UHS_CMD_SRFO_PULSE) {
            cmd |= PSRAM_UHS_STS_SRFO_DONE;
        }
        if (val & PSRAM_UHS_CMD_REGW_PULSE) {
            cmd |= PSRAM_UHS_STS_REGW_DONE;
        }
        if (val & PSRAM_UHS_CMD_REGR_PULSE) {
            cmd |= PSRAM_UHS_STS_REGR_DONE;
            cmd &= ~(0xffu << PSRAM_UHS_STS_CONFIG_READ_SHIFT);
            cmd |= (uint32_t)bl808_psram_uhs_mode_reg_readback(s)
                   << PSRAM_UHS_STS_CONFIG_READ_SHIFT;
        }
        bl808_psram_uhs_set_reg(s, offset, cmd);
        break;
    case PSRAM_UHS_FIFO_THRE:
    case PSRAM_UHS_MANUAL:
    case PSRAM_UHS_PSRAM_CFG:
        bl808_psram_uhs_set_reg(s, offset, val);
        break;
    default:
        bl808_psram_uhs_set_reg(s, offset, val);
        break;
    }
}

static const MemoryRegionOps bl808_psram_ctrl_ops = {
    .read = bl808_psram_ctrl_read,
    .write = bl808_psram_ctrl_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static const MemoryRegionOps bl808_psram_uhs_ops = {
    .read = bl808_psram_uhs_read,
    .write = bl808_psram_uhs_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static void bl808_psram_ctrl_reset(DeviceState *dev)
{
    bl808_psram_ctrl_reset_state(BL808_PSRAM_CTRL(dev));
}

static void bl808_psram_ctrl_init(Object *obj)
{
    BL808PSRAMCtrlState *s = BL808_PSRAM_CTRL(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    memory_region_init_io(&s->ctrl_iomem, obj, &bl808_psram_ctrl_ops, s,
                          TYPE_BL808_PSRAM_CTRL "-ctrl",
                          BL808_PSRAM_CTRL_REG_SIZE);
    memory_region_init_io(&s->uhs_iomem, obj, &bl808_psram_uhs_ops, s,
                          TYPE_BL808_PSRAM_CTRL "-uhs",
                          BL808_PSRAM_UHS_REG_SIZE);
    sysbus_init_mmio(sbd, &s->ctrl_iomem);
    sysbus_init_mmio(sbd, &s->uhs_iomem);
    s->clock_enabled = true;
}

static void bl808_psram_ctrl_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    device_class_set_legacy_reset(dc, bl808_psram_ctrl_reset);
}

static const TypeInfo bl808_psram_ctrl_info = {
    .name          = TYPE_BL808_PSRAM_CTRL,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(BL808PSRAMCtrlState),
    .instance_init = bl808_psram_ctrl_init,
    .class_init    = bl808_psram_ctrl_class_init,
};

static void bl808_psram_ctrl_register_types(void)
{
    type_register_static(&bl808_psram_ctrl_info);
}

type_init(bl808_psram_ctrl_register_types)
