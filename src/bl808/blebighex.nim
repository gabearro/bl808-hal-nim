## ESP/BLE P-256 BigHex compatibility helpers.
##
## The ROM/controller ABI represents field elements as nine big-endian u32
## magnitude words followed by a significant-word count and a sign flag:
## words[0] is the carry word above bit 255 and words[8] is least significant.

import p256

type
  BleBigHex256* = object
    words*: array[9, uint32]
    len*: uint32
    sign*: uint32

  BleP256Field = array[32, uint8]

const
  BigHexSize* = 44
  BigHexWords = 9
  P256BigHex = BleBigHex256(
    words: [
      0'u32, 0xFFFF_FFFF'u32, 0x0000_0001'u32, 0'u32, 0'u32,
      0'u32, 0xFFFF_FFFF'u32, 0xFFFF_FFFF'u32, 0xFFFF_FFFF'u32
    ],
    len: 8,
    sign: 0
  )

proc ptrAt(base: pointer, offset: int): pointer {.inline.} =
  cast[pointer](cast[uint](base) + offset.uint)

proc loadLeWord(bytes: BleP256Field, limb: int): uint32 =
  let off = limb * 4
  bytes[off].uint32 or
    (bytes[off + 1].uint32 shl 8) or
    (bytes[off + 2].uint32 shl 16) or
    (bytes[off + 3].uint32 shl 24)

proc storeLeWord(bytes: var BleP256Field, limb: int, word: uint32) =
  let off = limb * 4
  bytes[off] = word.uint8
  bytes[off + 1] = (word shr 8).uint8
  bytes[off + 2] = (word shr 16).uint8
  bytes[off + 3] = (word shr 24).uint8

proc fieldIsZero(a: BleP256Field): bool =
  for b in a:
    if b != 0:
      return false
  true

proc fieldEq(a, b: BleP256Field): bool =
  for i in 0 ..< a.len:
    if a[i] != b[i]:
      return false
  true

proc fieldAdd(a, b: BleP256Field): BleP256Field =
  discard p256FieldAddLe(unsafeAddr a[0], unsafeAddr b[0], addr result[0])

proc fieldSub(a, b: BleP256Field): BleP256Field =
  discard p256FieldSubLe(unsafeAddr a[0], unsafeAddr b[0], addr result[0])

proc fieldMul(a, b: BleP256Field): BleP256Field =
  discard p256FieldMulLe(unsafeAddr a[0], unsafeAddr b[0], addr result[0])

proc fieldMulSmall(a: BleP256Field, k: uint32): BleP256Field =
  discard p256FieldMulSmallLe(unsafeAddr a[0], k, addr result[0])

proc fieldInv(a: BleP256Field, outVal: var BleP256Field): bool =
  p256InverseFieldLe(unsafeAddr a[0], addr outVal[0])

proc fieldOne(): BleP256Field =
  result[0] = 1

proc normalize*(x: var BleBigHex256) =
  var first = BigHexWords
  for i in 0 ..< BigHexWords:
    if x.words[i] != 0:
      first = i
      break
  if first == BigHexWords:
    x.len = 0
    x.sign = 0
  else:
    x.len = uint32(BigHexWords - first)

proc loadBleBigHex256*(src: pointer): BleBigHex256 =
  if src == nil:
    return
  let raw = cast[ptr UncheckedArray[uint32]](src)
  for i in 0 ..< BigHexWords:
    result.words[i] = raw[i]
  result.len = raw[9]
  result.sign = raw[10]
  normalize(result)

proc storeBleBigHex256*(dst: pointer, value: BleBigHex256) =
  if dst == nil:
    return
  var v = value
  normalize(v)
  let raw = cast[ptr UncheckedArray[uint32]](dst)
  for i in 0 ..< BigHexWords:
    raw[i] = v.words[i]
  raw[9] = v.len
  raw[10] = v.sign

proc cmpAbs(a, b: BleBigHex256): cint =
  for i in 0 ..< BigHexWords:
    if a.words[i] > b.words[i]:
      return 1
    if a.words[i] < b.words[i]:
      return -1
  0

proc addAbs(a, b: BleBigHex256): BleBigHex256 =
  var carry = 0'u64
  for i in countdown(BigHexWords - 1, 0):
    let sum = a.words[i].uint64 + b.words[i].uint64 + carry
    result.words[i] = sum.uint32
    carry = sum shr 32
  normalize(result)

