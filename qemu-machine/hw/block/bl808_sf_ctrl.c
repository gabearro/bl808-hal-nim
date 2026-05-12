/*
 * Bouffalo Lab BL808 SF (Serial Flash) controller emulation
 *
 * Emulates the custom SPI NOR flash controller at 0x2000B000.
 * Backed by a 64MiB flash aperture, optionally loaded from a block drive
 * image and mirrored into the BL808 XIP windows.
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qapi/error.h"
#include "hw/sysbus.h"
#include "hw/qdev-properties.h"
#include "hw/qdev-properties-system.h"
#include "hw/block/bl808_sf_ctrl.h"
#include "system/block-backend.h"

/* ========================================================================= */
/* Register offsets                                                           */
/* ========================================================================= */

#define REG_SF_CTRL_0           0x000
#define REG_SF_CTRL_1           0x004
#define REG_SF_CTRL_IF_SAHB0    0x008
#define REG_SF_CTRL_IF_SAHB1    0x00C
#define REG_SF_CTRL_IF_SAHB2    0x010
#define REG_SF_CTRL_SF_ID0_OFFSET 0x0A0
#define REG_SF_CTRL_SF_ID1_OFFSET 0x0A4
#define REG_SF_CTRL_SF_BK2_ID0_OFFSET 0x0A8
#define REG_SF_CTRL_SF_BK2_ID1_OFFSET 0x0AC
#define REG_SF_CTRL_SF_ID0      0x14C
#define REG_SF_CTRL_SF_ID1      0x150

#define SF_CTRL_0_32B_ADDR_EN   (1u << 19)

/* Interface 0 command bits */
#define SAHB0_BUSY              (1u << 0)
#define SAHB0_TRIGGER           (1u << 1)
#define SAHB0_DATA_BYTES_SHIFT  2
#define SAHB0_DATA_BYTES_MASK   (0x3ffu << SAHB0_DATA_BYTES_SHIFT)
#define SAHB0_DUMMY_BYTES_SHIFT 12
#define SAHB0_DUMMY_BYTES_MASK  (0x1fu << SAHB0_DUMMY_BYTES_SHIFT)
#define SAHB0_ADDR_BYTES_SHIFT  17
#define SAHB0_ADDR_BYTES_MASK   (0x7u << SAHB0_ADDR_BYTES_SHIFT)
#define SAHB0_CMD_BYTES_SHIFT   20
#define SAHB0_CMD_BYTES_MASK    (0x7u << SAHB0_CMD_BYTES_SHIFT)
#define SAHB0_DATA_RW           (1u << 23)
#define SAHB0_DATA_EN           (1u << 24)
#define SAHB0_DUMMY_EN          (1u << 25)
#define SAHB0_ADDR_EN           (1u << 26)
#define SAHB0_CMD_EN            (1u << 27)

/* Flash commands (SPI NOR standard) */
#define FLASH_CMD_WRITE_SR      0x01
#define FLASH_CMD_WRITE_SR3     0x11
#define FLASH_CMD_PAGE_PROG     0x02
#define FLASH_CMD_READ          0x03
#define FLASH_CMD_WRDIS         0x04
#define FLASH_CMD_READ_SR1      0x05
#define FLASH_CMD_WREN          0x06
#define FLASH_CMD_FAST_READ     0x0B
#define FLASH_CMD_READ_SR3      0x15
#define FLASH_CMD_SECTOR_ERASE  0x20
#define FLASH_CMD_QPAGE_PROG    0x32
#define FLASH_CMD_WRITE_SR2     0x31
#define FLASH_CMD_READ_SR2      0x35
#define FLASH_CMD_QPP_OR_QPI    0x38
#define FLASH_CMD_DUAL_READ     0x3B
#define FLASH_CMD_SEC_REG_PROG  0x42
#define FLASH_CMD_SEC_REG_ERASE 0x44
#define FLASH_CMD_SEC_REG_READ  0x48
#define FLASH_CMD_READ_UID      0x4B
#define FLASH_CMD_WREN_VOLATILE 0x50
#define FLASH_CMD_READ_SFDP     0x5A
#define FLASH_CMD_BLOCK_ERASE32 0x52
#define FLASH_CMD_CHIP_ERASE_ALT 0x60
#define FLASH_CMD_QUAD_READ     0x6B
#define FLASH_CMD_ERASE_SUSPEND 0x75
#define FLASH_CMD_BURST_WRAP    0x77
#define FLASH_CMD_ERASE_RESUME  0x7A
#define FLASH_CMD_READ_MFG_DEVICE_ID 0x90
#define FLASH_CMD_READ_MFG_DEVICE_ID_DUAL 0x92
#define FLASH_CMD_READ_MFG_DEVICE_ID_QUAD 0x94
#define FLASH_CMD_CHIP_ERASE    0xC7
#define FLASH_CMD_READ_ID       0x9F
#define FLASH_CMD_REL_PD        0xAB
#define FLASH_CMD_DIO_READ      0xBB
#define FLASH_CMD_POWER_DN      0xB9
#define FLASH_CMD_BURST_WRAP_ALT 0xC0
#define FLASH_CMD_EN4B          0xB7
#define FLASH_CMD_BLOCK_ERASE64 0xD8
#define FLASH_CMD_QIO_READ      0xEB
#define FLASH_CMD_EX4B          0xE9
#define FLASH_CMD_EN_RESET      0x66
#define FLASH_CMD_RESET         0x99
#define FLASH_CMD_EXIT_QPI      0xFF

