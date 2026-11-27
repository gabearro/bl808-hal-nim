## WPA2 passphrase derivation using the SHA-1 compression of the vendored
## Mbed TLS 3.6.8 (vendor/mbedtls, built once per image by bl808/mbedtls/crypto;
## the 2.x names below come from bl808/mbedtls/bl808_mbedtls_compat.h).

type
  Wpa2Pmk* = array[32, uint8]
  Sha1State = array[5, uint32]
  Sha1Block = array[64, uint8]
  Sha1Context {.importc: "mbedtls_sha1_context", header: "<mbedtls/sha1.h>".} = object
    state: Sha1State

when defined(radioDiag):
  type Wpa2PmkTiming* = object
    slices*, preparedHits*, fallbackCalls*, maxSliceUs*: uint32

  var wpa2PmkTiming: Wpa2PmkTiming

  proc wpa2PmkTimingSnapshot*(): Wpa2PmkTiming = wpa2PmkTiming

  proc wpa2PmkNoteSlice*(elapsedUs: uint32) =
    inc wpa2PmkTiming.slices
    wpa2PmkTiming.maxSliceUs = max(wpa2PmkTiming.maxSliceUs, elapsedUs)

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

type
  Wpa2PmkStep* = enum
    pmkFailed, pmkPending, pmkReady

  Wpa2PmkDeriver* = object
    ## A PBKDF2 block takes 4096 HMACs. Keep its SHA-1 state between CPS
    ## scheduler turns so no callback owns the complete derivation.
    context: Sha1Context
    inner, outer, accum: Sha1State
    firstBlock, digestBlock: Sha1Block
    pmk*: Wpa2Pmk
    ssidLen, blockIndex, roundIndex: int
    active, finished*: bool

proc clearWpa2PmkDeriver*(deriver: var Wpa2PmkDeriver) =
  sha1Free(addr deriver.context)
  secureZero(addr deriver, sizeof(deriver).csize_t)

