/*
 * Mbed TLS 2.x names used by code that predates the 3.x API: the pinned
 * Bouffalo SDK supplicant (build/bl_iot_sdk_*, never edited) and
 * src/bl808/wifi/wpa2_pmk.nim. Mbed TLS 3.0 dropped the `_ret` suffix and
 * kept the signatures, so a rename is the whole translation.
 */
#ifndef BL808_MBEDTLS_COMPAT_H
#define BL808_MBEDTLS_COMPAT_H

#define mbedtls_md5_starts_ret    mbedtls_md5_starts
#define mbedtls_md5_update_ret    mbedtls_md5_update
#define mbedtls_md5_finish_ret    mbedtls_md5_finish
#define mbedtls_md5_ret           mbedtls_md5

#define mbedtls_sha1_starts_ret   mbedtls_sha1_starts
#define mbedtls_sha1_update_ret   mbedtls_sha1_update
#define mbedtls_sha1_finish_ret   mbedtls_sha1_finish
#define mbedtls_sha1_ret          mbedtls_sha1

#define mbedtls_sha256_starts_ret mbedtls_sha256_starts
#define mbedtls_sha256_update_ret mbedtls_sha256_update
#define mbedtls_sha256_finish_ret mbedtls_sha256_finish
#define mbedtls_sha256_ret        mbedtls_sha256

#define mbedtls_sha512_starts_ret mbedtls_sha512_starts
#define mbedtls_sha512_update_ret mbedtls_sha512_update
#define mbedtls_sha512_finish_ret mbedtls_sha512_finish
#define mbedtls_sha512_ret        mbedtls_sha512

#endif /* BL808_MBEDTLS_COMPAT_H */