/*
 * Ox64 128 Mbit board variant uses a Winbond W25Q128JWSQ, which maps to the
 * W25Q128JW-IQ device family: 16 MiB, device ID 0x17, JEDEC ID EFh 6018h,
 * and QE fixed high in status register 2.
 */
#define W25Q128JW_MFR           0xEF
#define W25Q128JW_MEM           0x60
#define W25Q128JW_CAP           0x18
#define W25Q128JW_DEVICE_ID     0x17

/* Deterministic UID for firmware tests */
#define W25Q128JW_UID_LO        0x44332211U
#define W25Q128JW_UID_HI        0x88776655U

/* Status register bits */
#define SR1_BUSY                (1u << 0)
#define SR1_WEL                 (1u << 1)
#define SR1_BP0                 (1u << 2)
#define SR1_BP1                 (1u << 3)
#define SR1_BP2                 (1u << 4)
#define SR1_TB                  (1u << 5)
#define SR1_SEC                 (1u << 6)
#define SR1_SRP0                (1u << 7)

#define SR2_SRL                 (1u << 0)
#define SR2_QE                  (1u << 1)
#define SR2_LB1                 (1u << 3)
#define SR2_LB2                 (1u << 4)
#define SR2_LB3                 (1u << 5)
#define SR2_CMP                 (1u << 6)
#define SR2_SUS                 (1u << 7)

#define SR3_WPS                 (1u << 2)
#define SR3_DRV0                (1u << 5)
#define SR3_DRV1                (1u << 6)

#define SR1_WRITABLE_MASK       (SR1_BP0 | SR1_BP1 | SR1_BP2 | SR1_TB | \
                                 SR1_SEC | SR1_SRP0)
#define SR2_LB_MASK             (SR2_LB1 | SR2_LB2 | SR2_LB3)
#define SR2_WRITABLE_MASK       (SR2_SRL | SR2_QE | SR2_LB_MASK | SR2_CMP)
#define SR3_WRITABLE_MASK       (SR3_WPS | SR3_DRV0 | SR3_DRV1)

/* Flash geometry */
#define FLASH_SECTOR_SIZE       (4 * 1024)
#define FLASH_BLOCK32_SIZE      (32 * 1024)
#define FLASH_BLOCK64_SIZE      (64 * 1024)
#define FLASH_PAGE_SIZE         256

/* ========================================================================= */
/* Helpers                                                                    */
/* ========================================================================= */

static bool sf_ctrl_valid_group_bank(uint8_t group, uint8_t bank)
{
    return group < BL808_SF_CTRL_GROUP_COUNT && bank < BL808_SF_CTRL_BANK_COUNT;
}

static hwaddr sf_ctrl_image_offset_reg(uint8_t group, uint8_t bank)
{
    static const hwaddr regs[BL808_SF_CTRL_GROUP_COUNT][BL808_SF_CTRL_BANK_COUNT] = {
        { REG_SF_CTRL_SF_ID0_OFFSET, REG_SF_CTRL_SF_BK2_ID0_OFFSET },
        { REG_SF_CTRL_SF_ID1_OFFSET, REG_SF_CTRL_SF_BK2_ID1_OFFSET },
    };

    assert(sf_ctrl_valid_group_bank(group, bank));
    return regs[group][bank];
}

static void sf_ctrl_sync_xip(BL808SfCtrlState *s, uint32_t offset, uint32_t size);
static void sf_ctrl_blk_write(BL808SfCtrlState *s, uint32_t offset,
                              uint32_t size);

uint32_t bl808_sf_ctrl_get_flash_image_offset(const BL808SfCtrlState *s,
                                              uint8_t group, uint8_t bank)
{
    if (!sf_ctrl_valid_group_bank(group, bank)) {
        return 0;
    }

    return s->xip_offset[group][bank];
}

static void sf_ctrl_refresh_xip_view(BL808SfCtrlState *s, uint8_t group,
                                     uint8_t bank)
{
    uint8_t *xip;
    uint32_t offset;
    uint32_t available;

    if (!sf_ctrl_valid_group_bank(group, bank)) {
        return;
    }

    xip = s->xip_ptr[group][bank];
    if (!xip) {
        return;
    }

    offset = s->xip_offset[group][bank];
    memset(xip, 0xFF, BL808_SF_CTRL_FLASH_APERTURE_SIZE);
    if (offset >= BL808_SF_CTRL_FLASH_SIZE) {
        return;
    }

    available = BL808_SF_CTRL_FLASH_SIZE - offset;
    memcpy(xip, s->flash + offset,
           MIN(available, BL808_SF_CTRL_FLASH_APERTURE_SIZE));
}

