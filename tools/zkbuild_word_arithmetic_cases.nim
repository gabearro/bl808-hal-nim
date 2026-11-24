## Shared host/RV32 checks of the pinned library's actual portable primitives.
import constantine/platforms/abstractions
import constantine/platforms/intrinsics/[extended_precision, addcarry_subborrow]

type WordArithmeticCase* = array[24, uint32]

proc checkWordArithmeticCase*(row: WordArithmeticCase): bool =
  let a = Ct[uint32](row[0])
  let b = Ct[uint32](row[1])
  let c = Ct[uint32](row[2])
  let d = Ct[uint32](row[3])
  var hi, lo: Ct[uint32]
  var carry: Carry
  addC(carry, lo, a, b, Carry(row[4]))
  if uint32(lo) != row[8] or uint32(carry) != row[9]: return false
  var borrow: Borrow
  subB(borrow, lo, a, b, Borrow(row[4]))
  if uint32(lo) != row[10] or uint32(borrow) != row[11]: return false
  mul(hi, lo, a, b)
  if uint32(lo) != row[12] or uint32(hi) != row[13]: return false
  muladd1(hi, lo, a, b, c)
  if uint32(lo) != row[14] or uint32(hi) != row[15]: return false
  muladd2(hi, lo, a, b, c, d)
  if uint32(lo) != row[16] or uint32(hi) != row[17]: return false
  var t = Ct[uint32](row[5])
  var u = Ct[uint32](row[6])
  var v = Ct[uint32](row[7])
  mulAcc(t, u, v, a, b)
  if uint32(v) != row[18] or uint32(u) != row[19] or uint32(t) != row[20]: return false
  t = Ct[uint32](0)
  u = Ct[uint32](row[6])
  v = Ct[uint32](row[7])
  for _ in 0..<16: mulAcc(t, u, v, a, b)
  if uint32(v) != row[21] or uint32(u) != row[22] or uint32(t) != row[23]: return false
  # Actual FIPS correction for r mod 2^32 = 1, negative inverse = -1.
  t = Ct[uint32](row[5])
  u = Ct[uint32](row[6])
  v = Ct[uint32](row[7])
  let correction = v * Ct[uint32](0xffffffff'u32)
  mulAcc(t, u, v, correction, Ct[uint32](1))
  uint32(v) == 0
