## Bluetooth P-256 helpers.
##
## BLE controller code consumes little-endian P-256 byte strings. This module
## keeps that representation at the boundary and selects the BL808 PKA-backed
## implementation on M0 while preserving the portable software implementation
## for host tests and non-M0 builds.

import p256
when defined(bl808m0):
  const bl808BleP256UsePka* {.booldefine.}: bool = true
  when bl808BleP256UsePka:
    import pka
else:
  const bl808BleP256UsePka* = false

const
  BleP256KeyLen* = 32
  BleP256DebugPrivateKeyLe* = P256DebugPrivateKeyLe
  BleP256DebugPublicKeyXLe* = P256DebugPublicKeyXLe
  BleP256DebugPublicKeyYLe* = P256DebugPublicKeyYLe

when defined(bl808m0) and bl808BleP256UsePka:
  type P256PkaWords = array[8, uint32]

  proc leBytesToPkaWords(dst: var P256PkaWords, src: ptr uint8) =
    let bytes = cast[ptr UncheckedArray[uint8]](src)
    for i in 0 ..< 8:
      let off = (7 - i) * 4
      dst[i] = bytes[off + 3].uint32 or
               (bytes[off + 2].uint32 shl 8) or
               (bytes[off + 1].uint32 shl 16) or
               (bytes[off].uint32 shl 24)

  proc pkaWordsToLeBytes(dst: ptr uint8, src: P256PkaWords) =
    let bytes = cast[ptr UncheckedArray[uint8]](dst)
    for i in 0 ..< 8:
      let off = (7 - i) * 4
      let word = src[i]
      bytes[off] = uint8((word shr 24) and 0xFF'u32)
      bytes[off + 1] = uint8((word shr 16) and 0xFF'u32)
      bytes[off + 2] = uint8((word shr 8) and 0xFF'u32)
      bytes[off + 3] = uint8(word and 0xFF'u32)

  proc scalarBaseMultPkaLe(secret, outX, outY: ptr uint8): bool =
    if not p256IsValidScalarLe(secret):
      return false

    var ecdh: pka.BflbEcdh
    var scalar: P256PkaWords
    var x: P256PkaWords
    var y: P256PkaWords
    leBytesToPkaWords(scalar, secret)

    if pka.bflb_sec_ecdh_init(addr ecdh, pka.EcpSecp256r1) != 0:
      return false
    let rc = pka.bflb_sec_ecdh_get_public_key(addr ecdh, addr scalar[0],
                                              addr x[0], addr y[0])
    discard pka.bflb_sec_ecdh_deinit(addr ecdh)
    if rc != 0:
      return false

    pkaWordsToLeBytes(outX, x)
    pkaWordsToLeBytes(outY, y)
    true

  proc scalarMultPkaLe(secret, pointX, pointY, outX, outY: ptr uint8): bool =
    if not p256IsValidScalarLe(secret):
      return false

    var ecdh: pka.BflbEcdh
    var scalar: P256PkaWords
    var px: P256PkaWords
    var py: P256PkaWords
    var x: P256PkaWords
    var y: P256PkaWords
    leBytesToPkaWords(scalar, secret)
    leBytesToPkaWords(px, pointX)
    leBytesToPkaWords(py, pointY)

    if pka.bflb_sec_ecdh_init(addr ecdh, pka.EcpSecp256r1) != 0:
      return false
    let rc = pka.bflb_sec_ecdh_get_encrypt_key(addr ecdh, addr px[0],
                                               addr py[0], addr scalar[0],
                                               addr x[0], addr y[0])
    discard pka.bflb_sec_ecdh_deinit(addr ecdh)
    if rc != 0:
      return false

    pkaWordsToLeBytes(outX, x)
    pkaWordsToLeBytes(outY, y)
    true

  proc inverseFieldPkaLe(input, output: ptr uint8): bool =
    if input == nil or output == nil:
      return false

    var value: P256PkaWords
    var inverse: P256PkaWords
    leBytesToPkaWords(value, input)
    if pka.bflb_sec_p256_inverse_field_be(addr value[0], addr inverse[0]) != 0:
      return false
    pkaWordsToLeBytes(output, inverse)
    true

proc bleP256IsValidScalarLe*(scalar: ptr uint8): bool =
  p256IsValidScalarLe(scalar)

proc bleP256IsValidPublicKeyLe*(x, y: ptr uint8): bool =
  p256IsValidPublicKeyLe(x, y)

proc bleP256ScalarBaseMultLe*(secret, outX, outY: ptr uint8): bool =
  if secret == nil or outX == nil or outY == nil:
    return false
  when defined(bl808m0) and bl808BleP256UsePka:
    scalarBaseMultPkaLe(secret, outX, outY)
  else:
    p256ScalarBaseMultLe(secret, outX, outY)

proc bleP256ScalarMultLe*(secret, pointX, pointY, outX, outY: ptr uint8): bool =
  if secret == nil or pointX == nil or pointY == nil or outX == nil or
      outY == nil:
    return false
  when defined(bl808m0) and bl808BleP256UsePka:
    scalarMultPkaLe(secret, pointX, pointY, outX, outY)
  else:
    p256ScalarMultLe(secret, pointX, pointY, outX, outY)

proc bleP256InverseFieldLe*(input, output: ptr uint8): bool =
  when defined(bl808m0) and bl808BleP256UsePka:
    inverseFieldPkaLe(input, output)
  else:
    p256InverseFieldLe(input, output)