static void sf_ctrl_sync_xip_range(BL808SfCtrlState *s, uint8_t group,
                                   uint8_t bank, uint32_t offset,
                                   uint32_t size)
{
    uint8_t *xip;
    uint32_t image_offset;
    uint32_t start;
    uint32_t end;

    if (!sf_ctrl_valid_group_bank(group, bank)) {
        return;
    }

    xip = s->xip_ptr[group][bank];
    if (!xip || size == 0) {
        return;
    }

    image_offset = s->xip_offset[group][bank];
    if (offset + size <= image_offset) {
        return;
    }

    start = (offset > image_offset) ? (offset - image_offset) : 0;
    if (start >= BL808_SF_CTRL_FLASH_APERTURE_SIZE) {
        return;
    }

    end = MIN(offset + size - image_offset, BL808_SF_CTRL_FLASH_APERTURE_SIZE);
    if (end <= start) {
        return;
    }

    memcpy(xip + start, s->flash + image_offset + start, end - start);
}

void bl808_sf_ctrl_sync_all_xip(BL808SfCtrlState *s)
{
    for (uint8_t group = 0; group < BL808_SF_CTRL_GROUP_COUNT; group++) {
        for (uint8_t bank = 0; bank < BL808_SF_CTRL_BANK_COUNT; bank++) {
            sf_ctrl_refresh_xip_view(s, group, bank);
        }
    }
}

void bl808_sf_ctrl_set_flash_image_offset(BL808SfCtrlState *s, uint8_t group,
                                          uint8_t bank, uint32_t addr_offset)
{
    hwaddr reg;

    if (!sf_ctrl_valid_group_bank(group, bank)) {
        return;
    }

    addr_offset &= 0x0FFFFFFFu;
    reg = sf_ctrl_image_offset_reg(group, bank);
    s->xip_offset[group][bank] = addr_offset;
    s->regs[reg / 4] = addr_offset;
    sf_ctrl_refresh_xip_view(s, group, bank);
}

void bl808_sf_ctrl_write_flash(BL808SfCtrlState *s, uint32_t offset,
                               const void *data, uint32_t size)
{
    if (!s->flash || !data || size == 0 || offset >= BL808_SF_CTRL_FLASH_SIZE) {
        return;
    }

    if (offset + size > BL808_SF_CTRL_FLASH_SIZE) {
        size = BL808_SF_CTRL_FLASH_SIZE - offset;
    }

    memcpy(s->flash + offset, data, size);
    sf_ctrl_sync_xip(s, offset, size);
    sf_ctrl_blk_write(s, offset, size);
}

static void sf_ctrl_sync_xip(BL808SfCtrlState *s, uint32_t offset, uint32_t size)
{
    for (uint8_t group = 0; group < BL808_SF_CTRL_GROUP_COUNT; group++) {
        for (uint8_t bank = 0; bank < BL808_SF_CTRL_BANK_COUNT; bank++) {
            sf_ctrl_sync_xip_range(s, group, bank, offset, size);
        }
    }
}

static void sf_ctrl_blk_write(BL808SfCtrlState *s, uint32_t offset,
                              uint32_t size)
{
    if (s->blk && offset + size <= BL808_SF_CTRL_FLASH_SIZE) {
        int ret = blk_pwrite(s->blk, offset, size, s->flash + offset, 0);
        if (ret < 0) {
            qemu_log_mask(LOG_GUEST_ERROR,
                          "bl808_sf_ctrl: flash writeback failed at "
                          "0x%08x: %s\n", offset, strerror(-ret));
        }
    }
}

static uint8_t *sf_ctrl_buf_bytes(BL808SfCtrlState *s)
{
    return (uint8_t *)s->buf;
}

static void sf_ctrl_store_data(BL808SfCtrlState *s, const uint8_t *data,
                               uint32_t len)
{
    uint8_t *buf = sf_ctrl_buf_bytes(s);
    uint32_t copy_len = MIN(len, BL808_SF_CTRL_BUF_SIZE);

    memset(buf, 0xFF, BL808_SF_CTRL_BUF_SIZE);
    if (copy_len) {
        memcpy(buf, data, copy_len);
    }
}

static void sf_ctrl_restore_status_from_nv(BL808SfCtrlState *s)
{
    s->sr1 = s->sr1_nv & SR1_WRITABLE_MASK;
    s->sr2 = (s->sr2_nv & SR2_WRITABLE_MASK) | SR2_QE;
    s->sr3 = s->sr3_nv & SR3_WRITABLE_MASK;
}

static void sf_ctrl_soft_reset(BL808SfCtrlState *s)
{
    s->sf_ctrl_0 &= ~SF_CTRL_0_32B_ADDR_EN;
    s->sf_ctrl_if_sahb0 = 0;
    s->sf_ctrl_if_sahb1 = 0;
    s->sf_ctrl_if_sahb2 = 0;
    sf_ctrl_restore_status_from_nv(s);
    s->sr1 &= ~SR1_WEL;
    s->sr2 &= ~SR2_SUS;
    s->volatile_wel = 0;
    s->powered_down = 0;
    s->qpi_mode = 0;
    s->reset_armed = 0;
    s->burst_wrap_data = 0;
    memset(s->buf, 0, sizeof(s->buf));
}

static bool sf_ctrl_status_write_enabled(BL808SfCtrlState *s)
{
    if (s->sr2 & SR2_SRL) {
        return false;
    }

    return (s->sr1 & SR1_WEL) || s->volatile_wel;
}

