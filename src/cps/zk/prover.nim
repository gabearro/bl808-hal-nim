## Experimental single-party Groth16 setup and prover, entirely in Nim.
## This is not a multiparty setup ceremony. Setup randomness must remain secret.
import std/sysrand
import groth16, r1cs, fft, msm, qap, blinding
export groth16, r1cs

type ProvingKey* = object
  verificationKey*: VerificationKey
  shape*: Circuit
  beta1*, delta1*: Point1
  a*, b1*, privateK*, h*: seq[Point1]
  b2*: seq[Point2]
  domainSize*: int

proc randomScalar(): Scalar =
  var bytes: array[32, byte]
  while true:
    if not urandom(bytes): raise newException(IOError, "OS randomness unavailable")
    if decodeScalar(bytes, result) and not result.zero(): return

proc setup*(shape: Circuit): ProvingKey =
  if shape.publicCount < 0 or shape.values.len < shape.publicCount + 1 or shape.constraints.len == 0:
    raise newException(ValueError, "invalid circuit shape")
  for gate in shape.constraints:
    for side in [gate.a, gate.b, gate.c]:
      for term in side:
        if term.wire < 0 or term.wire >= shape.values.len:
          raise newException(ValueError, "circuit references nonexistent wire")
  let n = powerOfTwoCeil(shape.constraints.len)
  if n <= 0 or n > (1 shl 24):
    raise newException(ValueError, "unsupported circuit size")
  var tau = randomScalar()
  while (tau.power(n.uint64) - scalar(1)).zero(): tau = randomScalar()
  let alpha = randomScalar()
  let beta = randomScalar()
  let gamma = randomScalar()
  let delta = randomScalar()
  let invGamma = gamma.inverse()
  let invDelta = delta.inverse()
  let z = tau.power(n.uint64) - scalar(1)
  let zOverN = z * scalar(n).inverse()
  let root = rootOfUnity(n)
  var point = scalar(1)
  var aa, bb, cc: seq[Scalar]
  aa.setLen(shape.values.len)
  bb.setLen(shape.values.len)
  cc.setLen(shape.values.len)
  for gate in shape.constraints:
    let lagrange = zOverN * point * (tau - point).inverse()
    for t in gate.a: aa[t.wire] += t.coefficient * lagrange
    for t in gate.b: bb[t.wire] += t.coefficient * lagrange
    for t in gate.c: cc[t.wire] += t.coefficient * lagrange
    point *= root
  result.domainSize = n
  result.shape = shape
  # A proving key needs the matrix shape, never the setup invocation's witness.
  for value in result.shape.values.mitems: value.setZero()
  result.shape.values[0] = scalar(1)
  result.verificationKey.alpha = generator1().multiply(alpha)
  result.verificationKey.beta = generator2().multiply(beta)
  result.verificationKey.gamma = generator2().multiply(gamma)
  result.verificationKey.delta = generator2().multiply(delta)
  result.beta1 = generator1().multiply(beta)
  result.delta1 = generator1().multiply(delta)
  for i in 0 ..< aa.len:
    result.a.add generator1().multiply(aa[i])
    result.b1.add generator1().multiply(bb[i])
    result.b2.add generator2().multiply(bb[i])
    let combined = beta * aa[i] + alpha * bb[i] + cc[i]
    if i <= shape.publicCount:
      result.verificationKey.inputs.add generator1().multiply(combined * invGamma)
    else:
      result.privateK.add generator1().multiply(combined * invDelta)
  var t = z * invDelta
  for _ in 0 ..< n - 1:
    result.h.add generator1().multiply(t)
    t *= tau

proc prove*(key: ProvingKey, witness: Circuit): Proof =
  if not sameShape(key.shape, witness):
    raise newException(ValueError, "witness circuit differs from setup")
  # qapQuotient checks the constant wire, all referenced wire bounds and every
  # R1CS equality while evaluating the domain; avoid evaluating them twice.
  let h = qapQuotient(witness, key.domainSize)
  let aBase = key.verificationKey.alpha.add(msm(key.a, witness.values))
  let bBase = key.verificationKey.beta.add(msm(key.b2, witness.values))
  let blindA = sampleBlinding(aBase, key.delta1, randomScalar)
  let blindB = sampleBlinding(bBase, key.verificationKey.delta, randomScalar)
  let r = blindA.nonce
  let s = blindB.nonce
  result.a = blindA.point
  result.b = blindB.point
  let b1 = key.beta1.add(msm(key.b1, witness.values)).add(key.delta1.multiply(s))
  let start = witness.publicCount + 1
  let privateValues = witness.values[start ..< witness.values.len]
  result.c = msm(key.privateK, privateValues).add(msm(key.h, h))
  result.c = result.c.add(result.a.multiply(s)).add(b1.multiply(r)).add(key.delta1.multiply(-(r*s)))
