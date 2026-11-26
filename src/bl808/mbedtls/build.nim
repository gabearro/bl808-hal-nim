## Build wiring for the vendored Mbed TLS 3.6 (vendor/mbedtls).
##
## Every module that compiles or binds Mbed TLS imports this one, so the whole
## image sees a single configuration (bl808_mbedtls_config.h) however many
## users it has. Paths are absolute: builds work from any directory.
##
## Hardware backends (BL808 M0 only, each with a software fallback at run
## time) are picked here at compile time:
##   -d:bl808MbedTlsSoftware        no hardware alternates at all
##   -d:bl808MbedTlsSha256Software  SHA-224/256 in software
##   -d:bl808MbedTlsSha512Software  SHA-384/512 in software
##   -d:bl808MbedTlsAesSoftware     AES in software (and so AES-GCM)
##   -d:bl808MbedTlsGcmSoftware     AES-GCM records block by block, GHASH in software
##   -d:bl808MbedTlsP256Software    P-256 in software
##   -d:bl808MbedTlsRsaSoftware     RSA public-key operations in software
## Host builds and enclave builds always use software: the enclave reserves
## the SEC_ENG blocks and their DMA windows for the secure world.
## The alternates are linked in by `import bl808/mbedtls/hw` (kernel/tls.nim
## does that); a Wi-Fi image that never imports it keeps its software crypto.

proc parentDir(path: string): string {.compileTime.} =
  var last = path.len - 1
  while last > 0 and path[last] != '/': dec last
  substr(path, 0, last - 1)

const
  MbedTlsPortDir* = parentDir(currentSourcePath())
  Bl808SourceDir* = parentDir(MbedTlsPortDir)
  MbedTlsRoot* = parentDir(parentDir(Bl808SourceDir)) & "/vendor/mbedtls"
  MbedTlsLibrary* = MbedTlsRoot & "/library"

  MbedTlsHardware* = defined(bl808m0) and not defined(bl808MbedTlsSoftware) and
    not defined(bl808enclave)
  MbedTlsHwSha256* = MbedTlsHardware and not defined(bl808MbedTlsSha256Software)
  MbedTlsHwSha512* = MbedTlsHardware and not defined(bl808MbedTlsSha512Software)
  MbedTlsHwAes* = MbedTlsHardware and not defined(bl808MbedTlsAesSoftware)
  MbedTlsHwGcm* = MbedTlsHwAes and not defined(bl808MbedTlsGcmSoftware)
  MbedTlsHwP256* = MbedTlsHardware and not defined(bl808MbedTlsP256Software)
  MbedTlsHwRsa* = MbedTlsHardware and not defined(bl808MbedTlsRsaSoftware)
  ## The TRNG is the chip's only entropy source, so it has no software twin.
  MbedTlsHwEntropy* = defined(bl808m0)

{.passC: "-I" & MbedTlsRoot & "/include".}
{.passC: "-I" & MbedTlsPortDir.}
{.passC: "-DMBEDTLS_CONFIG_FILE=\\\"bl808_mbedtls_config.h\\\"".}
# Nim binds a few context fields (digest state, AES round keys). The empty
# value matches the definition in the library's own common.h.
{.passC: "-DMBEDTLS_ALLOW_PRIVATE_ACCESS=".}
