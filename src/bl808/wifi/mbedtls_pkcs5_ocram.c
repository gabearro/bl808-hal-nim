#include <mbedtls/pkcs5.h>
#include "mbedtls_hot_ocram.h"

BL808_MBEDTLS_OCRAM(mbedtls_pkcs5_pbkdf2_hmac);

/* Mbed TLS 3 moved the iteration loop into a file-local function that the
 * public entry point only forwards to. Fold it back so the loop is placed
 * (and profiled) under the public name, as it was with Mbed TLS 2. */
static inline int pkcs5_pbkdf2_hmac(mbedtls_md_context_t *ctx,
                                    const unsigned char *password, size_t plen,
                                    const unsigned char *salt, size_t slen,
                                    unsigned int iteration_count,
                                    uint32_t key_length, unsigned char *output)
    __attribute__((always_inline));

#include "../../../vendor/mbedtls/library/pkcs5.c"
