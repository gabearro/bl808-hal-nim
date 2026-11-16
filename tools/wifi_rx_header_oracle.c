/* Restricted RX header comparison. TKIP/CCMP vendor paths are not executed. */
#include <stdint.h>
#include <stddef.h>

#ifndef FIXTURE_FAULT
#define FIXTURE_FAULT 0
#endif

_Static_assert(sizeof(void *) == 4, "RV32 ABI required");
unsigned char probe_error __asm__(ERROR_SYMBOL);
extern uint8_t rxu_cntrl_env[96];
extern uint8_t vendor_rxu_cntrl_env[96];
uint32_t vendor_sta_info_tab[644], vendor_vif_info_tab[756];
extern uint8_t rxu_cntrl_machdr_len_get(uint16_t);
extern uint8_t vendor_rxu_cntrl_machdr_len_get(uint16_t);
extern int rxu_cntrl_protected_handle(void *, uint32_t);
extern int vendor_rxu_cntrl_protected_handle(void *, uint32_t);
static uint32_t header_cases, protected_cases, checks, difference, fixture_error;
static uint32_t categories[6];
static uint8_t packet[96], before[96], initial[96], expected[96], observed[2][96];

void *memset(void *p, int value, size_t count) {
    uint8_t *b = p;
    for (size_t i = 0; i < count; ++i) b[i] = value;
    return p;
}
void *memcpy(void *to, const void *from, size_t count) {
    uint8_t *d = to; const uint8_t *s = from;
    for (size_t i = 0; i < count; ++i) d[i] = s[i];
    return to;
}
static int equal(const void *a, const void *b, size_t count) {
    const uint8_t *x = a, *y = b;
    for (size_t i = 0; i < count; ++i) if (x[i] != y[i]) return 0;
    return 1;
}
int printf(const char *format, ...) { (void)format; return 0; }
int puts(const char *text) { (void)text; return 0; }
void hw_validation_log_byte(uint8_t byte) { (void)byte; }
static uint32_t irq(void) {
    uint32_t value; __asm__ volatile("csrr %0, mstatus" : "=r"(value)); return value & 8;
}
static void set_irq(uint32_t value) {
    if (value) __asm__ volatile("csrsi mstatus, 8" ::: "memory");
    else __asm__ volatile("csrci mstatus, 8" ::: "memory");
}
#define CHECK(condition, code) do { \
    if (!(condition)) { difference = (code); return __LINE__; } ++checks; \
} while (0)

