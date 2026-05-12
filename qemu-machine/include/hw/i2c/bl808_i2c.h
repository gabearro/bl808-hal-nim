/*
 * Bouffalo Lab BL808 I2C controller emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_I2C_BL808_I2C_H
#define HW_I2C_BL808_I2C_H

#include <stdbool.h>

#include "hw/i2c/i2c.h"
#include "hw/sysbus.h"
#include "qom/object.h"

#define TYPE_BL808_I2C "bl808-i2c"

typedef struct BL808I2CState BL808I2CState;
OBJECT_DECLARE_SIMPLE_TYPE(BL808I2CState, BL808_I2C)

#define BL808_I2C_REG_SIZE     0x100
#define BL808_I2C_EEPROM_SIZE  256
#define BL808_I2C_EEPROM_ADDR  0x50
#define BL808_I2C_FIFO_DEPTH   2

struct BL808I2CState {
    /*< private >*/
    SysBusDevice parent_obj;

    /*< public >*/
    MemoryRegion iomem;
    qemu_irq irq;
    I2CBus *bus;

    uint32_t config;
    uint32_t int_sts;
    uint32_t sub_addr;
    uint32_t prd_start;
    uint32_t prd_stop;
    uint32_t prd_data;
    uint32_t fifo_config0;

    uint8_t tx_fifo[BL808_I2C_FIFO_DEPTH];
    int tx_head;
    int tx_count;
    uint8_t rx_fifo[BL808_I2C_FIFO_DEPTH];
    int rx_head;
    int rx_count;

    bool transfer_active;
    int xfer_remaining;
    bool xfer_is_read;

    bool attach_default_eeprom;
    bool gate_enabled;
    bool module_clock_enabled;
    bool clock_enabled;
    bool reset_asserted;
};

void bl808_i2c_set_clock_enabled(BL808I2CState *s, bool enabled);
void bl808_i2c_set_module_clock_enabled(BL808I2CState *s, bool enabled);
void bl808_i2c_set_reset_asserted(BL808I2CState *s, bool asserted);
bool bl808_i2c_dma_can_read(BL808I2CState *s, unsigned width_bytes);
bool bl808_i2c_dma_can_write(BL808I2CState *s, unsigned width_bytes);
uint32_t bl808_i2c_dma_read(BL808I2CState *s, unsigned width_bytes);
void bl808_i2c_dma_write(BL808I2CState *s, uint32_t value,
                         unsigned width_bytes);

#endif /* HW_I2C_BL808_I2C_H */
