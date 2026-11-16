/* Station-mode control comparison. Upper RX/free/beacon callbacks are models. */
#include <stdint.h>
#include <stddef.h>

#ifndef FIXTURE_FAULT
#define FIXTURE_FAULT 0
#endif
_Static_assert(sizeof(void *) == 4, "RV32 descriptor ABI required");
unsigned char probe_error __asm__(ERROR_SYMBOL);
extern uint8_t rx_dma_hdrdesc[4100], rx_payload_desc[2132], rx_swdesc_tab[984];
extern uint8_t rx_payload_desc_buffer[71176], sta_info_tab[2576], vif_info_tab[3024];
extern uint8_t rxu_cntrl_env[96], rxl_cntrl_env[28];
extern uint8_t active_control __asm__(ACTIVE_SYMBOL);
uint32_t g_bl_ops_funcs[64];
extern void rx_swdesc_init(void), rxl_cntrl_evt(void), vendor_rxl_cntrl_evt(void);
extern void capture_station(void *, uint32_t) __asm__(CAPTURE_SYMBOL);
void ap_hook(void *, void *, uint8_t, void *) __asm__(AP_SYMBOL);

enum { SLOTS = 10, TRACE_LIMIT = 40 };
struct call { uint32_t kind, slot, a, b, c; };
struct snapshot {
    uint8_t stations[2576], vifs[3024], headers[4100], software[984];
    uint32_t event_bits, first, last, remaining, queue[SLOTS], call_count, irq;
    struct call calls[TRACE_LIMIT];
};
static struct snapshot observed[2], *out;
static uint32_t fixture_error, side, tick_count, upload_result, beacon_result;
static uint32_t events, cases, checks, difference;
static uint32_t inputs[8];
static uint32_t *word(void *p, uint32_t offset) { return (uint32_t *)((uint8_t *)p + offset); }
static uint16_t *half(void *p, uint32_t offset) { return (uint16_t *)((uint8_t *)p + offset); }
static uint8_t *sw(uint32_t i) { return rx_swdesc_tab + i * 24; }
static uint8_t *hd(uint32_t i) { return rx_dma_hdrdesc + i * 100; }
static uint8_t *pd(uint32_t i) { return rx_payload_desc + i * 52; }
static uint8_t *frame(uint32_t i) { return rx_payload_desc_buffer + i * 1736; }
static uint8_t *station(void) { return sta_info_tab + 4 * 368; }
static uint8_t *vif(void) { return vif_info_tab + inputs[2] * 1512; }
static uint32_t irq(void) {
    uint32_t value; __asm__ volatile("csrr %0, mstatus" : "=r"(value)); return value & 8;
}
static void set_irq(uint32_t value) {
    if (value) __asm__ volatile("csrsi mstatus, 8" ::: "memory");
    else __asm__ volatile("csrci mstatus, 8" ::: "memory");
}
void *memset(void *p, int value, size_t count) {
    uint8_t *b = p; for (size_t i = 0; i < count; ++i) b[i] = value; return p;
}
void *memcpy(void *d, const void *s, size_t count) {
    uint8_t *to = d; const uint8_t *from = s;
    for (size_t i = 0; i < count; ++i) to[i] = from[i];
    return d;
}
int printf(const char *format, ...) { (void)format; return 0; }
int puts(const char *text) { (void)text; return 0; }
void hw_validation_log_byte(uint8_t byte) { (void)byte; }
static uint32_t index(void *p, uint8_t *base, uint32_t stride) {
    for (uint32_t i = 0; i < SLOTS; ++i) if (p == base + i * stride) return i;
    fixture_error = __LINE__; return UINT32_MAX;
}
static uint32_t slot(void *p) { return index(p, rx_swdesc_tab, 24); }
static void record(uint32_t kind, uint32_t i, uint32_t a, uint32_t b, uint32_t c) {
    if (out->call_count >= TRACE_LIMIT) { fixture_error = __LINE__; return; }
    out->calls[out->call_count++] = (struct call){kind, i, a, b, c};
}
void assert_rec(const char *condition, const char *file, int line) {
    (void)condition; (void)file; fixture_error = line;
}
void vendor_assert_rec(const char *c, const char *f, int line) { assert_rec(c, f, line); }
void ke_evt_clear(uint32_t bits) { events &= ~bits; }
void vendor_ke_evt_clear(uint32_t bits) { ke_evt_clear(bits); }
void ke_evt_set(uint32_t bits) { events |= bits; }
void vendor_ke_evt_set(uint32_t bits) { ke_evt_set(bits); }
static uint32_t tick(void) { ++tick_count; return 0xabcd0000 | tick_count; }
void ap_hook(void *v, void *s, uint8_t i, void *f) {
    /* This helper is separately covered by native AP tests; only non-AP here. */
    if (v != vif() || s != station() || i != 4 || vif()[86] == 2 ||
        index(f, rx_payload_desc_buffer, 1736) == UINT32_MAX) fixture_error = __LINE__;
}
uint32_t rxu_cntrl_frame_handle(void *p) {
    record(1, slot(p), upload_result, 0, 0); return upload_result;
}
uint32_t vendor_rxu_cntrl_frame_handle(void *p) { return rxu_cntrl_frame_handle(p); }
void rxl_mpdu_free(void *p) { record(2, slot(p), 0, 0, 0); }
void vendor_rxl_mpdu_free(void *p) { rxl_mpdu_free(p); }
void td_pck_ind(uint8_t v, uint8_t s, uint8_t count) { record(3, s, v, count, 0); }
void vendor_td_pck_ind(uint8_t v, uint8_t s, uint8_t c) { td_pck_ind(v, s, c); }
uint32_t mm_check_beacon(void *h, void *v, void *s, uint32_t *tim) {
    if (v != vif() || s != station()) fixture_error = __LINE__;
    *tim = 0x12345678;
    record(4, index(h, rx_dma_hdrdesc, 100), beacon_result, 0, 0); return beacon_result;
}
uint32_t vendor_mm_check_beacon(void *h, void *v, void *s, uint32_t *t) { return mm_check_beacon(h, v, s, t); }
void ps_check_beacon(void *tim, uint32_t length, void *v) {
    if (v != vif()) fixture_error = __LINE__;
    record(5, 4, (uint32_t)tim, length, 0);
}
void vendor_ps_check_beacon(void *t, uint32_t l, void *v) { ps_check_beacon(t, l, v); }
void vif_mgmt_bcn_recv(void *v) {
    if (v != vif()) fixture_error = __LINE__;
    record(6, 4, 0, 0, 0);
}
void vendor_vif_mgmt_bcn_recv(void *v) { vif_mgmt_bcn_recv(v); }
void chan_tbtt_switch_update(void *v, uint32_t expiry) {
    if (v != vif()) fixture_error = __LINE__;
    record(7, 4, expiry, 0, 0);
}
void vendor_chan_tbtt_switch_update(void *v, uint32_t e) { chan_tbtt_switch_update(v, e); }
void ps_check_frame(void *f, uint32_t flags, void *v) {
    if (v != vif()) fixture_error = __LINE__;
    record(8, index(f, rx_payload_desc_buffer, 1736), flags, 0, 0);
}
void vendor_ps_check_frame(void *f, uint32_t flags, void *v) { ps_check_frame(f, flags, v); }
/* The original AP branches are linked but never entered in this matrix. */
void vendor_mm_ps_change_ind(uint8_t s, uint8_t m) { (void)s; (void)m; fixture_error = __LINE__; }
void vendor_apm_tx_int_ps_clear(void *v, uint8_t s) { (void)v; (void)s; fixture_error = __LINE__; }
uint32_t vendor_sta_mgmt_send_postponed_frame(void *v, void *s, uint32_t n) {
    (void)v; (void)s; (void)n; fixture_error = __LINE__; return 0;
}
uint8_t vendor_txl_frame_send_qosnull_frame(uint8_t s, uint16_t q, void *c, uint32_t a) {
    (void)s; (void)q; (void)c; (void)a; fixture_error = __LINE__; return 0;
}
void *vendor_ke_msg_alloc(uint16_t id, uint8_t d, uint8_t s, uint32_t n) {
    (void)id; (void)d; (void)s; (void)n; fixture_error = __LINE__; return 0;
}
void vendor_ke_msg_send(void *p) { (void)p; fixture_error = __LINE__; }
extern const uint8_t mac_tid2ac[], mac_ac2uapsd[];

