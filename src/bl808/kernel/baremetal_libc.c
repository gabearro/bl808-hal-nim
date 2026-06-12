/*
 * Minimal libc stubs for bare-metal RTOS (mm:arc + useMalloc).
 * Provides memset, memcpy, memmove, strlen, exit, abort.
 */

#include <stddef.h>
#include <stdint.h>

void *memset(void *s, int c, size_t n) {
    unsigned char *p = (unsigned char *)s;
    while (n--) *p++ = (unsigned char)c;
    return s;
}

void *memcpy(void *dest, const void *src, size_t n) {
    unsigned char *d = (unsigned char *)dest;
    const unsigned char *s = (const unsigned char *)src;
    while (n--) *d++ = *s++;
    return dest;
}

void *memmove(void *dest, const void *src, size_t n) {
    unsigned char *d = (unsigned char *)dest;
    const unsigned char *s = (const unsigned char *)src;
    if (d < s) {
        while (n--) *d++ = *s++;
    } else {
        d += n; s += n;
        while (n--) *--d = *--s;
    }
    return dest;
}

size_t strlen(const char *s) {
    const char *p = s;
    while (*p) p++;
    return (size_t)(p - s);
}

char *strcpy(char *dest, const char *src) {
    char *d = dest;
    while ((*d++ = *src++));
    return dest;
}

char *strncpy(char *dest, const char *src, size_t n) {
    size_t i;
    for (i = 0; i < n && src[i]; i++) dest[i] = src[i];
    for (; i < n; i++) dest[i] = '\0';
    return dest;
}

char *strchr(const char *s, int c) {
    while (*s) {
        if (*s == (char)c) return (char *)s;
        s++;
    }
    return (c == 0) ? (char *)s : (void *)0;
}

int strcmp(const char *s1, const char *s2) {
    while (*s1 && *s1 == *s2) { s1++; s2++; }
    return *(unsigned char *)s1 - *(unsigned char *)s2;
}

size_t strspn(const char *s, const char *accept) {
    const char *p = s;
    while (*p) {
        const char *a = accept;
        int found = 0;
        while (*a) {
            if (*p == *a) { found = 1; break; }
            a++;
        }
        if (!found) break;
        p++;
    }
    return (size_t)(p - s);
}

size_t strcspn(const char *s, const char *reject) {
    const char *p = s;
    while (*p) {
        const char *r = reject;
        while (*r) {
            if (*p == *r) return (size_t)(p - s);
            r++;
        }
        p++;
    }
    return (size_t)(p - s);
}

int memcmp(const void *s1, const void *s2, size_t n) {
    const unsigned char *a = (const unsigned char *)s1;
    const unsigned char *b = (const unsigned char *)s2;
    while (n--) {
        if (*a != *b) return *a - *b;
        a++; b++;
    }
    return 0;
}

/* GCC builtins for platforms without libgcc (e.g., RV32E) */
int __clzsi2(unsigned int x) {
    if (x == 0) return 32;
    int n = 0;
    if (x <= 0x0000FFFF) { n += 16; x <<= 16; }
    if (x <= 0x00FFFFFF) { n += 8;  x <<= 8;  }
    if (x <= 0x0FFFFFFF) { n += 4;  x <<= 4;  }
    if (x <= 0x3FFFFFFF) { n += 2;  x <<= 2;  }
    if (x <= 0x7FFFFFFF) { n += 1; }
    return n;
}

int __ctzsi2(unsigned int x) {
    if (x == 0) return 32;
    int n = 0;
    if ((x & 0x0000FFFF) == 0) { n += 16; x >>= 16; }
    if ((x & 0x000000FF) == 0) { n += 8;  x >>= 8;  }
    if ((x & 0x0000000F) == 0) { n += 4;  x >>= 4;  }
    if ((x & 0x00000003) == 0) { n += 2;  x >>= 2;  }
    if ((x & 0x00000001) == 0) { n += 1; }
    return n;
}

uint64_t __udivdi3(uint64_t n, uint64_t d) {
    uint64_t q = 0;
    uint64_t bit = 1;

    if (d == 0) {
        return UINT64_MAX;
    }

    while ((d & (1ULL << 63)) == 0 && d < n) {
        d <<= 1;
        bit <<= 1;
    }

    while (bit != 0) {
        if (n >= d) {
            n -= d;
            q |= bit;
        }
        d >>= 1;
        bit >>= 1;
    }

    return q;
}

/* Network byte-order conversion (RISC-V is little-endian) */
unsigned short htons(unsigned short x) {
    return (x >> 8) | (x << 8);
}

