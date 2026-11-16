/* The S-mode MMU and store trap are fixture-only, not BL808 requirements. */
#include <stdint.h>
#include <stddef.h>

#ifndef FIXTURE_FAULT
#define FIXTURE_FAULT 0
#endif
_Static_assert(sizeof(void *) == 4, "RV32 descriptor addresses required");
unsigned char probe_error __asm__(ERROR_SYMBOL);
extern uint8_t rx_dma_hdrdesc[4100], rx_payload_desc[2132], rx_swdesc_tab[984];
extern uint32_t rxl_cntrl_env[7];
extern uint8_t rx_hwdesc_env[8];
extern void rxl_hd_append(void *), rxl_pd_append(void *, void *, void *), rxl_frame_release(void *);
extern void vendor_rxl_hd_append(void *), vendor_rxl_pd_append(void *, void *, void *), vendor_rxl_frame_release(void *);
uint32_t vendor_rxl_cntrl_env[7], vendor_rx_hwdesc_env[2];
extern uint32_t rx_supervisor_enter(void);
extern void rx_store_trap(void), rx_store_context_check(uint32_t *, uint32_t);

enum { MMIO_BASE = 0x24b08000u, TRIGGER = 0x180, HEADER_HEAD = 0x548, PAYLOAD_HEAD = 0x54c,
       HEADER_SIZE = 100, PAYLOAD_SIZE = 52, SOFTWARE_SIZE = 24, RING_COUNT = 41 };
