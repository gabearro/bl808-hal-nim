/*
 * Low-volume WPA connect trace for the BL808 vendor firmware path.
 *
 * The broad WiFi trace wrapper is useful for MAC timing work, but it emits
 * enough traffic to perturb scans.  This file only traces EAPOL handoff points
 * during station connect and intentionally avoids printing key material.
 */

#include <stdint.h>

#include <bl_os_adapter/bl_os_system.h>

extern uint8_t ke_state_get(uint16_t id);
extern uint8_t rxu_cntrl_env[];
#ifdef BL808_WIFI_CONNECT_TRACE_RAW_RX
extern uint8_t rxl_cntrl_env[];
#endif
extern uint8_t sta_info_tab[];
extern void *wpa_cbs;

#ifdef BL808_WIFI_CONNECT_TRACE_RAW_RX
void __real_rxl_cntrl_evt(void);
#endif
void __real_mm_active(void);
void __real_mm_hw_info_set(void *mac_addr);
uint8_t __real_mm_sec_machwaddr_wr(uint8_t sta_idx, uintptr_t key_slot);
void __real_txl_frame_push(void *frame, uint8_t ac);
void __real_txl_frame_push_force(void *frame, uint8_t ac);
void __real_txl_frame_cfm(void *frame);
void __real_txl_cfm_push(void *desc, uint32_t status, uint32_t ac);
void __real_txu_cntrl_push(void *desc, uint8_t ac);
uint8_t __real_txl_cntrl_push(void *desc, uint8_t ac);
unsigned long __real_rxu_cntrl_frame_handle(void *param);
void __real_sm_handle_eapol_input(uint8_t sta_idx, void *src_addr,
                                  void *eapol_buf, uint32_t eapol_len);
int __real_wpa_sm_rx_eapol(uint8_t *src_addr, uint8_t *buf, uint32_t len);
uint32_t hal_machw_search_addr(void *addr, uint32_t idx);

static void trace_mac(const uint8_t *mac)
{
    bl_os_printf("%02X:%02X:%02X:%02X:%02X:%02X",
                 mac ? mac[0] : 0, mac ? mac[1] : 0, mac ? mac[2] : 0,
                 mac ? mac[3] : 0, mac ? mac[4] : 0, mac ? mac[5] : 0);
}

static uint16_t trace_be16(const uint8_t *buf)
{
    return ((uint16_t)buf[0] << 8) | (uint16_t)buf[1];
}

static int trace_addr_ok(uintptr_t addr, uintptr_t len)
{
    uintptr_t end = addr + len;

    if (!addr || end < addr) {
        return 0;
    }
    if (addr >= 0x22020000u && end <= 0x22058000u) {
        return 1;
    }
    if (addr >= 0x62020000u && end <= 0x62058000u) {
        return 1;
    }
    return 0;
}

static uint32_t trace_reg32(uint32_t addr)
{
    return *(volatile uint32_t *)addr;
}

static void trace_hw_regs(const char *tag)
{
    bl_os_printf("[WIFI-HW] %s own0=0x%08lX own1=0x%08lX ownmask=0x%08lX bss0=0x%08lX bss1=0x%08lX rx=0x%08lX state=0x%08lX status=0x%08lX doze=0x%08lX sec=0x%08lX cmd=0x%08lX\r\n",
                 tag,
                 (unsigned long)trace_reg32(0x24B00010u),
                 (unsigned long)trace_reg32(0x24B00014u),
                 (unsigned long)trace_reg32(0x24B0001Cu),
                 (unsigned long)trace_reg32(0x24B00020u),
                 (unsigned long)trace_reg32(0x24B00024u),
                 (unsigned long)trace_reg32(0x24B00060u),
                 (unsigned long)trace_reg32(0x24B00038u),
                 (unsigned long)trace_reg32(0x24B0004Cu),
                 (unsigned long)trace_reg32(0x24B00054u),
                 (unsigned long)trace_reg32(0x24B000D8u),
                 (unsigned long)trace_reg32(0x24B000C4u));
}

static uint8_t trace_load8(uintptr_t addr)
{
    return trace_addr_ok(addr, 1u) ? *(uint8_t *)addr : 0;
}

