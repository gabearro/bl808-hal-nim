/*
 * Bouffalo Lab BL808 EMAC (Ethernet MAC) emulation
 *
 * 10/100 Mbps Ethernet MAC with buffer descriptor rings and MDIO PHY.
 * Register-compatible with the BL808 EMAC at 0x20070000.
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "hw/sysbus.h"
#include "hw/irq.h"
#include "hw/net/mii.h"
#include "hw/qdev-properties.h"
#include "hw/net/bl808_emac.h"
#include "net/net.h"
#include "exec/cpu-common.h"

/* ========================================================================= */
/* Register offsets                                                           */
/* ========================================================================= */

#define REG_MODE            0x00
#define REG_INT_SRC         0x04
#define REG_INT_MASK        0x08
#define REG_IPGT            0x0C
#define REG_PKT_LEN         0x18
#define REG_COLL_CONFIG     0x1C
#define REG_TX_BD_BASE      0x20
#define REG_FLOW_CTRL       0x24
#define REG_MII_MODE        0x28
#define REG_MII_CMD         0x2C
#define REG_MII_ADDR        0x30
#define REG_MII_TX_DATA     0x34
#define REG_MII_RX_DATA     0x38
#define REG_MII_STATUS      0x3C
#define REG_MAC_ADDR0       0x40
#define REG_MAC_ADDR1       0x44
#define REG_HASH0           0x48
#define REG_HASH1           0x4C
#define REG_TX_CTRL         0x50
#define REG_RX_CTRL         0x54

/* Mode register bits */
#define MODE_RX_EN          (1 << 0)
#define MODE_TX_EN          (1 << 1)

/* Interrupt bits */
#define INT_TX_B            (1 << 0)
#define INT_TX_E            (1 << 1)
#define INT_RX_B            (1 << 2)
#define INT_RX_E            (1 << 3)
#define INT_BUSY            (1 << 4)

/* MII command bits */
#define MII_CMD_READ        (1 << 1)
#define MII_CMD_WRITE       (1 << 2)

/* MII status bits */
#define MII_STATUS_BUSY     (1 << 1)

/* BD status bits (TX) */
#define TX_BD_READY         (1 << 15)
#define TX_BD_IRQ           (1 << 14)
#define TX_BD_WRAP          (1 << 13)
#define TX_BD_LEN_SHIFT     16
#define TX_BD_LEN_MASK      0xFFFF0000U

/* BD status bits (RX) */
#define RX_BD_EMPTY         (1 << 15)
#define RX_BD_IRQ           (1 << 14)
#define RX_BD_WRAP          (1 << 13)
#define RX_BD_LEN_SHIFT     16
#define RX_BD_LEN_MASK      0xFFFF0000U

/* IP101G PHY IDs */
#define IP101G_PHYID1       0x0243
#define IP101G_PHYID2       0x0C54

/* ========================================================================= */
/* IRQ update                                                                 */
/* ========================================================================= */

static void bl808_emac_update_irq(BL808EmacState *s)
{
    /* INT_MASK uses 1 = masked, 0 = unmasked. */
    qemu_set_irq(s->irq, (s->int_src & ~s->int_mask & 0x7f) != 0);
}

static uint32_t bl808_emac_num_tx(const BL808EmacState *s)
{
    return MIN(s->tx_bd_num & 0xff, BL808_EMAC_MAX_BD);
}

static uint32_t bl808_emac_num_rx(const BL808EmacState *s)
{
    return BL808_EMAC_MAX_BD - bl808_emac_num_tx(s);
}

static uint32_t bl808_emac_rx_start(const BL808EmacState *s)
{
    return bl808_emac_num_tx(s);
}

static uint32_t bl808_emac_next_tx_idx(const BL808EmacState *s, uint32_t idx,
                                       uint32_t status)
{
    uint32_t num_tx_bd = bl808_emac_num_tx(s);

    if (num_tx_bd == 0) {
        return 0;
    }
    if ((status & TX_BD_WRAP) || idx + 1 >= num_tx_bd) {
        return 0;
    }
    return idx + 1;
}

