## Pure Nim NIST P-256 arithmetic.
##
## Bluetooth LE Secure Connections encodes P-256 scalars and coordinates as
## 32-octet little-endian values. The helpers in this module use that wire
## format at their public boundary and little-endian 32-bit limbs internally.

type
  P256Int = array[8, uint32]

const
  P256P: P256Int = [
    0xFFFFFFFF'u32, 0xFFFFFFFF'u32, 0xFFFFFFFF'u32, 0x00000000'u32,
    0x00000000'u32, 0x00000000'u32, 0x00000001'u32, 0xFFFFFFFF'u32
  ]
  P256N: P256Int = [
    0xFC632551'u32, 0xF3B9CAC2'u32, 0xA7179E84'u32, 0xBCE6FAAD'u32,
    0xFFFFFFFF'u32, 0xFFFFFFFF'u32, 0x00000000'u32, 0xFFFFFFFF'u32
  ]
  P256B: P256Int = [
    0x27D2604B'u32, 0x3BCE3C3E'u32, 0xCC53B0F6'u32, 0x651D06B0'u32,
    0x769886BC'u32, 0xB3EBBD55'u32, 0xAA3A93E7'u32, 0x5AC635D8'u32
  ]
  P256Gx: P256Int = [
    0xD898C296'u32, 0xF4A13945'u32, 0x2DEB33A0'u32, 0x77037D81'u32,
    0x63A440F2'u32, 0xF8BCE6E5'u32, 0xE12C4247'u32, 0x6B17D1F2'u32
  ]
  P256Gy: P256Int = [
    0x37BF51F5'u32, 0xCBB64068'u32, 0x6B315ECE'u32, 0x2BCE3357'u32,
    0x7C0F9E16'u32, 0x8EE7EB4A'u32, 0xFE1A7F9B'u32, 0x4FE342E2'u32
  ]

  P256DebugPrivateKeyLe*: array[32, uint8] = [
    0xBD'u8, 0x1A, 0x3C, 0xCD, 0xA6, 0xB8, 0x99, 0x58,
    0x99, 0xB7, 0x40, 0xEB, 0x7B, 0x60, 0xFF, 0x4A,
    0x50, 0x3F, 0x10, 0xD2, 0xE3, 0xB3, 0xC9, 0x74,
    0x38, 0x5F, 0xC5, 0xA3, 0xD4, 0xF6, 0x49, 0x3F
  ]
  P256DebugPublicKeyXLe*: array[32, uint8] = [
    0xE6'u8, 0x9D, 0x35, 0x0E, 0x48, 0x01, 0x03, 0xCC,
    0xDB, 0xFD, 0xF4, 0xAC, 0x11, 0x91, 0xF4, 0xEF,
    0xB9, 0xA5, 0xF9, 0xE9, 0xA7, 0x83, 0x2C, 0x5E,
    0x2C, 0xBE, 0x97, 0xF2, 0xD2, 0x03, 0xB0, 0x20
  ]
  P256DebugPublicKeyYLe*: array[32, uint8] = [
    0x8B'u8, 0xD2, 0x89, 0x15, 0xD0, 0x8E, 0x1C, 0x74,
    0x24, 0x30, 0xED, 0x8F, 0xC2, 0x45, 0x63, 0x76,
    0x5C, 0x15, 0x52, 0x5A, 0xBF, 0x9A, 0x32, 0x63,
    0x6D, 0xEB, 0x2A, 0x65, 0x49, 0x9C, 0x80, 0xDC
  ]

proc loadLe(dst: var P256Int, src: ptr uint8) =
  let bytes = cast[ptr UncheckedArray[uint8]](src)
  for i in 0 ..< 8:
    let j = i * 4
    dst[i] = bytes[j].uint32 or
             (bytes[j + 1].uint32 shl 8) or
             (bytes[j + 2].uint32 shl 16) or
             (bytes[j + 3].uint32 shl 24)

