/*
 * BL808 IPC (Inter-Processor Communication) mailbox device
 *
 * Models the BL808 IPC mailbox register block.  Hardware exposes two banks.
 * Guest code normally writes CPU1_ISWR to signal this mailbox and reads,
 * unmasks, and clears the pending bit through the CPU0 receive bank.
 * The legacy single-bank offsets remain as aliases for older tests.
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "hw/misc/bl808_ipc.h"
#include "hw/irq.h"

#define IPC_CPU1_ISWR   0x00
#define IPC_CPU1_IRSRR  0x04
#define IPC_CPU1_ICR    0x08
#define IPC_CPU1_IUSR   0x0C
#define IPC_CPU1_IUCR   0x10
#define IPC_CPU1_ISTS   0x14  /* legacy masked-status alias */
#define IPC_CPU1_ILSHR  0x18
#define IPC_CPU1_ISR    0x1C

#define IPC_CPU0_ISWR   0x20
#define IPC_CPU0_IRSRR  0x24
#define IPC_CPU0_ICR    0x28
#define IPC_CPU0_IUSR   0x2C
#define IPC_CPU0_IUCR   0x30
#define IPC_CPU0_ILSLR  0x34
#define IPC_CPU0_ILSHR  0x38
#define IPC_CPU0_ISR    0x3C
#define IPC_SIZE        0x40

static bool bl808_ipc_active(const BL808IPCState *s)
{
    return s->clock_enabled && !s->reset_asserted;
}

static void bl808_ipc_update_irq(BL808IPCState *s)
{
    bool asserted = (s->pending & s->enabled) != 0;

    qemu_set_irq(s->irq, bl808_ipc_active(s) && asserted);
}

static uint64_t bl808_ipc_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808IPCState *s = BL808_IPC(opaque);

    if (size != 4 || offset >= IPC_SIZE) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_ipc: invalid read at offset 0x%" HWADDR_PRIx
                      " size %u\n", offset, size);
        return 0;
    }

    switch (offset) {
    case IPC_CPU1_ISWR:
    case IPC_CPU0_ISWR:
        return 0;
    case IPC_CPU1_IRSRR:
    case IPC_CPU0_IRSRR:
        return s->pending;
    case IPC_CPU1_ICR:
    case IPC_CPU0_ICR:
        return 0;
    case IPC_CPU1_IUSR:
    case IPC_CPU0_IUSR:
        return s->enabled;
    case IPC_CPU1_IUCR:
    case IPC_CPU0_IUCR:
        return ~s->enabled;
    case IPC_CPU1_ISTS:
    case IPC_CPU1_ISR:
    case IPC_CPU0_ISR:
        return s->pending & s->enabled;
    case IPC_CPU1_ILSHR:
    case IPC_CPU0_ILSLR:
    case IPC_CPU0_ILSHR:
        return 0xFFFFFFFFU;
    default:
        return 0;
    }
}

static void bl808_ipc_write(void *opaque, hwaddr offset, uint64_t value,
                             unsigned size)
{
    BL808IPCState *s = BL808_IPC(opaque);
    uint32_t masked = (uint32_t)value;

    if (size != 4 || offset >= IPC_SIZE) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_ipc: invalid write at offset 0x%" HWADDR_PRIx
                      " value 0x%" PRIx64 " size %u\n",
                      offset, value, size);
        return;
    }
    if (s->reset_asserted) {
        return;
    }

    switch (offset) {
    case IPC_CPU1_ISWR:
    case IPC_CPU0_ISWR:
        s->pending |= masked;
        bl808_ipc_update_irq(s);
        break;
    case IPC_CPU1_IRSRR:
    case IPC_CPU0_IRSRR:
        break;
    case IPC_CPU1_ICR:
    case IPC_CPU0_ICR:
        s->pending &= ~masked;
        bl808_ipc_update_irq(s);
        break;
    case IPC_CPU1_IUSR:
    case IPC_CPU0_IUSR:
        s->enabled |= masked;
        bl808_ipc_update_irq(s);
        break;
    case IPC_CPU1_IUCR:
    case IPC_CPU0_IUCR:
        s->enabled &= ~masked;
        bl808_ipc_update_irq(s);
        break;
    case IPC_CPU1_ISTS:
    case IPC_CPU1_ILSHR:
    case IPC_CPU1_ISR:
    case IPC_CPU0_ILSLR:
    case IPC_CPU0_ILSHR:
    case IPC_CPU0_ISR:
        break;
    default:
        break;
    }
}

static const MemoryRegionOps bl808_ipc_ops = {
    .read = bl808_ipc_read,
    .write = bl808_ipc_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static void bl808_ipc_init(Object *obj)
{
    BL808IPCState *s = BL808_IPC(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    memory_region_init_io(&s->iomem, obj, &bl808_ipc_ops, s,
                          TYPE_BL808_IPC, IPC_SIZE);
    sysbus_init_mmio(sbd, &s->iomem);
    sysbus_init_irq(sbd, &s->irq);
    s->clock_enabled = false;
    s->reset_asserted = false;
}

static void bl808_ipc_reset(DeviceState *dev)
{
    BL808IPCState *s = BL808_IPC(dev);

    s->pending = 0;
    s->enabled = 0;
    bl808_ipc_update_irq(s);
}

void bl808_ipc_set_clock_enabled(BL808IPCState *s, bool enabled)
{
    s->clock_enabled = enabled;
    bl808_ipc_update_irq(s);
}

void bl808_ipc_set_reset_asserted(BL808IPCState *s, bool asserted)
{
    s->reset_asserted = asserted;
    if (asserted) {
        device_cold_reset(DEVICE(s));
    } else {
        bl808_ipc_update_irq(s);
    }
}

static void bl808_ipc_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    device_class_set_legacy_reset(dc, bl808_ipc_reset);
}

static const TypeInfo bl808_ipc_info = {
    .name          = TYPE_BL808_IPC,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(BL808IPCState),
    .instance_init = bl808_ipc_init,
    .class_init    = bl808_ipc_class_init,
};

static void bl808_ipc_register_types(void)
{
    type_register_static(&bl808_ipc_info);
}

type_init(bl808_ipc_register_types)