static uint32_t bl808_emac_next_rx_idx(const BL808EmacState *s, uint32_t idx,
                                       uint32_t status)
{
    uint32_t rx_start = bl808_emac_rx_start(s);
    uint32_t rx_end = BL808_EMAC_MAX_BD;

    if (rx_start >= rx_end) {
        return rx_start;
    }
    if ((status & RX_BD_WRAP) || idx + 1 >= rx_end) {
        return rx_start;
    }
    return idx + 1;
}

static uint32_t bl808_emac_tx_bd_num_reg(const BL808EmacState *s)
{
    uint32_t tx_ptr = MIN(s->tx_bd_idx, 0x7fU);
    uint32_t rx_ptr = MIN(s->rx_bd_idx, 0x7fU);

    return (rx_ptr << 24) | (tx_ptr << 16) | (bl808_emac_num_tx(s) & 0xff);
}

static bool bl808_emac_phy_enabled(const BL808EmacState *s)
{
    uint16_t bmcr = s->phy_regs[MII_BMCR];

    return (bmcr & (MII_BMCR_PDOWN | MII_BMCR_ISOLATE)) == 0;
}

static bool bl808_emac_link_is_up(const BL808EmacState *s)
{
    NetClientState *nc;

    if (!s->phy_attached || !s->nic || !bl808_emac_phy_enabled(s)) {
        return false;
    }

    nc = qemu_get_queue(s->nic);
    return nc && nc->peer && !nc->link_down;
}

static void bl808_emac_phy_update_link(BL808EmacState *s)
{
    uint16_t bmsr;

    if (!s->phy_attached) {
        return;
    }

    bmsr = s->phy_regs[MII_BMSR] & ~(MII_BMSR_LINK_ST | MII_BMSR_AN_COMP);
    if (bl808_emac_link_is_up(s)) {
        bmsr |= MII_BMSR_LINK_ST;
        if (s->phy_regs[MII_BMCR] & MII_BMCR_AUTOEN) {
            bmsr |= MII_BMSR_AN_COMP;
        }
    }
    s->phy_regs[MII_BMSR] = bmsr;
}

/* ========================================================================= */
/* MDIO PHY (IP101G stub)                                                     */
/* ========================================================================= */

static void bl808_emac_phy_reset(BL808EmacState *s)
{
    memset(s->phy_regs, 0, sizeof(s->phy_regs));
    s->phy_regs[MII_BMCR] = MII_BMCR_AUTOEN | MII_BMCR_SPEED100 |
                            MII_BMCR_FD;
    s->phy_regs[MII_BMSR] = MII_BMSR_100TX_FD | MII_BMSR_100TX_HD |
                            MII_BMSR_10T_FD | MII_BMSR_10T_HD |
                            MII_BMSR_MFPS | MII_BMSR_AUTONEG |
                            MII_BMSR_EXTCAP;
    s->phy_regs[MII_PHYID1] = IP101G_PHYID1;
    s->phy_regs[MII_PHYID2] = IP101G_PHYID2;
    s->phy_regs[MII_ANAR] = MII_ANAR_PAUSE_ASYM | MII_ANAR_PAUSE |
                            MII_ANAR_TXFD | MII_ANAR_TX |
                            MII_ANAR_10FD | MII_ANAR_10 |
                            MII_ANAR_CSMACD;
    s->phy_regs[MII_ANLPAR] = MII_ANLPAR_ACK | MII_ANLPAR_PAUSEASY |
                              MII_ANLPAR_PAUSE | MII_ANLPAR_TXFD |
                              MII_ANLPAR_TX | MII_ANLPAR_10FD |
                              MII_ANLPAR_10 | MII_ANLPAR_CSMACD;
    s->phy_regs[MII_ANER] = MII_ANER_NWAY;
    bl808_emac_phy_update_link(s);
}