static uint16_t trace_load16(uintptr_t addr)
{
    if (!trace_addr_ok(addr, 2u)) {
        return 0;
    }
    return (uint16_t)trace_load8(addr) | ((uint16_t)trace_load8(addr + 1u) << 8);
}

static uint32_t trace_load32(uintptr_t addr)
{
    return trace_addr_ok(addr, 4u) ? *(uint32_t *)addr : 0;
}

static void trace_store32(uintptr_t addr, uint32_t value)
{
    if (trace_addr_ok(addr, 4u)) {
        *(uint32_t *)addr = value;
    }
}

static uint8_t trace_machdr_len(uint16_t fc)
{
    uint8_t len = 24;

    if ((fc & 0x0300u) == 0x0300u) {
        len += 6;
    }
    if ((fc & 0x0080u) != 0) {
        len += 2;
    }
    return len;
}

static uint8_t trace_is_eapol_proto(uint16_t proto)
{
    return proto == 0x8E88u || proto == 0x888Eu;
}

static void trace_tx_eapol_desc(const char *tag, void *frame, uint8_t ac,
                                uint32_t status, uint8_t has_status)
{
    uintptr_t desc = (uintptr_t)frame;
    uint16_t proto;
    uintptr_t cb;
    uintptr_t policy;
    uintptr_t link;
    uintptr_t hw;
    uintptr_t txctl;
    uintptr_t thd;
    uint16_t fc = 0u;
    uint8_t hdr_len = 0u;
    uint16_t eth_type = 0u;
    static uint32_t eapol_count;

    if (eapol_count >= 48u || !trace_addr_ok(desc, 116u)) {
        return;
    }

    proto = trace_load16(desc + 32u);
    if (!trace_is_eapol_proto(proto)) {
        return;
    }

    cb = trace_load32(desc + 8u);
    policy = trace_load32(desc + 88u);
    link = trace_load32(desc + 108u);
    hw = trace_load32(desc + 112u);
    txctl = trace_load32(hw + 40u);
    thd = trace_load32(hw + 20u);
    if (!trace_addr_ok(thd, 24u) && trace_addr_ok(link + 348u, 24u)) {
        thd = link + 348u;
    }
    if (trace_addr_ok(thd, 24u)) {
        fc = trace_load16(thd);
        hdr_len = trace_machdr_len(fc);
        if (trace_addr_ok(thd + hdr_len + 8u, 2u)) {
            eth_type = trace_load16(thd + hdr_len + 6u);
        }
    }

    bl_os_printf("[WIFI-EAPOL] %s n=%lu ac=%u sta=%u vif=%u info=%u len=%u proto=0x%04X hdr=%u qos=%u sec=%u status=0x%08lX ack=%u cb=0x%08lX pol=0x%08lX desc=0x%08lX link=0x%08lX hw=0x%08lX ctl=0x%08lX\r\n",
                 tag, (unsigned long)eapol_count, ac,
                 trace_load8(desc + 46u), trace_load8(desc + 47u),
                 trace_load8(desc + 49u), trace_load16(desc + 12u), proto,
                 trace_load8(desc + 98u), trace_load8(desc + 99u),
                 trace_load8(desc + 100u), (unsigned long)status,
                 (has_status && (status & 0x00800000u)) ? 1u : 0u,
                 (unsigned long)cb, (unsigned long)policy,
                 (unsigned long)desc, (unsigned long)link, (unsigned long)hw,
                 (unsigned long)txctl);

    if (trace_addr_ok(thd, 34u)) {
        bl_os_printf("[WIFI-EAPOLHDR] %s n=%lu fc=0x%04X hdr=%u et=0x%04X snap0=0x%08lX snap1=0x%08lX a1=",
                     tag, (unsigned long)eapol_count, fc, hdr_len, eth_type,
                     (unsigned long)trace_load32(thd + 24u),
                     (unsigned long)trace_load32(thd + 28u));
        trace_mac((const uint8_t *)thd + 4u);
        bl_os_printf(" a2=");
        trace_mac((const uint8_t *)thd + 10u);
        bl_os_printf(" a3=");
        trace_mac((const uint8_t *)thd + 16u);
        bl_os_printf("\r\n");
    }

    if (trace_addr_ok(hw + 72u, 4u)) {
        bl_os_printf("[WIFI-EAPOLHW] %s n=%lu hw0=0x%08lX/0x%08lX hw1=0x%08lX/0x%08lX hw2=0x%08lX/0x%08lX hw3=0x%08lX/0x%08lX hw4=0x%08lX/0x%08lX\r\n",
                     tag, (unsigned long)eapol_count,
                     (unsigned long)trace_load32(hw + 4u),
                     (unsigned long)trace_load32(hw + 8u),
                     (unsigned long)trace_load32(hw + 12u),
                     (unsigned long)trace_load32(hw + 16u),
                     (unsigned long)trace_load32(hw + 28u),
                     (unsigned long)trace_load32(hw + 36u),
                     (unsigned long)trace_load32(hw + 40u),
                     (unsigned long)trace_load32(hw + 56u),
                     (unsigned long)trace_load32(hw + 60u),
                     (unsigned long)trace_load32(hw + 64u));
    }

    if (trace_addr_ok(link + 312u, 4u)) {
        bl_os_printf("[WIFI-EAPOLLINK] %s n=%lu l0=0x%08lX/0x%08lX l1=0x%08lX/0x%08lX b0=0x%08lX/0x%08lX b1=0x%08lX/0x%08lX p0=0x%08lX/0x%08lX p1=0x%08lX/0x%08lX p2=0x%08lX/0x%08lX p3=0x%08lX/0x%08lX p4=0x%08lX/0x%08lX p5=0x%08lX/0x%08lX\r\n",
                     tag, (unsigned long)eapol_count,
                     (unsigned long)trace_load32(link + 72u),
                     (unsigned long)trace_load32(link + 76u),
                     (unsigned long)trace_load32(link + 80u),
                     (unsigned long)trace_load32(link + 84u),
                     (unsigned long)trace_load32(link + 92u),
                     (unsigned long)trace_load32(link + 96u),
                     (unsigned long)trace_load32(link + 100u),
                     (unsigned long)trace_load32(link + 104u),
                     (unsigned long)trace_load32(link + 256u),
                     (unsigned long)trace_load32(link + 260u),
                     (unsigned long)trace_load32(link + 264u),
                     (unsigned long)trace_load32(link + 268u),
                     (unsigned long)trace_load32(link + 272u),
                     (unsigned long)trace_load32(link + 276u),
                     (unsigned long)trace_load32(link + 280u),
                     (unsigned long)trace_load32(link + 284u),
                     (unsigned long)trace_load32(link + 288u),
                     (unsigned long)trace_load32(link + 292u),
                     (unsigned long)trace_load32(link + 296u),
                     (unsigned long)trace_load32(link + 300u));
    }

    eapol_count++;
}