unsigned short ntohs(unsigned short x) {
    return htons(x);
}

unsigned int htonl(unsigned int x) {
    return ((x & 0xFF) << 24) |
           ((x & 0xFF00) << 8) |
           ((x & 0xFF0000) >> 8) |
           ((x & 0xFF000000) >> 24);
}

unsigned int ntohl(unsigned int x) {
    return htonl(x);
}

__attribute__((weak)) int abs(int value) {
    return value < 0 ? -value : value;
}

/* The double-precision log() fallback drags in soft-float (__divdf3 etc). The
 * E902 (LP) builds rv32emc / ilp32e and has no FP, and the toolchain ships no
 * rv32e libgcc multilib, so linking it fails. M0/D0 have FP and keep it; LP
 * never calls log(), so omit it there. */
#ifndef __riscv_abi_rve
__attribute__((weak)) double log(double x) {
    union {
        double d;
        uint64_t u;
    } v;
    const double ln2 = 0.69314718055994530942;
    double y;
    double y2;
    double term;
    double sum;
    int exp;

    if (x <= 0.0) {
        return -1.0e308;
    }

    v.d = x;
    exp = (int)((v.u >> 52) & 0x7ffu) - 1023;
    v.u = (v.u & 0x000fffffffffffffull) | (uint64_t)0x3ff0000000000000ull;

    y = (v.d - 1.0) / (v.d + 1.0);
    y2 = y * y;
    term = y;
    sum = term;
    for (int n = 3; n <= 21; n += 2) {
        term *= y2;
        sum += term / (double)n;
    }
    return 2.0 * sum + (double)exp * ln2;
}
#endif /* !__riscv_abi_rve */

/* Nim's ARC runtime calls exit() on fatal errors */
void exit(int status) {
    (void)status;
    while (1) {
        __asm__ volatile("wfi");
    }
}

void abort(void) {
    while (1) {
        __asm__ volatile("wfi");
    }
}

/* ============================================================================
 * _ctype_ table — newlib-format character-classification table.
 *
 * Vendor lwIP's vendor/lwip/src/core/ipv4/ip4_addr.c uses <ctype.h> macros
 * (isdigit, isalpha, etc.) which expand to lookups against this table. We
 * build freestanding (-nostdlib), so newlib's libc.a is not in the link;
 * supply a minimal ASCII-only table that satisfies those references.
 *
 * The table has 257 entries: index 0 is the value for EOF (-1+1=0); indices
 * 1..256 correspond to characters 0..255. Bit flags per newlib convention:
 *   _U=01 upper, _L=02 lower, _N=04 numeric, _S=010 whitespace,
 *   _P=020 punct, _C=040 control, _X=0100 hex, _B=0200 blank.
 * ========================================================================== */

#define _U 01
#define _L 02
#define _N 04
#define _S 010
#define _P 020
#define _C 040
#define _X 0100
#define _B 0200

const char _ctype_[1 + 256] = {
    0,
    _C,     _C,     _C,     _C,     _C,     _C,     _C,     _C,
    _C,     _C|_S,  _C|_S,  _C|_S,  _C|_S,  _C|_S,  _C,     _C,
    _C,     _C,     _C,     _C,     _C,     _C,     _C,     _C,
    _C,     _C,     _C,     _C,     _C,     _C,     _C,     _C,
    _S|_B,  _P,     _P,     _P,     _P,     _P,     _P,     _P,
    _P,     _P,     _P,     _P,     _P,     _P,     _P,     _P,
    _N,     _N,     _N,     _N,     _N,     _N,     _N,     _N,
    _N,     _N,     _P,     _P,     _P,     _P,     _P,     _P,
    _P,     _U|_X,  _U|_X,  _U|_X,  _U|_X,  _U|_X,  _U|_X,  _U,
    _U,     _U,     _U,     _U,     _U,     _U,     _U,     _U,
    _U,     _U,     _U,     _U,     _U,     _U,     _U,     _U,
    _U,     _U,     _U,     _P,     _P,     _P,     _P,     _P,
    _P,     _L|_X,  _L|_X,  _L|_X,  _L|_X,  _L|_X,  _L|_X,  _L,
    _L,     _L,     _L,     _L,     _L,     _L,     _L,     _L,
    _L,     _L,     _L,     _L,     _L,     _L,     _L,     _L,
    _L,     _L,     _L,     _P,     _P,     _P,     _P,     _C,
    /* 128..255 — non-ASCII; left zero-classified */
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0
};