static void bl808_emac_mdio_command(BL808EmacState *s)
{
    uint32_t phy_addr = (s->mii_addr >> 8) & 0x1F;
    uint32_t reg_addr = s->mii_addr & 0x1F;

    s->mii_rx_data = 0xFFFF;

    if (!s->phy_attached || phy_addr != s->phy_addr ||
        reg_addr >= ARRAY_SIZE(s->phy_regs)) {
        goto done;
    }

    bl808_emac_phy_update_link(s);

    if (s->mii_cmd & MII_CMD_READ) {
        s->mii_rx_data = s->phy_regs[reg_addr];
    } else if (s->mii_cmd & MII_CMD_WRITE) {
        if (reg_addr != MII_BMSR && reg_addr != MII_PHYID1 &&
            reg_addr != MII_PHYID2 && reg_addr != MII_ANLPAR &&
            reg_addr != MII_ANER) {
            s->phy_regs[reg_addr] = s->mii_tx_data & 0xFFFF;
            if (reg_addr == MII_BMCR &&
                (s->mii_tx_data & MII_BMCR_RESET)) {
                bl808_emac_phy_reset(s);
            } else if (reg_addr == MII_BMCR) {
                bl808_emac_phy_update_link(s);
            }
        }
    }

done:
    /* Clear busy immediately (no real delay in QEMU) */
    s->mii_status &= ~MII_STATUS_BUSY;
    s->mii_cmd = 0;
}

/* ========================================================================= */
/* TX processing                                                              */
/* ========================================================================= */

static void bl808_emac_do_tx(BL808EmacState *s)
{
    uint32_t num_tx_bd = bl808_emac_num_tx(s);
    uint8_t pkt_buf[2048];

    if (!(s->mode & MODE_TX_EN)) {
        return;
    }

    if (num_tx_bd == 0 || num_tx_bd > BL808_EMAC_MAX_BD) {
        return;
    }

    /*
     * Scan TX BDs starting from current index. Process all ready BDs
     * in one pass, then stop.
     */
    for (uint32_t count = 0; count < num_tx_bd; count++) {
        uint32_t idx = s->tx_bd_idx;
        uint32_t status = s->bd[idx * 2];
        uint32_t addr = s->bd[idx * 2 + 1];

        if (!(status & TX_BD_READY)) {
            break;
        }

        uint32_t len = (status & TX_BD_LEN_MASK) >> TX_BD_LEN_SHIFT;
        if (len > sizeof(pkt_buf)) {
            len = sizeof(pkt_buf);
        }

        /* DMA: read packet from guest memory when a PHY link is present. */
        if (len > 0 && bl808_emac_link_is_up(s)) {
            cpu_physical_memory_read(addr, pkt_buf, len);
            qemu_send_packet(qemu_get_queue(s->nic), pkt_buf, len);
        }

        /* Clear ready bit */
        status &= ~TX_BD_READY;
        s->bd[idx * 2] = status;

        /* Raise interrupt if requested */
        if (status & TX_BD_IRQ) {
            s->int_src |= INT_TX_B;
        }

        /* Advance to next BD */
        s->tx_bd_idx = bl808_emac_next_tx_idx(s, idx, status);
    }

    bl808_emac_update_irq(s);
}

/* ========================================================================= */
/* RX (called by QEMU net backend)                                            */
/* ========================================================================= */

static bool bl808_emac_can_receive(NetClientState *nc)
{
    BL808EmacState *s = qemu_get_nic_opaque(nc);

    if (!(s->mode & MODE_RX_EN) || !bl808_emac_link_is_up(s)) {
        return false;
    }

    /* Check if the current RX BD is empty. */
    uint32_t num_rx_bd = bl808_emac_num_rx(s);
    if (num_rx_bd == 0 || num_rx_bd > BL808_EMAC_MAX_BD) {
        return false;
    }

    uint32_t status = s->bd[s->rx_bd_idx * 2];
    return (status & RX_BD_EMPTY) != 0;
}