static void trace_tx_assoc_ies(uintptr_t thd, uint32_t frame_len, uint8_t hdr_len)
{
    uintptr_t body = thd + hdr_len;
    uintptr_t pos = body + 4u;
    uintptr_t end;
    uint16_t cap;
    uint16_t listen;
    uint8_t ssid_len = 0xffu;
    uint8_t rates_len = 0u;
    uint8_t ext_rates_len = 0u;
    uint8_t rsn_len = 0u;
    uint8_t wpa_len = 0u;
    uint8_t ht_cap_len = 0u;
    uint8_t ht_op_len = 0u;
    uint8_t vendor_count = 0u;
    uint8_t malformed = 0u;
    uint8_t ids[12];
    uint8_t ids_count = 0u;
    static uint32_t assoc_ie_count;

    if (assoc_ie_count >= 8u || frame_len < (uint32_t)(hdr_len + 4u)) {
        return;
    }
    if (!trace_addr_ok(body, 4u)) {
        return;
    }

    end = thd + frame_len;
    cap = trace_load16(body);
    listen = trace_load16(body + 2u);

    while (pos + 2u <= end && trace_addr_ok(pos, 2u)) {
        uint8_t id = trace_load8(pos);
        uint8_t len = trace_load8(pos + 1u);
        uintptr_t data = pos + 2u;

        if (ids_count < (uint8_t)(sizeof(ids) / sizeof(ids[0]))) {
            ids[ids_count++] = id;
        }
        if (data + len > end || !trace_addr_ok(data, len)) {
            malformed = 1u;
            break;
        }

        switch (id) {
        case 0:
            ssid_len = len;
            break;
        case 1:
            rates_len = len;
            break;
        case 45:
            ht_cap_len = len;
            break;
        case 48:
            rsn_len = len;
            break;
        case 50:
            ext_rates_len = len;
            break;
        case 61:
            ht_op_len = len;
            break;
        case 221:
            vendor_count++;
            if (len >= 4u &&
                trace_load8(data) == 0x00u &&
                trace_load8(data + 1u) == 0x50u &&
                trace_load8(data + 2u) == 0xF2u &&
                trace_load8(data + 3u) == 0x01u) {
                wpa_len = len;
            }
            break;
        default:
            break;
        }

        pos = data + len;
    }
    if (pos != end) {
        malformed = 1u;
    }

    bl_os_printf("[WIFI-TXIE] assoc n=%lu len=%lu body=%lu cap=0x%04X listen=%u ssid=%u rates=%u ext=%u rsn=%u wpa=%u htcap=%u htop=%u vendor=%u bad=%u ids=",
                 (unsigned long)assoc_ie_count, (unsigned long)frame_len,
                 (unsigned long)(frame_len - hdr_len), cap, listen,
                 ssid_len, rates_len, ext_rates_len, rsn_len, wpa_len,
                 ht_cap_len, ht_op_len, vendor_count, malformed);
    for (uint8_t i = 0; i < ids_count; i++) {
        bl_os_printf("%s%u", i == 0 ? "" : ",", ids[i]);
    }
    bl_os_printf("\r\n");
    assoc_ie_count++;
}

