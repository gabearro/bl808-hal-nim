## Integer-backed IEEE-754 helpers for cores without hardware or toolchain FP.
##
## Values are represented as raw WebAssembly bit patterns. These routines avoid
## Nim float types and std/math so RV32E builds do not pull soft-float helpers.

const
  F32Sign* = 0x8000_0000'u32
  F32ExpMask* = 0x7F80_0000'u32
  F32FracMask* = 0x007F_FFFF'u32
  F32QuietNan* = 0x7FC0_0000'u32

type
  Wide64 = object
    lo: uint32
    hi: uint32

proc f32Sign(a: uint32): uint32 {.inline.} = a and F32Sign
proc f32Exp(a: uint32): int {.inline.} = int((a and F32ExpMask) shr 23)
proc f32Frac(a: uint32): uint32 {.inline.} = a and F32FracMask
proc f32IsNan*(a: uint32): bool {.inline.} =
  (a and F32ExpMask) == F32ExpMask and (a and F32FracMask) != 0
proc f32IsInf*(a: uint32): bool {.inline.} =
  (a and F32ExpMask) == F32ExpMask and (a and F32FracMask) == 0
proc f32IsZero*(a: uint32): bool {.inline.} =
  (a and not F32Sign) == 0

proc f32Abs*(a: uint32): uint32 {.inline.} = a and not F32Sign
proc f32Neg*(a: uint32): uint32 {.inline.} = a xor F32Sign

