## Mbed TLS entropy source for the BL808 M0: the SEC_ENG TRNG, as in
## Bouffalo's port (hw_entropy_poll.c). The HAL driver claims the TRNG block
## for this CPU group around each 256-bit read, so a block owned by the other
## group simply yields no entropy this round and Mbed TLS reports the
## shortfall instead of seeding from nothing.

{.used.}   # imported for the exported poll callback

import ../sec
import build

static: doAssert MbedTlsHwEntropy, "entropy_alt is the BL808 M0 TRNG source"

proc mbedtlsHardwarePoll(data: pointer; output: ptr UncheckedArray[uint8];
                         len: csize_t; olen: ptr csize_t): cint
    {.exportc: "mbedtls_hardware_poll", cdecl.} =
  ## MBEDTLS_ENTROPY_HARDWARE_ALT. Returning fewer bytes than asked is not an
  ## error; the entropy module keeps polling until its threshold is met.
  var produced = 0
  while produced < len.int:
    var words: array[8, uint32]
    if trngReadAll(words) != secOk: break
    for word in words.mitems:
      for shift in [0, 8, 16, 24]:
        if produced < len.int:
          output[produced] = uint8(word shr shift)
          inc produced
      word = 0
  if olen != nil: olen[] = produced.csize_t
  0
