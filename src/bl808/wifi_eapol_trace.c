#include <stdint.h>
#include <bl_os_adapter/bl_os_system.h>

struct wifi_pkt_trace {
    uint32_t pkt[4];
    void *pbuf[4];
    uint16_t len[4];
};

extern uint8_t ke_state_get(uint16_t id);

extern uint8_t sta_info_tab[];
extern uint8_t vif_info_tab[];
extern uint8_t sm_env[];
extern uint8_t rxu_cntrl_env[];
extern uint8_t txl_frame_env[];
extern uint8_t txl_cntrl_env[];
extern uint32_t txl_buffer_control_24G[];
extern void *wpa_cbs;
extern int bl_wifi_clock_enable(void);
volatile uint32_t bl808_wifi_trace_rx_all;
static uint32_t trace_forced_old_clk;
static uint32_t trace_forced_count;
static uint32_t trace_forced_ack_old_bcn;
static uint32_t trace_forced_ack_count;
static uint32_t trace_forced_mac_old_lo;
static uint32_t trace_forced_mac_old_hi;
static uint32_t trace_forced_mac_old_mask;
static uint32_t trace_forced_mac_count;
static uint32_t trace_forced_rx_old;
static uint32_t trace_forced_rx_count;

void __real_mm_hw_info_set(void *mac_addr);
uint8_t __real_mm_sec_machwaddr_wr(uint8_t sta_idx, uint8_t key_slot);
uint32_t hal_machw_search_addr(void *addr, uint32_t idx);
void __real_mm_active(void);
void __real_sm_handle_eapol_input(uint8_t sta_idx, void *src_addr,
                                  void *eapol_buf, uint32_t eapol_len);
int __real_tcpip_stack_input(void *swdesc, uint8_t status, void *hwhdr,
                             unsigned int msdu_offset, void *pkt,
                             uint8_t extra_status);
unsigned long __real_rxu_cntrl_frame_handle(void *param);
void __real_rxu_swdesc_upload_evt(void);
void __real_txl_frame_push(void *frame, uint8_t ac);
void __real_txl_frame_push_force(void *frame, uint8_t ac);
void __real_txl_frame_cfm(void *frame);
void __real_txl_frame_evt(void);
void __real_txl_transmit_trigger(void);
void __real_txl_cfm_push(void *desc, uint32_t status, uint32_t ac);

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

