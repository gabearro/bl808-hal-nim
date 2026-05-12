/*
 * Bouffalo Lab BL808 EMAC (Ethernet MAC) emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_NET_BL808_EMAC_H
#define HW_NET_BL808_EMAC_H

#include "hw/sysbus.h"
#include "net/net.h"
#include "qom/object.h"

#define TYPE_BL808_EMAC "bl808-emac"

typedef struct BL808EmacState BL808EmacState;
OBJECT_DECLARE_SIMPLE_TYPE(BL808EmacState, BL808_EMAC)

/* Register block size: 0x800 (control regs + BD region) */
#define BL808_EMAC_REG_SIZE     0x800

/* TX and RX share a single 128-descriptor pool at 0x400. */
#define BL808_EMAC_MAX_BD       128
#define BL808_EMAC_BD_SIZE      8   /* 2 words per BD */

/* Shared BD area: offset 0x400, 128 BDs * 8 bytes = 0x400 bytes */
#define BL808_EMAC_BD_OFF       0x400
#define BL808_EMAC_BD_AREA_SIZE 0x400

struct BL808EmacState {
    /*< private >*/
    SysBusDevice parent_obj;

    /*< public >*/
    MemoryRegion iomem;
    qemu_irq irq;
    NICState *nic;
    NICConf conf;

    /* Control registers */
    uint32_t mode;          /* 0x00 */
    uint32_t int_src;       /* 0x04 */
    uint32_t int_mask;      /* 0x08 */
    uint32_t ipgt;          /* 0x0C */
    uint32_t pkt_len;       /* 0x18 */
    uint32_t coll_config;   /* 0x1C */
    uint32_t tx_bd_num;     /* 0x20 - TXBDNUM, TXBDPTR, RXBDPTR */
    uint32_t flow_ctrl;     /* 0x24 */
    uint32_t mii_mode;      /* 0x28 */
    uint32_t mii_cmd;       /* 0x2C */
    uint32_t mii_addr;      /* 0x30 */
    uint32_t mii_tx_data;   /* 0x34 */
    uint32_t mii_rx_data;   /* 0x38 */
    uint32_t mii_status;    /* 0x3C */
    uint32_t mac_addr0;     /* 0x40 */
    uint32_t mac_addr1;     /* 0x44 */
    uint32_t hash0;         /* 0x48 */
    uint32_t hash1;         /* 0x4C */
    uint32_t tx_ctrl;       /* 0x50 */
    uint32_t rx_ctrl;       /* 0x54 */

    /* Shared buffer descriptor pool (stored as raw words) */
    uint32_t bd[BL808_EMAC_MAX_BD * 2];

    /* Absolute indices into the shared 128-BD pool */
    uint32_t tx_bd_idx;
    uint32_t rx_bd_idx;

    /* MDIO PHY registers (IP101G stub) */
    uint16_t phy_regs[32];
    uint8_t phy_addr;
    bool phy_attached;
};

#endif /* HW_NET_BL808_EMAC_H */
