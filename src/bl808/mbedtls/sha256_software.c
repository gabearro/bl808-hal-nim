/* Keep the vendored Mbed TLS software SHA-224/256 block function for the
 * run-time fallback, exactly as wifi/mbedtls_sha1_software.c does for SHA-1.
 * sha256.c itself is built with MBEDTLS_SHA256_PROCESS_ALT; the public block
 * function comes from Nim (sha256_alt.nim). The unused renamed stream entry
 * points are discarded by section GC. */
#undef BL808_MBEDTLS_HW_SHA256
#define mbedtls_internal_sha256_process bl808_software_sha256_process
#define mbedtls_sha256_init bl808_software_sha256_init
#define mbedtls_sha256_free bl808_software_sha256_free
#define mbedtls_sha256_clone bl808_software_sha256_clone
#define mbedtls_sha256_starts bl808_software_sha256_starts
#define mbedtls_sha256_update bl808_software_sha256_update
#define mbedtls_sha256_finish bl808_software_sha256_finish
#define mbedtls_sha256 bl808_software_sha256
#define mbedtls_sha256_self_test bl808_software_sha256_self_test
#define mbedtls_sha224_self_test bl808_software_sha224_self_test
#include "../../../vendor/mbedtls/library/sha256.c"

#undef mbedtls_internal_sha256_process

extern int bl808_mbedtls_sha256_process(mbedtls_sha256_context *ctx,
                                        const unsigned char *data);

int mbedtls_internal_sha256_process(mbedtls_sha256_context *ctx,
                                    const unsigned char data[64])
{
    return bl808_mbedtls_sha256_process(ctx, data);
}
