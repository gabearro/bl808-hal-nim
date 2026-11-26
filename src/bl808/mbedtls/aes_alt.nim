## Mbed TLS AES block-encryption provider for the BL808 M0 (SEC_ENG). Key
## schedules, decryption and every mode of operation remain in Mbed TLS; only
## the block encryption that CTR, GCM and CBC-encrypt are built on is replaced
## (MBEDTLS_AES_ENCRYPT_ALT), with the stock C block function as the fallback
## whenever the shared engine is not free or not trusted.
##
## The engine's key registers are write-only state this provider overwrites
## while it borrows an idle engine. Another AES user in the same image (the
## HAL's sec.nim API) must keep the engine enabled across its own key setup
## and data, or the image must be built with -d:bl808MbedTlsAesSoftware.

import ../[core, memmap, mmio]
import build, sec_borrow

static: doAssert MbedTlsHwAes, "aes_alt is the BL808 M0 hardware provider"

{.compile: MbedTlsPortDir & "/aes_software.c".}

type
  AesContext {.importc: "mbedtls_aes_context", header: "<mbedtls/aes.h>".} = object
    nr: cint
    rk_offset: csize_t
    buf: array[68, uint32]

proc softwareSetKey(ctx: ptr AesContext; key: ptr uint8; keyBits: cuint): cint
  {.importc: "bl808_software_aes_setkey_enc", cdecl.}
proc softwareEncrypt(ctx: ptr AesContext; input, output: ptr uint8): cint
  {.importc: "bl808_software_aes_encrypt", cdecl.}

when defined(bl808WifiNimFw):
  # The Wi-Fi linker scripts place .wifibss.* in uncached WRAM.
  {.pragma: aesDma, codegenDecl: "$# $# __attribute__((section(\".wifibss.aes\"), aligned(16), used))".}
else:
  # No DMA-visible section in this layout: the provider reports itself
  # unavailable at first use and every block is encrypted in software.
  {.pragma: aesDma.}

include aes_engine

proc mbedtlsAesEncrypt(ctx: ptr AesContext; input, output: ptr uint8): cint
    {.exportc: "bl808_mbedtls_aes_encrypt", cdecl.} =
  aesEncryptBlock(ctx, input, output)

proc mbedTlsAesBackend*(): array[6, uint32] =
  ## Per-key-size state, hardware blocks, software blocks, engine faults.
  aesBackend
