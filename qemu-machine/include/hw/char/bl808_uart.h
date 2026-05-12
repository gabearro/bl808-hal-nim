/*
 * Bouffalo Lab BL808 UART controller emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_CHAR_BL808_UART_H
#define HW_CHAR_BL808_UART_H

#include <stdbool.h>

#include "chardev/char-fe.h"
#include "hw/sysbus.h"
#include "qemu/typedefs.h"
#include "qom/object.h"

#define TYPE_BL808_UART "bl808-uart"
#define BL808_UART_REG_SIZE 0x100
#define BL808_UART_FIFO_DEPTH 32

typedef struct BL808UARTState BL808UARTState;
OBJECT_DECLARE_SIMPLE_TYPE(BL808UARTState, BL808_UART)

struct BL808UARTState {
    /*< private >*/
    SysBusDevice parent_obj;

    /*< public >*/
    MemoryRegion iomem;
    qemu_irq irq;
    CharBackend chr;

    uint32_t utx_config;
    uint32_t urx_config;
    uint32_t bit_prd;
    uint32_t data_config;
    uint32_t utx_ir_position;
    uint32_t urx_ir_position;
    uint32_t urx_rto_timer;
    uint32_t uart_sw_mode;
    uint32_t int_sts;
    uint32_t int_mask;
    uint32_t int_en;
    uint32_t fifo_config_0;
    uint32_t fifo_config_1;
    uint32_t sts_urx_abr_prd;
    uint32_t urx_abr_prd_b01;
    uint32_t urx_abr_prd_b23;
    uint32_t urx_abr_prd_b45;
    uint32_t urx_abr_prd_b67;
    uint32_t urx_abr_pw_tol;
    uint32_t urx_bcr_int_cfg;
    uint32_t utx_rs485_cfg;

    uint8_t tx_fifo[BL808_UART_FIFO_DEPTH];
    uint8_t rx_fifo[BL808_UART_FIFO_DEPTH];
    uint32_t tx_head;
    uint32_t tx_tail;
    uint32_t tx_count;
    uint32_t rx_head;
    uint32_t rx_tail;
    uint32_t rx_count;
    uint32_t tx_total;
    uint32_t rx_total;

    bool gate_enabled;
    bool module_clock_enabled;
    bool clock_enabled;
    bool reset_asserted;
};

void bl808_uart_set_clock_enabled(BL808UARTState *s, bool enabled);
void bl808_uart_set_module_clock_enabled(BL808UARTState *s, bool enabled);
void bl808_uart_set_reset_asserted(BL808UARTState *s, bool asserted);
bool bl808_uart_dma_can_read(BL808UARTState *s, unsigned width_bytes);
bool bl808_uart_dma_can_write(BL808UARTState *s, unsigned width_bytes);
uint32_t bl808_uart_dma_read(BL808UARTState *s, unsigned width_bytes);
void bl808_uart_dma_write(BL808UARTState *s, uint32_t value,
                          unsigned width_bytes);

#endif /* HW_CHAR_BL808_UART_H */
