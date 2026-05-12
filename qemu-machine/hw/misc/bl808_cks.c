/*
 * Bouffalo Lab BL808 checksum engine emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "hw/misc/bl808_cks.h"

#define CKS_CONFIG   0x00
#define CKS_DATA_IN  0x04
#define CKS_OUT      0x08

#define CKS_CR_CKS_CLR       BIT(0)
#define CKS_CR_CKS_BYTE_SWAP BIT(1)

static uint16_t bl808_cks_add_word(uint16_t acc, uint16_t word)
{
    uint32_t sum = acc + word;

    sum = (sum & 0xffffu) + (sum >> 16);
    sum = (sum & 0xffffu) + (sum >> 16);
    return (uint16_t)sum;
}

static uint16_t bl808_cks_current_output(const BL808CKSState *s)
{
    uint16_t acc = s->checksum;

    if (s->pending_valid) {
        uint16_t word;

        if (s->config & CKS_CR_CKS_BYTE_SWAP) {
            word = (uint16_t)s->pending_byte << 8;
        } else {
            word = s->pending_byte;
        }
        acc = bl808_cks_add_word(acc, word);
    }

    return acc;
}

static void bl808_cks_reset_state(BL808CKSState *s)
{
    s->config = 0;
    s->checksum = 0xffffu;
    s->pending_byte = 0;
    s->pending_valid = false;
}

void bl808_cks_set_clock_enabled(BL808CKSState *s, bool enabled)
{
    s->clock_enabled = enabled;
}

void bl808_cks_set_reset_asserted(BL808CKSState *s, bool asserted)
{
    s->reset_asserted = asserted;
    if (asserted) {
        device_cold_reset(DEVICE(s));
    }
}

static uint64_t bl808_cks_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808CKSState *s = opaque;

    switch (offset) {
    case CKS_CONFIG:
        return s->config;
    case CKS_DATA_IN:
        return 0;
    case CKS_OUT:
        return bl808_cks_current_output(s);
    default:
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_cks: bad read offset 0x%" HWADDR_PRIx "\n",
                      offset);
        return 0;
    }
}

static void bl808_cks_write(void *opaque, hwaddr offset, uint64_t value,
                            unsigned size)
{
    BL808CKSState *s = opaque;
    uint32_t val = (uint32_t)value;

    switch (offset) {
    case CKS_CONFIG:
        s->config = val & CKS_CR_CKS_BYTE_SWAP;
        if (val & CKS_CR_CKS_CLR) {
            s->checksum = 0xffffu;
            s->pending_valid = false;
            s->pending_byte = 0;
        }
        break;
    case CKS_DATA_IN: {
        uint8_t byte = val & 0xffu;

        if (!s->pending_valid) {
            s->pending_byte = byte;
            s->pending_valid = true;
            return;
        }

        if (s->config & CKS_CR_CKS_BYTE_SWAP) {
            s->checksum = bl808_cks_add_word(
                s->checksum,
                ((uint16_t)s->pending_byte << 8) | byte);
        } else {
            s->checksum = bl808_cks_add_word(
                s->checksum,
                ((uint16_t)byte << 8) | s->pending_byte);
        }
        s->pending_valid = false;
        s->pending_byte = 0;
        break;
    }
    case CKS_OUT:
        break;
    default:
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_cks: bad write offset 0x%" HWADDR_PRIx
                      " = 0x%" PRIx64 "\n", offset, value);
        break;
    }
}

static const MemoryRegionOps bl808_cks_ops = {
    .read = bl808_cks_read,
    .write = bl808_cks_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static void bl808_cks_reset(DeviceState *dev)
{
    bl808_cks_reset_state(BL808_CKS(dev));
}

static void bl808_cks_init(Object *obj)
{
    BL808CKSState *s = BL808_CKS(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    memory_region_init_io(&s->iomem, obj, &bl808_cks_ops, s,
                          TYPE_BL808_CKS, BL808_CKS_REG_SIZE);
    sysbus_init_mmio(sbd, &s->iomem);
    s->clock_enabled = true;
}

static void bl808_cks_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    device_class_set_legacy_reset(dc, bl808_cks_reset);
}

static const TypeInfo bl808_cks_info = {
    .name          = TYPE_BL808_CKS,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(BL808CKSState),
    .instance_init = bl808_cks_init,
    .class_init    = bl808_cks_class_init,
};

static void bl808_cks_register_types(void)
{
    type_register_static(&bl808_cks_info);
}

type_init(bl808_cks_register_types)