static void trace_tx_frame(const char *tag, void *frame, uint8_t ac,
                           uint32_t status, uint8_t has_status)
{
    uintptr_t desc = (uintptr_t)frame;
    uintptr_t link = trace_load32(desc + 108u);
    uintptr_t hw = trace_load32(desc + 112u);
    uintptr_t txctl = trace_load32(hw + 40u);
    uintptr_t thd = trace_load32(hw + 20u);
    uint16_t fc;
    uint8_t type;
    uint8_t subtype;
    uint32_t rate = trace_load32(txctl + 20u);
    uint32_t tx_power = trace_load32(txctl + 36u);
    uint32_t hw_flags = trace_load32(hw + 60u);
    uint32_t hw_status = trace_load32(hw + 64u);
    uint32_t hw_len = trace_load32(hw + 28u);
    uint32_t frame_len = hw_len >= 4u ? hw_len - 4u : 0u;
    uint8_t hdr_len;
    uint16_t eth_type = 0u;
    uint8_t trace_mgmt;
    uint8_t trace_eapol;
    static uint32_t tx_count;
    static uint32_t raw_count;

    if (!trace_addr_ok(desc, 116u)) {
        return;
    }
    if (!trace_addr_ok(thd, 24u) && trace_addr_ok(link + 348u, 24u)) {
        thd = link + 348u;
    }
    if (!trace_addr_ok(thd, 24u)) {
        return;
    }

    fc = trace_load16(thd);
    type = (uint8_t)((fc >> 2) & 0x0003u);
    subtype = (uint8_t)((fc >> 4) & 0x000fu);
    hdr_len = trace_machdr_len(fc);
    if (type == 2u && trace_addr_ok(thd + hdr_len + 8u, 2u)) {
        eth_type = trace_load16(thd + hdr_len + 6u);
    }
    trace_mgmt = (type == 0u && (subtype == 0u || subtype == 1u ||
                                 subtype == 11u || subtype == 12u));
    trace_eapol = (type == 2u && trace_is_eapol_proto(eth_type));
    if (!trace_mgmt && !trace_eapol) {
        return;
    }
    if (tx_count >= 48u) {
        return;
    }

    bl_os_printf("[WIFI-TX] %s n=%lu ac=%u fc=0x%04X type=%u sub=%u et=0x%04X status=0x%08lX ack=%u rate=0x%08lX pwr=0x%08lX hwf=0x%08lX hws=0x%08lX desc=0x%08lX hw=0x%08lX ctl=0x%08lX a1=",
                 tag, (unsigned long)tx_count, ac, fc, type, subtype,
                 eth_type,
                 (unsigned long)status,
                 (has_status && (status & 0x00800000u)) ? 1u : 0u,
                 (unsigned long)rate, (unsigned long)tx_power,
                 (unsigned long)hw_flags, (unsigned long)hw_status,
                 (unsigned long)desc, (unsigned long)hw,
                 (unsigned long)txctl);
    trace_mac((const uint8_t *)thd + 4u);
    bl_os_printf(" a2=");
    trace_mac((const uint8_t *)thd + 10u);
    bl_os_printf(" a3=");
    trace_mac((const uint8_t *)thd + 16u);
    bl_os_printf("\r\n");
    if (raw_count < 24u && trace_addr_ok(hw + 72u, 4u) &&
        trace_addr_ok(txctl + 40u, 4u)) {
        bl_os_printf("[WIFI-TXRAW] %s n=%lu sub=%u hw0=0x%08lX/0x%08lX hw1=0x%08lX/0x%08lX hw2=0x%08lX/0x%08lX hw3=0x%08lX/0x%08lX pol0=0x%08lX/0x%08lX pol1=0x%08lX/0x%08lX pol2=0x%08lX/0x%08lX\r\n",
                     tag, (unsigned long)raw_count, subtype,
                     (unsigned long)trace_load32(hw + 24u),
                     (unsigned long)trace_load32(hw + 28u),
                     (unsigned long)trace_load32(hw + 36u),
                     (unsigned long)trace_load32(hw + 40u),
                     (unsigned long)trace_load32(hw + 56u),
                     (unsigned long)trace_load32(hw + 60u),
                     (unsigned long)trace_load32(hw + 64u),
                     (unsigned long)trace_load32(hw + 72u),
                     (unsigned long)trace_load32(txctl + 0u),
                     (unsigned long)trace_load32(txctl + 4u),
                     (unsigned long)trace_load32(txctl + 16u),
                     (unsigned long)trace_load32(txctl + 20u),
                     (unsigned long)trace_load32(txctl + 32u),
                     (unsigned long)trace_load32(txctl + 36u));
        raw_count++;
    }
    if (!has_status && trace_mgmt && subtype == 0u) {
        trace_tx_assoc_ies(thd, frame_len, hdr_len);
    }
    tx_count++;
}