static void sf_ctrl_reset_register_defaults(BL808SfCtrlState *s)
{
    memset(s->regs, 0, sizeof(s->regs));
    for (uint8_t group = 0; group < BL808_SF_CTRL_GROUP_COUNT; group++) {
        for (uint8_t bank = 0; bank < BL808_SF_CTRL_BANK_COUNT; bank++) {
            hwaddr reg = sf_ctrl_image_offset_reg(group, bank);

            s->xip_offset[group][bank] = s->reset_xip_offset[group][bank] & 0x0FFFFFFFu;
            s->regs[reg / 4] = s->xip_offset[group][bank];
        }
    }
    s->regs[REG_SF_CTRL_SF_ID0 / 4] =
        W25Q128JW_MFR | (W25Q128JW_MEM << 8) |
        (W25Q128JW_CAP << 16);
    s->regs[REG_SF_CTRL_SF_ID1 / 4] = W25Q128JW_DEVICE_ID;
}

static void sf_ctrl_flash_power_on_reset(BL808SfCtrlState *s)
{
    s->sr1_nv = 0;
    s->sr2_nv = SR2_QE;
    s->sr3_nv = 0;
    sf_ctrl_restore_status_from_nv(s);
    s->volatile_wel = 0;
    s->powered_down = 0;
    s->qpi_mode = 0;
    s->reset_armed = 0;
    s->burst_wrap_data = 0;
}

static void sf_ctrl_read_buffer(BL808SfCtrlState *s, uint32_t addr,
                                uint32_t data_len)
{
    uint8_t *buf = sf_ctrl_buf_bytes(s);
    uint32_t max_bytes = data_len ? MIN(data_len, BL808_SF_CTRL_BUF_SIZE)
                                  : BL808_SF_CTRL_BUF_SIZE;
    uint32_t avail;
    uint32_t len;

    memset(buf, 0xFF, BL808_SF_CTRL_BUF_SIZE);

    if (addr >= BL808_SF_CTRL_FLASH_SIZE) {
        return;
    }

    avail = BL808_SF_CTRL_FLASH_SIZE - addr;
    len = MIN(avail, max_bytes);
    memcpy(buf, s->flash + addr, len);
}

static bool sf_ctrl_decode_sec_reg_addr(uint32_t addr, uint8_t *reg_index,
                                        uint8_t *reg_offset)
{
    uint8_t slot;

    if ((addr & 0xFF0000u) != 0 || (addr & 0x0F00u) != 0) {
        return false;
    }

    slot = (addr >> 12) & 0x0Fu;
    if (slot < 1 || slot > BL808_SF_CTRL_SEC_REG_COUNT) {
        return false;
    }

    *reg_index = slot - 1;
    *reg_offset = addr & 0xFFu;
    return true;
}

static uint8_t sf_ctrl_sec_reg_lock_mask(uint8_t reg_index)
{
    return SR2_LB1 << reg_index;
}

static void sf_ctrl_read_sec_reg(BL808SfCtrlState *s, uint32_t addr,
                                 uint32_t data_len)
{
    uint8_t *buf = sf_ctrl_buf_bytes(s);
    uint32_t max_bytes = data_len ? MIN(data_len, BL808_SF_CTRL_BUF_SIZE)
                                  : BL808_SF_CTRL_BUF_SIZE;
    uint32_t len;
    uint8_t reg_index;
    uint8_t reg_offset;

    memset(buf, 0xFF, BL808_SF_CTRL_BUF_SIZE);

    if (!sf_ctrl_decode_sec_reg_addr(addr, &reg_index, &reg_offset)) {
        return;
    }

    len = max_bytes;
    for (uint32_t i = 0; i < len; i++) {
        buf[i] = s->sec_reg[reg_index][(reg_offset + i) & 0xFFu];
    }
}

static void sf_ctrl_erase_range(BL808SfCtrlState *s, uint32_t base,
                                uint32_t size)
{
    memset(s->flash + base, 0xFF, size);
    sf_ctrl_sync_xip(s, base, size);
    sf_ctrl_blk_write(s, base, size);
    s->sr1 &= ~SR1_WEL;
}

static void sf_ctrl_page_program(BL808SfCtrlState *s, uint32_t addr,
                                 uint32_t data_len)
{
    uint8_t *src = sf_ctrl_buf_bytes(s);
    uint32_t page_base;
    uint32_t page_offset;
    uint32_t len;
    uint32_t i;

    if (addr >= BL808_SF_CTRL_FLASH_SIZE || !(s->sr1 & SR1_WEL)) {
        s->sr1 &= ~SR1_WEL;
        return;
    }

    page_base = addr & ~(FLASH_PAGE_SIZE - 1);
    page_offset = addr & (FLASH_PAGE_SIZE - 1);
    len = MIN(data_len ? data_len : BL808_SF_CTRL_BUF_SIZE, FLASH_PAGE_SIZE);

    for (i = 0; i < len; i++) {
        uint32_t dest = page_base + ((page_offset + i) & (FLASH_PAGE_SIZE - 1));

        if (dest < BL808_SF_CTRL_FLASH_SIZE) {
            s->flash[dest] &= src[i];
        }
    }

    sf_ctrl_sync_xip(s, page_base, FLASH_PAGE_SIZE);
    sf_ctrl_blk_write(s, page_base, FLASH_PAGE_SIZE);
    s->sr1 &= ~SR1_WEL;
}

