#include <mbedtls/md.h>
#include <mbedtls/pkcs5.h>
#include <mbedtls/platform.h>
#include <string.h>

int bl808_mbedtls_sha1_lease_begin(void *ctx);
int bl808_mbedtls_sha1_lease_end(void *ctx, int status);

int __real_mbedtls_pkcs5_pbkdf2_hmac(mbedtls_md_context_t *ctx,
    const unsigned char *password, size_t password_len,
    const unsigned char *salt, size_t salt_len, unsigned int rounds,
    uint32_t key_len, unsigned char *key);

/* Scope hardware ownership without changing the stock Mbed TLS call. */
int __wrap_mbedtls_pkcs5_pbkdf2_hmac(mbedtls_md_context_t *ctx,
    const unsigned char *password, size_t password_len,
    const unsigned char *salt, size_t salt_len, unsigned int rounds,
    uint32_t key_len, unsigned char *key)
{
    void *digest = NULL;
    if (ctx != NULL && ctx->md_info != NULL &&
        mbedtls_md_get_type(ctx->md_info) == MBEDTLS_MD_SHA1) {
        digest = ctx->md_ctx;
    }
    int lease = digest != NULL ? bl808_mbedtls_sha1_lease_begin(digest) : 0;
    if (lease < 0) {
        return MBEDTLS_ERR_PLATFORM_HW_ACCEL_FAILED;
    }
    int status = __real_mbedtls_pkcs5_pbkdf2_hmac(ctx, password, password_len,
                                                salt, salt_len, rounds, key_len, key);
    return lease != 0 ? bl808_mbedtls_sha1_lease_end(digest, status) : status;
}

/* RFC 6070, two iterations. Exercise repeated blocks before AP startup. */
int bl808_mbedtls_sha1_lease_selftest(void)
{
    static const unsigned char expected[20] = {
        0xea, 0x6c, 0x01, 0x4d, 0xc7, 0x2d, 0x6f, 0x8c, 0xcd, 0x1e,
        0xd9, 0x2a, 0xce, 0x1d, 0x41, 0xf0, 0xd8, 0xde, 0x89, 0x57
    };
    unsigned char out[sizeof(expected)];
    mbedtls_md_context_t ctx;
    mbedtls_md_init(&ctx);
    int status = mbedtls_md_setup(&ctx, mbedtls_md_info_from_type(MBEDTLS_MD_SHA1), 1);
    if (status == 0) {
        status = __wrap_mbedtls_pkcs5_pbkdf2_hmac(&ctx, (const unsigned char *) "password", 8,
            (const unsigned char *) "salt", 4, 2, sizeof(out), out);
    }
    mbedtls_md_free(&ctx);
    return status == 0 && memcmp(out, expected, sizeof(out)) == 0;
}