/* These describe the observed helper contracts, not validity of every FC. */
static uint32_t nim_length(uint16_t fc) {
    switch (fc & 12) {
    case 0: return 24 + ((fc & 0x8000) ? 4 : 0);
    case 4: return (fc & 0xe0) == 0xc0 ? 10 : 16;
    case 8: return ((fc & 0x300) == 0x300 ? 30 : 24) +
        ((fc & 0x80) ? 2 + ((fc & 0x8000) ? 4 : 0) : 0);
    default: return 0;
    }
}
static uint32_t vendor_length(uint16_t fc) {
    return ((fc & 0x300) == 0x300 ? 30 : 24) +
        ((fc & 0xfc) == 0x88 ? 2 : 0) + ((fc & 0x8000) ? 4 : 0);
}
static uint32_t category(uint16_t fc) {
    switch (fc & 12) {
    case 0: return (fc & 0x300) == 0x300 ? 1 : 0;
    case 4: return 2;
    case 12: return 3;
    default:
        if ((fc & 0x80) && (fc & 0xfc) != 0x88) return 5;
        return !(fc & 0x80) && (fc & 0x8000) ? 4 : 0;
    }
}
int wifi_rx_header_probe_main(void) {
    const uint32_t totals[] = {17408, 4096, 16384, 16384, 4096, 7168};
    const uint32_t lengths[] = {24, 26, 28, 30, 32, 36};
    const uint32_t noise[] = {0, 0x20026000, 0x810181e3, 0xfffffbe3};
    for (uint32_t raw = 0; raw < 65536; ++raw) {
        uint32_t incoming = (raw & 1) ? 8 : 0;
        set_irq(incoming);
        uint32_t a = rxu_cntrl_machdr_len_get(raw);
        uint32_t b = vendor_rxu_cntrl_machdr_len_get(raw);
        uint32_t bucket = category(raw);
        if (FIXTURE_FAULT == 1 && raw == 0x88) a ^= 2;
        if (FIXTURE_FAULT == 2 && raw == 0) bucket = 3;
        CHECK(a == nim_length(raw), 1);
        CHECK(b == vendor_length(raw), 2);
        CHECK((a == b) == (bucket == 0), 3);
        CHECK(irq() == incoming, 4);
        ++categories[bucket]; ++header_cases;
    }
    for (uint32_t i = 0; i < 6; ++i) CHECK(categories[i] == totals[i], 5);
    for (uint32_t kind = 0; kind <= 28; kind += 4) {
        if (kind == 24 || kind == 28) continue;
        for (uint32_t flagged = 0; flagged < 2; ++flagged)
        for (uint32_t l = 0; l < 6; ++l)
        for (uint32_t alignment = 0; alignment < 4; ++alignment)
        for (uint32_t seed = 0; seed < 4; ++seed)
        for (uint32_t incoming = 0; incoming <= 8; incoming += 8)
        for (uint32_t n = 0; n < 4; ++n) {
            for (uint32_t i = 0; i < 96; ++i) {
                initial[i] = (i * 73 + seed * 97) & 255;
                before[i] = (i * 43 + seed * 61) & 255;
            }
            initial[8] = lengths[l]; initial[9] = 255; initial[10] = 255;
            memcpy(expected, initial, 96);
            if (kind == 20) expected[8] += 4;
            uint32_t flags = kind | (flagged ? 0x400 : 0) | noise[n];
            for (uint32_t vendor = 0; vendor < 2; ++vendor) {
                uint8_t *env = vendor ? vendor_rxu_cntrl_env : rxu_cntrl_env;
                memcpy(env, initial, 96); memcpy(packet, before, 96);
                set_irq(incoming);
                int accepted = vendor ? vendor_rxu_cntrl_protected_handle(packet + alignment, flags) :
                    rxu_cntrl_protected_handle(packet + alignment, flags);
                if (!vendor && FIXTURE_FAULT == 3) env[16] ^= 1;
                if (!vendor && FIXTURE_FAULT == 4) packet[95] ^= 1;
                CHECK(accepted == (kind == 20), 6);
                CHECK(equal(env, expected, 96), 7);
                CHECK(equal(packet, before, 96), 8);
                CHECK(irq() == incoming, 9);
                memcpy(observed[vendor], env, 96);
            }
            CHECK(equal(observed[0], observed[1], 96), 10);
            ++protected_cases;
        }
    }
    CHECK(probe_error == 0 && fixture_error == 0, 11);
    return 0;
}
static void byte(uint8_t value) {
    volatile uint8_t *uart = (volatile uint8_t *)0x10000000;
    while (!(uart[5] & 0x20)) {} uart[0] = value;
}
static void hex(uint32_t value) {
    for (int shift = 28; shift >= 0; shift -= 4) {
        uint32_t digit = (value >> shift) & 15;
        byte(digit < 10 ? '0' + digit : 'a' + digit - 10);
    }
    byte(' ');
}
void wifi_rx_header_probe_report(uint32_t result) {
    const char *text = result ? "RXHEADER RV32 FAIL " : "RXHEADER RV32 PASS ";
    while (*text) byte(*text++);
    uint32_t values[] = {header_cases, protected_cases, checks, result, difference, fixture_error};
    for (uint32_t i = 0; i < 6; ++i) hex(values[i]);
    for (uint32_t i = 0; i < 6; ++i) hex(categories[i]);
    byte('\n');
}
