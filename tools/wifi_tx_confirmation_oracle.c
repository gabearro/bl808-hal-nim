/* RV32 differential fixture. No MAC registers or real callbacks are used. */
#include <stdint.h>
#include <stddef.h>

#ifndef FIXTURE_FAULT
#define FIXTURE_FAULT 0
#endif

_Static_assert(sizeof(void *) == 4, "RV32 descriptor ABI required");
unsigned char probe_error __asm__(ERROR_SYMBOL);
struct list { void *first, *last; };
extern uint32_t txl_cntrl_env[], txl_cfm_env[], ke_env[];
extern uint32_t rxl_cntrl_env[];
extern unsigned char rx_hwdesc_env[];
extern const uint32_t txl_cfm_evt_bit[5];
uint32_t vendor_txl_cntrl_env[23], vendor_ke_env[8];
uint32_t vendor_rx_hwdesc_env[2];
extern uint32_t vendor_txl_cfm_env[], vendor_rxl_cntrl_env[];
extern const uint32_t vendor_txl_cfm_evt_bit[5];
extern void txl_cfm_init(void), vendor_txl_cfm_init(void);
extern void txl_cfm_push(void *, uint32_t, uint32_t), vendor_txl_cfm_push(void *, uint32_t, uint32_t);
extern void txl_cfm_evt(uint8_t), vendor_txl_cfm_evt(uint8_t);
extern void txl_cfm_flush(uint8_t, struct list *, uint32_t), vendor_txl_cfm_flush(uint8_t, struct list *, uint32_t);
extern void txl_cfm_flush_desc(uint8_t, void *, uint32_t), vendor_txl_cfm_flush_desc(uint8_t, void *, uint32_t);
extern void txl_current_desc_get(uint8_t, void **), vendor_txl_current_desc_get(uint8_t, void **);
extern void txl_cntrl_inc_pck_cnt(uint8_t), vendor_txl_cntrl_inc_pck_cnt(uint8_t);
extern void rxl_current_desc_get(void **, void **), vendor_rxl_current_desc_get(void **, void **);

enum { SLOT_COUNT = 10, TRACE_CAPACITY = 5 * SLOT_COUNT + 4,
       DESC_SIZE = 220, HW_SIZE = 68, LINK_SIZE = 384 };
static union { uint32_t words[DESC_SIZE / 4]; unsigned char bytes[DESC_SIZE]; } desc[SLOT_COUNT];
static uint32_t hardware[SLOT_COUNT][HW_SIZE / 4], heads[SLOT_COUNT][5];
static uint32_t links[SLOT_COUNT][LINK_SIZE / 4];
static uint32_t *control, *events;
static struct list *queues;
static uint32_t fixture_error, unexpected_calls, active_vendor;
volatile uint32_t wifi_confirmation_probe_checks, wifi_confirmation_probe_cases;
volatile uint32_t wifi_confirmation_probe_failure;
static uint32_t failed_case[8];
struct event { uint32_t kind, slot, value; };
struct snapshot {
    uint32_t trace_count, packet_count, event_bits, queue_first[5], queue_last[5];
    uint32_t statuses[SLOT_COUNT], buffers[SLOT_COUNT], irq;
    struct event trace[TRACE_CAPACITY];
};
static struct snapshot observed[2];
static struct snapshot *out;

