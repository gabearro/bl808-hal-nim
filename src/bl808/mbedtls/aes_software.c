/* Keep the vendored Mbed TLS software AES block encryption for the run-time
 * fallback. aes.c itself is built with MBEDTLS_AES_ENCRYPT_ALT; the public
 * block function comes from Nim (aes_alt.nim). This copy uses the compact
 * ROM tables: the generated ones are only filled in by a key schedule of the
 * same translation unit, and that key schedule runs in the real aes.c. The
 * unused renamed entry points are discarded by section GC. */
#undef BL808_MBEDTLS_HW_AES
#undef MBEDTLS_AES_ROM_TABLES
#undef MBEDTLS_AES_FEWER_TABLES
#define MBEDTLS_AES_ROM_TABLES
#define MBEDTLS_AES_FEWER_TABLES
#define mbedtls_internal_aes_encrypt bl808_software_aes_encrypt
#define mbedtls_internal_aes_decrypt bl808_software_aes_decrypt
#define mbedtls_aes_init bl808_software_aes_init
#define mbedtls_aes_free bl808_software_aes_free
#define mbedtls_aes_setkey_enc bl808_software_aes_setkey_enc
#define mbedtls_aes_setkey_dec bl808_software_aes_setkey_dec
#define mbedtls_aes_crypt_ecb bl808_software_aes_crypt_ecb
#define mbedtls_aes_crypt_cbc bl808_software_aes_crypt_cbc
#define mbedtls_aes_crypt_cfb128 bl808_software_aes_crypt_cfb128
#define mbedtls_aes_crypt_cfb8 bl808_software_aes_crypt_cfb8
#define mbedtls_aes_crypt_ofb bl808_software_aes_crypt_ofb
#define mbedtls_aes_crypt_ctr bl808_software_aes_crypt_ctr
#define mbedtls_aes_crypt_xts bl808_software_aes_crypt_xts
#define mbedtls_aes_xts_init bl808_software_aes_xts_init
#define mbedtls_aes_xts_free bl808_software_aes_xts_free
#define mbedtls_aes_xts_setkey_enc bl808_software_aes_xts_setkey_enc
#define mbedtls_aes_xts_setkey_dec bl808_software_aes_xts_setkey_dec
#define mbedtls_aes_self_test bl808_software_aes_self_test
#include "../../../vendor/mbedtls/library/aes.c"

#undef mbedtls_internal_aes_encrypt

extern int bl808_mbedtls_aes_encrypt(mbedtls_aes_context *ctx,
                                     const unsigned char *input,
                                     unsigned char *output);

int mbedtls_internal_aes_encrypt(mbedtls_aes_context *ctx,
                                 const unsigned char input[16],
                                 unsigned char output[16])
{
    return bl808_mbedtls_aes_encrypt(ctx, input, output);
}
