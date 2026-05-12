/*
 * Bouffalo Lab BL808 USB v2 emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qemu/timer.h"
#include "exec/cpu-common.h"
#include "hw/irq.h"
#include "hw/misc/bl808_usb.h"

#define USB_HCCAP_OFFSET            0x000
#define USB_HCSPARAMS_OFFSET        0x004
#define USB_HCCPARAMS_OFFSET        0x008
#define USBCMD_OFFSET               0x010
#define USBSTS_OFFSET               0x014
#define USBINTR_OFFSET              0x018
#define USB_FRINDEX_OFFSET          0x01c
#define USB_PERIODICLISTBASE_OFFSET 0x024
#define USB_ASYNCLISTADDR_OFFSET    0x028
#define USB_PORTSC_OFFSET           0x030
#define USB_OTG_CSR_OFFSET          0x080
#define USB_OTG_ISR_OFFSET          0x084
#define USB_OTG_IER_OFFSET          0x088
#define USB_GLB_ISR_OFFSET          0x0c0
#define USB_GLB_INT_OFFSET          0x0c4
#define USB_REVISION_OFFSET         0x0e0
#define USB_FEATURE_OFFSET          0x0e4
#define USB_AXI_CR_OFFSET           0x0e8
#define USB_DEV_CTL_OFFSET          0x100
#define USB_DEV_ADR_OFFSET          0x104
#define USB_DEV_TST_OFFSET          0x108
#define USB_DEV_SFN_OFFSET          0x10c
#define USB_DEV_SMT_OFFSET          0x110
#define USB_PHY_TST_OFFSET          0x114
#define USB_DEV_VCTL_OFFSET         0x118
#define USB_DEV_CXCFG_OFFSET        0x11c
#define USB_DEV_CXCFE_OFFSET        0x120
#define USB_DEV_ICR_OFFSET          0x124
#define USB_DEV_MIGR_OFFSET         0x130
#define USB_DEV_MISG0_OFFSET        0x134
#define USB_DEV_MISG1_OFFSET        0x138
#define USB_DEV_MISG2_OFFSET        0x13c
#define USB_DEV_IGR_OFFSET          0x140
#define USB_DEV_ISG0_OFFSET         0x144
#define USB_DEV_ISG1_OFFSET         0x148
#define USB_DEV_ISG2_OFFSET         0x14c
#define USB_DEV_RXZ_OFFSET          0x150
#define USB_DEV_TXZ_OFFSET          0x154
#define USB_DEV_ISE_OFFSET          0x158
#define USB_DEV_INMPS1_OFFSET       0x160
#define USB_DEV_OUTMPS1_OFFSET      0x180
#define USB_DEV_EPMAP0_OFFSET       0x1a0
#define USB_DEV_EPMAP1_OFFSET       0x1a4
#define USB_DEV_FMAP_OFFSET         0x1a8
#define USB_DEV_FCFG_OFFSET         0x1ac
#define USB_DEV_FIBC0_OFFSET        0x1b0
#define USB_DMA_TFN_OFFSET          0x1c0
#define USB_DMA_CPS0_OFFSET         0x1c4
#define USB_DMA_CPS1_OFFSET         0x1c8
#define USB_DMA_CPS2_OFFSET         0x1cc
#define USB_DMA_CPS3_OFFSET         0x1d0
#define USB_DMA_CPS4_OFFSET         0x1d4
#define USB_DEV_FMAP2_OFFSET        0x1d8
#define USB_DEV_FCFG2_OFFSET        0x1dc
#define USB_DEV_FMAP3_OFFSET        0x1e0
#define USB_DEV_FCFG3_OFFSET        0x1e4
#define USB_DEV_FMAP4_OFFSET        0x1e8
#define USB_DEV_FCFG4_OFFSET        0x1ec
#define USB_DEV_FIBC4_OFFSET        0x1f0
#define USB_FIFO_PORT_OFFSET        0x200
#define USB_VDMA_CXFPS1_OFFSET      0x300
#define USB_VDMA_CXFPS2_OFFSET      0x304
#define USB_VDMA_F0PS1_OFFSET       0x308
#define USB_VDMA_F0PS2_OFFSET       0x30c
#define USB_DEV_ISG3_OFFSET         0x328
#define USB_DEV_MISG3_OFFSET        0x32c
#define USB_VDMA_CTRL_OFFSET        0x330
#define USB_LPM_CAP_OFFSET          0x334
#define USB_DEV_ISG4_OFFSET         0x338
#define USB_DEV_MISG4_OFFSET        0x33c
#define USB_VDMA_FNPS1_OFFSET       0x350
#define USB_VDMA_FNPS2_OFFSET       0x354

#define USB_RS                      BIT(0)
#define USB_HC_RESET                BIT(1)
#define USB_INT                     BIT(0)
#define USBERR_INT                  BIT(1)
#define USB_PO_CHG_DET              BIT(2)
#define USB_FRL_ROL                 BIT(3)
#define USB_H_SYSERR                BIT(4)
#define USB_INT_OAA                 BIT(5)
#define USB_HCHALTED                BIT(12)
#define USB_CONN_CHG                BIT(1)
#define USB_PO_EN_CHG               BIT(3)
#define USB_MDEV_INT                BIT(0)
#define USB_MOTG_INT                BIT(1)
#define USB_MHC_INT                 BIT(2)
#define USB_DEV_INT                 BIT(0)
#define USB_OTG_INT                 BIT(1)
#define USB_HC_INT                  BIT(2)
#define USB_GLINT_EN_HOV            BIT(2)
#define USB_SFRST_HOV               BIT(4)
#define USB_CHIP_EN_HOV             BIT(5)
#define USB_HS_EN_HOV               BIT(6)
#define USB_CX_DONE                 BIT(0)
#define USB_CX_STL                  BIT(2)
#define USB_CX_CLR                  BIT(3)
#define USB_CX_FUL                  BIT(4)
#define USB_CX_EMP                  BIT(5)
#define USB_F0_EMP                  BIT(8)
#define USB_F1_EMP                  BIT(9)
#define USB_F2_EMP                  BIT(10)
#define USB_F3_EMP                  BIT(11)
#define USB_MDMA_CMPLT_HOV          BIT(7)
#define USB_DMA_CMPLT_HOV           BIT(7)
#define USB_FFRST0_HOV              BIT(12)
#define USB_ACC_F0_HOV              BIT(0)
#define USB_ACC_F1_HOV              BIT(1)
#define USB_ACC_F2_HOV              BIT(2)
#define USB_ACC_F3_HOV              BIT(3)
#define USB_ACC_CXF_HOV             BIT(4)
#define USB_VDMA_START_CXF          BIT(0)
#define USB_VDMA_TYPE_CXF           BIT(1)
#define USB_VDMA_LEN_CXF_SHIFT      8
#define USB_VDMA_LEN_CXF_MASK       (0x1ffffu << USB_VDMA_LEN_CXF_SHIFT)
#define USB_VDMA_CMPLT_CXF          BIT(0)
#define USB_VDMA_CMPLT_F0           BIT(1)
#define USB_VDMA_CMPLT_F1           BIT(2)
#define USB_VDMA_CMPLT_F2           BIT(3)
#define USB_VDMA_CMPLT_F3           BIT(4)
#define USB_VDMA_ERROR_CXF          BIT(16)
#define USB_VDMA_ERROR_F0           BIT(17)
#define USB_VDMA_ERROR_F1           BIT(18)
#define USB_VDMA_ERROR_F2           BIT(19)
#define USB_VDMA_ERROR_F3           BIT(20)
#define USB_VDMA_EN                 BIT(0)
#define USB_A_BUS_REQ_HOV           BIT(4)
#define USB_A_BUS_DROP_HOV          BIT(5)
#define USB_A_SESS_VLD              BIT(18)
#define USB_VBUS_VLD_HOV            BIT(19)
#define USB_SPD_TYP_HOV_POV_SHIFT   22
#define USB_CONN_STS                BIT(0)
#define USB_PO_EN                   BIT(2)

enum {
    BL808_USB_AUTOHOST_IDLE = 0,
    BL808_USB_AUTOHOST_DEVICE_DESC,
    BL808_USB_AUTOHOST_CONFIG_DESC,
    BL808_USB_AUTOHOST_SET_ADDRESS,
    BL808_USB_AUTOHOST_SET_CONFIG,
    BL808_USB_AUTOHOST_DONE,
};

static void bl808_usb_autohost_advance(BL808USBState *s);
static void bl808_usb_loopback_timer(void *opaque);

static bool bl808_usb_dev_pending(BL808USBState *s)
{
    return ((s->regs[USB_DEV_ISG0_OFFSET / 4] & ~s->regs[USB_DEV_MISG0_OFFSET / 4]) != 0) ||
           ((s->regs[USB_DEV_ISG1_OFFSET / 4] & ~s->regs[USB_DEV_MISG1_OFFSET / 4]) != 0) ||
           ((s->regs[USB_DEV_ISG2_OFFSET / 4] & ~s->regs[USB_DEV_MISG2_OFFSET / 4]) != 0) ||
           ((s->regs[USB_DEV_ISG3_OFFSET / 4] & ~s->regs[USB_DEV_MISG3_OFFSET / 4]) != 0) ||
           ((s->regs[USB_DEV_ISG4_OFFSET / 4] & ~s->regs[USB_DEV_MISG4_OFFSET / 4]) != 0);
}

static bool bl808_usb_otg_pending(BL808USBState *s)
{
    return (s->regs[USB_OTG_ISR_OFFSET / 4] & s->regs[USB_OTG_IER_OFFSET / 4]) != 0;
}

static bool bl808_usb_host_pending(BL808USBState *s)
{
    return (s->regs[USBSTS_OFFSET / 4] & s->regs[USBINTR_OFFSET / 4] &
            (USB_INT | USBERR_INT | USB_PO_CHG_DET |
             USB_FRL_ROL | USB_H_SYSERR | USB_INT_OAA)) != 0;
}

static uint32_t bl808_usb_cxcfe_dynamic(BL808USBState *s)
{
    uint32_t value = s->regs[USB_DEV_CXCFE_OFFSET / 4] &
                     (USB_CX_DONE | USB_CX_STL);

    if (s->cx_fifo_len == 0) {
        value |= USB_CX_EMP;
    } else if (s->cx_fifo_len >= BL808_USB_FIFO_CAPACITY) {
        value |= USB_CX_FUL;
    }
    if (s->fifo_len[0] == 0) {
        value |= USB_F0_EMP;
    }
    if (s->fifo_len[1] == 0) {
        value |= USB_F1_EMP;
    }
    if (s->fifo_len[2] == 0) {
        value |= USB_F2_EMP;
    }
    if (s->fifo_len[3] == 0) {
        value |= USB_F3_EMP;
    }
    return value;
}

static void bl808_usb_update_irq(BL808USBState *s)
{
    uint32_t glb = 0;
    uint32_t raw_group = 0;
    uint32_t masked_group = 0;
    bool level;

    if (s->regs[USB_DEV_ISG0_OFFSET / 4] != 0) {
        raw_group |= BIT(0);
    }
    if (s->regs[USB_DEV_ISG1_OFFSET / 4] != 0) {
        raw_group |= BIT(1);
    }
    if (s->regs[USB_DEV_ISG2_OFFSET / 4] != 0) {
        raw_group |= BIT(2);
    }
    if (s->regs[USB_DEV_ISG3_OFFSET / 4] != 0) {
        raw_group |= BIT(3);
    }
    if (s->regs[USB_DEV_ISG4_OFFSET / 4] != 0) {
        raw_group |= BIT(4);
    }

    if ((s->regs[USB_DEV_ISG0_OFFSET / 4] & ~s->regs[USB_DEV_MISG0_OFFSET / 4]) != 0) {
        masked_group |= BIT(0);
    }
    if ((s->regs[USB_DEV_ISG1_OFFSET / 4] & ~s->regs[USB_DEV_MISG1_OFFSET / 4]) != 0) {
        masked_group |= BIT(1);
    }
    if ((s->regs[USB_DEV_ISG2_OFFSET / 4] & ~s->regs[USB_DEV_MISG2_OFFSET / 4]) != 0) {
        masked_group |= BIT(2);
    }
    if ((s->regs[USB_DEV_ISG3_OFFSET / 4] & ~s->regs[USB_DEV_MISG3_OFFSET / 4]) != 0) {
        masked_group |= BIT(3);
    }
    if ((s->regs[USB_DEV_ISG4_OFFSET / 4] & ~s->regs[USB_DEV_MISG4_OFFSET / 4]) != 0) {
        masked_group |= BIT(4);
    }

    s->regs[USB_DEV_IGR_OFFSET / 4] = raw_group;
    s->regs[USB_DEV_MIGR_OFFSET / 4] = masked_group;

    if (bl808_usb_dev_pending(s)) {
        glb |= USB_DEV_INT;
    }
    if (bl808_usb_otg_pending(s)) {
        glb |= USB_OTG_INT;
    }
    if (bl808_usb_host_pending(s)) {
        glb |= USB_HC_INT;
    }
    s->regs[USB_GLB_ISR_OFFSET / 4] = glb;
    level = (glb & ~s->regs[USB_GLB_INT_OFFSET / 4]) != 0 &&
            (s->regs[USB_DEV_CTL_OFFSET / 4] & USB_GLINT_EN_HOV);
    qemu_set_irq(s->irq, level);
}

static void bl808_usb_reset_fifo(BL808USBState *s, int fifo)
{
    if (fifo < 0) {
        s->cx_fifo_len = 0;
    } else if (fifo < BL808_USB_FIFO_COUNT) {
        s->fifo_len[fifo] = 0;
    }
}

static void bl808_usb_fifo_append(uint8_t *fifo, size_t *fifo_len,
                                  const uint8_t *data, size_t len)
{
    size_t room = BL808_USB_FIFO_CAPACITY - *fifo_len;
    size_t copy = MIN(room, len);

    memcpy(fifo + *fifo_len, data, copy);
    *fifo_len += copy;
}

static uint32_t bl808_usb_fifo_pop_word(uint8_t *fifo, size_t *fifo_len)
{
    uint32_t value = 0;
    size_t count = MIN((size_t)4, *fifo_len);

    for (size_t i = 0; i < count; i++) {
        value |= (uint32_t)fifo[i] << (i * 8);
    }
    if (count < *fifo_len) {
        memmove(fifo, fifo + count, *fifo_len - count);
    }
    *fifo_len -= count;
    return value;
}

static void bl808_usb_fifo_append_word(uint8_t *fifo, size_t *fifo_len,
                                       uint32_t value)
{
    uint8_t data[4] = {
        value & 0xff,
        (value >> 8) & 0xff,
        (value >> 16) & 0xff,
        (value >> 24) & 0xff,
    };

    bl808_usb_fifo_append(fifo, fifo_len, data, sizeof(data));
}

static uint32_t bl808_usb_fibc_value(BL808USBState *s, int fifo)
{
    return (uint32_t)(s->fifo_len[fifo] & 0x7ffu);
}

static void bl808_usb_inject_setup(BL808USBState *s,
                                   uint8_t bm_request_type,
                                   uint8_t request,
                                   uint16_t value,
                                   uint16_t index,
                                   uint16_t length)
{
    uint8_t setup[8] = {
        bm_request_type,
        request,
        value & 0xff,
        value >> 8,
        index & 0xff,
        index >> 8,
        length & 0xff,
        length >> 8,
    };

    bl808_usb_reset_fifo(s, -1);
    memcpy(s->cx_fifo, setup, sizeof(setup));
    s->cx_fifo_len = sizeof(setup);
    s->regs[USB_DEV_ISG0_OFFSET / 4] |= BIT(0);
    bl808_usb_update_irq(s);
}

static void bl808_usb_autohost_start(BL808USBState *s)
{
    if (s->autohost_started) {
        return;
    }

    s->autohost_started = true;
    s->autohost_step = BL808_USB_AUTOHOST_DEVICE_DESC;
    s->regs[USB_DEV_ISG2_OFFSET / 4] |= BIT(0);
    bl808_usb_update_irq(s);
}

static void bl808_usb_autohost_advance(BL808USBState *s)
{
    if (!s->autohost_started ||
        s->autohost_step == BL808_USB_AUTOHOST_DONE ||
        (s->regs[USB_DEV_ISG0_OFFSET / 4] & BIT(0)) != 0) {
        return;
    }

    switch (s->autohost_step) {
    case BL808_USB_AUTOHOST_DEVICE_DESC:
        s->autohost_step = BL808_USB_AUTOHOST_CONFIG_DESC;
        bl808_usb_inject_setup(s, 0x80, 6, 0x0100, 0, 18);
        break;
    case BL808_USB_AUTOHOST_CONFIG_DESC:
        s->autohost_step = BL808_USB_AUTOHOST_SET_ADDRESS;
        bl808_usb_inject_setup(s, 0x80, 6, 0x0200, 0, 255);
        break;
    case BL808_USB_AUTOHOST_SET_ADDRESS:
        s->autohost_step = BL808_USB_AUTOHOST_SET_CONFIG;
        bl808_usb_inject_setup(s, 0x00, 5, 1, 0, 0);
        break;
    case BL808_USB_AUTOHOST_SET_CONFIG:
        s->autohost_step = BL808_USB_AUTOHOST_DONE;
        bl808_usb_inject_setup(s, 0x00, 9, 1, 0, 0);
        break;
    default:
        s->autohost_step = BL808_USB_AUTOHOST_DONE;
        break;
    }
}

static void bl808_usb_schedule_loopback(BL808USBState *s)
{
    if (s->loopback_timer) {
        timer_mod(s->loopback_timer,
                  qemu_clock_get_ms(QEMU_CLOCK_VIRTUAL) + 2);
    }
}

static void bl808_usb_loopback_timer(void *opaque)
{
    BL808USBState *s = opaque;
    size_t room = BL808_USB_FIFO_CAPACITY - s->fifo_len[1];
    size_t copy = MIN(room, s->fifo_len[0]);

    if (copy == 0) {
        return;
    }

    bl808_usb_fifo_append(s->fifo[1], &s->fifo_len[1], s->fifo[0], copy);
    if (copy < s->fifo_len[0]) {
        memmove(s->fifo[0], s->fifo[0] + copy, s->fifo_len[0] - copy);
    }
    s->fifo_len[0] -= copy;
    s->regs[USB_DEV_ISG1_OFFSET / 4] |= BIT(2);
    bl808_usb_update_irq(s);
}

static size_t bl808_usb_vdma_len(uint32_t ps1)
{
    return (ps1 & USB_VDMA_LEN_CXF_MASK) >> USB_VDMA_LEN_CXF_SHIFT;
}

static hwaddr bl808_usb_vdma_addr(uint32_t ps2)
{
    return ps2;
}

static void bl808_usb_vdma_complete(BL808USBState *s, int fifo, bool error)
{
    uint32_t done_bit;
    uint32_t err_bit;

    if (fifo < 0) {
        done_bit = USB_VDMA_CMPLT_CXF;
        err_bit = USB_VDMA_ERROR_CXF;
    } else {
        done_bit = BIT(fifo + 1);
        err_bit = BIT(fifo + 17);
    }
    if (error) {
        s->regs[USB_DEV_ISG3_OFFSET / 4] |= err_bit;
    } else {
        s->regs[USB_DEV_ISG3_OFFSET / 4] |= done_bit;
        s->regs[USB_DEV_ISG2_OFFSET / 4] |= USB_DMA_CMPLT_HOV;
    }
    bl808_usb_update_irq(s);
}

static void bl808_usb_vdma_run(BL808USBState *s, int fifo, uint32_t *ps1,
                               uint32_t ps2)
{
    uint8_t scratch[BL808_USB_FIFO_CAPACITY];
    size_t len = bl808_usb_vdma_len(*ps1);
    hwaddr addr = bl808_usb_vdma_addr(ps2);
    bool mem_to_fifo = (*ps1 & USB_VDMA_TYPE_CXF) != 0;
    uint8_t *dst = fifo < 0 ? s->cx_fifo : s->fifo[fifo];
    size_t *dst_len = fifo < 0 ? &s->cx_fifo_len : &s->fifo_len[fifo];

    len = MIN(len, (size_t)BL808_USB_FIFO_CAPACITY);
    if (mem_to_fifo) {
        cpu_physical_memory_read(addr, dst, len);
        *dst_len = len;
    } else {
        size_t xfer = MIN(len, *dst_len);

        memcpy(scratch, dst, xfer);
        cpu_physical_memory_write(addr, scratch, xfer);
        if (xfer < *dst_len) {
            memmove(dst, dst + xfer, *dst_len - xfer);
        }
        *dst_len -= xfer;
    }

    *ps1 &= ~USB_VDMA_START_CXF;
    *ps1 &= ~USB_VDMA_LEN_CXF_MASK;
    bl808_usb_vdma_complete(s, fifo, false);
}

static uint64_t bl808_usb_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808USBState *s = opaque;

    if (size != 4) {
        return 0;
    }
    if ((offset & 3) || offset >= BL808_USB_REG_SIZE) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_usb: bad read offset 0x%" HWADDR_PRIx "\n",
                      offset);
        return 0;
    }

    if (offset >= USB_FIFO_PORT_OFFSET &&
        offset < USB_FIFO_PORT_OFFSET + BL808_USB_FIFO_COUNT * 4) {
        int fifo = (offset - USB_FIFO_PORT_OFFSET) / 4;
        uint32_t value = bl808_usb_fifo_pop_word(s->fifo[fifo],
                                                 &s->fifo_len[fifo]);

        if (fifo == 1 && s->fifo_len[fifo] == 0) {
            s->regs[USB_DEV_ISG1_OFFSET / 4] &= ~BIT(2);
            bl808_usb_update_irq(s);
        }
        return value;
    }

    if (offset == USB_VDMA_CXFPS1_OFFSET &&
        s->autohost_started && s->cx_fifo_len != 0) {
        return bl808_usb_fifo_pop_word(s->cx_fifo, &s->cx_fifo_len);
    }

    switch (offset) {
    case USB_DEV_CXCFE_OFFSET:
        return bl808_usb_cxcfe_dynamic(s);
    case USB_DEV_FIBC0_OFFSET:
    case USB_DEV_FIBC0_OFFSET + 4:
    case USB_DEV_FIBC0_OFFSET + 8:
    case USB_DEV_FIBC0_OFFSET + 12:
        return bl808_usb_fibc_value(s, (offset - USB_DEV_FIBC0_OFFSET) / 4);
    case USB_DEV_FIBC4_OFFSET:
    case USB_DEV_FIBC4_OFFSET + 4:
    case USB_DEV_FIBC4_OFFSET + 8:
    case USB_DEV_FIBC4_OFFSET + 12:
        return 0;
    default:
        return s->regs[offset / 4];
    }
}

static void bl808_usb_write(void *opaque, hwaddr offset, uint64_t value,
                            unsigned size)
{
    BL808USBState *s = opaque;
    uint32_t val = (uint32_t)value;

    if (size != 4) {
        return;
    }
    if ((offset & 3) || offset >= BL808_USB_REG_SIZE) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_usb: bad write offset 0x%" HWADDR_PRIx
                      " = 0x%" PRIx64 "\n", offset, value);
        return;
    }

    if (offset >= USB_FIFO_PORT_OFFSET &&
        offset < USB_FIFO_PORT_OFFSET + BL808_USB_FIFO_COUNT * 4) {
        int fifo = (offset - USB_FIFO_PORT_OFFSET) / 4;

        bl808_usb_fifo_append_word(s->fifo[fifo], &s->fifo_len[fifo], val);
        if (fifo == 0) {
            bl808_usb_schedule_loopback(s);
        }
        bl808_usb_update_irq(s);
        return;
    }

    switch (offset) {
    case USBCMD_OFFSET:
        s->regs[offset / 4] = val & 0x00ff0fff;
        if (val & USB_HC_RESET) {
            s->regs[USBSTS_OFFSET / 4] = USB_HCHALTED;
            s->regs[USB_FRINDEX_OFFSET / 4] = 0;
            s->regs[USB_PERIODICLISTBASE_OFFSET / 4] = 0;
            s->regs[USB_ASYNCLISTADDR_OFFSET / 4] = 0;
            s->regs[offset / 4] &= ~USB_HC_RESET;
        }
        if (val & USB_RS) {
            s->regs[USBSTS_OFFSET / 4] &= ~USB_HCHALTED;
        } else {
            s->regs[USBSTS_OFFSET / 4] |= USB_HCHALTED;
        }
        break;
    case USBSTS_OFFSET:
        s->regs[offset / 4] &= ~(val & (USB_INT | USBERR_INT | USB_PO_CHG_DET |
                                        USB_FRL_ROL | USB_H_SYSERR |
                                        USB_INT_OAA));
        break;
    case USBINTR_OFFSET:
    case USB_FRINDEX_OFFSET:
    case USB_PERIODICLISTBASE_OFFSET:
    case USB_ASYNCLISTADDR_OFFSET:
    case USB_HCSPARAMS_OFFSET:
    case USB_HCCPARAMS_OFFSET:
    case USB_GLB_INT_OFFSET:
    case USB_AXI_CR_OFFSET:
    case USB_DEV_ADR_OFFSET:
    case USB_DEV_TST_OFFSET:
    case USB_DEV_SFN_OFFSET:
    case USB_DEV_SMT_OFFSET:
    case USB_PHY_TST_OFFSET:
    case USB_DEV_VCTL_OFFSET:
    case USB_DEV_CXCFG_OFFSET:
    case USB_DEV_ICR_OFFSET:
    case USB_DEV_MIGR_OFFSET:
    case USB_DEV_MISG0_OFFSET:
    case USB_DEV_MISG1_OFFSET:
    case USB_DEV_MISG2_OFFSET:
    case USB_DEV_MISG3_OFFSET:
    case USB_DEV_MISG4_OFFSET:
    case USB_DEV_IGR_OFFSET:
    case USB_DEV_ISE_OFFSET:
    case USB_DEV_EPMAP0_OFFSET:
    case USB_DEV_EPMAP1_OFFSET:
    case USB_DEV_FMAP_OFFSET:
    case USB_DEV_FCFG_OFFSET:
    case USB_DMA_TFN_OFFSET:
    case USB_DMA_CPS0_OFFSET:
    case USB_DMA_CPS1_OFFSET:
    case USB_DMA_CPS2_OFFSET:
    case USB_DMA_CPS3_OFFSET:
    case USB_DMA_CPS4_OFFSET:
    case USB_DEV_FMAP2_OFFSET:
    case USB_DEV_FCFG2_OFFSET:
    case USB_DEV_FMAP3_OFFSET:
    case USB_DEV_FCFG3_OFFSET:
    case USB_DEV_FMAP4_OFFSET:
    case USB_DEV_FCFG4_OFFSET:
    case USB_VDMA_CTRL_OFFSET:
    case USB_LPM_CAP_OFFSET:
        s->regs[offset / 4] = val;
        break;
    case USB_PORTSC_OFFSET:
        s->regs[offset / 4] &= ~(val & (USB_CONN_CHG | USB_PO_EN_CHG));
        s->regs[offset / 4] |= val & ~(USB_CONN_CHG | USB_PO_EN_CHG);
        break;
    case USB_OTG_CSR_OFFSET:
        s->regs[offset / 4] &= ~((uint32_t)USB_A_BUS_REQ_HOV |
                                 USB_A_BUS_DROP_HOV);
        s->regs[offset / 4] |= val & (USB_A_BUS_REQ_HOV | USB_A_BUS_DROP_HOV);
        s->regs[offset / 4] |= USB_A_SESS_VLD | USB_VBUS_VLD_HOV |
                               (2u << USB_SPD_TYP_HOV_POV_SHIFT);
        break;
    case USB_OTG_ISR_OFFSET:
        s->regs[offset / 4] &= ~val;
        break;
    case USB_OTG_IER_OFFSET:
        s->regs[offset / 4] = val;
        break;
    case USB_DEV_CTL_OFFSET:
        s->regs[offset / 4] = val;
        if (val & USB_SFRST_HOV) {
            s->regs[USB_DEV_ADR_OFFSET / 4] = 0;
            s->regs[USB_DEV_TST_OFFSET / 4] = 0;
            s->regs[USB_DEV_SFN_OFFSET / 4] = 0;
            s->regs[USB_DEV_SMT_OFFSET / 4] = 0;
            s->regs[USB_DEV_VCTL_OFFSET / 4] = 0;
            s->regs[USB_DEV_CXCFG_OFFSET / 4] = 0;
            s->regs[USB_DEV_CXCFE_OFFSET / 4] &= ~(USB_CX_DONE | USB_CX_STL);
            bl808_usb_reset_fifo(s, -1);
            for (int i = 0; i < BL808_USB_FIFO_COUNT; i++) {
                bl808_usb_reset_fifo(s, i);
            }
            s->regs[offset / 4] &= ~USB_SFRST_HOV;
        }
        if ((s->regs[offset / 4] & USB_CHIP_EN_HOV) != 0) {
            bl808_usb_autohost_start(s);
        }
        break;
    case USB_DEV_CXCFE_OFFSET:
        if (val & USB_CX_CLR) {
            bl808_usb_reset_fifo(s, -1);
        }
        s->regs[offset / 4] &= ~(USB_CX_DONE | USB_CX_STL);
        s->regs[offset / 4] |= val & (USB_CX_DONE | USB_CX_STL);
        if (val & (USB_CX_DONE | USB_CX_STL)) {
            s->regs[USB_DEV_ISG0_OFFSET / 4] &= ~BIT(0);
            bl808_usb_reset_fifo(s, -1);
        }
        if (val & USB_CX_DONE) {
            bl808_usb_autohost_advance(s);
        }
        break;
    case USB_DEV_ISG0_OFFSET:
    case USB_DEV_ISG1_OFFSET:
    case USB_DEV_ISG3_OFFSET:
    case USB_DEV_ISG4_OFFSET:
    case USB_DEV_TXZ_OFFSET:
    case USB_DEV_RXZ_OFFSET:
        s->regs[offset / 4] &= ~val;
        break;
    case USB_DEV_ISG2_OFFSET:
        s->regs[offset / 4] &= ~val;
        if ((val & BIT(0)) != 0) {
            bl808_usb_autohost_advance(s);
        }
        break;
    case USB_DEV_FIBC0_OFFSET:
    case USB_DEV_FIBC0_OFFSET + 4:
    case USB_DEV_FIBC0_OFFSET + 8:
    case USB_DEV_FIBC0_OFFSET + 12:
        if (val & USB_FFRST0_HOV) {
            bl808_usb_reset_fifo(s, (offset - USB_DEV_FIBC0_OFFSET) / 4);
        }
        break;
    case USB_DEV_FIBC4_OFFSET:
    case USB_DEV_FIBC4_OFFSET + 4:
    case USB_DEV_FIBC4_OFFSET + 8:
    case USB_DEV_FIBC4_OFFSET + 12:
        break;
    case USB_VDMA_CXFPS1_OFFSET:
        if (s->autohost_started) {
            bl808_usb_fifo_append_word(s->cx_fifo, &s->cx_fifo_len, val);
            break;
        }
        s->regs[offset / 4] = val;
        if ((s->regs[USB_VDMA_CTRL_OFFSET / 4] & USB_VDMA_EN) &&
            (val & USB_VDMA_START_CXF)) {
            bl808_usb_vdma_run(s, -1, &s->regs[offset / 4],
                               s->regs[USB_VDMA_CXFPS2_OFFSET / 4]);
        }
        break;
    case USB_VDMA_F0PS1_OFFSET:
    case USB_VDMA_F0PS1_OFFSET + 8:
    case USB_VDMA_F0PS1_OFFSET + 16:
    case USB_VDMA_F0PS1_OFFSET + 24:
        s->regs[offset / 4] = val;
        if ((s->regs[USB_VDMA_CTRL_OFFSET / 4] & USB_VDMA_EN) &&
            (val & USB_VDMA_START_CXF)) {
            int fifo = (offset - USB_VDMA_F0PS1_OFFSET) / 8;

            bl808_usb_vdma_run(s, fifo, &s->regs[offset / 4],
                               s->regs[offset / 4 + 1]);
        }
        break;
    case USB_VDMA_FNPS1_OFFSET:
        s->regs[offset / 4] = val;
        break;
    default:
        if ((offset >= USB_DEV_INMPS1_OFFSET &&
             offset < USB_DEV_INMPS1_OFFSET + 8 * 4) ||
            (offset >= USB_DEV_OUTMPS1_OFFSET &&
             offset < USB_DEV_OUTMPS1_OFFSET + 8 * 4) ||
            (offset >= USB_VDMA_CXFPS2_OFFSET &&
             offset <= USB_VDMA_FNPS2_OFFSET + 3 * 8)) {
            s->regs[offset / 4] = val;
        } else {
            s->regs[offset / 4] = val;
        }
        break;
    }

    bl808_usb_update_irq(s);
}

static const MemoryRegionOps bl808_usb_ops = {
    .read = bl808_usb_read,
    .write = bl808_usb_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static void bl808_usb_reset(DeviceState *dev)
{
    BL808USBState *s = BL808_USB(dev);

    memset(s->regs, 0, sizeof(s->regs));
    memset(s->fifo_len, 0, sizeof(s->fifo_len));
    s->cx_fifo_len = 0;
    s->autohost_started = false;
    s->autohost_step = BL808_USB_AUTOHOST_IDLE;
    timer_del(s->loopback_timer);

    s->regs[USB_HCCAP_OFFSET / 4] = 0x01000010u;
    s->regs[USB_HCSPARAMS_OFFSET / 4] = 0x1u;
    s->regs[USB_HCCPARAMS_OFFSET / 4] = 0x6u;
    s->regs[USBSTS_OFFSET / 4] = USB_HCHALTED;
    s->regs[USB_PORTSC_OFFSET / 4] = USB_CONN_STS | USB_PO_EN;
    s->regs[USB_OTG_CSR_OFFSET / 4] =
        USB_A_SESS_VLD | USB_VBUS_VLD_HOV |
        (2u << USB_SPD_TYP_HOV_POV_SHIFT);
    s->regs[USB_REVISION_OFFSET / 4] = 0x00010000u;
    s->regs[USB_FEATURE_OFFSET / 4] =
        (0x10u << 0) | (4u << 5) | (5u << 10);
    s->regs[USB_DEV_CTL_OFFSET / 4] = USB_CHIP_EN_HOV | USB_HS_EN_HOV;
    s->regs[USB_DEV_MIGR_OFFSET / 4] = 0x1fu;
    s->regs[USB_DEV_MISG0_OFFSET / 4] = 0xffffffffu;
    s->regs[USB_DEV_MISG1_OFFSET / 4] = 0xffffffffu;
    s->regs[USB_DEV_MISG2_OFFSET / 4] = 0xffffffffu;
    s->regs[USB_DEV_MISG3_OFFSET / 4] = 0xffffffffu;
    s->regs[USB_DEV_MISG4_OFFSET / 4] = 0xffffffffu;
    s->regs[USB_VDMA_CTRL_OFFSET / 4] = USB_VDMA_EN;
    bl808_usb_update_irq(s);
}

static void bl808_usb_init(Object *obj)
{
    BL808USBState *s = BL808_USB(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    memory_region_init_io(&s->iomem, obj, &bl808_usb_ops, s,
                          TYPE_BL808_USB, BL808_USB_REG_SIZE);
    sysbus_init_mmio(sbd, &s->iomem);
    sysbus_init_irq(sbd, &s->irq);
    s->loopback_timer = timer_new_ms(QEMU_CLOCK_VIRTUAL,
                                     bl808_usb_loopback_timer, s);
}

static void bl808_usb_finalize(Object *obj)
{
    BL808USBState *s = BL808_USB(obj);

    timer_free(s->loopback_timer);
}

static void bl808_usb_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    device_class_set_legacy_reset(dc, bl808_usb_reset);
}

static const TypeInfo bl808_usb_info = {
    .name = TYPE_BL808_USB,
    .parent = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(BL808USBState),
    .instance_init = bl808_usb_init,
    .instance_finalize = bl808_usb_finalize,
    .class_init = bl808_usb_class_init,
};

static void bl808_usb_register_types(void)
{
    type_register_static(&bl808_usb_info);
}

type_init(bl808_usb_register_types)
