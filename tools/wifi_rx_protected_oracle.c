/* Original TKIP/CCMP execution; no radio, key installation or packet delivery. */
#include <stdint.h>
#include <stddef.h>

#ifndef FIXTURE_FAULT
#define FIXTURE_FAULT 0
#endif
_Static_assert(sizeof(void *) == 4, "RV32 key/context ABI required");
unsigned char probe_error __asm__(ERROR_SYMBOL);
extern uint8_t rxu_cntrl_env[96], vendor_rxu_cntrl_env[96];
extern uint8_t sta_info_tab[2576], vif_info_tab[3024];
extern int rxu_cntrl_protected_handle(void *, uint32_t), vendor_rxu_cntrl_protected_handle(void *, uint32_t);
extern uint32_t protected_wexti_a6(uint32_t, uint32_t), protected_wexti_t3(uint32_t, uint32_t);
static uint32_t matrix_cases, wire_cases, checks, instruction_checks, difference;
static uint32_t last_inputs[8];
static uint8_t initial[96], expected[96], packet[96], before[96], observed[2][96];

void *memset(void *p, int value, size_t count) {
    uint8_t *d = p;
    for (size_t i = 0; i < count; ++i) d[i] = value;
    return p;
}
void *memcpy(void *d, const void *s, size_t count) {
    uint8_t *to = d; const uint8_t *from = s;
    for (size_t i = 0; i < count; ++i) to[i] = from[i];
    return d;
}
int printf(const char *format, ...) { (void)format; return 0; }
int puts(const char *text) { (void)text; return 0; }
void hw_validation_log_byte(uint8_t value) { (void)value; }
static int equal(const void *a, const void *b, uint32_t count) {
    const uint8_t *x = a, *y = b;
    for (uint32_t i = 0; i < count; ++i) if (x[i] != y[i]) return 0;
    return 1;
}
static void put32(uint8_t *p, uint32_t value) {
    for (uint32_t i = 0; i < 4; ++i) p[i] = value >> (8 * i);
}
static uint32_t irq(void) {
    uint32_t value; __asm__ volatile("csrr %0, mstatus" : "=r"(value)); return value & 8;
}
static void set_irq(uint32_t value) {
    if (value) __asm__ volatile("csrsi mstatus, 8" ::: "memory");
    else __asm__ volatile("csrci mstatus, 8" ::: "memory");
}
static uint8_t key_byte(uint32_t offset) { return (offset * 37 + 41) & 255; }
static int key_intact(const uint8_t *key, const uint8_t *base, uint32_t size) {
    uint32_t offset = key - base;
    for (uint32_t i = 0; i < size; ++i) if (key[i] != key_byte(offset + i)) return 0;
    return 1;
}
#define CHECK(condition, code) do { \
    if (!(condition)) { difference = code; return __LINE__; } ++checks; \
} while (0)

