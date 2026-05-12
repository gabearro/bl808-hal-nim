/*
 * BL808 IPC (Inter-Processor Communication) mailbox device
 *
 * Each IPC instance exposes the BL808 two-bank register block:
 *   +0x00 CPU1_ISWR   - signal this mailbox
 *   +0x24 CPU0_IRSRR  - receive raw pending status
 *   +0x28 CPU0_ICR    - receive clear
 *   +0x2C CPU0_IUSR   - receive unmask
 *   +0x3C CPU0_ISR    - receive masked pending status
 * The older single-bank names are retained as aliases in the model.
 *
 * Three instances on the BL808:
 *   IPC0 at 0x2000A800 -- M0's mailbox (receives from LP and D0)
 *   IPC1 at 0x2000A840 -- LP's mailbox (receives from M0 and D0)
 *   IPC2 at 0x30005000 -- D0's mailbox (receives from M0 and LP)
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_MISC_BL808_IPC_H
#define HW_MISC_BL808_IPC_H

#include <stdbool.h>

#include "hw/sysbus.h"
#include "qom/object.h"

#define TYPE_BL808_IPC "bl808-ipc"
OBJECT_DECLARE_SIMPLE_TYPE(BL808IPCState, BL808_IPC)

struct BL808IPCState {
    /*< private >*/
    SysBusDevice parent_obj;

    /*< public >*/
    MemoryRegion iomem;
    qemu_irq irq;           /* Output IRQ to the owning core */

    uint32_t pending;       /* Raw pending status across 32 channels */
    uint32_t enabled;       /* Enabled interrupt channels */
    bool clock_enabled;
    bool reset_asserted;
};

void bl808_ipc_set_clock_enabled(BL808IPCState *s, bool enabled);
void bl808_ipc_set_reset_asserted(BL808IPCState *s, bool asserted);

#endif /* HW_MISC_BL808_IPC_H */