static void trace_rxl_frame(const char *tag, uintptr_t desc)
{
    uintptr_t swdesc = trace_load32(desc + 4u);
    uint32_t hw_flags = trace_load32(swdesc + 64u);
    uint16_t len = trace_load16(swdesc + 28u);
    uintptr_t buf_chain = trace_load32(swdesc + 8u);
    uintptr_t payload_addr = trace_load32(buf_chain + 8u);
    uint16_t fc;
    uint8_t hdr_len;
    uint8_t type;
    uint8_t subtype;
    uint8_t retry;
    uint16_t eth_type = 0u;
    uint16_t body0 = 0u;
    uint16_t body1 = 0u;
    uint16_t body2 = 0u;
    static uint32_t rxl_count;

    if (rxl_count >= 96u || !trace_addr_ok(payload_addr, 24u)) {
        return;
    }

    fc = trace_load16(payload_addr);
    hdr_len = trace_machdr_len(fc);
    type = (uint8_t)((fc >> 2) & 0x0003u);
    subtype = (uint8_t)((fc >> 4) & 0x000fu);
    retry = (uint8_t)((fc & 0x0800u) != 0);
    if (len >= (uint16_t)(hdr_len + 8u)) {
        eth_type = trace_load16(payload_addr + hdr_len + 6u);
    }
    if (type == 0u && len >= (uint16_t)(hdr_len + 6u)) {
        body0 = trace_load16(payload_addr + hdr_len);
        body1 = trace_load16(payload_addr + hdr_len + 2u);
        body2 = trace_load16(payload_addr + hdr_len + 4u);
    }

    if (type != 2u &&
        !(type == 0u && (subtype == 1u || subtype == 11u ||
                         subtype == 12u || retry))) {
        return;
    }

    bl_os_printf("[WIFI-RXL] %s n=%lu state=%u fc=0x%04X type=%u sub=%u retry=%u hw=0x%08lX len=%u hdr=%u et=0x%04X b0=0x%04X b1=0x%04X b2=0x%04X desc=0x%08lX sw=0x%08lX a1=",
                 tag, (unsigned long)rxl_count, ke_state_get(4), fc, type,
                 subtype, retry, (unsigned long)hw_flags, len, hdr_len,
                 eth_type, body0, body1, body2, (unsigned long)desc,
                 (unsigned long)swdesc);
    trace_mac((const uint8_t *)payload_addr + 4u);
    bl_os_printf(" a2=");
    trace_mac((const uint8_t *)payload_addr + 10u);
    bl_os_printf(" a3=");
    trace_mac((const uint8_t *)payload_addr + 16u);
    bl_os_printf("\r\n");
    rxl_count++;
}