static void sf_ctrl_sec_reg_erase(BL808SfCtrlState *s, uint32_t addr)
{
    uint8_t reg_index;
    uint8_t reg_offset;

    if (!sf_ctrl_decode_sec_reg_addr(addr, &reg_index, &reg_offset)) {
        s->sr1 &= ~SR1_WEL;
        return;
    }
    (void)reg_offset;

    if (s->sr2 & sf_ctrl_sec_reg_lock_mask(reg_index)) {
        s->sr1 &= ~SR1_WEL;
        return;
    }

    memset(s->sec_reg[reg_index], 0xFF, BL808_SF_CTRL_SEC_REG_SIZE);
    s->sr1 &= ~SR1_WEL;
}

static void sf_ctrl_sec_reg_program(BL808SfCtrlState *s, uint32_t addr,
                                    uint32_t data_len)
{
    uint8_t *src = sf_ctrl_buf_bytes(s);
    uint32_t len;
    uint32_t i;
    uint8_t reg_index;
    uint8_t reg_offset;

    if (!(s->sr1 & SR1_WEL) ||
        !sf_ctrl_decode_sec_reg_addr(addr, &reg_index, &reg_offset)) {
        s->sr1 &= ~SR1_WEL;
        return;
    }

    if (s->sr2 & sf_ctrl_sec_reg_lock_mask(reg_index)) {
        s->sr1 &= ~SR1_WEL;
        return;
    }

    len = MIN(data_len ? data_len : BL808_SF_CTRL_BUF_SIZE,
              BL808_SF_CTRL_SEC_REG_SIZE);

    for (i = 0; i < len; i++) {
        s->sec_reg[reg_index][(reg_offset + i) & 0xFFu] &= src[i];
    }

    s->sr1 &= ~SR1_WEL;
}

static uint8_t sf_ctrl_apply_sr2_write(uint8_t current, uint8_t requested)
{
    uint8_t next = current;

    next &= ~(SR2_SRL | SR2_CMP);
    next |= requested & (SR2_SRL | SR2_CMP);
    next |= current & SR2_LB_MASK;
    next |= requested & SR2_LB_MASK;
    next |= SR2_QE;
    return next;
}

static uint8_t sf_ctrl_apply_sr3_write(uint8_t current, uint8_t requested)
{
    return (current & ~SR3_WRITABLE_MASK) | (requested & SR3_WRITABLE_MASK);
}

static void sf_ctrl_commit_status_write(BL808SfCtrlState *s,
                                        bool write_volatile)
{
    s->sr1 &= ~SR1_WEL;
    s->sr2 |= SR2_QE;
    s->volatile_wel = 0;

    if (!write_volatile) {
        s->sr1_nv = s->sr1 & SR1_WRITABLE_MASK;
        s->sr2_nv = (s->sr2 & SR2_WRITABLE_MASK) | SR2_QE;
        s->sr3_nv = s->sr3 & SR3_WRITABLE_MASK;
    }
}

/* ========================================================================= */
/* Command execution                                                          */
/* ========================================================================= */

