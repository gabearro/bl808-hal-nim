/* Keep the vendored Mbed TLS software SHA-384/512 block function for the
 * run-time fallback, exactly as sha256_software.c does for SHA-224/256.
 * sha512.c itself is built with MBEDTLS_SHA512_PROCESS_ALT; the public block
 * function comes from Nim (sha512_alt.nim). The unused renamed stream entry
 * points are discarded by section GC. */
#undef BL808_MBEDTLS_HW_SHA512
#define mbedtls_internal_sha512_process bl808_software_sha512_process
#define mbedtls_sha512_init bl808_software_sha512_init
#define mbedtls_sha512_free bl808_software_sha512_free
#define mbedtls_sha512_clone bl808_software_sha512_clone
#define mbedtls_sha512_starts bl808_software_sha512_starts
#define mbedtls_sha512_update bl808_software_sha512_update
#define mbedtls_sha512_finish bl808_software_sha512_finish
#define mbedtls_sha512 bl808_software_sha512
#define mbedtls_sha512_self_test bl808_software_sha512_self_test
#define mbedtls_sha384_self_test bl808_software_sha384_self_test
#include "../../../vendor/mbedtls/library/sha512.c"

#undef mbedtls_internal_sha512_process

extern int bl808_mbedtls_sha512_process(mbedtls_sha512_context *ctx,
                                        const unsigned char *data);

int mbedtls_internal_sha512_process(mbedtls_sha512_context *ctx,
                                    const unsigned char data[128])
{
    return bl808_mbedtls_sha512_process(ctx, data);
}
