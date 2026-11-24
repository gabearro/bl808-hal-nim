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
{.compile: "build/bl_iot_sdk_b773b3f/components/security/mbedtls_lts/mbedtls/library/aes.c".}
when defined(bl808WifiMbedTlsHotOcram):
  static: doAssert (defined(bl808WifiHttpServer) or defined(bl808AllcoreWasmHttp)) and
    defined(bl808WifiMbedTlsSha1Hardware)
  {.passC: "-DBL808_WIFI_MBEDTLS_HOT_OCRAM".}
  {.compile: "src/bl808/wifi/mbedtls_md_ocram.c".}
else:
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/mbedtls_lts/mbedtls/library/md.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/mbedtls_lts/mbedtls/library/md5.c".}
when defined(bl808WifiMbedTlsHotOcram):
  {.compile: "src/bl808/wifi/mbedtls_pkcs5_ocram.c".}
else:
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/mbedtls_lts/mbedtls/library/pkcs5.c".}
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
{.compile: "build/bl_iot_sdk_b773b3f/components/security/mbedtls_lts/mbedtls/library/ripemd160.c".}
when defined(bl808WifiMbedTlsSha1Hardware):
  {.passC: "-DMBEDTLS_SHA1_PROCESS_ALT".}
  {.compile: "src/bl808/wifi/mbedtls_sha1_software.c".}
when defined(bl808WifiMbedTlsHotOcram):
  {.compile: "src/bl808/wifi/mbedtls_sha1_ocram.c".}
else:
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/mbedtls_lts/mbedtls/library/sha1.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/mbedtls_lts/mbedtls/library/sha256.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/mbedtls_lts/mbedtls/library/sha512.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/mbedtls_lts/mbedtls/library/platform.c".}
{.compile: "build/bl_iot_sdk_b773b3f/components/security/mbedtls_lts/mbedtls/library/platform_util.c".}