static void sf_ctrl_execute_cmd(BL808SfCtrlState *s)
{
    uint8_t cmd_stream[8];
    uint8_t cmd;
    uint32_t addr = 0;
    uint32_t sahb0 = s->sf_ctrl_if_sahb0;
    uint32_t cmd_bytes = (sahb0 & SAHB0_CMD_EN) ?
        (((sahb0 & SAHB0_CMD_BYTES_MASK) >> 20) + 1) : 0;
    uint32_t addr_bytes = (sahb0 & SAHB0_ADDR_EN) ?
        (((sahb0 & SAHB0_ADDR_BYTES_MASK) >> SAHB0_ADDR_BYTES_SHIFT) + 1) : 0;
    uint32_t data_len = (sahb0 & SAHB0_DATA_EN) ?
        (((sahb0 & SAHB0_DATA_BYTES_MASK) >> SAHB0_DATA_BYTES_SHIFT) + 1) : 0;
    bool has_addr = addr_bytes != 0;
    bool write_status_volatile = s->volatile_wel != 0;
    uint8_t ab_device_id = W25Q128JW_DEVICE_ID;
    uint8_t mfg_device_id[2] = { W25Q128JW_MFR, W25Q128JW_DEVICE_ID };
    uint8_t uid[8];
    uint8_t jedec_id[3] = {
        W25Q128JW_MFR, W25Q128JW_MEM, W25Q128JW_CAP
    };

    stl_be_p(cmd_stream, s->sf_ctrl_if_sahb1);
    stl_be_p(cmd_stream + 4, s->sf_ctrl_if_sahb2);

    if (cmd_bytes == 0) {
        s->sf_ctrl_if_sahb0 &= ~(SAHB0_BUSY | SAHB0_TRIGGER);
        return;
    }

    cmd = cmd_stream[0];
    for (uint32_t i = 0; i < addr_bytes && cmd_bytes + i < sizeof(cmd_stream); i++) {
        addr = (addr << 8) | cmd_stream[cmd_bytes + i];
    }
    if (!(s->sf_ctrl_0 & SF_CTRL_0_32B_ADDR_EN)) {
        addr &= 0x00FFFFFFu;
    }

    stl_le_p(uid + 0, W25Q128JW_UID_LO);
    stl_le_p(uid + 4, W25Q128JW_UID_HI);

    if (s->powered_down && cmd != FLASH_CMD_REL_PD) {
        goto finish;
    }

    if (s->reset_armed && cmd != FLASH_CMD_RESET) {
        s->reset_armed = 0;
    }

    switch (cmd) {
    case FLASH_CMD_WREN:
        s->sr1 |= SR1_WEL;
        s->volatile_wel = 0;
        break;

    case FLASH_CMD_WREN_VOLATILE:
        s->volatile_wel = 1;
        break;

    case FLASH_CMD_WRDIS:
        s->sr1 &= ~SR1_WEL;
        s->volatile_wel = 0;
        break;

    case FLASH_CMD_READ_SR1:
        sf_ctrl_store_data(s, &s->sr1, 1);
        break;

    case FLASH_CMD_READ_SR2:
        sf_ctrl_store_data(s, &s->sr2, 1);
        break;

    case FLASH_CMD_READ_SR3:
        sf_ctrl_store_data(s, &s->sr3, 1);
        break;

    case FLASH_CMD_WRITE_SR:
        if (sf_ctrl_status_write_enabled(s)) {
            uint8_t *buf = sf_ctrl_buf_bytes(s);

            if (data_len > 0) {
                s->sr1 = (s->sr1 & ~SR1_WRITABLE_MASK) |
                         (buf[0] & SR1_WRITABLE_MASK);
            }
            if (data_len > 1) {
                s->sr2 = sf_ctrl_apply_sr2_write(s->sr2, buf[1]);
            }
            sf_ctrl_commit_status_write(s, write_status_volatile);
        }
        break;

    case FLASH_CMD_WRITE_SR2:
        if (sf_ctrl_status_write_enabled(s)) {
            uint8_t *buf = sf_ctrl_buf_bytes(s);

            if (data_len > 0) {
                s->sr2 = sf_ctrl_apply_sr2_write(s->sr2, buf[0]);
            }
            sf_ctrl_commit_status_write(s, write_status_volatile);
        }
        break;

    case FLASH_CMD_WRITE_SR3:
        if (sf_ctrl_status_write_enabled(s)) {
            uint8_t *buf = sf_ctrl_buf_bytes(s);

            if (data_len > 0) {
                s->sr3 = sf_ctrl_apply_sr3_write(s->sr3, buf[0]);
            }
            sf_ctrl_commit_status_write(s, write_status_volatile);
        }
        break;

    case FLASH_CMD_READ_ID:
        sf_ctrl_store_data(s, jedec_id, sizeof(jedec_id));
        break;

    case FLASH_CMD_READ_UID:
        sf_ctrl_store_data(s, uid, sizeof(uid));
        break;

    case FLASH_CMD_REL_PD:
        s->powered_down = 0;
        if (data_len > 0) {
            sf_ctrl_store_data(s, &ab_device_id, 1);
        }
        break;

    case FLASH_CMD_READ_MFG_DEVICE_ID:
    case FLASH_CMD_READ_MFG_DEVICE_ID_DUAL:
    case FLASH_CMD_READ_MFG_DEVICE_ID_QUAD:
        if (!has_addr || addr == 0) {
            sf_ctrl_store_data(s, mfg_device_id, sizeof(mfg_device_id));
        }
        break;

    case FLASH_CMD_READ:
    case FLASH_CMD_FAST_READ:
    case FLASH_CMD_DIO_READ:
    case FLASH_CMD_DUAL_READ:
    case FLASH_CMD_QIO_READ:
    case FLASH_CMD_QUAD_READ:
        if (has_addr) {
            sf_ctrl_read_buffer(s, addr, data_len);
        }
        break;

    case FLASH_CMD_SEC_REG_READ:
        if (has_addr) {
            sf_ctrl_read_sec_reg(s, addr, data_len);
        }
        break;

    case FLASH_CMD_PAGE_PROG:
    case FLASH_CMD_QPAGE_PROG:
        if (has_addr) {
            sf_ctrl_page_program(s, addr, data_len);
        }
        break;

    case FLASH_CMD_SEC_REG_PROG:
        if (has_addr) {
            sf_ctrl_sec_reg_program(s, addr, data_len);
        }
        break;

    case FLASH_CMD_QPP_OR_QPI:
        if (has_addr) {
            sf_ctrl_page_program(s, addr, data_len);
        } else {
            s->qpi_mode = 1;
        }
        break;

    case FLASH_CMD_SECTOR_ERASE:
        if (has_addr && (s->sr1 & SR1_WEL)) {
            uint32_t base = addr & ~(FLASH_SECTOR_SIZE - 1);
            if (base + FLASH_SECTOR_SIZE <= BL808_SF_CTRL_FLASH_SIZE) {
                sf_ctrl_erase_range(s, base, FLASH_SECTOR_SIZE);
            } else {
                s->sr1 &= ~SR1_WEL;
            }
        }
        break;

    case FLASH_CMD_SEC_REG_ERASE:
        if (has_addr && (s->sr1 & SR1_WEL)) {
            sf_ctrl_sec_reg_erase(s, addr);
        }
        break;

    case FLASH_CMD_BLOCK_ERASE32:
        if (has_addr && (s->sr1 & SR1_WEL)) {
            uint32_t base = addr & ~(FLASH_BLOCK32_SIZE - 1);
            if (base + FLASH_BLOCK32_SIZE <= BL808_SF_CTRL_FLASH_SIZE) {
                sf_ctrl_erase_range(s, base, FLASH_BLOCK32_SIZE);
            } else {
                s->sr1 &= ~SR1_WEL;
            }
        }
        break;

    case FLASH_CMD_BLOCK_ERASE64:
        if (has_addr && (s->sr1 & SR1_WEL)) {
            uint32_t base = addr & ~(FLASH_BLOCK64_SIZE - 1);
            if (base + FLASH_BLOCK64_SIZE <= BL808_SF_CTRL_FLASH_SIZE) {
                sf_ctrl_erase_range(s, base, FLASH_BLOCK64_SIZE);
            } else {
                s->sr1 &= ~SR1_WEL;
            }
        }
        break;

    case FLASH_CMD_CHIP_ERASE:
    case FLASH_CMD_CHIP_ERASE_ALT:
        if (s->sr1 & SR1_WEL) {
            sf_ctrl_erase_range(s, 0, BL808_SF_CTRL_FLASH_SIZE);
        }
        break;

    case FLASH_CMD_BURST_WRAP:
    case FLASH_CMD_BURST_WRAP_ALT:
        if (data_len > 0) {
            s->burst_wrap_data = sf_ctrl_buf_bytes(s)[0];
        }
        break;

    case FLASH_CMD_POWER_DN:
        s->powered_down = 1;
        break;

    case FLASH_CMD_EN4B:
    case FLASH_CMD_EX4B:
        /* W25Q128JW is a 24-bit-address device; ignore 4-byte mode commands. */
        break;

    case FLASH_CMD_EXIT_QPI:
        s->qpi_mode = 0;
        break;

    case FLASH_CMD_EN_RESET:
        s->reset_armed = 1;
        break;

    case FLASH_CMD_RESET:
        if (s->reset_armed) {
            sf_ctrl_soft_reset(s);
            sf_ctrl_reset_register_defaults(s);
        }
        break;

    case FLASH_CMD_ERASE_SUSPEND:
    case FLASH_CMD_ERASE_RESUME:
    case FLASH_CMD_READ_SFDP:
        qemu_log_mask(LOG_UNIMP,
                      "bl808_sf_ctrl: flash command 0x%02x not modeled yet\n",
                      cmd);
        break;

    default:
        qemu_log_mask(LOG_UNIMP,
                      "bl808_sf_ctrl: unimplemented flash command 0x%02x\n",
                      cmd);
        break;
    }

finish:
    s->sf_ctrl_if_sahb0 &= ~(SAHB0_BUSY | SAHB0_TRIGGER);
}

