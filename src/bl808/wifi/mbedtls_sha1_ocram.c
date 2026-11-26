#include <string.h>
#include <mbedtls/sha1.h>
#include <mbedtls/platform_util.h>
#include "mbedtls_hot_ocram.h"

BL808_MBEDTLS_OCRAM(mbedtls_sha1_starts);
BL808_MBEDTLS_OCRAM(mbedtls_sha1_update);
BL808_MBEDTLS_OCRAM(mbedtls_sha1_finish);
/* Mbed TLS 3 wipes the context at the end of every digest. Keep that wipe on
 * the hot path in RAM too: the context outlives the call, so the RAM-resident
 * memset cannot be optimized away. */
BL808_MBEDTLS_OCRAM(mbedtls_sha1_free);
#define mbedtls_platform_zeroize(buf, len) ((void) memset((buf), 0, (len)))

#include "../../../vendor/mbedtls/library/sha1.c"
