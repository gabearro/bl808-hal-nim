/*
 * Mbed TLS 3.6 configuration for the BL808 HAL (vendor/mbedtls).
 *
 * One configuration serves the whole image: the Wi-Fi supplicant's hashes,
 * AES and PBKDF2, and the TLS client behind src/bl808/kernel/tls.nim. Host
 * builds use the same file with the software backends.
 *
 * Selected from Nim (src/bl808/mbedtls/build.nim), never edited per build:
 *   BL808_MBEDTLS_HW_SHA256   SHA-224/256 compression on SEC_ENG
 *   BL808_MBEDTLS_HW_SHA512   SHA-384/512 compression on SEC_ENG
 *   BL808_MBEDTLS_HW_AES      AES block encryption on SEC_ENG
 *   BL808_MBEDTLS_HW_P256     P-256 scalar multiplication on the PKA
 *   BL808_MBEDTLS_HW_RSA      RSA public-key exponentiation on the PKA
 *   BL808_MBEDTLS_HW_ENTROPY  entropy from the SEC_ENG TRNG
 * MBEDTLS_SHA1_PROCESS_ALT is passed by the Wi-Fi build itself
 * (-d:bl808WifiMbedTlsSha1Hardware).
 */
#ifndef BL808_MBEDTLS_CONFIG_H
#define BL808_MBEDTLS_CONFIG_H

/* ---- Platform: no filesystem, no sockets, no clock ---------------------- */
#define MBEDTLS_PLATFORM_C
/* calloc/free default to the C library (the kernel TLSF heap on the BL808)
 * and can be redirected at run time, e.g. to a PSRAM pool. */
#define MBEDTLS_PLATFORM_MEMORY
/* Certificate validity periods are checked against the clock given to
 * mbedTlsSetClock (mbedtls/clock.nim). While none is set the time is the Unix
 * epoch, before any certificate is valid, so verification fails rather than
 * accept a certificate that cannot be dated. No C library clock is used. */
#define MBEDTLS_HAVE_TIME
#define MBEDTLS_HAVE_TIME_DATE
#define MBEDTLS_PLATFORM_TIME_TYPE_MACRO long long
#define MBEDTLS_PLATFORM_TIME_MACRO bl808_mbedtls_time
#define MBEDTLS_PLATFORM_MS_TIME_ALT
#define MBEDTLS_PLATFORM_GMTIME_R_ALT
#ifndef __ASSEMBLER__
long long bl808_mbedtls_time(long long *timer);
#endif

/* ---- Hashes -------------------------------------------------------------- */
#define MBEDTLS_MD_C
#define MBEDTLS_MD5_C               /* Wi-Fi supplicant (WPA key MIC) */
#define MBEDTLS_SHA1_C              /* Wi-Fi PBKDF2/PRF, legacy certificates */
#define MBEDTLS_SHA256_C
#define MBEDTLS_SHA384_C
#define MBEDTLS_SHA512_C
#define MBEDTLS_HKDF_C
#define MBEDTLS_PKCS5_C             /* Wi-Fi WPA2 passphrase derivation */

/* ---- Ciphers ------------------------------------------------------------- */
#define MBEDTLS_CIPHER_C
#define MBEDTLS_AES_C
#define MBEDTLS_GCM_C
#define MBEDTLS_CHACHA20_C
#define MBEDTLS_POLY1305_C
#define MBEDTLS_CHACHAPOLY_C
#define MBEDTLS_CIPHER_MODE_CBC     /* Wi-Fi key wrap helpers, TLS 1.2 CBC */

/* ---- Public key ---------------------------------------------------------- */
#define MBEDTLS_BIGNUM_C
#define MBEDTLS_ECP_C
#define MBEDTLS_ECP_DP_SECP256R1_ENABLED
#define MBEDTLS_ECP_DP_SECP384R1_ENABLED
#define MBEDTLS_ECP_DP_CURVE25519_ENABLED
#define MBEDTLS_ECP_NIST_OPTIM
#define MBEDTLS_ECDH_C
#define MBEDTLS_ECDSA_C
#define MBEDTLS_RSA_C               /* server signatures: public operations */
#define MBEDTLS_PKCS1_V15
#define MBEDTLS_PKCS1_V21
#define MBEDTLS_ASN1_PARSE_C
#define MBEDTLS_ASN1_WRITE_C
#define MBEDTLS_OID_C
#define MBEDTLS_PK_C
#define MBEDTLS_PK_PARSE_C
/* 4096-bit RSA is the largest server key accepted. */
#define MBEDTLS_MPI_MAX_SIZE 512