proc subAbs(a, b: BleBigHex256): BleBigHex256 =
  var borrow = 0'u64
  for i in countdown(BigHexWords - 1, 0):
    let lhs = a.words[i].uint64
    let rhs = b.words[i].uint64 + borrow
    if lhs >= rhs:
      result.words[i] = (lhs - rhs).uint32
      borrow = 0
    else:
      result.words[i] = ((1'u64 shl 32) + lhs - rhs).uint32
      borrow = 1
  normalize(result)

proc addSigned(a, b: BleBigHex256): BleBigHex256 =
  if a.sign == b.sign:
    result = addAbs(a, b)
    result.sign = a.sign
    normalize(result)
    return
  let c = cmpAbs(a, b)
  if c == 0:
    return
  if c > 0:
    result = subAbs(a, b)
    result.sign = a.sign
  else:
    result = subAbs(b, a)
    result.sign = b.sign
  normalize(result)

proc subSigned(a, b: BleBigHex256): BleBigHex256 =
  var negB = b
  if negB.len != 0:
    negB.sign = if negB.sign == 0: 1'u32 else: 0'u32
  addSigned(a, negB)

proc mulAbsByU32(a: BleBigHex256, k: uint32): BleBigHex256 =
  var carry = 0'u64
  for i in countdown(BigHexWords - 1, 0):
    let product = a.words[i].uint64 * k.uint64 + carry
    result.words[i] = product.uint32
    carry = product shr 32
  result.sign = a.sign
  normalize(result)

proc div2Abs(a: BleBigHex256): BleBigHex256 =
  var carry = 0'u32
  for i in 0 ..< BigHexWords:
    let nextCarry = a.words[i] and 1'u32
    result.words[i] = (a.words[i] shr 1) or (carry shl 31)
    carry = nextCarry
  result.sign = a.sign
  normalize(result)

proc isOdd(a: BleBigHex256): bool =
  (a.words[BigHexWords - 1] and 1'u32) != 0

proc fieldWithLimb(limb: int, word: uint32): BleP256Field =
  if limb >= 0 and limb < 8:
    storeLeWord(result, limb, word)

proc toFieldAbs(a: BleBigHex256): BleP256Field =
  for limb in 0 ..< 8:
    storeLeWord(result, limb, a.words[8 - limb])
  discard p256FieldNormalizeLe(addr result[0], addr result[0])

  let high = a.words[0]
  if high != 0:
    result = fieldAdd(result, fieldWithLimb(0, high))
    result = fieldAdd(result, fieldWithLimb(7, high))
    result = fieldSub(result, fieldWithLimb(6, high))
    result = fieldSub(result, fieldWithLimb(3, high))

proc toField(a: BleBigHex256): BleP256Field =
  result = toFieldAbs(a)
  if a.sign != 0 and not fieldIsZero(result):
    var zero: BleP256Field
    result = fieldSub(zero, result)

proc fromField(field: BleP256Field): BleBigHex256 =
  for limb in 0 ..< 8:
    result.words[8 - limb] = loadLeWord(field, limb)
  normalize(result)

proc bleBigHexToFieldLe*(src: pointer, dst: ptr uint8): bool =
  if src == nil or dst == nil:
    return false
  let field = toField(loadBleBigHex256(src))
  for i in 0 ..< 32:
    cast[ptr UncheckedArray[uint8]](dst)[i] = field[i]
  true

proc bleBigHexFromFieldLe*(dst: pointer, src: ptr uint8): bool =
  if dst == nil or src == nil:
    return false
  let bytes = cast[ptr UncheckedArray[uint8]](src)
  var field: BleP256Field
  for i in 0 ..< 32:
    field[i] = bytes[i]
  discard p256FieldNormalizeLe(addr field[0], addr field[0])
  storeBleBigHex256(dst, fromField(field))
  true

proc bleBigHexAdd*(a, b, dst: pointer) =
  storeBleBigHex256(dst, addSigned(loadBleBigHex256(a), loadBleBigHex256(b)))

proc bleBigHexAddSelf*(dst, other: pointer) =
  bleBigHexAdd(dst, other, dst)

proc bleBigHexSubtract*(a, b, dst: pointer) =
  storeBleBigHex256(dst, subSigned(loadBleBigHex256(a), loadBleBigHex256(b)))

proc bleBigHexSubtractSelf*(dst, other: pointer) =
  bleBigHexSubtract(dst, other, dst)

proc bleBigHexAddModP256*(a, b, dst: pointer) =
  let fa = toField(loadBleBigHex256(a))
  let fb = toField(loadBleBigHex256(b))
  storeBleBigHex256(dst, fromField(fieldAdd(fa, fb)))

proc bleBigHexSubtractModP256*(a, b, dst: pointer) =
  let fa = toField(loadBleBigHex256(a))
  let fb = toField(loadBleBigHex256(b))
  storeBleBigHex256(dst, fromField(fieldSub(fa, fb)))

proc bleBigHexMultiplyModP256*(a, b, dst: pointer) =
  let fa = toField(loadBleBigHex256(a))
  let fb = toField(loadBleBigHex256(b))
  storeBleBigHex256(dst, fromField(fieldMul(fa, fb)))

proc bleBigHexMultiplyByU32ModP256*(a: pointer, k: uint32, dst: pointer) =
  let fa = toField(loadBleBigHex256(a))
  storeBleBigHex256(dst, fromField(fieldMulSmall(fa, k)))

proc bleBigHexP256TimesU32*(k: uint32, dst: pointer) =
  storeBleBigHex256(dst, mulAbsByU32(P256BigHex, k))

proc bleBigHexFromU32*(k: uint32): BleBigHex256 =
  result.words[BigHexWords - 1] = k
  normalize(result)

proc bleBigHexSubtractU32*(a: pointer, k: uint32, dst: pointer) =
  storeBleBigHex256(dst, subSigned(loadBleBigHex256(a), bleBigHexFromU32(k)))

proc bleBigHexSpecialModP256*(value: pointer) =
  if value == nil:
    return
  storeBleBigHex256(value, fromField(toField(loadBleBigHex256(value))))

proc bleBigHexAddP256*(value: pointer) =
  if value == nil:
    return
  storeBleBigHex256(value, addSigned(loadBleBigHex256(value), P256BigHex))

proc bleBigHexAddPdiv2*(value: pointer) =
  if value == nil:
    return
  var positive = fromField(toField(loadBleBigHex256(value)))
  if isOdd(positive):
    positive = addAbs(positive, P256BigHex)
  storeBleBigHex256(value, div2Abs(positive))

type P256Affine = object
  x, y: BleP256Field
  inf: bool

proc loadPoint(point: pointer): tuple[x, y, z: BleP256Field, inf: bool] =
  if point == nil:
    result.inf = true
    return
  result.x = toField(loadBleBigHex256(ptrAt(point, 0)))
  result.y = toField(loadBleBigHex256(ptrAt(point, BigHexSize)))
  result.z = toField(loadBleBigHex256(ptrAt(point, BigHexSize * 2)))
  result.inf = fieldIsZero(result.z)

proc storePoint(point: pointer, x, y, z: BleP256Field) =
  if point == nil:
    return
  storeBleBigHex256(ptrAt(point, 0), fromField(x))
  storeBleBigHex256(ptrAt(point, BigHexSize), fromField(y))
  storeBleBigHex256(ptrAt(point, BigHexSize * 2), fromField(z))

proc storeInfinity(point: pointer) =
  var zero: BleP256Field
  storePoint(point, zero, zero, zero)

proc toAffine(point: pointer): P256Affine =
  let p = loadPoint(point)
  if p.inf:
    result.inf = true
    return
  var zInv: BleP256Field
  if not fieldInv(p.z, zInv):
    result.inf = true
    return
  let z2 = fieldMul(zInv, zInv)
  let z3 = fieldMul(z2, zInv)
  result.x = fieldMul(p.x, z2)
  result.y = fieldMul(p.y, z3)

proc affineDouble(p: P256Affine): P256Affine =
  if p.inf or fieldIsZero(p.y):
    result.inf = true
    return
  let x2 = fieldMul(p.x, p.x)
  let numerator = fieldSub(fieldMulSmall(x2, 3), fieldWithLimb(0, 3))
  let denominator = fieldMulSmall(p.y, 2)
  var invDen: BleP256Field
  if not fieldInv(denominator, invDen):
    result.inf = true
    return
  let slope = fieldMul(numerator, invDen)
  result.x = fieldSub(fieldSub(fieldMul(slope, slope), p.x), p.x)
  result.y = fieldSub(fieldMul(slope, fieldSub(p.x, result.x)), p.y)

proc affineAdd(a, b: P256Affine): P256Affine =
  if a.inf:
    return b
  if b.inf:
    return a
  if fieldEq(a.x, b.x):
    if fieldIsZero(fieldAdd(a.y, b.y)):
      result.inf = true
      return
    return affineDouble(a)
  let numerator = fieldSub(b.y, a.y)
  let denominator = fieldSub(b.x, a.x)
  var invDen: BleP256Field
  if not fieldInv(denominator, invDen):
    result.inf = true
    return
  let slope = fieldMul(numerator, invDen)
  result.x = fieldSub(fieldSub(fieldMul(slope, slope), a.x), b.x)
  result.y = fieldSub(fieldMul(slope, fieldSub(a.x, result.x)), a.y)

proc bleP256StoreAffinePoint(dst: pointer, p: P256Affine) =
  if p.inf:
    storeInfinity(dst)
  else:
    storePoint(dst, p.x, p.y, fieldOne())

proc bleP256JacobianToAffineInPlace*(point: pointer) =
  bleP256StoreAffinePoint(point, toAffine(point))

proc bleP256JacobianDouble*(point, dst: pointer) =
  bleP256StoreAffinePoint(dst, affineDouble(toAffine(point)))

proc bleP256JacobianAdd*(a, b, dst: pointer) =
  bleP256StoreAffinePoint(dst, affineAdd(toAffine(a), toAffine(b)))
