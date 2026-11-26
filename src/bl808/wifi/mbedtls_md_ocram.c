#include <mbedtls/md.h>
#include "mbedtls_hot_ocram.h"

BL808_MBEDTLS_OCRAM(mbedtls_md_starts);
BL808_MBEDTLS_OCRAM(mbedtls_md_update);
BL808_MBEDTLS_OCRAM(mbedtls_md_finish);
BL808_MBEDTLS_OCRAM(mbedtls_md_hmac_starts);
BL808_MBEDTLS_OCRAM(mbedtls_md_hmac_update);
BL808_MBEDTLS_OCRAM(mbedtls_md_hmac_finish);
BL808_MBEDTLS_OCRAM(mbedtls_md_hmac_reset);

#include "../../../vendor/mbedtls/library/md.c"
