/* The vendored Mbed TLS GCM with its two one-shot entry points routed to the
 * BL808 provider (gcm_alt.nim): the SEC_ENG AES block in CTR mode and the GMAC
 * block, a whole record at a time. Those are the calls TLS makes for every
 * record. The stock implementation is kept as the fallback and for everything
 * else (the streaming interface, IVs that are not 96 bits, ciphers other than
 * AES). */
#include "mbedtls/build_info.h"

#define mbedtls_gcm_crypt_and_tag bl808_software_gcm_crypt_and_tag
#define mbedtls_gcm_auth_decrypt bl808_software_gcm_auth_decrypt
#include "../../../vendor/mbedtls/library/gcm.c"
#undef mbedtls_gcm_crypt_and_tag
#undef mbedtls_gcm_auth_decrypt

#include "mbedtls/aes.h"
#include "mbedtls/platform.h"

/* 0: done, the tag is in `tag`. 1: not handled, nothing written. 2: the
 * hardware failed after overwriting an in-place record. */
extern int bl808_mbedtls_gcm_oneshot(mbedtls_aes_context *aes, int encrypt,
                                     size_t length,
                                     const unsigned char *iv, size_t iv_len,
                                     const unsigned char *add, size_t add_len,
                                     const unsigned char *input,
                                     unsigned char *output,
                                     unsigned char tag[16]);

static mbedtls_aes_context *bl808_gcm_aes(mbedtls_gcm_context *ctx)
{
#if defined(MBEDTLS_BLOCK_CIPHER_C)
    (void) ctx;
    return NULL;
#else
    const mbedtls_cipher_info_t *info = ctx->cipher_ctx.cipher_info;
    if (info == NULL) {
        return NULL;
    }
    switch (mbedtls_cipher_info_get_type(info)) {
        case MBEDTLS_CIPHER_AES_128_ECB:
        case MBEDTLS_CIPHER_AES_192_ECB:
        case MBEDTLS_CIPHER_AES_256_ECB:
            return (mbedtls_aes_context *) ctx->cipher_ctx.cipher_ctx;
        default:
            return NULL;
    }
#endif
}

/* The stock implementation's answer for the provider's first-use check,
 * and the key schedule the provider is handed for the same key. */
int bl808_gcm_reference(const unsigned char *key, unsigned int keybits,
                        size_t length, const unsigned char iv[12],
                        const unsigned char *add, size_t add_len,
                        const unsigned char *input, unsigned char *output,
                        unsigned char tag[16], mbedtls_aes_context *schedule)
{
    mbedtls_gcm_context gcm;
    int ret;

    mbedtls_gcm_init(&gcm);
    mbedtls_aes_init(schedule);
    ret = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key, keybits);
    if (ret == 0) {
        ret = mbedtls_aes_setkey_enc(schedule, key, keybits);
    }
    if (ret == 0) {
        ret = bl808_software_gcm_crypt_and_tag(&gcm, MBEDTLS_GCM_ENCRYPT, length,
                                               iv, 12, add, add_len, input,
                                               output, 16, tag);
    }
    mbedtls_gcm_free(&gcm);
    return ret;
}

static int bl808_gcm_try(mbedtls_gcm_context *ctx, int encrypt, size_t length,
                         const unsigned char *iv, size_t iv_len,
                         const unsigned char *add, size_t add_len,
                         const unsigned char *input, unsigned char *output,
                         size_t tag_len, unsigned char full[16])
{
    mbedtls_aes_context *aes = bl808_gcm_aes(ctx);

    if (aes == NULL || tag_len < 4 || tag_len > 16) {
        return 1;
    }
    return bl808_mbedtls_gcm_oneshot(aes, encrypt, length, iv, iv_len, add,
                                     add_len, input, output, full);
}

int mbedtls_gcm_crypt_and_tag(mbedtls_gcm_context *ctx, int mode, size_t length,
                              const unsigned char *iv, size_t iv_len,
                              const unsigned char *add, size_t add_len,
                              const unsigned char *input, unsigned char *output,
                              size_t tag_len, unsigned char *tag)
{
    unsigned char full[16];
    int hw = bl808_gcm_try(ctx, mode == MBEDTLS_GCM_ENCRYPT, length, iv, iv_len,
                           add, add_len, input, output, tag_len, full);

    if (hw == 0) {
        memcpy(tag, full, tag_len);
        mbedtls_platform_zeroize(full, sizeof(full));
        return 0;
    }
    if (hw != 1) {
        return MBEDTLS_ERR_PLATFORM_HW_ACCEL_FAILED;
    }
    return bl808_software_gcm_crypt_and_tag(ctx, mode, length, iv, iv_len,
                                            add, add_len, input, output,
                                            tag_len, tag);
}

int mbedtls_gcm_auth_decrypt(mbedtls_gcm_context *ctx, size_t length,
                             const unsigned char *iv, size_t iv_len,
                             const unsigned char *add, size_t add_len,
                             const unsigned char *tag, size_t tag_len,
                             const unsigned char *input, unsigned char *output)
{
    unsigned char full[16];
    int hw = bl808_gcm_try(ctx, 0, length, iv, iv_len, add, add_len, input,
                           output, tag_len, full);

    if (hw == 0) {
        int diff = mbedtls_ct_memcmp(tag, full, tag_len);
        mbedtls_platform_zeroize(full, sizeof(full));
        if (diff != 0) {
            mbedtls_platform_zeroize(output, length);
            return MBEDTLS_ERR_GCM_AUTH_FAILED;
        }
        return 0;
    }
    if (hw != 1) {
        return MBEDTLS_ERR_PLATFORM_HW_ACCEL_FAILED;
    }
    return bl808_software_gcm_auth_decrypt(ctx, length, iv, iv_len, add, add_len,
                                           tag, tag_len, input, output);
}
