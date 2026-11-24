## Host-side proving key format. Verification does not import this module.
import prover, wire, fft
export prover, wire

const MaxEntries = 1 shl 20

proc boundedCount(r: var Reader): int =
  result = r.getU32().int
  if result < 0 or result > MaxEntries:
    raise newException(ValueError, "oversized proving key")

proc putLinear(outp: var seq[byte], linear: Linear) =
  outp.putU32(linear.len.uint32)
  for term in linear:
    outp.putU32(term.wire.uint32)
    outp.add encodeScalar(term.coefficient)

proc getLinear(r: var Reader, wires: int): Linear =
  let n = r.boundedCount()
  if n > (r.data.len-r.position) div 36:
    raise newException(ValueError, "truncated linear combination")
  for _ in 0 ..< n:
    let index = r.getU32().int
    if index < 0 or index >= wires: raise newException(ValueError, "invalid wire")
    var encoded: array[32, byte]
    let bytes = r.take(32)
    for i in 0 ..< 32: encoded[i] = bytes[i]
    var coefficient: Scalar
    if not decodeScalar(encoded, coefficient): raise newException(ValueError, "invalid scalar")
    result.add Term(wire: index, coefficient: coefficient)

proc encodeProvingKey*(key: ProvingKey, mode: ProofMode): seq[byte] =
  let vk = encodeKey(key.verificationKey, mode)
  result = @[0x5a'u8, 0x4b, 0x50, 1]
  result.putU32(vk.len.uint32)
  result.add vk
  result.putU32(key.domainSize.uint32)
  result.putU32(key.shape.values.len.uint32)
  result.putU32(key.shape.constraints.len.uint32)
  for constraint in key.shape.constraints:
    result.putLinear constraint.a
    result.putLinear constraint.b
    result.putLinear constraint.c
  result.put key.beta1
  result.put key.delta1
  for p in key.a: result.put p
  for p in key.b1: result.put p
  for p in key.b2: result.put p
  for p in key.privateK: result.put p
  for p in key.h: result.put p

proc decodeProvingKey*(bytes: openArray[byte], mode: var ProofMode): ProvingKey =
  var r = Reader(data: @bytes)
  if r.take(4) != @[0x5a'u8, 0x4b, 0x50, 1]:
    raise newException(ValueError, "invalid proving-key magic")
  let vkLen = r.boundedCount()
  let vk = r.take(vkLen)
  if not decodeKey(vk, result.verificationKey, mode):
    raise newException(ValueError, "invalid verification key")
  let n = r.boundedCount()
  let wires = r.boundedCount()
  let constraints = r.boundedCount()
  if n == 0 or n != powerOfTwoCeil(constraints) or wires <= mode.inputCount:
    raise newException(ValueError, "invalid proving-key dimensions")
  result.domainSize = n
  result.shape.publicCount = mode.inputCount
  result.shape.values = newSeq[Scalar](wires)
  result.shape.values[0] = scalar(1)
  for _ in 0 ..< constraints:
    let a = r.getLinear(wires)
    let b = r.getLinear(wires)
    let c = r.getLinear(wires)
    result.shape.constraints.add R1Constraint(a: a, b: b, c: c)
  # Check all remaining point-array lengths before allocating them.
  let expected = 96 + wires*192 + (wires-mode.inputCount-1)*48 + (n-1)*48
  if r.data.len-r.position != expected:
    raise newException(ValueError, "invalid proving-key length")
  result.beta1 = r.point1(false)
  result.delta1 = r.point1(false)
  for _ in 0 ..< wires: result.a.add r.point1()
  for _ in 0 ..< wires: result.b1.add r.point1()
  for _ in 0 ..< wires: result.b2.add r.point2()
  for _ in 0 ..< wires-mode.inputCount-1: result.privateK.add r.point1()
  for _ in 0 ..< n-1: result.h.add r.point1()
