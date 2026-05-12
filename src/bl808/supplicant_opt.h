/*
 * Bare-metal supplicant options for the BL808 WiFi validation build.
 *
 * The SDK's port/include/supplicant_opt.h routes BL808 through mbedTLS.  The
 * b773b3f Bouffalo makefile instead builds the in-tree supplicant crypto and
 * blcrypto_suite glue, so this local header keeps that vendor source path
 * self-contained for the HAL test binary.
 */
#ifndef _SUPPLICANT_OPT_H
#define _SUPPLICANT_OPT_H

#define CONFIG_AUTHENTICATOR_MAX_STA 4
#define CONFIG_IEEE80211W
#define CONFIG_WPA3_SAE

#define WPA_SUPPLICANT_4WAY_HANDSHAKE_TIMEOUT_MS (10 * 1000)
#define WPA_SUPPLICANT_QUICKCONN_4WAY_HANDSHAKE_TIMEOUT_MS (5 * 1000)

#define SAE_FFC 0

#endif /* _SUPPLICANT_OPT_H */