/* ========================================================================= */
/* Register read/write                                                        */
/* ========================================================================= */

static uint64_t bl808_sf_ctrl_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808SfCtrlState *s = opaque;

    if (offset >= BL808_SF_CTRL_BUF_OFF &&
        offset < BL808_SF_CTRL_BUF_OFF + BL808_SF_CTRL_BUF_SIZE) {
        uint8_t *buf = sf_ctrl_buf_bytes(s) + (offset - BL808_SF_CTRL_BUF_OFF);

        switch (size) {
        case 1:
            return buf[0];
        case 2:
            return lduw_le_p(buf);
        case 4:
            return ldl_le_p(buf);
        default:
            return 0;
        }
    }

    if (size != 4) {
        return 0;
    }

    switch (offset) {
    case REG_SF_CTRL_0:
        return s->sf_ctrl_0;
    case REG_SF_CTRL_1:
        return s->sf_ctrl_1;
    case REG_SF_CTRL_IF_SAHB0:
        return s->sf_ctrl_if_sahb0;
    case REG_SF_CTRL_IF_SAHB1:
        return s->sf_ctrl_if_sahb1;
    case REG_SF_CTRL_IF_SAHB2:
        return s->sf_ctrl_if_sahb2;
    default:
        if (offset < BL808_SF_CTRL_BUF_OFF && (offset & 3) == 0) {
            return s->regs[offset / 4];
        }
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_sf_ctrl: read from unknown offset 0x%03"
                      HWADDR_PRIx "\n", offset);
        return 0;
    }
}