proc shrSticky(v: uint32, shift: int): uint32 =
  if shift <= 0:
    return v
  if shift >= 32:
    return if v == 0: 0'u32 else: 1'u32
  let lostMask = (1'u32 shl shift) - 1'u32
  result = v shr shift
  if (v and lostMask) != 0:
    result = result or 1'u32

proc shrStickyWide(v: Wide64, shift: int): uint32 =
  if shift <= 0:
    return v.lo
  if shift >= 64:
    return if v.lo == 0 and v.hi == 0: 0'u32 else: 1'u32
  if shift >= 32:
    let upperShift = shift - 32
    result = v.hi shr upperShift
    let lost =
      if upperShift == 0:
        v.lo != 0
      else:
        v.lo != 0 or (v.hi and ((1'u32 shl upperShift) - 1'u32)) != 0
    if lost:
      result = result or 1'u32
    return
  result = (v.hi shl (32 - shift)) or (v.lo shr shift)
  let lostMask = (1'u32 shl shift) - 1'u32
  if (v.lo and lostMask) != 0:
    result = result or 1'u32

proc wideMul32(a, b: uint32): Wide64 =
  let
    a0 = a and 0xFFFF'u32
    a1 = a shr 16
    b0 = b and 0xFFFF'u32
    b1 = b shr 16
    p0 = a0 * b0
    p1 = a0 * b1
    p2 = a1 * b0
    p3 = a1 * b1
    middle = (p0 shr 16) + (p1 and 0xFFFF'u32) + (p2 and 0xFFFF'u32)
  result.lo = (p0 and 0xFFFF'u32) or (middle shl 16)
  result.hi = p3 + (p1 shr 16) + (p2 shr 16) + (middle shr 16)

proc clz32(v: uint32): int =
  if v == 0:
    return 32
  var bit = 0x8000_0000'u32
  while (v and bit) == 0:
    inc result
    bit = bit shr 1

proc packF32(sign: uint32, exp: int, mantWithGuard: uint32): uint32 =
  var e = exp
  var mant = mantWithGuard

  if mant == 0:
    return sign

  # Hidden bit is at bit 26 because mantissa has three guard/round/sticky bits.
  while mant >= (1'u32 shl 27):
    mant = shrSticky(mant, 1)
    inc e
  while e > 0 and mant < (1'u32 shl 26):
    mant = mant shl 1
    dec e

  if e >= 255:
    return sign or F32ExpMask

  if e <= 0:
    mant = shrSticky(mant, 1 - e)
    e = 0

  let guard = (mant shr 2) and 1'u32
  let roundBit = (mant shr 1) and 1'u32
  let sticky = mant and 1'u32
  var frac = mant shr 3
  if guard != 0 and (roundBit != 0 or sticky != 0 or (frac and 1'u32) != 0):
    inc frac
    if e > 0 and frac >= (1'u32 shl 24):
      frac = frac shr 1
      inc e
      if e >= 255:
        return sign or F32ExpMask

  if e == 0:
    sign or (frac and F32FracMask)
  else:
    sign or (uint32(e) shl 23) or (frac and F32FracMask)

proc f32Add*(a, b: uint32): uint32 =
  if f32IsNan(a): return F32QuietNan or f32Frac(a)
  if f32IsNan(b): return F32QuietNan or f32Frac(b)
  if f32IsInf(a) or f32IsInf(b):
    if f32IsInf(a) and f32IsInf(b) and f32Sign(a) != f32Sign(b):
      return F32QuietNan
    return if f32IsInf(a): a else: b
  if f32IsZero(a): return b
  if f32IsZero(b): return a

  var signA = f32Sign(a)
  var signB = f32Sign(b)
  var expA = f32Exp(a)
  var expB = f32Exp(b)
  var mantA = f32Frac(a)
  var mantB = f32Frac(b)

  if expA == 0:
    expA = 1
  else:
    mantA = mantA or (1'u32 shl 23)
  if expB == 0:
    expB = 1
  else:
    mantB = mantB or (1'u32 shl 23)

  mantA = mantA shl 3
  mantB = mantB shl 3

  if expA < expB or (expA == expB and mantA < mantB):
    swap(signA, signB)
    swap(expA, expB)
    swap(mantA, mantB)

  mantB = shrSticky(mantB, expA - expB)
  let mant =
    if signA == signB:
      mantA + mantB
    else:
      mantA - mantB
  packF32(signA, expA, mant)

proc f32Sub*(a, b: uint32): uint32 =
  f32Add(a, f32Neg(b))

proc f32Mul*(a, b: uint32): uint32 =
  if f32IsNan(a): return F32QuietNan or f32Frac(a)
  if f32IsNan(b): return F32QuietNan or f32Frac(b)
  let sign = f32Sign(a) xor f32Sign(b)
  if f32IsInf(a) or f32IsInf(b):
    if f32IsZero(a) or f32IsZero(b):
      return F32QuietNan
    return sign or F32ExpMask
  if f32IsZero(a) or f32IsZero(b):
    return sign

  var expA = f32Exp(a)
  var expB = f32Exp(b)
  var mantA = f32Frac(a)
  var mantB = f32Frac(b)
  if expA == 0:
    expA = 1
  else:
    mantA = mantA or (1'u32 shl 23)
  if expB == 0:
    expB = 1
  else:
    mantB = mantB or (1'u32 shl 23)

  var exp = expA + expB - 127
  let product = wideMul32(mantA, mantB)
  let mant =
    if (product.hi and (1'u32 shl 15)) != 0:
      inc exp
      shrStickyWide(product, 21)
    else:
      shrStickyWide(product, 20)
  packF32(sign, exp, mant)

proc f32Copysign*(mag, sgn: uint32): uint32 =
  f32Abs(mag) or f32Sign(sgn)

proc u32ToF32*(v: uint32): uint32 =
  if v == 0:
    return 0
  let msb = 31 - clz32(v)
  let exp = msb + 127
  let mant =
    if msb >= 26:
      shrSticky(v, msb - 26)
    else:
      v shl (26 - msb)
  packF32(0, exp, mant)

proc i32ToF32*(v: int32): uint32 =
  if v == 0:
    return 0
  if v < 0:
    let mag =
      if v == int32.low:
        0x8000_0000'u32
      else:
        uint32(-v)
    F32Sign or u32ToF32(mag)
  else:
    u32ToF32(uint32(v))

proc f32Eq*(a, b: uint32): bool =
  if f32IsNan(a) or f32IsNan(b):
    return false
  if f32IsZero(a) and f32IsZero(b):
    return true
  a == b

proc f32Lt*(a, b: uint32): bool =
  if f32IsNan(a) or f32IsNan(b) or f32Eq(a, b):
    return false
  let sa = f32Sign(a) != 0
  let sb = f32Sign(b) != 0
  if sa != sb:
    return sa
  if sa:
    f32Abs(a) > f32Abs(b)
  else:
    f32Abs(a) < f32Abs(b)

proc f32Le*(a, b: uint32): bool =
  f32Eq(a, b) or f32Lt(a, b)

proc f32Min*(a, b: uint32): uint32 =
  if f32IsNan(a) or f32IsNan(b): return F32QuietNan
  if f32IsZero(a) and f32IsZero(b):
    return a or b
  if f32Lt(a, b): a else: b

proc f32Max*(a, b: uint32): uint32 =
  if f32IsNan(a) or f32IsNan(b): return F32QuietNan
  if f32IsZero(a) and f32IsZero(b):
    return a and b
  if f32Lt(a, b): b else: a