static uint32_t root_table[1024] __attribute__((aligned(4096)));
static uint32_t register_table[1024] __attribute__((aligned(4096)));
static volatile uint32_t registers[1024] __attribute__((aligned(4096)));
struct write {
    uint32_t address, value;
    uint8_t headers[4100], payloads[2132];
};
static volatile struct write writes[8];
static volatile uint32_t write_count, last_width;
static uint32_t fixture_error, active_vendor;
static uint32_t last_case[9];
static uint32_t context[64];
volatile uint32_t wifi_rx_descriptor_probe_checks, wifi_rx_descriptor_probe_cases;
volatile uint32_t wifi_rx_descriptor_probe_difference;
struct snapshot {
    uint8_t headers[4100], payloads[2132], software[984];
    uint32_t environment[7], hardware_environment[2], mmio[1024], count;
    struct write writes[8];
};
static struct snapshot observed[2];
static uint32_t *env, *hwenv;
void *memset(void *p, int value, size_t length) {
    unsigned char *bytes = p;
    for (size_t i = 0; i < length; ++i) bytes[i] = value;
    return p;
}
void *memcpy(void *d, const void *s, size_t length) {
    unsigned char *to = d; const unsigned char *from = s;
    for (size_t i = 0; i < length; ++i) to[i] = from[i];
    return d;
}
void assert_err(const char *c, const char *f, int line) { (void)c; (void)f; fixture_error = line; }
void vendor_assert_err(const char *c, const char *f, int line) { assert_err(c, f, line); }
static void print_hex(uint32_t value) {
    volatile unsigned char *uart = (volatile unsigned char *)0x10000000;
    for (int shift = 28; shift >= 0; shift -= 4) {
        unsigned int digit = (value >> shift) & 15;
        while (!(uart[5] & 0x20)) {} uart[0] = digit < 10 ? '0' + digit : 'a' + digit - 10;
    }
}
static void fatal(uint32_t cause, uint32_t pc, uint32_t address) {
    volatile unsigned char *uart = (volatile unsigned char *)0x10000000;
    const char *text = "RX MODEL TRAP ";
    while (*text) { while (!(uart[5] & 0x20)) {} uart[0] = *text++; }
    print_hex(cause); print_hex(pc); print_hex(address);
    *(volatile uint32_t *)0x100000 = 0x00ff3333;
    for (;;) __asm__ volatile("wfi");
}
void rx_oracle_unexpected_trap(uint32_t cause, uint32_t pc, uint32_t address) { fatal(cause, pc, address); }
void rx_oracle_handle_store(const uint32_t *gpr) {
    uint32_t cause, pc, address;
    __asm__ volatile("csrr %0, scause" : "=r"(cause));
    __asm__ volatile("csrr %0, sepc" : "=r"(pc));
    __asm__ volatile("csrr %0, stval" : "=r"(address));
    if (cause != 15 || address != MMIO_BASE + TRIGGER || write_count >= 8) fatal(cause, pc, address);
    uint16_t low = *(const uint16_t *)pc;
    uint32_t rs2, length;
    if ((low & 3) != 3) {
        if ((low & 0xe003) != 0xc000) fatal(cause, pc, address);
        rs2 = 8 + ((low >> 2) & 7); length = 2; /* C.SW */
    } else {
        uint32_t instruction = low | ((uint32_t)*(const uint16_t *)(pc + 2) << 16);
        if ((instruction & 0x707f) != 0x2023) fatal(cause, pc, address);
        rs2 = (instruction >> 20) & 31; length = 4; /* SW */
    }
    uint32_t value = gpr[rs2];
    volatile struct write *entry = &writes[write_count];
    entry->address = address;
    entry->value = value;
    for (uint32_t i = 0; i < 4100; ++i) entry->headers[i] = ((volatile uint8_t *)rx_dma_hdrdesc)[i];
    for (uint32_t i = 0; i < 2132; ++i) entry->payloads[i] = ((volatile uint8_t *)rx_payload_desc)[i];
    ++write_count;
    registers[TRIGGER / 4] = value;
    last_width = length;
    if (FIXTURE_FAULT == 7) ((uint32_t *)gpr)[31] ^= 1; /* Observer self-test control. */
    pc += length;
    __asm__ volatile("csrw sepc, %0" :: "r"(pc) : "memory");
}
static uint32_t pte(uint32_t physical, uint32_t permissions) { return ((physical >> 12) << 10) | permissions; }
static void setup_mapping(void) {
    root_table[0] = 0xc7; /* QEMU's finisher. */
    root_table[0x10000000u >> 22] = pte(0x10000000u, 0xc7); /* QEMU UART. */
    for (uint32_t base = 0x80000000; base < 0x82000000; base += 0x400000)
        root_table[base >> 22] = pte(base, 0xcf);
    root_table[MMIO_BASE >> 22] = pte((uint32_t)register_table, 1);
    register_table[(MMIO_BASE >> 12) & 1023] = pte((uint32_t)registers, 0x43); /* Read only. */
    uint32_t all = UINT32_MAX, permissions = 0x1f;
    __asm__ volatile("csrw pmpaddr0, %0; csrw pmpcfg0, %1" :: "r"(all), "r"(permissions) : "memory");
    uint32_t delegated = 1u << 15;
    __asm__ volatile("csrw medeleg, %0; csrw stvec, %1" :: "r"(delegated), "r"((uint32_t)rx_store_trap) : "memory");
    uint32_t satp = 0x80000000u | ((uint32_t)root_table >> 12);
    __asm__ volatile("csrw satp, %0; sfence.vma" :: "r"(satp) : "memory");
}
static uint32_t sie(void) { uint32_t v; __asm__ volatile("csrr %0, sstatus" : "=r"(v)); return v & 2; }
static void set_sie(uint32_t enabled) {
    if (enabled) __asm__ volatile("csrsi sstatus, 2" ::: "memory");
    else __asm__ volatile("csrci sstatus, 2" ::: "memory");
}
static uint32_t *word(void *p, uint32_t offset) { return (uint32_t *)((uint8_t *)p + offset); }
static void *header(uint32_t i) { return rx_dma_hdrdesc + (i % RING_COUNT) * HEADER_SIZE; }
static void *payload(uint32_t i) { return rx_payload_desc + (i % RING_COUNT) * PAYLOAD_SIZE; }
static void *software(uint32_t i) { return rx_swdesc_tab + (i % RING_COUNT) * SOFTWARE_SIZE; }
static void poison(volatile void *p, uint32_t size, uint32_t seed) {
    volatile uint8_t *bytes = p;
    for (uint32_t i = 0; i < size; ++i) bytes[i] = (seed >> ((i & 3) * 8)) ^ (i * 13);
}
static void setup(uint32_t vendor, uint32_t hbase, uint32_t pbase, uint32_t hmatch,
                  uint32_t pmatch, uint32_t has_previous, uint32_t empty, uint32_t seed) {
    active_vendor = vendor;
    env = vendor ? vendor_rxl_cntrl_env : rxl_cntrl_env;
    hwenv = vendor ? vendor_rx_hwdesc_env : (uint32_t *)rx_hwdesc_env;
    poison(rx_dma_hdrdesc, 4100, seed); poison(rx_payload_desc, 2132, seed);
    poison(rx_swdesc_tab, 984, seed); poison(registers, sizeof(registers), seed);
    poison(env, 28, seed); poison(hwenv, 8, seed);
    for (uint32_t i = 0; i < RING_COUNT; ++i) {
        *word(header(i), 12) = (uint32_t)software(i);
        *word(software(i), 4) = (uint32_t)header(i);
    }
    env[2] = empty ? 0 : (uint32_t)header(hbase + 13);
    env[3] = (uint32_t)header(hbase + 13);
    env[4] = (uint32_t)header(hbase);
    hwenv[0] = (uint32_t)payload(pbase + 4);
    hwenv[1] = (uint32_t)payload(pbase + 3);
    registers[HEADER_HEAD / 4] = (uint32_t)header(hbase + (hmatch ? 0 : 7));
    registers[PAYLOAD_HEAD / 4] = (uint32_t)payload(pbase + (pmatch ? 3 : 2));
    void *sw = software(hbase + 7);
    *word(sw, 8) = (uint32_t)payload(pbase + (has_previous ? 0 : 2));
    *word(sw, 12) = has_previous ? (uint32_t)payload(pbase + 1) : 0;
    *word(sw, 16) = (uint32_t)payload(pbase + 2);
    *word(header(hbase + 7), 8) = (uint32_t)payload(pbase + (has_previous ? 0 : 2));
    write_count = 0;
}
static void capture(uint32_t vendor) {
    struct snapshot *s = &observed[vendor];
    memset(s, 0, sizeof(*s));
    memcpy(s->headers, rx_dma_hdrdesc, 4100); memcpy(s->payloads, rx_payload_desc, 2132);
    memcpy(s->software, rx_swdesc_tab, 984); memcpy(s->environment, env, 28);
    memcpy(s->hardware_environment, hwenv, 8);
    for (uint32_t i = 0; i < 1024; ++i) s->mmio[i] = registers[i];
    s->count = write_count;
    volatile const uint8_t *source = (volatile const uint8_t *)writes;
    uint8_t *destination = (uint8_t *)s->writes;
    for (uint32_t i = 0; i < write_count * sizeof(writes[0]); ++i) destination[i] = source[i];
}
static int same(void) {
    const uint8_t *a = (const uint8_t *)&observed[0], *b = (const uint8_t *)&observed[1];
    for (uint32_t i = 0; i < sizeof(observed[0]); ++i) if (a[i] != b[i]) {
        wifi_rx_descriptor_probe_difference = i + 1; return 0;
    }
    return 1;
}
#define CHECK(c) do { if (!(c)) return __LINE__; ++wifi_rx_descriptor_probe_checks; } while (0)
static int pair(uint32_t operation, uint32_t hbase, uint32_t pbase, uint32_t hmatch,
                uint32_t pmatch, uint32_t previous, uint32_t empty, uint32_t seed, uint32_t incoming) {
    uint32_t description[] = {operation, hbase, pbase, hmatch, pmatch, previous, empty, seed, incoming};
    memcpy(last_case, description, sizeof(last_case));
    for (uint32_t vendor = 0; vendor < 2; ++vendor) {
        setup(vendor, hbase, pbase, hmatch, pmatch, previous == 1, empty, seed);
        set_sie(incoming);
        if (operation == 0) {
            if (vendor) vendor_rxl_hd_append(header(hbase + 7));
            else rxl_hd_append(header(hbase + 7));
        } else if (operation == 1) {
            void *first = previous == 1 ? payload(pbase) : payload(pbase + 2);
            if (previous == 2) first = 0; /* Unused when no predecessor is supplied. */
            void *prev = previous == 1 ? payload(pbase + 1) : 0;
            if (vendor) vendor_rxl_pd_append(first, prev, payload(pbase + 2));
            else rxl_pd_append(first, prev, payload(pbase + 2));
        } else {
            if (vendor) vendor_rxl_frame_release(software(hbase + 7));
            else rxl_frame_release(software(hbase + 7));
        }
        int trace_ok = write_count == (operation == 2 ? 2u : 1u);
        for (uint32_t i = 0; i < write_count; ++i) {
            uint32_t expected = operation == 1 || (operation == 2 && i == 0) ? 0x02000000 : 0x01000000;
            trace_ok &= writes[i].address == MMIO_BASE + TRIGGER && writes[i].value == expected;
        }
        /* Corrupt observations only; the selected firmware instructions stay intact. */
        if (!vendor) {
            uint32_t returned = (hbase + (hmatch ? 7 : 0)) % RING_COUNT;
            uint32_t status_index = (pbase + (pmatch ? 2 : 3)) % RING_COUNT;
            if (FIXTURE_FAULT == 1 && operation == 0) ((uint8_t *)header(returned))[30] ^= 1;
            if (FIXTURE_FAULT == 2 && operation == 1) ((uint8_t *)payload(status_index))[18] ^= 1;
            if (FIXTURE_FAULT == 3 && operation == 0) env[4] ^= 1;
            if (FIXTURE_FAULT == 4 && operation == 1) hwenv[0] ^= 1;
            if (FIXTURE_FAULT == 5 && operation == 2) {
                volatile uint8_t *a = (volatile uint8_t *)&writes[0], *b = (volatile uint8_t *)&writes[1];
                for (uint32_t i = 0; i < sizeof(writes[0]); ++i) { uint8_t temp = a[i]; a[i] = b[i]; b[i] = temp; }
            }
            if (FIXTURE_FAULT == 6 && operation == 0) writes[0].headers[returned * HEADER_SIZE + 4] ^= 1;
        }
        capture(vendor);
        int aliases_ok = *(volatile uint32_t *)(MMIO_BASE + HEADER_HEAD) == registers[HEADER_HEAD / 4] &&
                         *(volatile uint32_t *)(MMIO_BASE + PAYLOAD_HEAD) == registers[PAYLOAD_HEAD / 4];
        CHECK(sie() == incoming && fixture_error == 0 && trace_ok && aliases_ok);
    }
    CHECK(same());
    ++wifi_rx_descriptor_probe_cases;
    return 0;
}
int rx_descriptor_oracle_body(void) {
    for (uint32_t enabled = 0; enabled <= 2; enabled += 2) for (uint32_t kind = 0; kind < 2; ++kind) {
        set_sie(enabled); write_count = 0; registers[TRIGGER / 4] = 0;
        rx_store_context_check(context, kind);
        uint32_t expected = kind ? 0x87654321u : 0x12345678u;
        CHECK(write_count == 1 && writes[0].address == MMIO_BASE + TRIGGER &&
              writes[0].value == expected && last_width == (kind ? 2u : 4u) &&
              registers[TRIGGER / 4] == expected && *(volatile uint32_t *)(MMIO_BASE + TRIGGER) == expected);
        for (uint32_t i = 0; i < 32; ++i) CHECK(context[i] == context[i + 32]);
        CHECK(sie() == enabled);
    }
    const uint32_t hindices[] = {0, 1, 39, 40}, pindices[] = {0, 1, 38, 39, 40};
    const uint32_t seeds[] = {0, UINT32_MAX, 0xa5a55a5a, 0xffff0000, 0x0000ffff};
    for (uint32_t irq = 0; irq <= 2; irq += 2)
    for (uint32_t s = 0; s < 5; ++s) {
        for (uint32_t h = 0; h < 4; ++h) for (uint32_t match = 0; match < 2; ++match)
        for (uint32_t empty = 0; empty < 2; ++empty) {
            int r = pair(0, hindices[h], 0, match, 0, 0, empty, seeds[s], irq); if (r) return r;
        }
        for (uint32_t p = 0; p < 5; ++p) for (uint32_t match = 0; match < 2; ++match)
        for (uint32_t prev = 0; prev < 3; ++prev) {
            int r = pair(1, 0, pindices[p], 0, match, prev, 0, seeds[s], irq); if (r) return r;
        }
        for (uint32_t h = 0; h < 4; ++h) for (uint32_t p = 0; p < 5; ++p)
        for (uint32_t hm = 0; hm < 2; ++hm) for (uint32_t pm = 0; pm < 2; ++pm)
        for (uint32_t prev = 0; prev < 2; ++prev) for (uint32_t empty = 0; empty < 2; ++empty) {
            int r = pair(2, hindices[h], pindices[p], hm, pm, prev, empty, seeds[s], irq); if (r) return r;
        }
    }
    CHECK(fixture_error == 0 && probe_error == 0);
    return 0;
}
int wifi_rx_descriptor_probe_main(void) { setup_mapping(); return rx_supervisor_enter(); }
void wifi_rx_descriptor_probe_report(uint32_t result) {
    volatile unsigned char *uart = (volatile unsigned char *)0x10000000;
    const char *text = result ? "RXDESC RV32 FAIL " : "RXDESC RV32 PASS ";
    while (*text) { while (!(uart[5] & 0x20)) {} uart[0] = *text++; }
    uint32_t values[] = {wifi_rx_descriptor_probe_cases, wifi_rx_descriptor_probe_checks, result,
        wifi_rx_descriptor_probe_difference, fixture_error, active_vendor};
    for (uint32_t i = 0; i < sizeof(values) / 4; ++i) {
        print_hex(values[i]); while (!(uart[5] & 0x20)) {} uart[0] = ' ';
    }
    if (result) for (uint32_t i = 0; i < 9; ++i) {
        print_hex(last_case[i]); while (!(uart[5] & 0x20)) {} uart[0] = ' ';
    }
    while (!(uart[5] & 0x20)) {} uart[0] = '\n';
}
