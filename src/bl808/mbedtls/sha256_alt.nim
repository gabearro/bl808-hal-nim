## Mbed TLS SHA-224/256 block provider for the BL808 M0 (SEC_ENG). Streaming,
## padding and HMAC remain in Mbed TLS; only the compression function is
## replaced (MBEDTLS_SHA256_PROCESS_ALT), with the stock C block function as
## the fallback whenever the shared engine is not free or not trusted.

import ../[core, memmap, mmio]
import build, sec_borrow

static: doAssert MbedTlsHwSha256, "sha256_alt is the BL808 M0 hardware provider"

{.compile: MbedTlsPortDir & "/sha256_software.c".}

type
  Sha256Context {.importc: "mbedtls_sha256_context", header: "<mbedtls/sha256.h>".} = object
    state: array[8, uint32]

proc softwareProcess(ctx: ptr Sha256Context; data: ptr uint8): cint
  {.importc: "bl808_software_sha256_process", cdecl.}

when defined(bl808WifiNimFw):
  # The Wi-Fi linker scripts place .wifibss.* in uncached WRAM.
  {.pragma: sha256Dma, codegenDecl: "$# $# __attribute__((section(\".wifibss.sha256\"), aligned(16), used))".}
else:
  # No DMA-visible section in this layout: the provider reports itself
  # unavailable at first use and every block is hashed in software.
  {.pragma: sha256Dma.}

include sha256_engine

proc mbedtlsSha256Process(ctx: ptr Sha256Context; data: ptr uint8): cint
    {.exportc: "bl808_mbedtls_sha256_process", cdecl.} =
  sha256Process(ctx, data)

proc mbedTlsSha256Backend*(): array[4, uint32] =
  ## State, hardware blocks, software blocks, engine faults (see the engine).
  sha256Backend
