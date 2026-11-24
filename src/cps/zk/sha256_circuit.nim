## SHA-256 over a bounded, private byte vector with a private u32 length.
## FIPS 180-4 padding is selected by constrained length bits, never by host
## control flow. The matrix depends only on byte capacity.
import r1cs, range_check, sha256_word, sha256_boundary

type ShaDigestWires* = array[2, Linear]

const
  ShaInitial* = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
    0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]
  ShaRound* = [0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
    0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
    0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
    0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
    0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
    0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
    0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
    0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
    0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
    0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
    0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
    0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
    0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
    0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
    0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
    0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

proc compress*(c: var Circuit, previous: array[8,ShaWord],
    bytes: array[64,array[8,Linear]]): array[8,ShaWord] =
  var schedule: array[64,ShaWord]
  for i in 0..15:
    schedule[i] = c.word(shaWordBits([bytes[i*4],bytes[i*4+1],bytes[i*4+2],bytes[i*4+3]]))
  for i in 16..63:
    let low = schedule[i-15]
    let high = schedule[i-2]
    let s0 = c.xor3(low.rotate(7),low.rotate(18),low.shift(3))
    let s1 = c.xor3(high.rotate(17),high.rotate(19),high.shift(10))
    schedule[i] = c.add([schedule[i-16],s0,schedule[i-7],s1])
  var state = previous
  for i in 0..63:
    let s1 = c.xor3(state[4].rotate(6),state[4].rotate(11),state[4].rotate(25))
    let ch = c.choose(state[4],state[5],state[6])
    let t1 = c.add([state[7],s1,ch,literal(ShaRound[i]),schedule[i]])
    let s0 = c.xor3(state[0].rotate(2),state[0].rotate(13),state[0].rotate(22))
    let maj = c.majority(state[0],state[1],state[2])
    let t2 = c.add([s0,maj])
    let e = c.add([state[3],t1])
    let a = c.add([t1,t2])
    state = [a,state[0],state[1],state[2],e,state[4],state[5],state[6]]
  for i in 0..7: result[i] = c.add([previous[i],state[i]])

proc sha256BlockCapacity*(capacity: int): int =
  if capacity < 0 or uint64(capacity) > uint64(high(uint32)):
    raise newException(ValueError, "invalid SHA-256 capacity")
  result = capacity div 64+1+ord(capacity mod 64 >= 56)
  if result > high(int) div 64:
    raise newException(ValueError,"SHA-256 padded capacity exceeds machine index")

proc constrainSha256*(c: var Circuit, bytes: openArray[Linear], length: Linear,
    digest: ShaDigestWires) =
  let blocks = sha256BlockCapacity(bytes.len)
  let lengthBits = c.constrainUnsigned(length,32)
  when defined(zkbuildShaAudit):
    let hashFirstWire = c.values.len
    let hashFirstGate = c.constraints.len
    let lengthRange = c.auditRangeSource(length,32)
  discard c.constrainUnsigned(constant(bytes.len)-length,32)
  let extra = c.multiply(c.multiply(lengthBits[3],lengthBits[4]),lengthBits[5])
  let finalBlock = c.materialize(pack(lengthBits.toOpenArray(6,31))+extra)
  var state: array[8,ShaWord]
  for i in 0..7: state[i] = literal(ShaInitial[i])
  var selected: array[8,Linear]
  for i in 0..7: selected[i] = constant(0)
  var dataActive = constant(1)
  var ends = constant(0)
  for blockIndex in 0..<blocks:
    let last = c.zeroIndicator(finalBlock-constant(blockIndex))
    ends = ends+last
    var blockBytes: array[64,array[8,Linear]]
    for offset in 0..63:
      let position = blockIndex*64+offset
      let boundary = if position <= bytes.len: c.zeroIndicator(length-constant(position)) else: constant(0)
      dataActive = c.materialize(dataActive-boundary)
      let value = if position < bytes.len: bytes[position] else: constant(0)
      c.constrain(constant(1)-dataActive,value,constant(0))
      let lengthByte = shaLengthByte(lengthBits,offset)
      let padded = c.materialize(value+boundary.scale(scalar(128))+c.multiply(last,lengthByte))
      let bits = c.constrainUnsigned(padded,8)
      for bit in 0..7: blockBytes[offset][bit] = bits[bit]
    state = c.compress(state,blockBytes)
    for i in 0..7: selected[i].add c.multiply(last,state[i].value)
  c.assertEqual(dataActive,constant(0))
  c.assertEqual(ends,constant(1))
  for limb in 0..1:
    c.assertEqual(digest[limb],shaDigestLimb([selected[limb*4],selected[limb*4+1],selected[limb*4+2],selected[limb*4+3]]))
  when defined(zkbuildShaAudit):
    c.recordSha256(hashFirstWire,hashFirstGate,bytes,length,digest,lengthRange)
