#include <mbedtls/pkcs5.h>
#include "mbedtls_hot_ocram.h"

BL808_MBEDTLS_OCRAM(mbedtls_pkcs5_pbkdf2_hmac);

#include "../../../build/bl_iot_sdk_b773b3f/components/security/mbedtls_lts/mbedtls/library/pkcs5.c"