static void bl808_sf_ctrl_write(void *opaque, hwaddr offset, uint64_t value,
                                unsigned size)
{
    BL808SfCtrlState *s = opaque;

    if (offset >= BL808_SF_CTRL_BUF_OFF &&
        offset < BL808_SF_CTRL_BUF_OFF + BL808_SF_CTRL_BUF_SIZE) {
        uint8_t *buf = sf_ctrl_buf_bytes(s) + (offset - BL808_SF_CTRL_BUF_OFF);

        switch (size) {
        case 1:
            buf[0] = value;
            break;
        case 2:
            stw_le_p(buf, value);
            break;
        case 4:
            stl_le_p(buf, value);
            break;
        default:
            break;
        }
        return;
    }

    if (size != 4) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_sf_ctrl: invalid write size %u at 0x%03"
                      HWADDR_PRIx "\n", size, offset);
        return;
    }

    switch (offset) {
    case REG_SF_CTRL_0:
        s->sf_ctrl_0 = (uint32_t)value;
        break;
    case REG_SF_CTRL_1:
        s->sf_ctrl_1 = (uint32_t)value;
        break;
    case REG_SF_CTRL_IF_SAHB0:
    {
        uint32_t old = s->sf_ctrl_if_sahb0;
        uint32_t new_value = (uint32_t)value & ~SAHB0_BUSY;

        s->sf_ctrl_if_sahb0 = new_value;
        if (!(old & SAHB0_TRIGGER) && (new_value & SAHB0_TRIGGER)) {
            s->sf_ctrl_if_sahb0 |= SAHB0_BUSY;
            sf_ctrl_execute_cmd(s);
        }
        break;
    }
    case REG_SF_CTRL_IF_SAHB1:
        s->sf_ctrl_if_sahb1 = (uint32_t)value;
        break;
    case REG_SF_CTRL_IF_SAHB2:
        s->sf_ctrl_if_sahb2 = (uint32_t)value;
        break;
    case REG_SF_CTRL_SF_ID0_OFFSET:
        bl808_sf_ctrl_set_flash_image_offset(s, 0, 0, (uint32_t)value);
        break;
    case REG_SF_CTRL_SF_ID1_OFFSET:
        bl808_sf_ctrl_set_flash_image_offset(s, 1, 0, (uint32_t)value);
        break;
    case REG_SF_CTRL_SF_BK2_ID0_OFFSET:
        bl808_sf_ctrl_set_flash_image_offset(s, 0, 1, (uint32_t)value);
        break;
    case REG_SF_CTRL_SF_BK2_ID1_OFFSET:
        bl808_sf_ctrl_set_flash_image_offset(s, 1, 1, (uint32_t)value);
        break;
    default:
        if (offset < BL808_SF_CTRL_BUF_OFF && (offset & 3) == 0) {
            s->regs[offset / 4] = (uint32_t)value;
        } else {
            qemu_log_mask(LOG_GUEST_ERROR,
                          "bl808_sf_ctrl: write to unknown offset 0x%03"
                          HWADDR_PRIx " = 0x%" PRIx64 "\n", offset, value);
        }
        break;
    }
}

static const MemoryRegionOps bl808_sf_ctrl_ops = {
    .read = bl808_sf_ctrl_read,
    .write = bl808_sf_ctrl_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 1,
    .impl.max_access_size = 4,
};

/* ========================================================================= */
/* Device lifecycle                                                           */
/* ========================================================================= */

static void bl808_sf_ctrl_reset(DeviceState *dev)
{
    BL808SfCtrlState *s = BL808_SF_CTRL(dev);

    sf_ctrl_reset_register_defaults(s);
    sf_ctrl_flash_power_on_reset(s);
    s->sf_ctrl_0 = 0;
    s->sf_ctrl_1 = 0;
    sf_ctrl_soft_reset(s);
    bl808_sf_ctrl_sync_all_xip(s);
}

static void bl808_sf_ctrl_init(Object *obj)
{
    BL808SfCtrlState *s = BL808_SF_CTRL(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    memory_region_init_io(&s->iomem, obj, &bl808_sf_ctrl_ops, s,
                          TYPE_BL808_SF_CTRL, BL808_SF_CTRL_REG_SIZE);
    sysbus_init_mmio(sbd, &s->iomem);
}

static void bl808_sf_ctrl_realize(DeviceState *dev, Error **errp)
{
    BL808SfCtrlState *s = BL808_SF_CTRL(dev);

    s->flash = g_malloc(BL808_SF_CTRL_FLASH_SIZE);
    memset(s->flash, 0xFF, BL808_SF_CTRL_FLASH_SIZE);
    memset(s->sec_reg, 0xFF, sizeof(s->sec_reg));
    sf_ctrl_reset_register_defaults(s);
    sf_ctrl_flash_power_on_reset(s);

    if (s->blk) {
        int ret = blk_set_perm(s->blk,
                               BLK_PERM_CONSISTENT_READ | BLK_PERM_WRITE,
                               BLK_PERM_ALL, errp);
        int64_t len;

        if (ret < 0) {
            return;
        }

        len = blk_getlength(s->blk);
        if (len < 0) {
            error_setg(errp, "bl808_sf_ctrl: failed to get drive length");
            return;
        }
        if (len > BL808_SF_CTRL_FLASH_SIZE) {
            len = BL808_SF_CTRL_FLASH_SIZE;
        }
        if (len > 0) {
            ret = blk_pread(s->blk, 0, len, s->flash, 0);
            if (ret < 0) {
                error_setg(errp, "bl808_sf_ctrl: failed to read drive: %s",
                           strerror(-ret));
                return;
            }
        }
    }

    bl808_sf_ctrl_sync_all_xip(s);
}

static const Property bl808_sf_ctrl_properties[] = {
    DEFINE_PROP_DRIVE("drive", BL808SfCtrlState, blk),
};

static void bl808_sf_ctrl_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    dc->realize = bl808_sf_ctrl_realize;
    device_class_set_legacy_reset(dc, bl808_sf_ctrl_reset);
    device_class_set_props(dc, bl808_sf_ctrl_properties);
}

static const TypeInfo bl808_sf_ctrl_info = {
    .name          = TYPE_BL808_SF_CTRL,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(BL808SfCtrlState),
    .instance_init = bl808_sf_ctrl_init,
    .class_init    = bl808_sf_ctrl_class_init,
};

static void bl808_sf_ctrl_register_types(void)
{
    type_register_static(&bl808_sf_ctrl_info);
}

type_init(bl808_sf_ctrl_register_types)