static int run_case(uint32_t kind, uint32_t group, uint32_t offset, uint32_t alignment,
                    uint32_t sta, uint32_t vif, uint32_t seed, uint32_t incoming,
                    const uint8_t wire[8], uint32_t noise) {
    uint32_t args[] = {kind, group, offset, alignment, sta, vif, seed, incoming};
    memcpy(last_inputs, args, sizeof(args));
    for (uint32_t i = 0; i < 96; ++i) {
        initial[i] = (i * 73 + seed * 97) & 255;
        before[i] = (i * 43 + seed * 61) & 255;
    }
    initial[8] = offset; initial[9] = sta; initial[10] = vif;
    memcpy(before + alignment + offset, wire, 8);
    memcpy(expected, initial, 96);
    expected[8] += 8;
    uint32_t lo = (kind == 24 ? wire[2] | ((uint32_t)wire[0] << 8) :
                    wire[0] | ((uint32_t)wire[1] << 8)) |
                  ((uint32_t)wire[4] << 16) | ((uint32_t)wire[5] << 24);
    put32(expected + 16, lo); put32(expected + 20, wire[6] | ((uint32_t)wire[7] << 8));
    uint8_t *base = group ? vif_info_tab : sta_info_tab;
    uint8_t *key = base + (group ? vif * 1512 + 528 + (wire[3] >> 6) * 160 : sta * 368 + 80);
    put32(expected + 32, (uint32_t)key);
    expected[48] |= kind == 24 ? 3 : 2;
    uint32_t flags = kind | (group ? 0x400 : 0) | noise;
    for (uint32_t side = 0; side < 2; ++side) {
        uint8_t *env = side ? vendor_rxu_cntrl_env : rxu_cntrl_env;
        memcpy(env, initial, 96); memcpy(packet, before, 96);
        set_irq(incoming);
        int accepted = side ? vendor_rxu_cntrl_protected_handle(packet + alignment, flags) :
            rxu_cntrl_protected_handle(packet + alignment, flags);
        if (!side) {
            if (FIXTURE_FAULT == 2) env[16] ^= 1;
            if (FIXTURE_FAULT == 3) env[32] ^= 4;
            if (FIXTURE_FAULT == 4) env[48] ^= 0x80;
            if (FIXTURE_FAULT == 5) env[4] ^= 1;
            if (FIXTURE_FAULT == 6) packet[95] ^= 1;
        }
        CHECK(accepted == 1, 3);
        CHECK(equal(env, expected, 96), 4);
        CHECK(equal(packet, before, 96), 5);
        CHECK(irq() == incoming, 6);
        CHECK(key_intact(key, base, 160), 7);
        memcpy(observed[side], env, 96);
    }
    CHECK(equal(observed[0], observed[1], 96), 8);
    return 0;
}
int wifi_rx_protected_probe_main(void) {
    static const uint32_t values[] = {0, 1, 0x7fff, 0x8000, 0xffff, 0x80000000, 0xffffffff, 0x12345678};
    static const uint32_t lengths[] = {24, 26, 28, 30, 32, 36};
    static const uint32_t noise[] = {0, 0x20026000, 0x810181e3, 0xfffffbe3};
    for (uint32_t i = 0; i < 8; ++i) for (uint32_t j = 0; j < 8; ++j) {
        uint32_t expected_word = (((uint64_t)values[j] << 32) | values[i]) >> 16;
        uint32_t a = protected_wexti_a6(values[i], values[j]);
        uint32_t b = protected_wexti_t3(values[i], values[j]);
        if (FIXTURE_FAULT == 1 && i == 0 && j == 0) a ^= 1;
        CHECK(a == expected_word, 1); ++instruction_checks;
        CHECK(b == expected_word, 2); ++instruction_checks;
    }
    for (uint32_t i = 0; i < 2576; ++i) sta_info_tab[i] = key_byte(i);
    for (uint32_t i = 0; i < 3024; ++i) vif_info_tab[i] = key_byte(i);
    for (uint32_t kind = 24; kind <= 28; kind += 4)
    for (uint32_t sta = 0; sta < 7; ++sta)
    for (uint32_t vif = 0; vif < 2; ++vif)
    for (uint32_t id = 0; id < 4; ++id)
    for (uint32_t group = 0; group < 2; ++group)
    for (uint32_t l = 0; l < 6; ++l)
    for (uint32_t alignment = 0; alignment < 4; ++alignment)
    for (uint32_t seed = 0; seed < 4; ++seed)
    for (uint32_t incoming = 0; incoming <= 8; incoming += 8)
    for (uint32_t n = 0; n < 4; ++n) {
        uint8_t wire[8];
        for (uint32_t i = 0; i < 8; ++i) wire[i] = (i * 59 + seed * 43) & 255;
        wire[3] = (wire[3] & 63) | (id << 6);
        int result = run_case(kind, group, lengths[l], alignment, sta, vif, seed, incoming, wire, noise[n]);
        if (result) return result;
        ++matrix_cases;
    }
    for (uint32_t kind = 24; kind <= 28; kind += 4)
    for (uint32_t position = 0; position < 8; ++position)
    for (uint32_t value = 0; value < 256; ++value)
    for (uint32_t group = 0; group < 2; ++group)
    for (uint32_t incoming = 0; incoming <= 8; incoming += 8) {
        uint8_t wire[] = {0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0};
        wire[position] = value;
        int result = run_case(kind, group, lengths[position % 6], value & 3,
                             (position + value) % 7, position & 1, value, incoming, wire, 0x20026000);
        if (result) return result;
        ++wire_cases;
    }
    CHECK(probe_error == 0 && key_intact(sta_info_tab, sta_info_tab, 2576) &&
          key_intact(vif_info_tab, vif_info_tab, 3024), 9);
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
void wifi_rx_protected_probe_report(uint32_t result) {
    const char *text = result ? "RXPROTECTED RV32 FAIL " : "RXPROTECTED RV32 PASS ";
    while (*text) byte(*text++);
    hex(matrix_cases); hex(wire_cases); hex(checks); hex(instruction_checks);
    hex(result); hex(difference);
    for (uint32_t i = 0; i < 8; ++i) hex(last_inputs[i]);
    byte('\n');
}
void wifi_rx_protected_trap_report(uint32_t cause, uint32_t pc, uint32_t value) {
    const char *text = "RXPROTECTED TRAP ";
    while (*text) byte(*text++);
    hex(cause); hex(pc); hex(value); byte('\n');
}
