{.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/aes-cbc.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/aes-internal-bl.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/aes-omac1.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/aes-unwrap.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/aes-wrap.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/crypto_internal-modexp.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/dh_group5.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/dh_groups.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/md5-internal.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/md5.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/rc4.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/sha1-internal.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/sha1-pbkdf2-bl.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/sha1.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/sha256-internal.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/sha256-prf.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/sha256.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/blcrypto_suite/src/blcrypto_suite_aes.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/blcrypto_suite/src/blcrypto_suite_bignum.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/blcrypto_suite/src/blcrypto_suite_ecp.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/blcrypto_suite/src/blcrypto_suite_ecp_curves.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/blcrypto_suite/src/blcrypto_suite_hacc.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/blcrypto_suite/src/blcrypto_suite_hacc_glue.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/blcrypto_suite/src/blcrypto_suite_hacc_secp256r1_mul.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/blcrypto_suite/src/blcrypto_suite_platform_util.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/blcrypto_suite/src/blcrypto_suite_porting.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/blcrypto_suite/src/blcrypto_suite_supplicant_api.c".}
when defined(bl808AllcoreWasmHttp):
  # Keep the generated AES tables out of the secure OCRAM stack bank.
  {.passC: "-DMBEDTLS_AES_ROM_TABLES -DMBEDTLS_AES_FEWER_TABLES".}
when defined(bl808WifiMbedTlsHotOcram):
  static: doAssert (defined(bl808WifiHttpServer) or defined(bl808AllcoreWasmHttp)) and
    defined(bl808WifiMbedTlsSha1Hardware)
  {.passC: "-DBL808_WIFI_MBEDTLS_HOT_OCRAM".}
when defined(bl808WifiMbedTlsSha1Lease):
  static:
    doAssert defined(bl808WifiMbedTlsHotOcram) and
      defined(bl808WifiMbedTlsSha1Hardware)
    when defined(bl808AllcoreWasmHttp):
      doAssert defined(bl808enclave) and defined(bl808EnclaveWram) and
        (defined(bl808WifiMbedTlsCachedWram) or defined(bl808AllcoreWifiApEngineBench)),
        "All-core SHA lease requires the enclave WRAM partition and cached code outside the AP bench"
    else:
      doAssert defined(bl808WifiApHttpSmoke)
  {.passL: "-Wl,--wrap=mbedtls_pkcs5_pbkdf2_hmac".}
  {.compile: "src/bl808/wifi/mbedtls_pkcs5_lease.c".}
when defined(bl808WifiMbedTlsSha1Hardware):
  {.passC: "-DMBEDTLS_SHA1_PROCESS_ALT".}
# Mbed TLS itself is the vendored 3.6 tree (vendor/mbedtls). Its hash, HMAC,
# PBKDF2 and AES sources, including the OCRAM and SHA-1 provider variants the
# defines above select, are compiled once by bl808/mbedtls/crypto so that a
# TLS client in the same image shares them.
import ../../../mbedtls/crypto
