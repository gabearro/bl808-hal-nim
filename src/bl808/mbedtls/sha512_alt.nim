## Mbed TLS SHA-384/512 block provider for the BL808 M0 (SEC_ENG). Streaming,
## padding and HMAC remain in Mbed TLS; only the compression function is
## replaced (MBEDTLS_SHA512_PROCESS_ALT), with the stock C block function as
## the fallback whenever the shared engine is not free or not trusted.
##
## In a TLS session this is the transcript hash and key schedule of the
## TLS_AES_256_GCM_SHA384 suites and the digests of SHA-384/512 signatures.

import ../[core, memmap, mmio]
import build, sec_borrow

static: doAssert MbedTlsHwSha512, "sha512_alt is the BL808 M0 hardware provider"

{.compile: MbedTlsPortDir & "/sha512_software.c".}

type
  Sha512Context {.importc: "mbedtls_sha512_context", header: "<mbedtls/sha512.h>".} = object
    state: array[8, uint64]

proc softwareProcess(ctx: ptr Sha512Context; data: ptr uint8): cint
  {.importc: "bl808_software_sha512_process", cdecl.}

when defined(bl808WifiNimFw):
  # The Wi-Fi linker scripts place .wifibss.* in uncached WRAM.
  {.pragma: sha512Dma, codegenDecl: "$# $# __attribute__((section(\".wifibss.sha512\"), aligned(16), used))".}
else:
  # No DMA-visible section in this layout: the provider reports itself
  # unavailable at first use and every block is hashed in software.
  {.pragma: sha512Dma.}

include sha512_engine

proc mbedtlsSha512Process(ctx: ptr Sha512Context; data: ptr uint8): cint
    {.exportc: "bl808_mbedtls_sha512_process", cdecl.} =
  sha512Process(ctx, data)

proc mbedTlsSha512Backend*(): array[4, uint32] =
  ## State, hardware blocks, software blocks, engine faults (see the engine).
  sha512Backend