#ifdef BL808_WIFI_CONNECT_TRACE_RAW_RX
void __wrap_rxl_cntrl_evt(void)
{
    uintptr_t node = trace_load32((uintptr_t)&rxl_cntrl_env[0]);
    uint8_t i = 0u;

    while (i < 8u && trace_addr_ok(node, 8u)) {
        trace_rxl_frame("pre", node);
        node = trace_load32(node);
        i++;
    }
    __real_rxl_cntrl_evt();
}
#endif

#if defined(BL808_WIFI_FORCE_TX_POWER) || defined(BL808_WIFI_FORCE_TX_RATE)
static void trace_force_tx_vector(void *frame)
{
    uintptr_t desc = (uintptr_t)frame;
    uintptr_t link = trace_load32(desc + 108u);
    uintptr_t hw = trace_load32(desc + 112u);
    uintptr_t txctl = trace_load32(hw + 40u);
    uintptr_t thd = trace_load32(hw + 20u);
    uint16_t fc;
    uint8_t type;

    if (!trace_addr_ok(desc, 116u)) {
        return;
    }
    if (!trace_addr_ok(thd, 24u) && trace_addr_ok(link + 348u, 24u)) {
        thd = link + 348u;
    }
    if (!trace_addr_ok(thd, 24u) || !trace_addr_ok(txctl, 40u)) {
        return;
    }

    fc = trace_load16(thd);
    type = (uint8_t)((fc >> 2) & 0x0003u);
    if (type != 0u) {
        return;
    }

#ifdef BL808_WIFI_FORCE_TX_RATE
    trace_store32(txctl + 20u, (uint32_t)BL808_WIFI_FORCE_TX_RATE);
#endif
#ifdef BL808_WIFI_FORCE_TX_POWER
    trace_store32(txctl + 36u, (uint32_t)BL808_WIFI_FORCE_TX_POWER);
#endif
}
#endif

void __wrap_mm_active(void)
{
    uint32_t bss0 = trace_reg32(0x24B00020u);
    uint32_t bss1 = trace_reg32(0x24B00024u);
    static uint32_t active_log_count;
    uint8_t log_regs = (active_log_count < 2u || bss0 != 0u || bss1 != 0u);

    if (log_regs) {
        trace_hw_regs("before-active");
    }
    __real_mm_active();
    if (log_regs) {
        trace_hw_regs("after-active");
        active_log_count++;
    }
}

void __wrap_mm_hw_info_set(void *mac_addr)
{
    bl_os_printf("[WIFI-HW] mm_hw_info_set mac=");
    trace_mac((const uint8_t *)mac_addr);
    bl_os_printf("\r\n");
    trace_hw_regs("before-hwinfo");
    __real_mm_hw_info_set(mac_addr);
    trace_hw_regs("after-hwinfo");
}

