/* Keep the pinned Mbed TLS software block function for the runtime fallback.
 * The alternate build provides the public block function from Nim. The
 * unused renamed stream entry points are discarded by section GC. */
#undef MBEDTLS_SHA1_PROCESS_ALT
#define mbedtls_internal_sha1_process bl808_software_sha1_process
#define mbedtls_sha1_init bl808_software_sha1_init
#define mbedtls_sha1_free bl808_software_sha1_free
#define mbedtls_sha1_clone bl808_software_sha1_clone
#define mbedtls_sha1_starts_ret bl808_software_sha1_starts_ret
#define mbedtls_sha1_starts bl808_software_sha1_starts
#define mbedtls_sha1_process bl808_software_sha1_legacy_process
#define mbedtls_sha1_update_ret bl808_software_sha1_update_ret
#define mbedtls_sha1_update bl808_software_sha1_update
#define mbedtls_sha1_finish_ret bl808_software_sha1_finish_ret
#define mbedtls_sha1_finish bl808_software_sha1_finish
#define mbedtls_sha1_ret bl808_software_sha1_ret
#define mbedtls_sha1 bl808_software_sha1
#define mbedtls_sha1_self_test bl808_software_sha1_self_test
#include "../../../build/bl_iot_sdk_b773b3f/components/security/mbedtls_lts/mbedtls/library/sha1.c"

#undef mbedtls_internal_sha1_process
#undef mbedtls_sha1_process

#ifdef BL808_WIFI_MBEDTLS_HOT_OCRAM
__attribute__((section(".ramfunc.mbedtls.block")))
#endif
int mbedtls_internal_sha1_process(mbedtls_sha1_context *ctx,
                                  const unsigned char data[64]);

extern int bl808_mbedtls_sha1_process(mbedtls_sha1_context *ctx,
                                    const unsigned char *data);

int mbedtls_internal_sha1_process(mbedtls_sha1_context *ctx,
                                  const unsigned char data[64])
{
    return bl808_mbedtls_sha1_process(ctx, data);
}

#if !defined(MBEDTLS_DEPRECATED_REMOVED)
void mbedtls_sha1_process(mbedtls_sha1_context *ctx, const unsigned char data[64])
{
    (void)mbedtls_internal_sha1_process(ctx, data);
}
#endif