proc storeLe(dst: ptr uint8, src: P256Int) =
  let bytes = cast[ptr UncheckedArray[uint8]](dst)
  for i in 0 ..< 8:
    let w = src[i]
    let j = i * 4
    bytes[j] = w.uint8
    bytes[j + 1] = (w shr 8).uint8
    bytes[j + 2] = (w shr 16).uint8
    bytes[j + 3] = (w shr 24).uint8

proc cmp(a, b: P256Int): cint =
  for i in countdown(7, 0):
    if a[i] > b[i]:
      return 1
    if a[i] < b[i]:
      return -1
  0

proc isZero(a: P256Int): bool =
  for w in a:
    if w != 0:
      return false
  true

proc getBit(a: P256Int, bit: int): bool =
  ((a[bit shr 5] shr (bit and 31)) and 1'u32) != 0

proc subRaw(dst: var P256Int, a, b: P256Int) =
  var borrow = 0'u64
  for i in 0 ..< 8:
    let lhs = a[i].uint64
    let rhs = b[i].uint64 + borrow
    if lhs >= rhs:
      dst[i] = (lhs - rhs).uint32
      borrow = 0
    else:
      dst[i] = ((1'u64 shl 32) + lhs - rhs).uint32
      borrow = 1

proc addRaw(dst: var P256Int, a, b: P256Int) =
  var carry = 0'u64
  for i in 0 ..< 8:
    let sum = a[i].uint64 + b[i].uint64 + carry
    dst[i] = sum.uint32
    carry = sum shr 32

proc normalize(a: var P256Int, modulus: P256Int) =
  while cmp(a, modulus) >= 0:
    var tmp: P256Int
    subRaw(tmp, a, modulus)
    a = tmp

proc addMod(dst: var P256Int, a, b, modulus: P256Int) =
  var threshold: P256Int
  subRaw(threshold, modulus, b)
  if cmp(a, threshold) >= 0:
    subRaw(dst, a, threshold)
  else:
    addRaw(dst, a, b)

proc subMod(dst: var P256Int, a, b, modulus: P256Int) =
  if cmp(a, b) >= 0:
    subRaw(dst, a, b)
  else:
    var delta: P256Int
    subRaw(delta, modulus, b)
    addRaw(dst, a, delta)

proc mulSmallMod(dst: var P256Int, a: P256Int, k: uint32, modulus: P256Int) =
  var acc: P256Int
  var term = a
  var n = k
  while n != 0:
    if (n and 1) != 0:
      addMod(acc, acc, term, modulus)
    n = n shr 1
    if n != 0:
      addMod(term, term, term, modulus)
  dst = acc

proc mulMod(dst: var P256Int, a, b, modulus: P256Int) =
  var acc: P256Int
  var term = a
  normalize(term, modulus)
  for bit in 0 ..< 256:
    if getBit(b, bit):
      addMod(acc, acc, term, modulus)
    addMod(term, term, term, modulus)
  dst = acc

proc subSmall(dst: var P256Int, a: P256Int, value: uint32) =
  dst = a
  var borrow = value.uint64
  var i = 0
  while borrow != 0 and i < 8:
    let lhs = dst[i].uint64
    let sub = borrow and 0xFFFF_FFFF'u64
    if lhs >= sub:
      dst[i] = (lhs - sub).uint32
      borrow = borrow shr 32
    else:
      dst[i] = ((1'u64 shl 32) + lhs - sub).uint32
      borrow = (borrow shr 32) + 1
    inc i

proc invMod(dst: var P256Int, a, modulus: P256Int) =
  var exp: P256Int
  subSmall(exp, modulus, 2)
  var result: P256Int
  var base = a
  result[0] = 1
  normalize(base, modulus)
  for bit in countdown(255, 0):
    var squared: P256Int
    mulMod(squared, result, result, modulus)
    result = squared
    if getBit(exp, bit):
      var product: P256Int
      mulMod(product, result, base, modulus)
      result = product
  dst = result

type
  Point = object
    x, y, z: P256Int
    inf: bool

proc pointDouble(p: var Point) =
  if p.inf or isZero(p.y):
    p.inf = true
    return

  var delta, gamma, beta, xm, xp, alpha: P256Int
  var tmp, tmp2, x3, y3, z3: P256Int
  mulMod(delta, p.z, p.z, P256P)
  mulMod(gamma, p.y, p.y, P256P)
  mulMod(beta, p.x, gamma, P256P)
  subMod(xm, p.x, delta, P256P)
  addMod(xp, p.x, delta, P256P)
  mulMod(alpha, xm, xp, P256P)
  mulSmallMod(alpha, alpha, 3, P256P)

  mulMod(x3, alpha, alpha, P256P)
  mulSmallMod(tmp, beta, 8, P256P)
  subMod(x3, x3, tmp, P256P)

  mulSmallMod(tmp, beta, 4, P256P)
  subMod(tmp, tmp, x3, P256P)
  mulMod(y3, alpha, tmp, P256P)
  mulMod(tmp2, gamma, gamma, P256P)
  mulSmallMod(tmp2, tmp2, 8, P256P)
  subMod(y3, y3, tmp2, P256P)

  addMod(tmp, p.y, p.z, P256P)
  mulMod(z3, tmp, tmp, P256P)
  subMod(z3, z3, gamma, P256P)
  subMod(z3, z3, delta, P256P)

  p.x = x3
  p.y = y3
  p.z = z3

proc pointAddMixed(p: var Point, ax, ay: P256Int) =
  if p.inf:
    p.x = ax
    p.y = ay
    p.z = [1'u32, 0, 0, 0, 0, 0, 0, 0]
    p.inf = false
    return

  var z2, z3v, u2, s2, h, r: P256Int
  mulMod(z2, p.z, p.z, P256P)
  mulMod(u2, ax, z2, P256P)
  mulMod(z3v, z2, p.z, P256P)
  mulMod(s2, ay, z3v, P256P)
  subMod(h, u2, p.x, P256P)
  subMod(r, s2, p.y, P256P)

  if isZero(h):
    if isZero(r):
      pointDouble(p)
    else:
      p.inf = true
    return

  var hh, hhh, v, x3, y3, tmp: P256Int
  mulMod(hh, h, h, P256P)
  mulMod(hhh, h, hh, P256P)
  mulMod(v, p.x, hh, P256P)
  mulMod(x3, r, r, P256P)
  subMod(x3, x3, hhh, P256P)
  subMod(x3, x3, v, P256P)
  subMod(x3, x3, v, P256P)
  subMod(tmp, v, x3, P256P)
  mulMod(y3, r, tmp, P256P)
  mulMod(tmp, p.y, hhh, P256P)
  subMod(y3, y3, tmp, P256P)
  mulMod(p.z, p.z, h, P256P)
  p.x = x3
  p.y = y3

proc pointToAffine(p: Point, outX, outY: var P256Int): bool =
  if p.inf or isZero(p.z):
    return false
  var zInv, z2, z3v: P256Int
  invMod(zInv, p.z, P256P)
  mulMod(z2, zInv, zInv, P256P)
  mulMod(z3v, z2, zInv, P256P)
  mulMod(outX, p.x, z2, P256P)
  mulMod(outY, p.y, z3v, P256P)
  true

proc scalarMulAffine(scalar, px, py: P256Int, outX, outY: var P256Int): bool =
  var p = Point(inf: true)
  for bit in countdown(255, 0):
    if not p.inf:
      pointDouble(p)
    if getBit(scalar, bit):
      pointAddMixed(p, px, py)
  pointToAffine(p, outX, outY)

proc p256IsValidScalarLe*(scalar: ptr uint8): bool =
  if scalar == nil:
    return false
  var k: P256Int
  loadLe(k, scalar)
  not isZero(k) and cmp(k, P256N) < 0

proc p256IsValidPublicKeyLe*(x, y: ptr uint8): bool =
  if x == nil or y == nil:
    return false

  var px, py: P256Int
  loadLe(px, x)
  loadLe(py, y)
  if isZero(px) and isZero(py):
    return false
  if cmp(px, P256P) >= 0 or cmp(py, P256P) >= 0:
    return false

  var y2, x2, rhs, threeX: P256Int
  mulMod(y2, py, py, P256P)
  mulMod(x2, px, px, P256P)
  mulMod(rhs, x2, px, P256P)
  mulSmallMod(threeX, px, 3, P256P)
  subMod(rhs, rhs, threeX, P256P)
  addMod(rhs, rhs, P256B, P256P)
  cmp(y2, rhs) == 0

proc p256ScalarBaseMultLe*(scalar, outX, outY: ptr uint8): bool =
  if scalar == nil or outX == nil or outY == nil:
    return false
  var k, rx, ry: P256Int
  loadLe(k, scalar)
  if isZero(k) or cmp(k, P256N) >= 0:
    return false
  if not scalarMulAffine(k, P256Gx, P256Gy, rx, ry):
    return false
  storeLe(outX, rx)
  storeLe(outY, ry)
  true

proc p256ScalarMultLe*(scalar, x, y, outX, outY: ptr uint8): bool =
  if scalar == nil or x == nil or y == nil or outX == nil or outY == nil:
    return false
  if not p256IsValidPublicKeyLe(x, y):
    return false
  var k, px, py, rx, ry: P256Int
  loadLe(k, scalar)
  if isZero(k) or cmp(k, P256N) >= 0:
    return false
  loadLe(px, x)
  loadLe(py, y)
  if not scalarMulAffine(k, px, py, rx, ry):
    return false
  storeLe(outX, rx)
  storeLe(outY, ry)
  true

proc p256InverseFieldLe*(input, output: ptr uint8): bool =
  if input == nil or output == nil:
    return false
  var a, inv: P256Int
  loadLe(a, input)
  if isZero(a) or cmp(a, P256P) >= 0:
    return false
  invMod(inv, a, P256P)
  storeLe(output, inv)
  true

proc p256OrderLe*(output: ptr uint8) =
  if output != nil:
    storeLe(output, P256N)

proc p256FieldNormalizeLe*(input, output: ptr uint8): bool =
  if input == nil or output == nil:
    return false
  var a: P256Int
  loadLe(a, input)
  normalize(a, P256P)
  storeLe(output, a)
  true

proc p256FieldAddLe*(a, b, output: ptr uint8): bool =
  if a == nil or b == nil or output == nil:
    return false
  var aa, bb, sum: P256Int
  loadLe(aa, a)
  loadLe(bb, b)
  normalize(aa, P256P)
  normalize(bb, P256P)
  addMod(sum, aa, bb, P256P)
  storeLe(output, sum)
  true

proc p256FieldSubLe*(a, b, output: ptr uint8): bool =
  if a == nil or b == nil or output == nil:
    return false
  var aa, bb, diff: P256Int
  loadLe(aa, a)
  loadLe(bb, b)
  normalize(aa, P256P)
  normalize(bb, P256P)
  subMod(diff, aa, bb, P256P)
  storeLe(output, diff)
  true

proc p256FieldMulLe*(a, b, output: ptr uint8): bool =
  if a == nil or b == nil or output == nil:
    return false
  var aa, bb, product: P256Int
  loadLe(aa, a)
  loadLe(bb, b)
  normalize(aa, P256P)
  normalize(bb, P256P)
  mulMod(product, aa, bb, P256P)
  storeLe(output, product)
  true

proc p256FieldMulSmallLe*(a: ptr uint8, k: uint32, output: ptr uint8): bool =
  if a == nil or output == nil:
    return false
  var aa, product: P256Int
  loadLe(aa, a)
  normalize(aa, P256P)
  mulSmallMod(product, aa, k, P256P)
  storeLe(output, product)
  true
