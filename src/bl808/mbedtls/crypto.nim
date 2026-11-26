## The Mbed TLS hash, HMAC, PBKDF2 and AES sources: all the Wi-Fi supplicant
## needs, and the base the TLS client builds on (tls_sources.nim adds the rest).
## Importing this module is the only way these files get compiled, so an image
## with both Wi-Fi and TLS still holds each of them once.

import build
export build

# The Wi-Fi AP benches run the PBKDF2 path from OCRAM. Their wrappers include
# the stock file after placing its hot functions, so they replace it here.
when defined(bl808WifiMbedTlsHotOcram):
  {.compile: Bl808SourceDir & "/wifi/mbedtls_md_ocram.c".}
  {.compile: Bl808SourceDir & "/wifi/mbedtls_pkcs5_ocram.c".}
  {.compile: Bl808SourceDir & "/wifi/mbedtls_sha1_ocram.c".}
else:
  {.compile: MbedTlsLibrary & "/md.c".}
  {.compile: MbedTlsLibrary & "/pkcs5.c".}
  {.compile: MbedTlsLibrary & "/sha1.c".}
when defined(bl808WifiMbedTlsSha1Hardware):
  # Software SHA-1 block function behind the Nim provider in
  # wifi/mbedtls_sha1_alt.nim, plus the MBEDTLS_SHA1_PROCESS_ALT entry point.
  {.compile: Bl808SourceDir & "/wifi/mbedtls_sha1_software.c".}

{.compile: MbedTlsLibrary & "/aes.c".}
{.compile: MbedTlsLibrary & "/md5.c".}
{.compile: MbedTlsLibrary & "/sha256.c".}
{.compile: MbedTlsLibrary & "/sha512.c".}
{.compile: MbedTlsLibrary & "/constant_time.c".}
{.compile: MbedTlsLibrary & "/platform.c".}
{.compile: MbedTlsLibrary & "/platform_util.c".}