static uint32_t irq(void) { uint32_t v; __asm__ volatile("csrr %0, mstatus" : "=r"(v)); return v & 8; }
static void set_irq(uint32_t enabled) {
    if (enabled) __asm__ volatile("csrsi mstatus, 8" ::: "memory");
    else __asm__ volatile("csrci mstatus, 8" ::: "memory");
}
static uint32_t *word(void *p, size_t offset) { return (uint32_t *)((unsigned char *)p + offset); }
static uint32_t slot(void *p) {
    for (uint32_t i = 0; i < SLOT_COUNT; ++i) if (p == desc[i].bytes) return i;
    fixture_error = __LINE__; return UINT32_MAX;
}
static void record(uint32_t kind, void *p, uint32_t value) {
    if (out->trace_count >= TRACE_CAPACITY) { fixture_error = __LINE__; return; }
    struct event *e = &out->trace[out->trace_count++];
    e->kind = kind; e->slot = p ? slot(p) : UINT32_MAX; e->value = value;
}
void *memset(void *p, int byte, size_t size) {
    unsigned char *d = p;
    for (size_t i = 0; i < size; ++i) d[i] = byte;
    return p;
}
void *memcpy(void *d, const void *s, size_t size) {
    unsigned char *to = d; const unsigned char *from = s;
    for (size_t i = 0; i < size; ++i) to[i] = from[i];
    return d;
}
void *vendor_memset(void *p, int byte, size_t size) { return memset(p, byte, size); }
int printf(const char *format, ...) { (void)format; return 0; }
int puts(const char *text) { (void)text; return 0; }
void hw_validation_log_byte(uint8_t byte) { (void)byte; }
void assert_err(const char *condition, const char *file, int line) {
    (void)condition; (void)file; fixture_error = line;
}
void vendor_assert_err(const char *c, const char *f, int line) { assert_err(c, f, line); }
void hal_machw_disable_int(void) { ++unexpected_calls; }
void ke_evt_set(uint32_t bits) { *events |= bits; record(1, 0, bits); }
void vendor_ke_evt_set(uint32_t bits) { ke_evt_set(bits); }
void ke_evt_clear(uint32_t bits) { *events &= ~bits; record(2, 0, bits); }
void vendor_ke_evt_clear(uint32_t bits) { ke_evt_clear(bits); }
void me_tx_cfm_singleton(void *p) { record(3, p, heads[slot(p)][4]); }
void vendor_me_tx_cfm_singleton(void *p) { me_tx_cfm_singleton(p); }
void txu_cntrl_cfm(void *p) { record(4, p, heads[slot(p)][4]); }
void vendor_txu_cntrl_cfm(void *p) { txu_cntrl_cfm(p); }
void ipc_emb_txcfm(void *p) { record(5, p, *word(p, 108) != 0); }
void vendor_ipc_emb_txcfm(void *p) { ipc_emb_txcfm(p); }
void ipc_emb_txcfm_ind(uint32_t bits) { record(6, 0, bits); }
void vendor_ipc_emb_txcfm_ind(uint32_t bits) { ipc_emb_txcfm_ind(bits); }
void txl_frame_cfm(void *p) { record(7, p, heads[slot(p)][4]); }
void vendor_txl_frame_cfm(void *p) { txl_frame_cfm(p); }
void txl_frame_evt(void) { record(8, 0, 0); }
void vendor_txl_frame_evt(void) { txl_frame_evt(); }

