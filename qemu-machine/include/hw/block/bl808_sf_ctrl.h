/*
 * Bouffalo Lab BL808 SF (Serial Flash) controller emulation
 *
 * Custom SPI NOR flash controller at 0x2000B000. Firmware sends
 * commands via a register-based protocol backed by a 64MiB flash aperture.
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_BLOCK_BL808_SF_CTRL_H
#define HW_BLOCK_BL808_SF_CTRL_H

#include "hw/sysbus.h"
#include "qom/object.h"
#include "qemu/typedefs.h"

#define TYPE_BL808_SF_CTRL "bl808-sf-ctrl"

typedef struct BL808SfCtrlState BL808SfCtrlState;
OBJECT_DECLARE_SIMPLE_TYPE(BL808SfCtrlState, BL808_SF_CTRL)

/* Register block size */
#define BL808_SF_CTRL_REG_SIZE  0x1000

/* BL808 exposes a 64 MiB XIP aperture even when the attached flash is smaller */
#define BL808_SF_CTRL_FLASH_APERTURE_SIZE (64 * 1024 * 1024)

/* Pine64 Ox64 128 Mbit Winbond W25Q128JW NOR flash */
#define BL808_SF_CTRL_FLASH_SIZE (16 * 1024 * 1024)

/* W25Q128JW has 3 x 256-byte OTP security registers */
#define BL808_SF_CTRL_SEC_REG_COUNT 3
#define BL808_SF_CTRL_SEC_REG_SIZE  256

/* Command buffer at offset 0x600, 512 bytes */
#define BL808_SF_CTRL_BUF_OFF   0x600
#define BL808_SF_CTRL_BUF_SIZE  512

#define BL808_SF_CTRL_GROUP_COUNT 2
#define BL808_SF_CTRL_BANK_COUNT  2

struct BL808SfCtrlState {
    /*< private >*/
    SysBusDevice parent_obj;

    /*< public >*/
    MemoryRegion iomem;

    /* Optional block backend for persistent storage */
    BlockBackend *blk;

    /* Control registers */
    uint32_t sf_ctrl_0;         /* +0x000 */
    uint32_t sf_ctrl_1;         /* +0x004 */
    uint32_t sf_ctrl_if_sahb0;  /* +0x008 */
    uint32_t sf_ctrl_if_sahb1;  /* +0x00C */
    uint32_t sf_ctrl_if_sahb2;  /* +0x010 */

    /* Generic register storage for other offsets */
    uint32_t regs[BL808_SF_CTRL_BUF_OFF / 4];

    /* Command/data buffer (512 bytes at offset 0x600) */
    uint32_t buf[BL808_SF_CTRL_BUF_SIZE / 4];

    /* Flash backing storage (64 MB aperture) */
    uint8_t *flash;
    uint8_t sec_reg[BL808_SF_CTRL_SEC_REG_COUNT][BL808_SF_CTRL_SEC_REG_SIZE];

    /*
     * Optional pointers to XIP RAM regions, indexed by [group][bank].
     * BL808DK uses group 0 bank 0 for M0/LP and group 1 bank 0 for D0.
     */
    uint8_t *xip_ptr[BL808_SF_CTRL_GROUP_COUNT][BL808_SF_CTRL_BANK_COUNT];
    uint32_t xip_offset[BL808_SF_CTRL_GROUP_COUNT][BL808_SF_CTRL_BANK_COUNT];
    uint32_t reset_xip_offset[BL808_SF_CTRL_GROUP_COUNT][BL808_SF_CTRL_BANK_COUNT];

    /* SPI NOR status registers */
    uint8_t sr1;    /* Status register 1: bit 1 = WEL */
    uint8_t sr2;    /* Status register 2 */
    uint8_t sr3;    /* Status register 3 */
    uint8_t sr1_nv; /* Non-volatile status register 1 image */
    uint8_t sr2_nv; /* Non-volatile status register 2 image */
    uint8_t sr3_nv; /* Non-volatile status register 3 image */
    uint8_t volatile_wel;
    uint8_t powered_down;
    uint8_t qpi_mode;
    uint8_t reset_armed;
    uint8_t burst_wrap_data;
};

void bl808_sf_ctrl_set_flash_image_offset(BL808SfCtrlState *s, uint8_t group,
                                          uint8_t bank, uint32_t addr_offset);
uint32_t bl808_sf_ctrl_get_flash_image_offset(const BL808SfCtrlState *s,
                                              uint8_t group, uint8_t bank);
void bl808_sf_ctrl_write_flash(BL808SfCtrlState *s, uint32_t offset,
                               const void *data, uint32_t size);
void bl808_sf_ctrl_sync_all_xip(BL808SfCtrlState *s);

#endif /* HW_BLOCK_BL808_SF_CTRL_H */
