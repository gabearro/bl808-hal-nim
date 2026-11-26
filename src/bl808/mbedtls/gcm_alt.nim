## Mbed TLS AES-GCM, one record at a time, on the BL808 M0's SEC_ENG: the AES
## block in CTR mode and the GMAC block for GHASH (gcm_engine.nim).
## gcm_hook.c routes the two one-shot entry points here, which is how TLS
## encrypts and decrypts every record, and keeps the stock implementation for
## the rest and as the fallback.
##
## This is the one provider that goes beyond Bouffalo's own Mbed TLS port,
## which stops at single AES blocks: GHASH in software was most of the cost
## of a record.

import ../[core, memmap, mmio]
import build, sec_borrow

static: doAssert MbedTlsHwGcm, "gcm_alt is the BL808 M0 hardware provider"

{.compile: MbedTlsPortDir & "/gcm_hook.c".}

type
  AesContext {.importc: "mbedtls_aes_context", header: "<mbedtls/aes.h>".} = object
    nr: cint
    rk_offset: csize_t
    buf: array[68, uint32]

proc aesBlock(ctx: ptr AesContext; input, output: ptr uint8): cint
  {.importc: "bl808_mbedtls_aes_encrypt", cdecl.}   # the AES provider (aes_alt.nim)
proc softwareOneshot(key: ptr uint8; keyBits: cuint; length: csize_t; iv, add: ptr uint8;
                     addLen: csize_t; input, output, tag: ptr uint8;
                     schedule: ptr AesContext): cint
  {.importc: "bl808_gcm_reference", cdecl.}

when defined(bl808WifiNimFw):
  # The Wi-Fi linker scripts place .wifibss.* in uncached WRAM.
  {.pragma: gcmDma, codegenDecl: "$# $# __attribute__((section(\".wifibss.gcm\"), aligned(16), used))".}
else:
  # No DMA-visible section in this layout: the provider reports itself
  # unavailable at first use and every record is done in software.
  {.pragma: gcmDma.}

include gcm_engine

proc mbedtlsGcmOneshot(ctx: ptr AesContext; encrypt: cint; length: csize_t; iv: ptr uint8;
                       ivLen: csize_t; add: ptr uint8; addLen: csize_t;
                       input, output: ptr uint8; tag: ptr array[16, uint8]): cint
    {.exportc: "bl808_mbedtls_gcm_oneshot", cdecl.} =
  template bytes(p: ptr uint8): untyped = cast[ptr UncheckedArray[uint8]](p)
  gcmOneshot(ctx, encrypt != 0, length.int, bytes(iv), ivLen.int, bytes(add), addLen.int,
             bytes(input), bytes(output), tag[])

proc mbedTlsGcmBackend*(): array[7, uint32] =
  ## Per-key-size state, records on hardware, records left to software,
  ## engine faults, blocks on hardware.
  gcmBackend
