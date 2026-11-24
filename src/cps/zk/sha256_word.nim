## SHA-256 word circuits. Inputs to Boolean operations must have Boolean bits;
## inputs to addition must also bind value to those 32 bits. rotate/shift
## return bit views; word materializes the associated packed value.
import r1cs, range_check

type ShaWord* = object
  bits*: array[32, Linear]
  value*: Linear

proc pack*(bits: openArray[Linear]): Linear =
  result = constant(0)
  var weight = scalar(1)
  for bit in bits:
    result = result+bit.scale(weight)
    weight = weight+weight

proc literal*(value: uint32): ShaWord =
  result.value = constant(value)
  for i in 0..31: result.bits[i] = constant((value shr i) and 1)

proc word*(c: var Circuit, bits: array[32, Linear]): ShaWord =
  result.bits = bits
  result.value = c.materialize(pack(bits))

proc add*(c: var Circuit, values: openArray[ShaWord]): ShaWord =
  var sum = constant(0)
  for value in values: sum = sum+value.value
  var carryBits = 0
  while (1 shl carryBits) < values.len: inc carryBits
  let bits = c.constrainUnsigned(sum, 32+carryBits)
  for i in 0..31: result.bits[i] = bits[i]
  result.value = c.materialize(pack(result.bits))

proc rotate*(value: ShaWord, amount: int): ShaWord =
  for i in 0..31: result.bits[i] = value.bits[(i+amount) mod 32]

proc shift*(value: ShaWord, amount: int): ShaWord =
  for i in 0..31:
    result.bits[i] = if i+amount < 32: value.bits[i+amount] else: constant(0)

proc xor3*(c: var Circuit, a,b,d: ShaWord): ShaWord =
  var bits: array[32, Linear]
  for i in 0..31:
    let ab = a.bits[i]+b.bits[i]-c.multiply(a.bits[i],b.bits[i]).scale(scalar(2))
    bits[i] = ab+d.bits[i]-c.multiply(ab,d.bits[i]).scale(scalar(2))
  c.word(bits)

proc choose*(c: var Circuit, a,b,d: ShaWord): ShaWord =
  var bits: array[32, Linear]
  for i in 0..31: bits[i] = d.bits[i]+c.multiply(a.bits[i],b.bits[i]-d.bits[i])
  c.word(bits)

proc majority*(c: var Circuit, a,b,d: ShaWord): ShaWord =
  var bits: array[32, Linear]
  for i in 0..31:
    let ab = c.multiply(a.bits[i],b.bits[i])
    bits[i] = ab+c.multiply(d.bits[i],a.bits[i]+b.bits[i]-ab.scale(scalar(2)))
  c.word(bits)

