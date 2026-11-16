/* C callers exercise the compiler's variadic ABI, not a hand-built argument list. */
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

volatile unsigned int wifi_console_format_probe_checks;

static int validate(const unsigned char *actual, size_t capacity,
                    const unsigned char *expected, size_t length, int count) {
    if (count != (int)length) return 0;
    size_t stored = capacity ? (length < capacity - 1 ? length : capacity - 1) : 0;
    for (size_t i = 0; i < 8; ++i) if (actual[i] != 0xa5) return 0;
    for (size_t i = 0; i < stored; ++i) if (actual[8 + i] != expected[i]) return 0;
    if (capacity && actual[8 + stored]) return 0;
    size_t untouched = 8 + stored + (capacity != 0);
    for (size_t i = untouched; i < 96; ++i) if (actual[i] != 0xa5) return 0;
    ++wifi_console_format_probe_checks;
    return 1;
}

#define VERIFY(expected, format, ...) do { \
    ++case_id; \
    static const size_t capacities[] = {0, 1, 2, 4, 15, 64}; \
    for (unsigned int c = 0; c < sizeof(capacities) / sizeof(capacities[0]); ++c) { \
        unsigned char actual[96]; \
        for (unsigned int i = 0; i < sizeof(actual); ++i) actual[i] = 0xa5; \
        int count = snprintf((char *)actual + 8, capacities[c], format, __VA_ARGS__); \
        if (!validate(actual, capacities[c], (const unsigned char *)(expected), \
                      sizeof(expected) - 1, count)) return case_id; \
    } \
} while (0)

int wifi_console_format_probe_main(void) {
    unsigned int case_id = 0;
    VERIFY("-2147483648:4294967295:OK", "%d:%u:%s", INT32_MIN, UINT32_MAX, "OK");
    VERIFY("A:-4294967297|18446744073709551615|173", "A:%lld|%llu|%d",
           -4294967297LL, (unsigned long long)UINT64_MAX, 173);
    VERIFY("0|1234605616436508552|-7|18446744073709551615|-9223372036854775808|193",
           "%d|%llu|%d|%llu|%lld|%d", 0, 0x1122334455667788ULL, -7,
           (unsigned long long)UINT64_MAX, (long long)INT64_MIN, 193);
    VERIFY("-2147483648|4294967295|abcd|173", "%ld|%lu|%lx|%d",
           (long)INT32_MIN, (unsigned long)UINT32_MAX, 0xabcdUL, 173);
    VERIFY("0x00abcd|-0000007|tex||0", "%#08x|%+08d|%.3s|%.0u|%#.0o",
           0xabcdU, -7, "text", 0U, 0U);
    VERIFY("-9223372036854775808|18446744073709551615", "%jd|%ju",
           (intmax_t)INT64_MIN, (uintmax_t)UINT64_MAX);
    VERIFY("4294967295|-2147483648|-2147483648|4294967295", "%zu|%zd|%td|%tu",
           (size_t)UINT32_MAX,
           _Generic((size_t)0, unsigned int: (int)INT32_MIN,
                    unsigned long: (long)INT32_MIN, unsigned long long: (long long)INT32_MIN),
           (ptrdiff_t)INT32_MIN,
           _Generic((ptrdiff_t)0, int: (unsigned int)UINT32_MAX,
                    long: (unsigned long)UINT32_MAX, long long: (unsigned long long)UINT32_MAX));
    VERIFY("-1|-1|255|65535", "%hhd|%hd|%hhu|%hu", 255, 65535, 255, 65535);
    VERIFY("A\0B", "A%cB", 0);
    const char bounded[3] = {'A', 'B', 'C'};
    VERIFY("ABC:0x12345678", "%.3s:%p", bounded, (void *)(uintptr_t)0x12345678U);
#ifndef WIFI_CONSOLE_FORMAT_NO_SPRINTF
    {
        const char expected[] = "S:-4294967297|18446744073709551615|17";
        unsigned char actual[96];
        for (unsigned int i = 0; i < sizeof(actual); ++i) actual[i] = 0xa5;
        int count = sprintf((char *)actual + 8, "S:%lld|%llu|%d",
                            -4294967297LL, (unsigned long long)UINT64_MAX, 17);
        if (!validate(actual, sizeof(expected), (const unsigned char *)expected,
                      sizeof(expected) - 1, count)) return 100;
    }
#endif
#ifndef WIFI_CONSOLE_FORMAT_HOST
    char output[8];
    if (snprintf(output, sizeof(output), "%2147483647d", 0) != INT32_MAX) return 101;
    if (output[7] != 0) return 102;
    for (unsigned int i = 0; i < 7; ++i) if (output[i] != ' ') return 103;
    ++wifi_console_format_probe_checks;
    if (snprintf(output, sizeof(output), "%2147483647dX", 0) != -1) return 104;
    ++wifi_console_format_probe_checks;
    if (snprintf(NULL, 0, "%llu:%d", (unsigned long long)UINT64_MAX, 17) != 23) return 105;
    ++wifi_console_format_probe_checks;
#endif
    return 0;
}

#ifdef WIFI_CONSOLE_FORMAT_HOST
int main(void) { return wifi_console_format_probe_main(); }
#else
void wifi_console_format_probe_report(unsigned int result) {
    volatile unsigned char *uart = (volatile unsigned char *)0x10000000U;
    const char *text = result ? "CONSOLE-FORMAT RV32 FAIL checks=0x" : "CONSOLE-FORMAT RV32 PASS checks=0x";
    while (*text) {
        while (!(uart[5] & 0x20)) { }
        uart[0] = (unsigned char)*text++;
    }
    for (int shift = 28; shift >= 0; shift -= 4) {
        unsigned int digit = (wifi_console_format_probe_checks >> shift) & 15;
        while (!(uart[5] & 0x20)) { }
        uart[0] = (unsigned char)(digit < 10 ? '0' + digit : 'a' + digit - 10);
    }
    while (!(uart[5] & 0x20)) { }
    uart[0] = '\n';
}
#endif
