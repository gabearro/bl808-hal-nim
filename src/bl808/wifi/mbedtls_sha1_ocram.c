#include <mbedtls/sha1.h>
#include "mbedtls_hot_ocram.h"

BL808_MBEDTLS_OCRAM(mbedtls_sha1_starts_ret);
BL808_MBEDTLS_OCRAM(mbedtls_sha1_update_ret);
BL808_MBEDTLS_OCRAM(mbedtls_sha1_finish_ret);

#include "../../../build/bl_iot_sdk_b773b3f/components/security/mbedtls_lts/mbedtls/library/sha1.c"
