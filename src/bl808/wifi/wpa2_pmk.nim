## WPA2 passphrase derivation using the SHA-1 compression of the vendored
## Mbed TLS 3.6.8 (vendor/mbedtls, built once per image by bl808/mbedtls/crypto;
## the 2.x names below come from bl808/mbedtls/bl808_mbedtls_compat.h).

type
  Wpa2Pmk* = array[32, uint8]
  Sha1State = array[5, uint32]
  Sha1Block = array[64, uint8]
  Sha1Context {.importc: "mbedtls_sha1_context", header: "<mbedtls/sha1.h>".} = object
    state: Sha1State

proc sha1Start(context: ptr Sha1Context): cint
  {.importc: "mbedtls_sha1_starts_ret", cdecl, header: "<mbedtls/sha1.h>".}
proc sha1Compress(context: ptr Sha1Context; data: ptr uint8): cint
  {.importc: "mbedtls_internal_sha1_process", cdecl, header: "<mbedtls/sha1.h>".}
proc sha1Free(context: ptr Sha1Context)
  {.importc: "mbedtls_sha1_free", cdecl, header: "<mbedtls/sha1.h>".}
proc secureZero(data: pointer; size: csize_t)
  {.importc: "mbedtls_platform_zeroize", cdecl, header: "<mbedtls/platform_util.h>".}

proc writeBigEndian(data: var openArray[uint8]; offset: int; value: uint32) {.inline.} =
  data[offset] = uint8(value shr 24)
  data[offset + 1] = uint8(value shr 16)
  data[offset + 2] = uint8(value shr 8)
  data[offset + 3] = uint8(value)

proc deriveWpa2Pmk*(passphrase, ssid: openArray[uint8]; pmk: var Wpa2Pmk): bool =
  if passphrase.len notin 8..63 or ssid.len > 32: return false
  var context: Sha1Context
  var inner, outer, accum: Sha1State
  var firstBlock, digestBlock: Sha1Block
  defer:
    sha1Free(addr context)
    secureZero(addr inner, sizeof(inner).csize_t)
    secureZero(addr outer, sizeof(outer).csize_t)
    secureZero(addr accum, sizeof(accum).csize_t)
    secureZero(addr digestBlock, sizeof(digestBlock).csize_t)
    secureZero(addr firstBlock, sizeof(firstBlock).csize_t)
    if not result: secureZero(addr pmk, sizeof(pmk).csize_t)

  # RFC 2104 section 4: reuse H(K xor ipad) and H(K xor opad) in this call only.
  for index in 0 ..< firstBlock.len:
    firstBlock[index] = (if index < passphrase.len: passphrase[index] else: 0'u8) xor 0x36'u8
  if sha1Start(addr context) != 0 or sha1Compress(addr context, addr firstBlock[0]) != 0:
    return false
  inner = context.state
  for value in firstBlock.mitems:
    value = value xor (0x36'u8 xor 0x5c'u8)
  if sha1Start(addr context) != 0 or sha1Compress(addr context, addr firstBlock[0]) != 0:
    return false
  outer = context.state

  # The prehashed pad accounts for the first 64 bytes. Every suffix here
  # (SSID plus the block index, or a 20-byte digest) fits one final block.
  firstBlock = default(Sha1Block)
  for index, value in ssid:
    firstBlock[index] = value
  firstBlock[ssid.len + 4] = 0x80
  firstBlock.writeBigEndian(60, ((64 + ssid.len + 4) * 8).uint32)
  digestBlock[20] = 0x80
  digestBlock.writeBigEndian(60, ((64 + 20) * 8).uint32)

  for blockIndex in 1 .. 2:
    firstBlock[ssid.len + 3] = blockIndex.uint8
    context.state = inner
    if sha1Compress(addr context, addr firstBlock[0]) != 0: return false
    for roundIndex in 0 ..< 4096:
      for index in 0 ..< 5:
        digestBlock.writeBigEndian(index * 4, context.state[index])
      context.state = outer
      if sha1Compress(addr context, addr digestBlock[0]) != 0: return false
      if roundIndex == 0:
        accum = context.state
      else:
        for index in 0 ..< 5:
          accum[index] = accum[index] xor context.state[index]
      if roundIndex != 4095:
        for index in 0 ..< 5:
          digestBlock.writeBigEndian(index * 4, context.state[index])
        context.state = inner
        if sha1Compress(addr context, addr digestBlock[0]) != 0: return false
    let words = if blockIndex == 1: 5 else: 3
    for index in 0 ..< words:
      pmk.writeBigEndian((blockIndex - 1) * 20 + index * 4, accum[index])
  true

when defined(bl808m0) and defined(bl808WifiNimFw):
  {.passL: "-Wl,--wrap=pbkdf2_sha1".}
  proc sdkPbkdf2(passphrase, ssid: cstring; ssidLength: csize_t;
                 iterations: cint; output: ptr uint8; outputLength: csize_t): cint
    {.importc: "__real_pbkdf2_sha1", cdecl.}

  proc wifiPbkdf2(passphrase, ssid: cstring; ssidLength: csize_t;
                  iterations: cint; output: ptr uint8; outputLength: csize_t): cint
    {.exportc: "__wrap_pbkdf2_sha1", cdecl.} =
    if passphrase == nil or ssid == nil or output == nil or outputLength != 32 or iterations <= 0:
      return -1
    var passphraseLength = 0
    while passphraseLength < 64 and passphrase[passphraseLength] != '\0':
      inc passphraseLength
    if iterations != 4096 or ssidLength notin 1.csize_t .. 32.csize_t or
        passphraseLength notin 8..63:
      return sdkPbkdf2(passphrase, ssid, ssidLength, iterations, output, outputLength)
    let secret = cast[ptr UncheckedArray[uint8]](passphrase)
    let salt = cast[ptr UncheckedArray[uint8]](ssid)
    if deriveWpa2Pmk(secret.toOpenArray(0, passphraseLength - 1),
                     salt.toOpenArray(0, ssidLength.int - 1), cast[ptr Wpa2Pmk](output)[]):
      0
    else:
      -1