static void setup(uint32_t vendor, uint32_t ac, uint32_t count, uint32_t host_mask,
                  uint32_t dma_mask, uint32_t status, uint32_t packet_count) {
    active_vendor = vendor;
    control = vendor ? vendor_txl_cntrl_env : txl_cntrl_env;
    events = vendor ? vendor_ke_env : ke_env;
    queues = (struct list *)(vendor ? vendor_txl_cfm_env : txl_cfm_env);
    out = &observed[vendor];
    memset(out, 0, sizeof(*out));
    memset(control, 0, 92);
    memset(queues, 0, 40);
    memset(desc, 0, sizeof(desc)); memset(hardware, 0, sizeof(hardware));
    memset(heads, 0, sizeof(heads)); memset(links, 0, sizeof(links));
    *events = txl_cfm_evt_bit[ac] | 0x100;
    control[20] = packet_count;
    for (uint32_t i = 0; i < SLOT_COUNT; ++i) {
        void *p = desc[i].bytes;
        *word(p, 8) = (host_mask & (1u << i)) ? 0x4000 : 0;
        *word(p, 104) = (dma_mask & (1u << i)) ? 0x4004 : 0;
        *word(p, 108) = ((host_mask ^ dma_mask) & (1u << i)) ? (uint32_t)links[i] : 0;
        *word(p, 112) = (uint32_t)hardware[i];
        hardware[i][0] = (uint32_t)heads[i];
        hardware[i][1] = 0xcafebabe;
        hardware[i][16] = 0x12345678; /* Distinct from head-THD status at head+16. */
        heads[i][0] = 0xbadcab1d;
        heads[i][4] = status ^ (i * 0x10000) ^ ((i & 1) ? 0x80000000 : 0);
        links[i][348 / 4] = 8; /* Data FC: the management diagnostic path is not used. */
        if (i + 1 < count) *word(p, 0) = (uint32_t)desc[i + 1].bytes;
    }
    if (count) {
        queues[ac].first = desc[0].bytes;
        queues[ac].last = desc[count - 1].bytes;
    }
}
static void capture(void) {
    out->packet_count = control[20]; out->event_bits = *events; out->irq = irq();
    for (uint32_t i = 0; i < 5; ++i) {
        out->queue_first[i] = (uint32_t)queues[i].first;
        out->queue_last[i] = (uint32_t)queues[i].last;
    }
    for (uint32_t i = 0; i < SLOT_COUNT; ++i) {
        out->statuses[i] = heads[i][4]; out->buffers[i] = *word(desc[i].bytes, 108);
        if (hardware[i][16] != 0x12345678) fixture_error = __LINE__;
    }
}
static void invoke(uint32_t vendor, uint32_t operation, uint32_t ac,
                   uint32_t count, uint32_t status) {
    if (operation == 0) {
        memset(&queues[ac], 0, sizeof(queues[ac]));
        for (uint32_t i = 0; i < count; ++i) {
            if (vendor) vendor_txl_cfm_push(desc[i].bytes, status ^ i, ac);
            else txl_cfm_push(desc[i].bytes, status ^ i, ac);
        }
    } else if (operation == 1) {
        if (vendor) vendor_txl_cfm_flush(ac, &queues[ac], status);
        else txl_cfm_flush(ac, &queues[ac], status);
    } else if (operation == 2) {
        /* The single-descriptor API is called after the caller detaches it. */
        memset(&queues[ac], 0, sizeof(queues[ac]));
        if (vendor) vendor_txl_cfm_flush_desc(ac, desc[0].bytes, status);
        else txl_cfm_flush_desc(ac, desc[0].bytes, status);
    } else {
        if (vendor) vendor_txl_cfm_evt(ac);
        else txl_cfm_evt(ac);
    }
    /* Negative controls corrupt fixture output, never firmware instructions. */
    if (!vendor && operation == 1 && count != 0) {
        if (FIXTURE_FAULT == 1) heads[0][4] ^= 1;
        if (FIXTURE_FAULT == 2) control[20] ^= 1;
        if (FIXTURE_FAULT == 3) *events ^= 0x100;
        if (FIXTURE_FAULT == 4) queues[ac].first = desc[0].bytes;
        if (FIXTURE_FAULT == 5 && out->trace_count) out->trace[0].value ^= 1;
    }
    capture();
}
static int same(void) {
    const unsigned char *a = (const unsigned char *)&observed[0], *b = (const unsigned char *)&observed[1];
    for (uint32_t i = 0; i < sizeof(observed[0]); ++i) if (a[i] != b[i]) {
        wifi_confirmation_probe_failure = i / 4 + 1; return 0;
    }
    return 1;
}
#define CHECK(c) do { if (!(c)) return __LINE__; ++wifi_confirmation_probe_checks; } while (0)
int wifi_confirmation_probe_main(void) {
    const uint32_t statuses[] = {0, 1, 0x7fffffff, 0x80000000, 0x80800000, 0xffffffff};
    const uint32_t overrides[] = {0, 0x20000, 0x40000000, 0x80000000};
    const uint32_t counters[] = {0, UINT32_MAX, 31};
    const uint32_t ownership[] = {0, 0x3ff, 1, 0x200, 0x155, 0x2aa, 0xf, 0x3f0};
    for (uint32_t ac = 0; ac < 5; ++ac) CHECK(txl_cfm_evt_bit[ac] == vendor_txl_cfm_evt_bit[ac]);
    for (uint32_t incoming = 0; incoming <= 8; incoming += 8)
    for (uint32_t ac = 0; ac < 5; ++ac)
    for (uint32_t s = 0; s < 6; ++s)
    for (uint32_t dma = 0; dma < 8; ++dma)
    for (uint32_t hosts = 0; hosts < 8; ++hosts)
    for (uint32_t c = 0; c < 3; ++c)
    for (uint32_t operation = 0; operation < 4; ++operation) {
        if ((operation == 0 || operation == 3) && hosts != 1) continue;
        if (operation == 2 && hosts > 1) continue;
        uint32_t count = operation == 2 ? 1 : (s * 3 + c) % (SLOT_COUNT + 1);
        uint32_t override = overrides[(s + c + ac) % 4];
        uint32_t description[] = {incoming, ac, s, dma, hosts, c, operation, count};
        memcpy(failed_case, description, sizeof(failed_case));
        for (uint32_t vendor = 0; vendor < 2; ++vendor) {
            setup(vendor, ac, count, ownership[hosts], ownership[dma], statuses[s], counters[c]);
            set_irq(incoming);
            invoke(vendor, operation, ac, count, override);
            CHECK(irq() == incoming && fixture_error == 0 && unexpected_calls == 0);
        }
        CHECK(same());
        ++wifi_confirmation_probe_cases;
    }
    /* Compare actual getters/accounting across all queues and rollover. */
    for (uint32_t ac = 0; ac < 5; ++ac) for (uint32_t occupied = 0; occupied < 2; ++occupied) {
        void *result[2];
        for (uint32_t vendor = 0; vendor < 2; ++vendor) {
            setup(vendor, ac, 0, 0, 0, 0, UINT32_MAX);
            control[ac * 4 + 1] = occupied ? (uint32_t)desc[0].bytes : 0;
            if (vendor) { vendor_txl_current_desc_get(ac, &result[vendor]); vendor_txl_cntrl_inc_pck_cnt(ac); }
            else { txl_current_desc_get(ac, &result[vendor]); txl_cntrl_inc_pck_cnt(ac); }
            CHECK(control[20] == 0);
        }
        CHECK(result[0] == result[1]);
        CHECK(result[0] == (occupied ? (void *)&hardware[0][1] : 0));
    }
    for (uint32_t occupied = 0; occupied < 4; ++occupied) {
        void *a[2], *b[2];
        for (uint32_t vendor = 0; vendor < 2; ++vendor) {
            uint32_t *rx = vendor ? vendor_rxl_cntrl_env : rxl_cntrl_env;
            uint32_t *hw = vendor ? vendor_rx_hwdesc_env : (uint32_t *)rx_hwdesc_env;
            rx[4] = (occupied & 1) ? (uint32_t)desc[0].bytes : 0;
            hw[1] = (occupied & 2) ? (uint32_t)desc[1].bytes : 0;
            if (vendor) vendor_rxl_current_desc_get(&a[vendor], &b[vendor]);
            else rxl_current_desc_get(&a[vendor], &b[vendor]);
        }
        CHECK(a[0] == a[1] && b[0] == b[1]);
    }
    CHECK(probe_error == 0 && fixture_error == 0 && unexpected_calls == 0);
    return 0;
}
static void print_hex(uint32_t value) {
    volatile unsigned char *uart = (volatile unsigned char *)0x10000000;
    for (int shift = 28; shift >= 0; shift -= 4) {
        unsigned int digit = (value >> shift) & 15;
        while (!(uart[5] & 0x20)) {} uart[0] = digit < 10 ? '0' + digit : 'a' + digit - 10;
    }
}
void wifi_confirmation_probe_report(uint32_t result) {
    volatile unsigned char *uart = (volatile unsigned char *)0x10000000;
    const char *text = result ? "CONFIRM RV32 FAIL " : "CONFIRM RV32 PASS ";
    while (*text) { while (!(uart[5] & 0x20)) {} uart[0] = *text++; }
    uint32_t values[] = {wifi_confirmation_probe_cases, wifi_confirmation_probe_checks, result,
        wifi_confirmation_probe_failure, fixture_error, active_vendor};
    for (uint32_t i = 0; i < sizeof(values) / 4; ++i) {
        print_hex(values[i]); while (!(uart[5] & 0x20)) {} uart[0] = ' ';
    }
    if (result) for (uint32_t i = 0; i < 8; ++i) {
        print_hex(failed_case[i]); while (!(uart[5] & 0x20)) {} uart[0] = ' ';
    }
    while (!(uart[5] & 0x20)) {} uart[0] = '\n';
}