static ssize_t bl808_emac_receive(NetClientState *nc, const uint8_t *buf,
                                  size_t size)
{
    BL808EmacState *s = qemu_get_nic_opaque(nc);

    if (!(s->mode & MODE_RX_EN) || !bl808_emac_link_is_up(s)) {
        return size;
    }

    uint32_t num_rx_bd = bl808_emac_num_rx(s);
    if (num_rx_bd == 0 || num_rx_bd > BL808_EMAC_MAX_BD) {
        return -1;
    }

    uint32_t idx = s->rx_bd_idx;
    uint32_t status = s->bd[idx * 2];
    uint32_t addr = s->bd[idx * 2 + 1];

    if (!(status & RX_BD_EMPTY)) {
        /* No empty BD available */
        s->int_src |= INT_BUSY;
        bl808_emac_update_irq(s);
        return 0;
    }

    /* DMA: write packet into guest memory */
    cpu_physical_memory_write(addr, buf, size);

    /* Update BD: set length, clear empty bit */
    status = (status & 0x0000FFFF) & ~RX_BD_EMPTY;
    status |= ((uint32_t)size << RX_BD_LEN_SHIFT);
    s->bd[idx * 2] = status;

    /* Raise interrupt if requested */
    if (status & RX_BD_IRQ) {
        s->int_src |= INT_RX_B;
    }

    /* Advance to next RX BD */
    s->rx_bd_idx = bl808_emac_next_rx_idx(s, idx, status);

    bl808_emac_update_irq(s);
    return size;
}

/* ========================================================================= */
/* Register read/write                                                        */
/* ========================================================================= */

static uint64_t bl808_emac_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808EmacState *s = opaque;

    if (offset >= BL808_EMAC_BD_OFF &&
        offset < BL808_EMAC_BD_OFF + BL808_EMAC_BD_AREA_SIZE) {
        uint32_t bd_off = (offset - BL808_EMAC_BD_OFF) / 4;
        if (bd_off < BL808_EMAC_MAX_BD * 2) {
            return s->bd[bd_off];
        }
        return 0;
    }

    switch (offset) {
    case REG_MODE:          return s->mode;
    case REG_INT_SRC:       return s->int_src;
    case REG_INT_MASK:      return s->int_mask;
    case REG_IPGT:          return s->ipgt;
    case REG_PKT_LEN:       return s->pkt_len;
    case REG_COLL_CONFIG:   return s->coll_config;
    case REG_TX_BD_BASE:    return bl808_emac_tx_bd_num_reg(s);
    case REG_FLOW_CTRL:     return s->flow_ctrl;
    case REG_MII_MODE:      return s->mii_mode;
    case REG_MII_CMD:       return s->mii_cmd;
    case REG_MII_ADDR:      return s->mii_addr;
    case REG_MII_TX_DATA:   return s->mii_tx_data;
    case REG_MII_RX_DATA:   return s->mii_rx_data;
    case REG_MII_STATUS:    return s->mii_status;
    case REG_MAC_ADDR0:     return s->mac_addr0;
    case REG_MAC_ADDR1:     return s->mac_addr1;
    case REG_HASH0:         return s->hash0;
    case REG_HASH1:         return s->hash1;
    case REG_TX_CTRL:       return s->tx_ctrl;
    case REG_RX_CTRL:       return s->rx_ctrl;
    default:
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_emac: read from unknown register 0x%03"
                      HWADDR_PRIx "\n", offset);
        return 0;
    }
}