uint8_t __wrap_mm_sec_machwaddr_wr(uint8_t sta_idx, uintptr_t key_slot)
{
    uint8_t ret;
    uint32_t found = 0xffu;
    uint8_t *sta = sta_info_tab + (uintptr_t)sta_idx * 368u;

    bl_os_printf("[WIFI-HW] mm_sec_machwaddr_wr sta=%u key=%lu mac=",
                 sta_idx, (unsigned long)key_slot);
    if (trace_addr_ok((uintptr_t)sta + 4u, 6u)) {
        trace_mac(sta + 4u);
    } else {
        trace_mac(0);
    }
    bl_os_printf("\r\n");
    trace_hw_regs("before-staaddr");
    ret = __real_mm_sec_machwaddr_wr(sta_idx, key_slot);
    if (trace_addr_ok((uintptr_t)sta + 4u, 6u)) {
        found = hal_machw_search_addr(sta + 4u, 0);
    }
    trace_hw_regs("after-staaddr");
    bl_os_printf("[WIFI-HW] mm_sec_machwaddr_wr ret=%u search=%lu\r\n",
                 ret, (unsigned long)found);
    return ret;
}

void __wrap_txl_frame_push(void *frame, uint8_t ac)
{
#if defined(BL808_WIFI_FORCE_TX_POWER) || defined(BL808_WIFI_FORCE_TX_RATE)
    trace_force_tx_vector(frame);
#endif
    trace_tx_frame("push", frame, ac, 0, 0);
    __real_txl_frame_push(frame, ac);
}

void __wrap_txl_frame_push_force(void *frame, uint8_t ac)
{
#if defined(BL808_WIFI_FORCE_TX_POWER) || defined(BL808_WIFI_FORCE_TX_RATE)
    trace_force_tx_vector(frame);
#endif
    trace_tx_frame("push_force", frame, ac, 0, 0);
    __real_txl_frame_push_force(frame, ac);
}

void __wrap_txl_frame_cfm(void *frame)
{
    uintptr_t desc = (uintptr_t)frame;
    uintptr_t hw = trace_load32(desc + 112u);
    uint32_t status = trace_load32(hw + 64u);

    trace_tx_frame("frame_cfm", frame, 0xffu, status, 1);
    __real_txl_frame_cfm(frame);
}

void __wrap_txl_cfm_push(void *desc, uint32_t status, uint32_t ac)
{
    trace_tx_eapol_desc("cfm", desc, (uint8_t)ac, status, 1);
    trace_tx_frame("cfm", desc, (uint8_t)ac, status, 1);
    __real_txl_cfm_push(desc, status, ac);
}

void __wrap_txu_cntrl_push(void *desc, uint8_t ac)
{
    trace_tx_eapol_desc("txu-pre", desc, ac, 0, 0);
    __real_txu_cntrl_push(desc, ac);
}

uint8_t __wrap_txl_cntrl_push(void *desc, uint8_t ac)
{
    uint8_t ret;

    trace_tx_eapol_desc("txl-pre", desc, ac, 0, 0);
    ret = __real_txl_cntrl_push(desc, ac);
    trace_tx_eapol_desc("txl-post", desc, ac, 0, 0);
    return ret;
}

