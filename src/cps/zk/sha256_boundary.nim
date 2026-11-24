## Pure SHA wiring shared by the production circuit and boundary checks.
import r1cs, sha256_word

type ShaByteBits* = array[8,Linear]

proc shaWordBits*(bytes: array[4,ShaByteBits]): array[32,Linear] =
  ## SHA words read four bytes in big-endian order; bit arrays are little-endian.
  for byteIndex in 0..3:
    for bit in 0..7: result[8*(3-byteIndex)+bit] = bytes[byteIndex][bit]

proc shaDigestLimb*(words: array[4,Linear]): Linear =
  ## Pack four consecutive 32-bit digest words into one big-endian 128-bit limb.
  result = constant(0)
  var weight = scalar(1)
  for i in countdown(3,0):
    result = result+words[i].scale(weight)
    weight = weight*scalar(4294967296'u64)

proc shaLengthByte*(lengthBits: openArray[Linear], offset: int): Linear =
  ## The last eight byte positions hold the u32 byte length times eight as u64.
  if lengthBits.len != 32 or offset < 0 or offset >= 64:
    raise newException(ValueError,"invalid SHA length-byte wiring")
  result = constant(0)
  if offset < 56: return
  var bits: ShaByteBits
  for bit in 0..7:
    let index = (63-offset)*8+bit-3
    bits[bit] = if index >= 0 and index < 32: lengthBits[index] else: constant(0)
  result = pack(bits)