static void bl808_emac_write(void *opaque, hwaddr offset, uint64_t value,
                             unsigned size)
{
    BL808EmacState *s = opaque;

    if (offset >= BL808_EMAC_BD_OFF &&
        offset < BL808_EMAC_BD_OFF + BL808_EMAC_BD_AREA_SIZE) {
        uint32_t bd_off = (offset - BL808_EMAC_BD_OFF) / 4;
        if (bd_off < BL808_EMAC_MAX_BD * 2) {
            uint32_t desc = bd_off / 2;

            s->bd[bd_off] = (uint32_t)value;
            /*
             * Only TX descriptors live in [0, TXBDNUM). If a TX status word is
             * marked ready, kick the transmit engine.
             */
            if ((bd_off & 1) == 0 && desc < bl808_emac_num_tx(s) &&
                (value & TX_BD_READY)) {
                bl808_emac_do_tx(s);
            }
        }
        return;
    }

    switch (offset) {
    case REG_MODE:
    {
        uint32_t old_mode = s->mode;
        s->mode = (uint32_t)value;
        /* If TxEn transitions 0->1, trigger TX processing */
        if (!(old_mode & MODE_TX_EN) && (s->mode & MODE_TX_EN)) {
            bl808_emac_do_tx(s);
        }
        /* If RxEn transitions 0->1, flush queued packets */
        if (!(old_mode & MODE_RX_EN) && (s->mode & MODE_RX_EN)) {
            if (bl808_emac_link_is_up(s)) {
                qemu_flush_queued_packets(qemu_get_queue(s->nic));
            }
        }
        break;
    }
    case REG_INT_SRC:
        /* Write-1-to-clear */
        s->int_src &= ~(uint32_t)value;
        bl808_emac_update_irq(s);
        break;
    case REG_INT_MASK:
        s->int_mask = (uint32_t)value;
        bl808_emac_update_irq(s);
        break;
    case REG_IPGT:
        s->ipgt = (uint32_t)value;
        break;
    case REG_PKT_LEN:
        s->pkt_len = (uint32_t)value;
        break;
    case REG_COLL_CONFIG:
        s->coll_config = (uint32_t)value;
        break;
    case REG_TX_BD_BASE:
        s->tx_bd_num = MIN((uint32_t)value & 0xff, BL808_EMAC_MAX_BD);
        s->tx_bd_idx = MIN(s->tx_bd_idx, MAX(bl808_emac_num_tx(s), 1U) - 1);
        s->rx_bd_idx = bl808_emac_rx_start(s);
        if (s->mode & MODE_TX_EN) {
            bl808_emac_do_tx(s);
        }
        break;
    case REG_FLOW_CTRL:
        s->flow_ctrl = (uint32_t)value;
        break;
    case REG_MII_MODE:
        s->mii_mode = (uint32_t)value;
        break;
    case REG_MII_CMD:
        s->mii_cmd = (uint32_t)value;
        if (value & (MII_CMD_READ | MII_CMD_WRITE)) {
            bl808_emac_mdio_command(s);
        }
        break;
    case REG_MII_ADDR:
        s->mii_addr = (uint32_t)value;
        break;
    case REG_MII_TX_DATA:
        s->mii_tx_data = (uint32_t)value & 0xFFFF;
        break;
    case REG_MAC_ADDR0:
        s->mac_addr0 = (uint32_t)value;
        break;
    case REG_MAC_ADDR1:
        s->mac_addr1 = (uint32_t)value;
        break;
    case REG_HASH0:
        s->hash0 = (uint32_t)value;
        break;
    case REG_HASH1:
        s->hash1 = (uint32_t)value;
        break;
    case REG_TX_CTRL:
        s->tx_ctrl = (uint32_t)value;
        break;
    case REG_RX_CTRL:
        s->rx_ctrl = (uint32_t)value;
        break;
    /* Read-only registers */
    case REG_MII_RX_DATA:
    case REG_MII_STATUS:
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_emac: write to read-only register 0x%03"
                      HWADDR_PRIx "\n", offset);
        break;
    default:
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_emac: write to unknown register 0x%03"
                      HWADDR_PRIx " = 0x%" PRIx64 "\n", offset, value);
        break;
    }
}