proc startWpa2PmkDeriver*(deriver: var Wpa2PmkDeriver;
                          passphrase, ssid: openArray[uint8]): bool =
  deriver.clearWpa2PmkDeriver()
  if passphrase.len notin 8..63 or ssid.len notin 1..32:
    return false
  var pad: Sha1Block
  defer: secureZero(addr pad, sizeof(pad).csize_t)
  for index in 0 ..< pad.len:
    pad[index] = (if index < passphrase.len: passphrase[index] else: 0'u8) xor 0x36'u8
  if sha1Start(addr deriver.context) != 0 or
      sha1Compress(addr deriver.context, addr pad[0]) != 0:
    deriver.clearWpa2PmkDeriver()
    return false
  deriver.inner = deriver.context.state
  for value in pad.mitems:
    value = value xor (0x36'u8 xor 0x5c'u8)
  if sha1Start(addr deriver.context) != 0 or
      sha1Compress(addr deriver.context, addr pad[0]) != 0:
    deriver.clearWpa2PmkDeriver()
    return false
  deriver.outer = deriver.context.state
  for index, value in ssid:
    deriver.firstBlock[index] = value
  deriver.firstBlock[ssid.len + 4] = 0x80'u8
  deriver.firstBlock.writeBigEndian(60, ((64 + ssid.len + 4) * 8).uint32)
  deriver.digestBlock[20] = 0x80'u8
  deriver.digestBlock.writeBigEndian(60, ((64 + 20) * 8).uint32)
  deriver.ssidLen = ssid.len
  deriver.blockIndex = 1
  deriver.active = true
  true

proc stepWpa2PmkDeriver*(deriver: var Wpa2PmkDeriver;
                         maxRounds: int): Wpa2PmkStep =
  if deriver.finished: return pmkReady
  if not deriver.active or maxRounds <= 0: return pmkFailed
  var rounds = 0
  while rounds < maxRounds:
    if deriver.roundIndex == 0:
      deriver.firstBlock[deriver.ssidLen + 3] = deriver.blockIndex.uint8
      deriver.context.state = deriver.inner
      if sha1Compress(addr deriver.context, addr deriver.firstBlock[0]) != 0:
        deriver.clearWpa2PmkDeriver()
        return pmkFailed
    for index in 0 ..< 5:
      deriver.digestBlock.writeBigEndian(index * 4, deriver.context.state[index])
    deriver.context.state = deriver.outer
    if sha1Compress(addr deriver.context, addr deriver.digestBlock[0]) != 0:
      deriver.clearWpa2PmkDeriver()
      return pmkFailed
    if deriver.roundIndex == 0:
      deriver.accum = deriver.context.state
    else:
      for index in 0 ..< 5:
        deriver.accum[index] = deriver.accum[index] xor deriver.context.state[index]
    inc deriver.roundIndex
    inc rounds
    if deriver.roundIndex == 4096:
      let words = if deriver.blockIndex == 1: 5 else: 3
      for index in 0 ..< words:
        deriver.pmk.writeBigEndian((deriver.blockIndex - 1) * 20 + index * 4,
                                    deriver.accum[index])
      if deriver.blockIndex == 2:
        deriver.active = false
        deriver.finished = true
        return pmkReady
      deriver.blockIndex = 2
      deriver.roundIndex = 0
    else:
      for index in 0 ..< 5:
        deriver.digestBlock.writeBigEndian(index * 4, deriver.context.state[index])
      deriver.context.state = deriver.inner
      if sha1Compress(addr deriver.context, addr deriver.digestBlock[0]) != 0:
        deriver.clearWpa2PmkDeriver()
        return pmkFailed
  pmkPending

when defined(bl808m0) and defined(bl808WifiNimFw):
  type PreparedWpa2Pmk = object
    valid: bool
    passphraseLen, ssidLen: uint8
    passphrase: array[63, uint8]
    ssid: array[32, uint8]
    pmk: Wpa2Pmk

  var preparedWpa2Pmk: PreparedWpa2Pmk

  proc clearPreparedWpa2Pmk*() =
    secureZero(addr preparedWpa2Pmk, sizeof(preparedWpa2Pmk).csize_t)

  proc cachePreparedWpa2Pmk*(deriver: var Wpa2PmkDeriver;
                              passphrase, ssid: openArray[uint8]): bool =
    clearPreparedWpa2Pmk()
    if not deriver.finished or passphrase.len notin 8..63 or
        ssid.len notin 1..32:
      deriver.clearWpa2PmkDeriver()
      return false
    preparedWpa2Pmk.passphraseLen = passphrase.len.uint8
    preparedWpa2Pmk.ssidLen = ssid.len.uint8
    for index, value in passphrase:
      preparedWpa2Pmk.passphrase[index] = value
    for index, value in ssid:
      preparedWpa2Pmk.ssid[index] = value
    preparedWpa2Pmk.pmk = deriver.pmk
    preparedWpa2Pmk.valid = true
    deriver.clearWpa2PmkDeriver()
    true

  proc preparedWpa2PmkMatches(passphrase, ssid: cstring;
                              passphraseLen: int; ssidLen: csize_t): bool =
    if not preparedWpa2Pmk.valid or
        passphraseLen != preparedWpa2Pmk.passphraseLen.int or
        ssidLen != preparedWpa2Pmk.ssidLen.csize_t:
      return false
    var mismatch = 0'u8
    for index in 0 ..< passphraseLen:
      mismatch = mismatch or
        (passphrase[index].uint8 xor preparedWpa2Pmk.passphrase[index])
    for index in 0 ..< ssidLen.int:
      mismatch = mismatch or (ssid[index].uint8 xor preparedWpa2Pmk.ssid[index])
    mismatch == 0

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
    if preparedWpa2Pmk.valid:
      let matches = preparedWpa2PmkMatches(passphrase, ssid,
                                            passphraseLength, ssidLength)
      if matches and iterations == 4096 and outputLength == 32:
        copyMem(output, addr preparedWpa2Pmk.pmk[0], 32)
        clearPreparedWpa2Pmk()
        when defined(radioDiag):
          inc wpa2PmkTiming.preparedHits
        return 0
      clearPreparedWpa2Pmk()
    when defined(radioDiag):
      inc wpa2PmkTiming.fallbackCalls
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
