/*
 * Bouffalo Lab BL808 SPI controller emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_SSI_BL808_SPI_H
#define HW_SSI_BL808_SPI_H

#include <stdbool.h>

#include "hw/irq.h"
#include "hw/sysbus.h"
#include "qemu/typedefs.h"
#include "qom/object.h"

#define TYPE_BL808_SPI "bl808-spi"
#define BL808_SPI_FIFO_DEPTH 32
#define BL808_SPI_REG_SIZE   0x100

typedef struct BL808SPIState BL808SPIState;
OBJECT_DECLARE_SIMPLE_TYPE(BL808SPIState, BL808_SPI)

struct BL808SPIState {
    /*< private >*/
    SysBusDevice parent_obj;

    /*< public >*/
    MemoryRegion iomem;
    qemu_irq irq;
    qemu_irq cs;
    QEMUBH *transfer_bh;
    SSIBus *bus;

    uint32_t config;
    uint32_t int_sts;
    uint32_t int_enable;
    uint32_t int_mask;
    uint32_t prd0;
    uint32_t prd1;
    uint32_t rxd_ignr;
    uint32_t sto_value;
    uint32_t fifo_config0;
    uint32_t fifo_config1;

    uint32_t tx_fifo[BL808_SPI_FIFO_DEPTH];
    uint32_t rx_fifo[BL808_SPI_FIFO_DEPTH];
    uint32_t tx_head;
    uint32_t tx_tail;
    uint32_t tx_count;
    uint32_t rx_head;
    uint32_t rx_tail;
    uint32_t rx_count;
    uint32_t rx_ignore_remaining;

    bool transfer_scheduled;
    bool transfer_active;
    bool gate_enabled;
    bool module_clock_enabled;
    bool clock_enabled;
    bool reset_asserted;
    bool loopback;
};

void bl808_spi_set_clock_enabled(BL808SPIState *s, bool enabled);
void bl808_spi_set_module_clock_enabled(BL808SPIState *s, bool enabled);
void bl808_spi_set_reset_asserted(BL808SPIState *s, bool asserted);
bool bl808_spi_dma_can_read(BL808SPIState *s, unsigned width_bytes);
bool bl808_spi_dma_can_write(BL808SPIState *s, unsigned width_bytes);
uint32_t bl808_spi_dma_read(BL808SPIState *s, unsigned width_bytes);
void bl808_spi_dma_write(BL808SPIState *s, uint32_t value,
                         unsigned width_bytes);

#endif /* HW_SSI_BL808_SPI_H */