unsigned long __wrap_rxu_cntrl_frame_handle(void *param)
{
    uint32_t swdesc = 0;
    uint32_t hw_flags = 0;
    uint32_t buf_chain = 0;
    uintptr_t payload_addr = 0;
    uint16_t fc = 0;
    uint16_t len = 0;
    uint16_t eth_type = 0;
    uint8_t hdr_len = 0;
    uint8_t type = 0;
    uint8_t subtype = 0;
    uint8_t retry = 0;
    uint16_t body0 = 0;
    uint16_t body1 = 0;
    uint16_t body2 = 0;
    unsigned long ret;
    static uint32_t rx_count;

    if (param) {
        swdesc = trace_load32((uintptr_t)param + 4u);
        if (swdesc) {
            hw_flags = trace_load32((uintptr_t)swdesc + 64u);
            len = trace_load16((uintptr_t)swdesc + 28u);
            buf_chain = trace_load32((uintptr_t)swdesc + 8u);
            if (buf_chain) {
                payload_addr = trace_load32((uintptr_t)buf_chain + 8u);
                if (trace_addr_ok(payload_addr, 24u)) {
                    fc = trace_load16(payload_addr);
                    hdr_len = trace_machdr_len(fc);
                    type = (uint8_t)((fc >> 2) & 0x0003u);
                    subtype = (uint8_t)((fc >> 4) & 0x000fu);
                    retry = (uint8_t)((fc & 0x0800u) != 0);
                    if (len >= (uint16_t)(hdr_len + 8u)) {
                        eth_type = trace_load16(payload_addr + hdr_len + 6u);
                    }
                    if (type == 0u && len >= (uint16_t)(hdr_len + 6u)) {
                        body0 = trace_load16(payload_addr + hdr_len);
                        body1 = trace_load16(payload_addr + hdr_len + 2u);
                        body2 = trace_load16(payload_addr + hdr_len + 4u);
                    }
                }
            }
        }
    }

    ret = __real_rxu_cntrl_frame_handle(param);

    if (rx_count < 64u &&
        ((type == 0u && (subtype == 1u || subtype == 11u || retry)) ||
         type == 2u)) {
        bl_os_printf("[WIFI-RX] n=%lu ret=%lu state=%u fc=0x%04X sub=%u retry=%u hw=0x%08lX len=%u et=0x%04X b0=0x%04X b1=0x%04X b2=0x%04X sta=%u vif=%u own0=0x%08lX own1=0x%08lX mask=0x%08lX bss0=0x%08lX bss1=0x%08lX rx=0x%08lX a1=",
                     (unsigned long)rx_count, ret, ke_state_get(4), fc,
                     subtype, retry, (unsigned long)hw_flags, len, eth_type,
                     body0, body1, body2,
                     rxu_cntrl_env[9], rxu_cntrl_env[10],
                     (unsigned long)trace_reg32(0x24B00010u),
                     (unsigned long)trace_reg32(0x24B00014u),
                     (unsigned long)trace_reg32(0x24B0001Cu),
                     (unsigned long)trace_reg32(0x24B00020u),
                     (unsigned long)trace_reg32(0x24B00024u),
                     (unsigned long)trace_reg32(0x24B00060u));
        trace_mac((const uint8_t *)payload_addr + 4u);
        bl_os_printf(" a2=");
        trace_mac((const uint8_t *)payload_addr + 10u);
        bl_os_printf(" a3=");
        trace_mac((const uint8_t *)payload_addr + 16u);
        bl_os_printf("\r\n");
        rx_count++;
    }

    return ret;
}

void __wrap_sm_handle_eapol_input(uint8_t sta_idx, void *src_addr,
                                  void *eapol_buf, uint32_t eapol_len)
{
    const uint8_t *src = (const uint8_t *)src_addr;
    const uint8_t *eapol = (const uint8_t *)eapol_buf;
    void *rx_cb = NULL;

    if (wpa_cbs) {
        rx_cb = ((void **)wpa_cbs)[5];
    }

    bl_os_printf("[WPA-TRACE] sm_eapol sta=%u state=%u cb=%p len=%lu src=",
                 sta_idx, ke_state_get(4), rx_cb, (unsigned long)eapol_len);
    trace_mac(src);
    if (eapol && eapol_len >= 4) {
        bl_os_printf(" hdr=%02X:%02X:%02X:%02X",
                     eapol[0], eapol[1], eapol[2], eapol[3]);
    }
    if (eapol && eapol_len >= 8) {
        bl_os_printf(" key_info=0x%04X", trace_be16(eapol + 5));
    }
    bl_os_printf("\r\n");

    __real_sm_handle_eapol_input(sta_idx, src_addr, eapol_buf, eapol_len);
}

int __wrap_wpa_sm_rx_eapol(uint8_t *src_addr, uint8_t *buf, uint32_t len)
{
    int ret;

    bl_os_printf("[WPA-TRACE] wpa_rx len=%lu src=", (unsigned long)len);
    trace_mac(src_addr);
    if (buf && len >= 4) {
        bl_os_printf(" hdr=%02X:%02X:%02X:%02X",
                     buf[0], buf[1], buf[2], buf[3]);
    }
    if (buf && len >= 8) {
        bl_os_printf(" key_info=0x%04X", trace_be16(buf + 5));
    }
    bl_os_printf("\r\n");

    ret = __real_wpa_sm_rx_eapol(src_addr, buf, len);
    bl_os_printf("[WPA-TRACE] wpa_rx ret=%d\r\n", ret);
    return ret;
}
