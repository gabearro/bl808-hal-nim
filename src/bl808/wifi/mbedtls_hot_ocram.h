#ifndef BL808_MBEDTLS_HOT_OCRAM_H
#define BL808_MBEDTLS_HOT_OCRAM_H

/* Redeclare the upstream function so its definition inherits placement.
 * A section per function keeps unused entry points eligible for linker GC. */
#define BL808_MBEDTLS_OCRAM(symbol) \
    __typeof__(symbol) symbol __attribute__((section(".ramfunc.mbedtls." #symbol)))

#endif