static void setup(void) {
    uint32_t count = inputs[0], mode = inputs[3];
    static const uint16_t fc[] = {8, 8, 8, 8, 0x80, 0x88, 0xa4, 0x50, 8};
    memset(out, 0, sizeof(*out)); memset(rxl_cntrl_env, 0, 28); memset(rxu_cntrl_env, 0, 96);
    memset(rx_dma_hdrdesc, 0, 4100); memset(rx_payload_desc, 0, 2132); memset(rx_swdesc_tab, 0, 984);
    memset(sta_info_tab, 0, 2576); memset(vif_info_tab, 0, 3024);
    events = 0x00100100; tick_count = 0; active_control = 0;
    station()[42] = 1; station()[39] = inputs[2]; station()[40] = 4;
    vif()[86] = mode == 1 || mode == 8 ? 1 : 0;
    vif()[87] = inputs[2]; vif()[88] = mode >= 3;
    *word(vif(), 64) = inputs[6] ? (uint32_t)station() : 0;
    *word(vif(), 36) = 0x13572468;
    rx_swdesc_init();
    for (uint32_t i = 0; i < SLOTS; ++i) {
        *word(sw(i), 0) = i + 1 < count ? (uint32_t)sw(i + 1) : 0;
        *word(hd(i), 12) = (uint32_t)sw(i);
        *word(hd(i), 8) = (uint32_t)pd(i); *half(hd(i), 28) = 123;
        uint32_t flags = mode == 0 ? 0x6000 : 0x22066000;
        *word(hd(i), 64) = flags;
        *word(pd(i), 8) = (uint32_t)frame(i); *word(pd(i), 24) = (uint32_t)frame(i);
        *half(pd(i), 16) = 1; *half(frame(i), 0) = fc[mode];
        capture_station(sw(i), flags);
    }
    if (count) { *word(rxl_cntrl_env, 0) = (uint32_t)sw(0); *word(rxl_cntrl_env, 4) = (uint32_t)sw(count - 1); }
    rxl_cntrl_env[24] = inputs[1];
    upload_result = inputs[4]; beacon_result = inputs[5];
    g_bl_ops_funcs[50] = (uint32_t)tick;
}
static void capture(void) {
    memcpy(out->stations, sta_info_tab, 2576); memcpy(out->vifs, vif_info_tab, 3024);
    memcpy(out->headers, rx_dma_hdrdesc, 4100); memcpy(out->software, rx_swdesc_tab, 984);
    /* Popped-link clearing differs intentionally; the remaining FIFO is checked. */
    for (uint32_t i = 0; i < 41; ++i) *word(out->software, i * 24) = 0;
    out->event_bits = events; out->irq = irq();
    void *head = (void *)*word(rxl_cntrl_env, 0), *last = (void *)*word(rxl_cntrl_env, 4);
    out->first = head ? slot(head) + 1 : 0; out->last = last ? slot(last) + 1 : 0;
    while (head && out->remaining < SLOTS) {
        out->queue[out->remaining++] = slot(head) + 1; head = (void *)*word(head, 0);
    }
    if (head || active_control != 0) fixture_error = __LINE__;
    if (!side && FIXTURE_FAULT == 1) out->event_bits ^= 0x100;
    if (!side && FIXTURE_FAULT == 2) out->stations[4 * 368 + 20] ^= 1;
    if (!side && FIXTURE_FAULT == 3 && out->call_count) out->calls[0].kind ^= 1;
    if (!side && FIXTURE_FAULT == 4 && out->remaining) out->queue[0] ^= 1;
}
#define CHECK(c) do { if (!(c)) return __LINE__; ++checks; } while (0)
int wifi_rx_control_probe_main(void) {
    for (inputs[0] = 0; inputs[0] <= SLOTS; ++inputs[0])
    for (inputs[1] = 0; inputs[1] < 2; ++inputs[1])
    for (inputs[2] = 0; inputs[2] < 2; ++inputs[2])
    for (inputs[3] = 0; inputs[3] < 9; ++inputs[3])
    for (inputs[4] = 0; inputs[4] < 2; ++inputs[4])
    for (inputs[5] = 0; inputs[5] < 2; ++inputs[5])
    for (inputs[6] = 0; inputs[6] < 2; ++inputs[6])
    for (inputs[7] = 0; inputs[7] <= 8; inputs[7] += 8) {
        for (side = 0; side < 2; ++side) {
            out = &observed[side]; setup(); set_irq(inputs[7]);
            if (side) vendor_rxl_cntrl_evt(); else rxl_cntrl_evt();
            capture(); CHECK(probe_error == 0 && fixture_error == 0);
            CHECK(out->irq == inputs[7]);
            uint32_t processed = inputs[1] ? 0 : (inputs[0] < 4 ? inputs[0] : 4);
            uint32_t remaining = inputs[0] - processed;
            CHECK(out->remaining == remaining && out->event_bits ==
                (0x100u | (remaining && !inputs[1] ? 0x100000u : 0)));
            uint32_t upper = 0, freed = 0;
            for (uint32_t i = 0; i < out->call_count; ++i) {
                upper += out->calls[i].kind == 1; freed += out->calls[i].kind == 2;
            }
            uint32_t beacon_drop = inputs[3] == 4 && !inputs[5];
            CHECK(upper == (beacon_drop ? 0 : processed) &&
                  freed == (beacon_drop || !inputs[4] ? processed : 0));
            uint32_t timed = inputs[3] ? processed : 0;
            CHECK(tick_count == timed && *word(station(), 20) == (timed ? 0xabcd0000u | timed : 0));
        }
        const uint8_t *a = (const uint8_t *)&observed[0], *b = (const uint8_t *)&observed[1];
        for (uint32_t i = 0; i < sizeof(observed[0]); ++i) if (a[i] != b[i]) { difference = i + 1; break; }
        CHECK(difference == 0); ++cases;
    }
    return 0;
}
static void byte(uint8_t value) {
    volatile uint8_t *uart = (volatile uint8_t *)0x10000000;
    while (!(uart[5] & 0x20)) {} uart[0] = value;
}
static void hex(uint32_t value) {
    for (int shift = 28; shift >= 0; shift -= 4) { uint32_t d = (value >> shift) & 15; byte(d < 10 ? '0' + d : 'a' + d - 10); }
    byte(' ');
}
void wifi_rx_control_probe_report(uint32_t result) {
    const char *text = result ? "RXCONTROL RV32 FAIL " : "RXCONTROL RV32 PASS ";
    while (*text) byte(*text++);
    hex(cases); hex(checks); hex(result); hex(difference); hex(fixture_error);
    for (uint32_t i = 0; i < 8; ++i) hex(inputs[i]);
    byte('\n');
}