/* ---- X.509: parsing and chain verification, DER only --------------------- */
#define MBEDTLS_X509_USE_C
#define MBEDTLS_X509_CRT_PARSE_C
#define MBEDTLS_X509_RSASSA_PSS_SUPPORT
#define MBEDTLS_X509_REMOVE_INFO

/* ---- Random numbers ------------------------------------------------------ */
#define MBEDTLS_ENTROPY_C
#define MBEDTLS_ENTROPY_FORCE_SHA256
#define MBEDTLS_CTR_DRBG_C
#if defined(BL808_MBEDTLS_HW_ENTROPY)
#define MBEDTLS_NO_PLATFORM_ENTROPY
#define MBEDTLS_ENTROPY_HARDWARE_ALT
#endif

/* ---- PSA Crypto: required by TLS 1.3, used for all TLS and X.509 crypto -- */
#define MBEDTLS_PSA_CRYPTO_C
#define MBEDTLS_USE_PSA_CRYPTO
#define MBEDTLS_PSA_KEY_STORE_DYNAMIC
/* One address space, no concurrent callers: PSA may work on the caller's
 * buffers instead of allocating a copy of every record it decrypts. */
#define MBEDTLS_PSA_ASSUME_EXCLUSIVE_BUFFERS

/* ---- TLS client: 1.3 with a 1.2 fallback --------------------------------- */
#define MBEDTLS_SSL_TLS_C
#define MBEDTLS_SSL_CLI_C
#define MBEDTLS_SSL_PROTO_TLS1_3
#define MBEDTLS_SSL_TLS1_3_COMPATIBILITY_MODE
#define MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_EPHEMERAL_ENABLED
#define MBEDTLS_SSL_PROTO_TLS1_2
#define MBEDTLS_KEY_EXCHANGE_ECDHE_RSA_ENABLED
#define MBEDTLS_KEY_EXCHANGE_ECDHE_ECDSA_ENABLED
#define MBEDTLS_SSL_EXTENDED_MASTER_SECRET
#define MBEDTLS_SSL_ENCRYPT_THEN_MAC
#define MBEDTLS_SSL_SERVER_NAME_INDICATION
#define MBEDTLS_SSL_ALL_ALERT_MESSAGES
#define MBEDTLS_SSL_KEEP_PEER_CERTIFICATE   /* required by TLS 1.3 */
/* Session tickets, resumption, renegotiation, ALPN and DTLS are left out. */

/* A full-size record always fits the input buffer. The client only sends
 * handshake messages and short requests, so the output buffer is smaller. */
#ifndef MBEDTLS_SSL_IN_CONTENT_LEN
#define MBEDTLS_SSL_IN_CONTENT_LEN 16384
#endif
#ifndef MBEDTLS_SSL_OUT_CONTENT_LEN
#define MBEDTLS_SSL_OUT_CONTENT_LEN 4096
#endif

/* ---- BL808 hardware alternates ------------------------------------------- */
#if defined(BL808_MBEDTLS_HW_SHA256)
#define MBEDTLS_SHA256_PROCESS_ALT
#endif
#if defined(BL808_MBEDTLS_HW_SHA512)
#define MBEDTLS_SHA512_PROCESS_ALT
#endif
#if defined(BL808_MBEDTLS_HW_AES)
#define MBEDTLS_AES_ENCRYPT_ALT
/* Software AES is then the key schedule, decryption and the fallback: keep
 * its tables small and in flash instead of generating 8.5 KiB of them in RAM. */
#ifndef MBEDTLS_AES_ROM_TABLES
#define MBEDTLS_AES_ROM_TABLES
#endif
#ifndef MBEDTLS_AES_FEWER_TABLES
#define MBEDTLS_AES_FEWER_TABLES
#endif
#endif
/* BL808_MBEDTLS_HW_P256 and BL808_MBEDTLS_HW_RSA need no Mbed TLS option:
 * ecp_p256_hook.c wraps the scalar multiplication entry points of the stock
 * ecp.c, rsa_exp_mod_hook.c the public-value exponentiation of bignum.c. */

/* Mbed TLS 2.x names still used by the pinned SDK supplicant sources. */
#include "bl808_mbedtls_compat.h"

#endif /* BL808_MBEDTLS_CONFIG_H */