static uint16_t trace_read16(const void *ptr)
{
    const uint8_t *p = (const uint8_t *)ptr;

    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t trace_reg32(uintptr_t addr)
{
    return *(volatile uint32_t *)addr;
}

static void trace_write32(uintptr_t addr, uint32_t val)
{
    *(volatile uint32_t *)addr = val;
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
    if (addr >= 0x40000000u && end <= 0x40004000u) {
        return 1;
    }
    if (addr >= 0x58000000u && end <= 0x58100000u) {
        return 1;
    }
    return 0;
}

static uint8_t trace_load8(uintptr_t addr)
{
    return trace_addr_ok(addr, 1u) ? *(uint8_t *)addr : 0;
}

static uint16_t trace_load16(uintptr_t addr)
{
    return trace_addr_ok(addr, 2u) ? trace_read16((void *)addr) : 0;
}

static uint32_t trace_load32(uintptr_t addr)
{
    return trace_addr_ok(addr, 4u) ? *(uint32_t *)addr : 0;
}

static void trace_print_mac(const uint8_t *mac)
{
    bl_os_printf("%02X:%02X:%02X:%02X:%02X:%02X",
                 mac ? mac[0] : 0, mac ? mac[1] : 0, mac ? mac[2] : 0,
                 mac ? mac[3] : 0, mac ? mac[4] : 0, mac ? mac[5] : 0);
}

static uint8_t trace_specific_mac(uintptr_t addr)
{
    uint8_t any = 0;

    if (!trace_addr_ok(addr, 6u) || (trace_load8(addr) & 1u) != 0u) {
        return 0;
    }
    for (uint32_t i = 0; i < 6u; i++) {
        any |= trace_load8(addr + i);
    }
    return any != 0u;
}

static uint8_t trace_mac_equal(uintptr_t a, uintptr_t b)
{
    if (!trace_addr_ok(a, 6u) || !trace_addr_ok(b, 6u)) {
        return 0;
    }
    for (uint32_t i = 0; i < 6u; i++) {
        if (trace_load8(a + i) != trace_load8(b + i)) {
            return 0;
        }
    }
    return 1;
}

static uint8_t trace_mac_equal_bytes(uintptr_t a, const uint8_t *b)
{
    if (!trace_addr_ok(a, 6u) || !b) {
        return 0;
    }
    for (uint32_t i = 0; i < 6u; i++) {
        if (trace_load8(a + i) != b[i]) {
            return 0;
        }
    }
    return 1;
}

static uint32_t trace_rescale_field(uint32_t raw, uint32_t shift,
                                    uint32_t width, uint32_t old_clk,
                                    uint32_t new_clk)
{
    uint32_t mask = (1u << width) - 1u;
    uint32_t field = (raw >> shift) & mask;
    uint32_t scaled = old_clk ? ((field * new_clk) / old_clk) : field;

    if (scaled > mask) {
        scaled = mask;
    }
    return (raw & ~(mask << shift)) | ((scaled & mask) << shift);
}

static void trace_force_mac_timing_80mhz(void)
{
    const uint32_t old_clk = trace_reg32(0x24B000E4u) & 0xffu;
    const uint32_t new_clk = 80u;
    uint32_t r;

    return;

    if (old_clk == 0u || old_clk == new_clk) {
        return;
    }
    trace_forced_old_clk = old_clk;
    trace_forced_count++;

    r = trace_reg32(0x24B000E4u);
    r = (r & 0xffffff00u) | new_clk;
    r = trace_rescale_field(r, 8u, 10u, old_clk, new_clk);
    r = (r & 0xf003ffffu) | 0x02200000u;
    trace_write32(0x24B000E4u, r);

    r = trace_reg32(0x24B000E8u);
    r = trace_rescale_field(r, 8u, 16u, old_clk, new_clk);
    trace_write32(0x24B000E8u, r);

    r = trace_reg32(0x24B000ECu);
    r = (r & 0xc00fffffu) | 0x02700000u;
    r = trace_rescale_field(r, 10u, 10u, old_clk, new_clk);
    r = (r & 0xfffffc00u) | 180u;
    trace_write32(0x24B000ECu, r);

    r = trace_reg32(0x24B000F0u);
    r = (r & ~0x03u) | 0x01u;
    trace_write32(0x24B000F0u, r);

    r = trace_reg32(0x24B000F4u);
    r = trace_rescale_field(r, 8u, 16u, old_clk, new_clk);
    trace_write32(0x24B000F4u, r);

    r = trace_reg32(0x24B000F8u);
    r = trace_rescale_field(r, 8u, 16u, old_clk, new_clk);
    trace_write32(0x24B000F8u, r);

    r = trace_reg32(0x24B00104u);
    r = trace_rescale_field(r, 20u, 10u, old_clk, new_clk);
    r = trace_rescale_field(r, 10u, 10u, old_clk, new_clk);
    r = trace_rescale_field(r, 0u, 10u, old_clk, new_clk);
    trace_write32(0x24B00104u, r);

    bl_os_printf("[TRACE] forced_mac_timing old=%lu new=%lu\r\n",
                 (unsigned long)old_clk, (unsigned long)new_clk);
}

static void trace_force_mac_ack_mode(void)
{
    uint32_t ctrl = trace_reg32(0x24B00400u);
    uint32_t pti = trace_reg32(0x24B00404u);
    uint32_t pta = trace_reg32(0x24920404u);

    return;

    if (ctrl == 0x00000F49u && pti == 0xFFFFFFFFu &&
        pta == 0x50000013u) {
        return;
    }
    trace_forced_ack_old_bcn = ctrl;
    trace_forced_ack_count++;
    trace_write32(0x24920428u, 0x00000000u);
    trace_write32(0x24920404u, 0x50000013u);
    trace_write32(0x24B00400u, 0x00000F48u);
    trace_write32(0x24B00404u, 0xFFFFFFFFu);
    trace_write32(0x24B00400u, 0x00000F49u);
    bl_os_printf("[TRACE] forced_ack_mode ctrl=0x%08lX pti=0x%08lX pta=0x%08lX\r\n",
                 (unsigned long)ctrl, (unsigned long)pti,
                 (unsigned long)pta);
}

static uint32_t trace_pack_mac_low(const uint8_t *mac)
{
    return (uint32_t)mac[0] | ((uint32_t)mac[1] << 8) |
           ((uint32_t)mac[2] << 16) | ((uint32_t)mac[3] << 24);
}

static uint32_t trace_pack_mac_high(const uint8_t *mac)
{
    return (uint32_t)mac[4] | ((uint32_t)mac[5] << 8);
}

static void trace_force_own_mac(const uint8_t *mac)
{
    const uint32_t want_mask = 0x100u;
    uint32_t lo;
    uint32_t hi;
    uint32_t old_lo;
    uint32_t old_hi;
    uint32_t old_mask;

    if (!mac || !trace_specific_mac((uintptr_t)mac)) {
        return;
    }

    lo = trace_pack_mac_low(mac);
    hi = trace_pack_mac_high(mac);
    old_lo = trace_reg32(0x24B00010u);
    old_hi = trace_reg32(0x24B00014u);
    old_mask = trace_reg32(0x24B0001Cu);

    if (old_lo == lo && (old_hi & 0xffffu) == hi && old_mask == want_mask) {
        return;
    }

    trace_forced_mac_old_lo = old_lo;
    trace_forced_mac_old_hi = old_hi;
    trace_forced_mac_old_mask = old_mask;
    trace_forced_mac_count++;
    trace_write32(0x24B00010u, lo);
    trace_write32(0x24B00014u, hi);
    trace_write32(0x24B0001Cu, want_mask);
    bl_os_printf("[TRACE] forced_own_mac oldlo=0x%08lX oldhi=0x%08lX oldmask=0x%08lX newlo=0x%08lX newhi=0x%08lX newmask=0x%08lX\r\n",
                 (unsigned long)old_lo, (unsigned long)old_hi,
                 (unsigned long)old_mask, (unsigned long)lo,
                 (unsigned long)hi, (unsigned long)want_mask);
}

static void trace_force_sta_rx_filter(void)
{
    uint32_t old_rx = trace_reg32(0x24B00060u);
    uint32_t new_rx = old_rx | 0x00002000u;

    return;

    if (old_rx == new_rx) {
        return;
    }
    trace_forced_rx_old = old_rx;
    trace_forced_rx_count++;
    trace_write32(0x24B00060u, new_rx);
}

static void trace_prepare_tx_frame(void *frame)
{
    uintptr_t desc = (uintptr_t)frame;
    uintptr_t link = trace_load32(desc + 108u);
    uintptr_t hw = trace_load32(desc + 112u);
    uintptr_t thd = trace_load32(hw + 20u);
    uint16_t fc;
    uint8_t type;
    uint8_t subtype;

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
    if (type == 0u && (subtype == 0u || subtype == 2u || subtype == 11u)) {
        (void)bl_wifi_clock_enable();
        trace_force_own_mac((const uint8_t *)thd + 10u);
        trace_force_sta_rx_filter();
        trace_force_mac_ack_mode();
    }
}

static void trace_mac_regs(const char *tag)
{
    bl_os_printf("[TRACE] machw %s maclo=0x%08lX machi=0x%08lX bsslo=0x%08lX bsshi=0x%08lX mask=0x%08lX state=0x%08lX status=0x%08lX doze=0x%08lX rx=0x%08lX sec=0x%08lX\r\n",
                 tag,
                 (unsigned long)trace_reg32(0x24B00010u),
                 (unsigned long)trace_reg32(0x24B00014u),
                 (unsigned long)trace_reg32(0x24B00020u),
                 (unsigned long)trace_reg32(0x24B00024u),
                 (unsigned long)trace_reg32(0x24B0001Cu),
                 (unsigned long)trace_reg32(0x24B00038u),
                 (unsigned long)trace_reg32(0x24B0004Cu),
                 (unsigned long)trace_reg32(0x24B00054u),
                 (unsigned long)trace_reg32(0x24B00060u),
                 (unsigned long)trace_reg32(0x24B000C4u));
    bl_os_printf("[TRACE] machw_aux %s bcn0=0x%08lX bcn4=0x%08lX bcn10=0x%08lX rx9c=0x%08lX rxa0=0x%08lX\r\n",
                 tag,
                 (unsigned long)trace_reg32(0x24B00400u),
                 (unsigned long)trace_reg32(0x24B00404u),
                 (unsigned long)trace_reg32(0x24B00410u),
                 (unsigned long)trace_reg32(0x24B0009Cu),
                 (unsigned long)trace_reg32(0x24B000A0u));
    bl_os_printf("[TRACE] machw_timing0 %s e4=0x%08lX e8=0x%08lX ec=0x%08lX f0=0x%08lX f4=0x%08lX f8=0x%08lX 100=0x%08lX 104=0x%08lX\r\n",
                 tag,
                 (unsigned long)trace_reg32(0x24B000E4u),
                 (unsigned long)trace_reg32(0x24B000E8u),
                 (unsigned long)trace_reg32(0x24B000ECu),
                 (unsigned long)trace_reg32(0x24B000F0u),
                 (unsigned long)trace_reg32(0x24B000F4u),
                 (unsigned long)trace_reg32(0x24B000F8u),
                 (unsigned long)trace_reg32(0x24B00100u),
                 (unsigned long)trace_reg32(0x24B00104u));
    bl_os_printf("[TRACE] machw_timing1 %s 114=0x%08lX 150=0x%08lX 310=0x%08lX 510=0x%08lX 064=0x%08lX 0d8=0x%08lX 224=0x%08lX\r\n",
                 tag,
                 (unsigned long)trace_reg32(0x24B00114u),
                 (unsigned long)trace_reg32(0x24B00150u),
                 (unsigned long)trace_reg32(0x24B00310u),
                 (unsigned long)trace_reg32(0x24B00510u),
                 (unsigned long)trace_reg32(0x24B00064u),
                 (unsigned long)trace_reg32(0x24B000D8u),
                 (unsigned long)trace_reg32(0x24B00224u));
    bl_os_printf("[TRACE] machw_irq %s raw=0x%08lX ack=0x%08lX unmask=0x%08lX gen=0x%08lX tx78=0x%08lX trig=0x%08lX active=0x%08lX\r\n",
                 tag,
                 (unsigned long)trace_reg32(0x24B0806Cu),
                 (unsigned long)trace_reg32(0x24B08070u),
                 (unsigned long)trace_reg32(0x24B08074u),
                 (unsigned long)trace_reg32(0x24B08080u),
                 (unsigned long)trace_reg32(0x24B08078u),
                 (unsigned long)trace_reg32(0x24B0808Cu),
                 (unsigned long)trace_reg32(0x24B08050u));
    bl_os_printf("[TRACE] wifi_clk %s cfg0=0x%08lX cgen0=0x%08lX cgen1=0x%08lX cgen2=0x%08lX coex04=0x%08lX coex28=0x%08lX wpll10=0x%08lX\r\n",
                 tag,
                 (unsigned long)trace_reg32(0x200003B0u),
                 (unsigned long)trace_reg32(0x20000580u),
                 (unsigned long)trace_reg32(0x20000584u),
                 (unsigned long)trace_reg32(0x20000588u),
                 (unsigned long)trace_reg32(0x24920004u),
                 (unsigned long)trace_reg32(0x24920028u),
                 (unsigned long)trace_reg32(0x20000810u));
    bl_os_printf("[TRACE] clkrst %s r000=0x%08lX r004=0x%08lX r008=0x%08lX r00c=0x%08lX r010=0x%08lX r014=0x%08lX r018=0x%08lX r01c=0x%08lX\r\n",
                 tag,
                 (unsigned long)trace_reg32(0x30007000u),
                 (unsigned long)trace_reg32(0x30007004u),
                 (unsigned long)trace_reg32(0x30007008u),
                 (unsigned long)trace_reg32(0x3000700Cu),
                 (unsigned long)trace_reg32(0x30007010u),
                 (unsigned long)trace_reg32(0x30007014u),
                 (unsigned long)trace_reg32(0x30007018u),
                 (unsigned long)trace_reg32(0x3000701Cu));
    bl_os_printf("[TRACE] txpol_tmpl %s p0=0x%08lX p1=0x%08lX p2=0x%08lX p3=0x%08lX p4=0x%08lX p5=0x%08lX p6=0x%08lX p7=0x%08lX\r\n",
                 tag,
                 (unsigned long)txl_buffer_control_24G[0],
                 (unsigned long)txl_buffer_control_24G[1],
                 (unsigned long)txl_buffer_control_24G[2],
                 (unsigned long)txl_buffer_control_24G[3],
                 (unsigned long)txl_buffer_control_24G[4],
                 (unsigned long)txl_buffer_control_24G[5],
                 (unsigned long)txl_buffer_control_24G[6],
                 (unsigned long)txl_buffer_control_24G[7]);
}

static void trace_tx_bssid(const char *tag, uintptr_t thd, uint8_t type,
                           uint8_t subtype)
{
    uint8_t bss[6];
    uint32_t bsslo = trace_reg32(0x24B00020u);
    uint32_t bsshi = trace_reg32(0x24B00024u);
    uint8_t should_match = type == 0u &&
        (subtype == 0u || subtype == 2u || subtype == 11u);

    if (!should_match || !trace_specific_mac(thd + 16u)) {
        return;
    }
    (void)bl_wifi_clock_enable();
    trace_force_own_mac((const uint8_t *)thd + 10u);
    trace_force_mac_ack_mode();
    bss[0] = (uint8_t)bsslo;
    bss[1] = (uint8_t)(bsslo >> 8);
    bss[2] = (uint8_t)(bsslo >> 16);
    bss[3] = (uint8_t)(bsslo >> 24);
    bss[4] = (uint8_t)bsshi;
    bss[5] = (uint8_t)(bsshi >> 8);

    bl_os_printf("[TRACE] tx_bssid_%s hw=", tag);
    trace_print_mac(bss);
    bl_os_printf(" hdr=");
    trace_print_mac((const uint8_t *)thd + 16u);
    bl_os_printf(" a1eq=%u a3eq=%u\r\n",
                 trace_mac_equal_bytes(thd + 4u, bss) ? 1u : 0u,
                 trace_mac_equal_bytes(thd + 16u, bss) ? 1u : 0u);
    bl_os_printf("[TRACE] tx_timing_%s force_count=%lu oldclk=%lu ack_count=%lu ack_old=0x%08lX mac_count=%lu mac_old=0x%08lX/0x%08lX/0x%08lX rx_count=%lu rx_old=0x%08lX mac=0x%08lX/0x%08lX/0x%08lX cfg0=0x%08lX cl0=0x%08lX pta=0x%08lX pti=0x%08lX e4=0x%08lX e8=0x%08lX ec=0x%08lX f0=0x%08lX f4=0x%08lX f8=0x%08lX 100=0x%08lX 104=0x%08lX bcn0=0x%08lX st=0x%08lX rx=0x%08lX r54=0x%08lX r64=0x%08lX r9c=0x%08lX r0a0=0x%08lX r114=0x%08lX r310=0x%08lX r510=0x%08lX\r\n",
                 tag,
                 (unsigned long)trace_forced_count,
                 (unsigned long)trace_forced_old_clk,
                 (unsigned long)trace_forced_ack_count,
                 (unsigned long)trace_forced_ack_old_bcn,
                 (unsigned long)trace_forced_mac_count,
                 (unsigned long)trace_forced_mac_old_lo,
                 (unsigned long)trace_forced_mac_old_hi,
                 (unsigned long)trace_forced_mac_old_mask,
                 (unsigned long)trace_forced_rx_count,
                 (unsigned long)trace_forced_rx_old,
                 (unsigned long)trace_reg32(0x24B00010u),
                 (unsigned long)trace_reg32(0x24B00014u),
                 (unsigned long)trace_reg32(0x24B0001Cu),
                 (unsigned long)trace_reg32(0x200003B0u),
                 (unsigned long)trace_reg32(0x30007000u),
                 (unsigned long)trace_reg32(0x24920404u),
                 (unsigned long)trace_reg32(0x24B00404u),
                 (unsigned long)trace_reg32(0x24B000E4u),
                 (unsigned long)trace_reg32(0x24B000E8u),
                 (unsigned long)trace_reg32(0x24B000ECu),
                 (unsigned long)trace_reg32(0x24B000F0u),
                 (unsigned long)trace_reg32(0x24B000F4u),
                 (unsigned long)trace_reg32(0x24B000F8u),
                 (unsigned long)trace_reg32(0x24B00100u),
                 (unsigned long)trace_reg32(0x24B00104u),
                 (unsigned long)trace_reg32(0x24B00400u),
                 (unsigned long)trace_reg32(0x24B0004Cu),
                 (unsigned long)trace_reg32(0x24B00060u),
                 (unsigned long)trace_reg32(0x24B00054u),
                 (unsigned long)trace_reg32(0x24B00064u),
                 (unsigned long)trace_reg32(0x24B0009Cu),
                 (unsigned long)trace_reg32(0x24B000A0u),
                 (unsigned long)trace_reg32(0x24B00114u),
                 (unsigned long)trace_reg32(0x24B00310u),
                 (unsigned long)trace_reg32(0x24B00510u));
}

static void trace_tx_frame(const char *tag, void *frame, uint8_t ac,
                           uint32_t status, uint8_t has_status)
{
    uintptr_t desc = (uintptr_t)frame;
    uintptr_t link = trace_load32(desc + 108u);
    uintptr_t hw = trace_load32(desc + 112u);
    uintptr_t thd = trace_load32(hw + 20u);
    uint32_t hw_len0 = trace_load32(hw + 24u);
    uint32_t hw_len1 = trace_load32(hw + 28u);
    uint32_t hw_next0 = trace_load32(hw + 8u);
    uint32_t hw_next1 = trace_load32(hw + 12u);
    uint32_t hw_pbuf = trace_load32(hw + 20u);
    uint32_t hw_end = trace_load32(hw + 24u);
    uint32_t hw_pol0 = trace_load32(hw + 36u);
    uint32_t hw_polp = trace_load32(hw + 40u);
    uint32_t hw_rate = trace_load32(hw + 56u);
    uint32_t hw_ctrl = trace_load32(hw + 60u);
    uint32_t hw_status = trace_load32(hw + 64u);
    uint16_t fc;
    uint16_t seqctl;
    uint16_t seq;
    uint8_t frag;
    uint8_t type;
    uint8_t subtype;
    uint8_t retry;
    uint8_t log_it = 0;
    static uint32_t tx_count;

    if (!trace_addr_ok(desc, 116u)) {
        if (has_status && tx_count < 48u) {
            bl_os_printf("[TRACE] tx_%s n=%lu desc=%p ac=%u status=0x%08lX ack=%u invalid_desc\r\n",
                         tag, (unsigned long)tx_count, frame, ac,
                         (unsigned long)status,
                         (status & 0x00800000u) ? 1u : 0u);
            tx_count++;
        }
        return;
    }
    if (!trace_addr_ok(thd, 24u) && trace_addr_ok(link + 348u, 24u)) {
        thd = link + 348u;
    }

    fc = trace_load16(thd);
    seqctl = trace_load16(thd + 22u);
    seq = (uint16_t)(seqctl >> 4);
    frag = (uint8_t)(seqctl & 0x000fu);
    type = (uint8_t)((fc >> 2) & 0x0003u);
    subtype = (uint8_t)((fc >> 4) & 0x000fu);
    retry = (uint8_t)((fc & 0x0800u) != 0);

    if (type == 0u && (subtype == 0u || subtype == 10u ||
                       subtype == 11u || subtype == 12u ||
                       subtype == 13u || retry)) {
        log_it = 1u;
    }
    if (type == 2u || has_status) {
        log_it = 1u;
    }
    if (!log_it || tx_count >= 160u) {
        return;
    }

    bl_os_printf("[TRACE] tx_%s n=%lu desc=%p link=0x%08lX hw=0x%08lX thd=0x%08lX ac=%u fc=0x%04X type=%u sub=%u retry=%u seq=%u frag=%u len0=0x%08lX len1=0x%08lX ctrl=0x%08lX hwst=0x%08lX status=0x%08lX ack=%u a1=%02X:%02X:%02X:%02X:%02X:%02X a2=%02X:%02X:%02X:%02X:%02X:%02X a3=%02X:%02X:%02X:%02X:%02X:%02X\r\n",
                 tag, (unsigned long)tx_count, frame,
                 (unsigned long)link, (unsigned long)hw, (unsigned long)thd,
                 ac, fc, type, subtype, retry, seq, frag,
                 (unsigned long)hw_len0, (unsigned long)hw_len1,
                 (unsigned long)hw_ctrl, (unsigned long)hw_status,
                 (unsigned long)status,
                 (has_status && (status & 0x00800000u)) ? 1u : 0u,
                 trace_load8(thd + 4u), trace_load8(thd + 5u),
                 trace_load8(thd + 6u), trace_load8(thd + 7u),
                 trace_load8(thd + 8u), trace_load8(thd + 9u),
                 trace_load8(thd + 10u), trace_load8(thd + 11u),
                 trace_load8(thd + 12u), trace_load8(thd + 13u),
                 trace_load8(thd + 14u), trace_load8(thd + 15u),
                 trace_load8(thd + 16u), trace_load8(thd + 17u),
                 trace_load8(thd + 18u), trace_load8(thd + 19u),
                 trace_load8(thd + 20u), trace_load8(thd + 21u));
    bl_os_printf("[TRACE] tx_desc_%s n=%lu next0=0x%08lX next1=0x%08lX pbuf=0x%08lX end=0x%08lX hw36=0x%08lX hw40=0x%08lX hw56=0x%08lX\r\n",
                 tag, (unsigned long)tx_count,
                 (unsigned long)hw_next0, (unsigned long)hw_next1,
                 (unsigned long)hw_pbuf, (unsigned long)hw_end,
                 (unsigned long)hw_pol0, (unsigned long)hw_polp,
                 (unsigned long)hw_rate);
    trace_tx_bssid(tag, thd, type, subtype);
    if (trace_addr_ok(link + 312u, 4u)) {
        bl_os_printf("[TRACE] tx_pol_%s n=%lu p00=0x%08lX p04=0x%08lX p08=0x%08lX p0c=0x%08lX p10=0x%08lX p14=0x%08lX p18=0x%08lX p1c=0x%08lX p20=0x%08lX p24=0x%08lX p34=0x%08lX p38=0x%08lX\r\n",
                     tag, (unsigned long)tx_count,
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
                     (unsigned long)trace_load32(link + 308u),
                     (unsigned long)trace_load32(link + 312u));
    }
    tx_count++;
}

static void trace_txl_frame_evt_list(const char *tag)
{
    uintptr_t env = (uintptr_t)txl_frame_env;
    uintptr_t first = trace_load32(env + 8u);
    uintptr_t last = trace_load32(env + 12u);
    uint32_t pending = trace_load32((uintptr_t)txl_cntrl_env + 80u);
    uintptr_t node = first;
    uint32_t i = 0;
    static uint32_t empty_count;

    if (!first) {
        if ((last || pending) && empty_count < 4u) {
            bl_os_printf("[TRACE] frame_evt_%s empty last=0x%08lX pending=%lu\r\n",
                         tag, (unsigned long)last, (unsigned long)pending);
        }
        empty_count++;
        return;
    }

    if (first || last || pending) {
        bl_os_printf("[TRACE] frame_evt_%s first=0x%08lX last=0x%08lX pending=%lu\r\n",
                     tag, (unsigned long)first, (unsigned long)last,
                     (unsigned long)pending);
    }

    while (node && i < 8u && trace_addr_ok(node, 116u)) {
        uintptr_t hw = trace_load32(node + 112u);
        uint32_t status = trace_load32(hw + 64u);

        trace_tx_frame("evt", (void *)node, 0xffu, status, 1);
        node = trace_load32(node);
        i++;
    }
}

void __wrap_mm_active(void)
{
    (void)bl_wifi_clock_enable();
    trace_force_mac_timing_80mhz();
    trace_force_mac_ack_mode();
    trace_mac_regs("before_active");
    __real_mm_active();
    trace_force_mac_ack_mode();
    trace_mac_regs("after_active");
}

void __wrap_mm_hw_info_set(void *mac_addr)
{
    uint8_t *mac = (uint8_t *)mac_addr;
    uint32_t found;

    bl_os_printf("[TRACE] mm_hw_info_set mac=%02X:%02X:%02X:%02X:%02X:%02X\r\n",
                 mac ? mac[0] : 0, mac ? mac[1] : 0, mac ? mac[2] : 0,
                 mac ? mac[3] : 0, mac ? mac[4] : 0, mac ? mac[5] : 0);
    trace_mac_regs("before_hwinfo");
    __real_mm_hw_info_set(mac_addr);
    found = hal_machw_search_addr(mac_addr, 0);
    trace_mac_regs("after_hwinfo");
    bl_os_printf("[TRACE] mm_hw_info_set search=%lu\r\n",
                 (unsigned long)found);
}

uint8_t __wrap_mm_sec_machwaddr_wr(uint8_t sta_idx, uint8_t key_slot)
{
    uint8_t ret;
    uint8_t *sta = sta_info_tab + (uint32_t)sta_idx * 368u;
    uint32_t found;

    bl_os_printf("[TRACE] mm_sec_machwaddr_wr sta=%u key=%u mac=%02X:%02X:%02X:%02X:%02X:%02X\r\n",
                 sta_idx, key_slot,
                 sta[4], sta[5], sta[6], sta[7], sta[8], sta[9]);
    ret = __real_mm_sec_machwaddr_wr(sta_idx, key_slot);
    found = hal_machw_search_addr(sta + 4u, 0);
    trace_mac_regs("after_staaddr");
    bl_os_printf("[TRACE] mm_sec_machwaddr_wr ret=%u search=%lu\r\n",
                 ret, (unsigned long)found);
    return ret;
}

unsigned long __wrap_rxu_cntrl_frame_handle(void *param)
{
    uint32_t swdesc = 0;
    uint32_t hw_flags = 0;
    uint32_t buf_chain = 0;
    uint32_t payload_addr = 0;
    uint16_t fc = 0;
    uint16_t len = 0;
    uint16_t seqctl = 0;
    uint16_t seq = 0;
    uint16_t eth_type = 0;
    uint8_t hdr_len = 0;
    uint8_t frag = 0;
    uint8_t type = 0;
    uint8_t subtype = 0;
    uint8_t retry = 0;
    uint8_t *payload = 0;
    unsigned long ret;
    static uint32_t data_count;
    static uint32_t all_count;

    if (param) {
        swdesc = *(uint32_t *)((uintptr_t)param + 4u);
        if (swdesc) {
            hw_flags = *(uint32_t *)(uintptr_t)(swdesc + 64u);
            len = *(uint16_t *)(uintptr_t)(swdesc + 28u);
            buf_chain = *(uint32_t *)(uintptr_t)(swdesc + 8u);
            if (buf_chain) {
                payload_addr = *(uint32_t *)(uintptr_t)(buf_chain + 8u);
                payload = (uint8_t *)(uintptr_t)payload_addr;
                if (payload) {
                    fc = trace_read16(payload);
                    hdr_len = trace_machdr_len(fc);
                    if (len >= 24u) {
                        seqctl = trace_read16(payload + 22u);
                        seq = (uint16_t)(seqctl >> 4);
                        frag = (uint8_t)(seqctl & 0x000fu);
                    }
                    type = (uint8_t)((fc >> 2) & 0x0003u);
                    subtype = (uint8_t)((fc >> 4) & 0x000fu);
                    retry = (uint8_t)((fc & 0x0800u) != 0);
                    if (len >= (uint16_t)(hdr_len + 8u)) {
                        eth_type = trace_read16(payload + hdr_len + 6u);
                    }
                }
            }
        }
    }

    ret = __real_rxu_cntrl_frame_handle(param);

    if (bl808_wifi_trace_rx_all && all_count < 64u &&
        ((type == 0u && (subtype == 1u || subtype == 10u ||
                         subtype == 11u || subtype == 12u ||
                         subtype == 13u || retry)) ||
         type == 2u)) {
        bl_os_printf("[TRACE] rxu_frame n=%lu ret=%lu fc=0x%04X type=%u sub=%u retry=%u seq=%u frag=%u hw=0x%08lX len=%u hdr=%u et=0x%04X sta=%u vif=%u a1=%02X:%02X:%02X:%02X:%02X:%02X a2=%02X:%02X:%02X:%02X:%02X:%02X a3=%02X:%02X:%02X:%02X:%02X:%02X\r\n",
                     (unsigned long)all_count, ret, fc, type, subtype,
                     retry, seq, frag, (unsigned long)hw_flags, len,
                     hdr_len, eth_type,
                     rxu_cntrl_env[9], rxu_cntrl_env[10],
                     payload ? payload[4] : 0, payload ? payload[5] : 0,
                     payload ? payload[6] : 0, payload ? payload[7] : 0,
                     payload ? payload[8] : 0, payload ? payload[9] : 0,
                     payload ? payload[10] : 0, payload ? payload[11] : 0,
                     payload ? payload[12] : 0, payload ? payload[13] : 0,
                     payload ? payload[14] : 0, payload ? payload[15] : 0,
                     payload ? payload[16] : 0, payload ? payload[17] : 0,
                     payload ? payload[18] : 0, payload ? payload[19] : 0,
                     payload ? payload[20] : 0, payload ? payload[21] : 0);
        all_count++;
    }

    if (((fc & 0x000cu) == 0x0008u) &&
        (data_count < 64u || eth_type == 0x8e88u)) {
        bl_os_printf("[TRACE] rxu_data n=%lu ret=%lu fc=0x%04X hw=0x%08lX len=%u hdr=%u et=0x%04X sta=%u vif=%u da=%02X:%02X:%02X:%02X:%02X:%02X sa=%02X:%02X:%02X:%02X:%02X:%02X\r\n",
                     (unsigned long)data_count, ret, fc,
                     (unsigned long)hw_flags, len, hdr_len, eth_type,
                     rxu_cntrl_env[9], rxu_cntrl_env[10],
                     payload ? payload[4] : 0, payload ? payload[5] : 0,
                     payload ? payload[6] : 0, payload ? payload[7] : 0,
                     payload ? payload[8] : 0, payload ? payload[9] : 0,
                     payload ? payload[10] : 0, payload ? payload[11] : 0,
                     payload ? payload[12] : 0, payload ? payload[13] : 0,
                     payload ? payload[14] : 0, payload ? payload[15] : 0);
        data_count++;
    }

    return ret;
}

void __wrap_rxu_swdesc_upload_evt(void)
{
    static uint32_t upload_count;

    if (upload_count < 16u) {
        bl_os_printf("[TRACE] rxu_upload n=%lu before\r\n",
                     (unsigned long)upload_count);
    }
    __real_rxu_swdesc_upload_evt();
    if (upload_count < 16u) {
        bl_os_printf("[TRACE] rxu_upload n=%lu after\r\n",
                     (unsigned long)upload_count);
    }
    upload_count++;
}

void __wrap_txl_frame_push(void *frame, uint8_t ac)
{
    trace_prepare_tx_frame(frame);
    __real_txl_frame_push(frame, ac);
}

void __wrap_txl_frame_push_force(void *frame, uint8_t ac)
{
    trace_prepare_tx_frame(frame);
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

void __wrap_txl_frame_evt(void)
{
    trace_txl_frame_evt_list("before");
    __real_txl_frame_evt();
    trace_txl_frame_evt_list("after");
}

void __wrap_txl_transmit_trigger(void)
{
    __real_txl_transmit_trigger();
}

void __wrap_txl_cfm_push(void *desc, uint32_t status, uint32_t ac)
{
    trace_tx_frame("cfm", desc, (uint8_t)ac, status, 1);
    __real_txl_cfm_push(desc, status, ac);
}

void __wrap_sm_handle_eapol_input(uint8_t sta_idx, void *src_addr,
                                  void *eapol_buf, uint32_t eapol_len)
{
    uint8_t *src = (uint8_t *)src_addr;
    uint8_t *eapol = (uint8_t *)eapol_buf;
    uint8_t vif_idx = 0xff;
    uint8_t vif_sm_active = 0;
    uint8_t sm_mode = sm_env[0x2c];
    uint8_t state = ke_state_get(4);
    void *rx_cb = NULL;

    if (sta_idx < 16) {
        vif_idx = sta_info_tab[(uint32_t)sta_idx * 368u + 39u];
        if (vif_idx < 4) {
            vif_sm_active = vif_info_tab[(uint32_t)vif_idx * 1512u + 488u];
        }
    }
    if (wpa_cbs) {
        rx_cb = ((void **)wpa_cbs)[5];
    }

    bl_os_printf("[TRACE] sm_eapol sta=%u vif=%u active=%u state=%u mode=%u cb=%p len=%lu src=%02X:%02X:%02X:%02X:%02X:%02X hdr=%02X:%02X:%02X:%02X\r\n",
                 sta_idx, vif_idx, vif_sm_active, state, sm_mode, rx_cb,
                 (unsigned long)eapol_len,
                 src ? src[0] : 0, src ? src[1] : 0, src ? src[2] : 0,
                 src ? src[3] : 0, src ? src[4] : 0, src ? src[5] : 0,
                 eapol_len > 0 ? eapol[0] : 0,
                 eapol_len > 1 ? eapol[1] : 0,
                 eapol_len > 2 ? eapol[2] : 0,
                 eapol_len > 3 ? eapol[3] : 0);

    __real_sm_handle_eapol_input(sta_idx, src_addr, eapol_buf, eapol_len);
}

int __wrap_tcpip_stack_input(void *swdesc, uint8_t status, void *hwhdr,
                             unsigned int msdu_offset, void *pkt,
                             uint8_t extra_status)
{
    struct wifi_pkt_trace *wp = (struct wifi_pkt_trace *)pkt;
    uint8_t *payload = 0;
    uint16_t proto = 0;
    static uint32_t trace_count;
    int should_trace = 0;

    if (wp && wp->pkt[0]) {
        payload = (uint8_t *)(uintptr_t)(wp->pkt[0] + msdu_offset);
        if (wp->len[0] >= msdu_offset + 14u) {
            proto = ((uint16_t)payload[12] << 8) | payload[13];
        }
    }

    if (proto == 0x888e || trace_count < 16u) {
        should_trace = 1;
    }
    if (should_trace) {
        bl_os_printf("[TRACE] tcpip_in status=0x%02X off=%lu extra=0x%02X proto=0x%04X len0=%u dst=%02X:%02X:%02X:%02X:%02X:%02X src=%02X:%02X:%02X:%02X:%02X:%02X\r\n",
                     status, (unsigned long)msdu_offset, extra_status, proto,
                     wp ? wp->len[0] : 0,
                     payload ? payload[0] : 0, payload ? payload[1] : 0,
                     payload ? payload[2] : 0, payload ? payload[3] : 0,
                     payload ? payload[4] : 0, payload ? payload[5] : 0,
                     payload ? payload[6] : 0, payload ? payload[7] : 0,
                     payload ? payload[8] : 0, payload ? payload[9] : 0,
                     payload ? payload[10] : 0, payload ? payload[11] : 0);
        trace_count++;
    }

    return __real_tcpip_stack_input(swdesc, status, hwhdr, msdu_offset, pkt,
                                    extra_status);
}