static const MemoryRegionOps bl808_emac_ops = {
    .read = bl808_emac_read,
    .write = bl808_emac_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

/* ========================================================================= */
/* Device lifecycle                                                           */
/* ========================================================================= */

static void bl808_emac_reset(DeviceState *dev)
{
    BL808EmacState *s = BL808_EMAC(dev);

    s->mode = 0;
    s->int_src = 0;
    s->int_mask = 0x7f;
    s->ipgt = 0x18;
    s->pkt_len = 0x00400600;
    s->coll_config = 0;
    s->tx_bd_num = 0x40;
    s->flow_ctrl = 0;
    s->mii_mode = 0;
    s->mii_cmd = 0;
    s->mii_addr = 0;
    s->mii_tx_data = 0;
    s->mii_rx_data = 0;
    s->mii_status = 0;
    s->mac_addr0 = 0;
    s->mac_addr1 = 0;
    s->hash0 = 0;
    s->hash1 = 0;
    s->tx_ctrl = 0;
    s->rx_ctrl = 0;

    s->mode = (1 << 15) | (1 << 13) | (1 << 3);
    memset(s->bd, 0, sizeof(s->bd));
    s->tx_bd_idx = 0;
    s->rx_bd_idx = bl808_emac_rx_start(s);

    bl808_emac_phy_reset(s);
    bl808_emac_update_irq(s);
}

static void bl808_emac_link_status_changed(NetClientState *nc)
{
    BL808EmacState *s = qemu_get_nic_opaque(nc);

    bl808_emac_phy_update_link(s);
    if ((s->mode & MODE_RX_EN) && bl808_emac_link_is_up(s)) {
        qemu_flush_queued_packets(nc);
    }
}

static NetClientInfo net_bl808_emac_info = {
    .type = NET_CLIENT_DRIVER_NIC,
    .size = sizeof(NICState),
    .can_receive = bl808_emac_can_receive,
    .receive = bl808_emac_receive,
    .link_status_changed = bl808_emac_link_status_changed,
};

static void bl808_emac_init(Object *obj)
{
    BL808EmacState *s = BL808_EMAC(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    memory_region_init_io(&s->iomem, obj, &bl808_emac_ops, s,
                          TYPE_BL808_EMAC, BL808_EMAC_REG_SIZE);
    sysbus_init_mmio(sbd, &s->iomem);
    sysbus_init_irq(sbd, &s->irq);
}

static void bl808_emac_realize(DeviceState *dev, Error **errp)
{
    BL808EmacState *s = BL808_EMAC(dev);

    qemu_macaddr_default_if_unset(&s->conf.macaddr);
    s->phy_addr &= 0x1f;

    s->nic = qemu_new_nic(&net_bl808_emac_info, &s->conf,
                           object_get_typename(OBJECT(dev)), dev->id,
                           &dev->mem_reentrancy_guard, s);
    qemu_format_nic_info_str(qemu_get_queue(s->nic), s->conf.macaddr.a);
    bl808_emac_phy_update_link(s);
}

static const Property bl808_emac_properties[] = {
    DEFINE_PROP_BOOL("phy-attached", BL808EmacState, phy_attached, false),
    DEFINE_PROP_UINT8("phy-addr", BL808EmacState, phy_addr, 0),
    DEFINE_NIC_PROPERTIES(BL808EmacState, conf),
};

static void bl808_emac_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    dc->realize = bl808_emac_realize;
    device_class_set_legacy_reset(dc, bl808_emac_reset);
    device_class_set_props(dc, bl808_emac_properties);
}

static const TypeInfo bl808_emac_info = {
    .name          = TYPE_BL808_EMAC,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(BL808EmacState),
    .instance_init = bl808_emac_init,
    .class_init    = bl808_emac_class_init,
};

static void bl808_emac_register_types(void)
{
    type_register_static(&bl808_emac_info);
}

type_init(bl808_emac_register_types)
