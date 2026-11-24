import cps/zk/[field, fft, r1cs, qap]
import zkbuild_qap_reference

proc check(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc same(a, b: seq[Scalar]): bool =
  if a.len != b.len: return false
  for i in 0..<a.len:
    if not a[i].equals(b[i]): return false
  true

proc fixture(count: int): Circuit =
  result = initCircuit()
  for i in 0..<count:
    let a = result.allocate(scalar(i*17+5))
    let b = result.allocate(scalar(-i*31-9))
    discard result.multiply(a + constant(i), b - constant(i*3))

for power in 0..24:
  let n = 1 shl power
  let root = rootOfUnity(n)
  check(root.power(n.uint64).equals(scalar(1)), "FFT root has the required order")
  if n > 1:
    check(not root.power((n div 2).uint64).equals(scalar(1)), "FFT root is primitive")
  check(not (scalar(7).power(n.uint64) - scalar(1)).zero(), "QAP coset avoids the root domain")

for n in [1, 2, 4, 8, 32]:
  var coefficients: seq[Scalar]
  for i in 0..<n: coefficients.add scalar(i*i-17)
  let original = coefficients
  let shift = scalar(7)
  coefficients.cosetFft(shift)
  var point = shift
  let root = rootOfUnity(n)
  for i in 0..<n:
    var expected = scalar(0)
    for j in countdown(n-1, 0): expected = expected * point + original[j]
    check(coefficients[i].equals(expected), "coset FFT agrees with polynomial evaluation")
    point *= root
  coefficients.cosetFft(shift, invert = true)
  check(same(coefficients, original), "coset FFT inverse")
  # These are arbitrary evaluations, independent of the forward transform.
  var evaluations: seq[Scalar]
  for i in 0..<n: evaluations.add scalar(3*i*i-19*i+5)
  let inputValues = evaluations
  var legacy = evaluations
  legacy.referenceInverseFft()
  evaluations.fft(invert = true)
  check(same(evaluations, legacy), "inverse DIF agrees with inverse DIT")
  let invN = scalar(n).inverse()
  let invRoot = root.inverse()
  for k in 0..<n:
    var expected = scalar(0)
    for j in 0..<n: expected += inputValues[j] * invRoot.power(uint64(j*k))
    check(evaluations[k].equals(expected * invN), "inverse FFT agrees with direct inverse DFT")

for n in [1, 2, 4, 8, 16, 32, 64]:
  let root = rootOfUnity(n)
  let inverseRoot = root.inverse()
  let inverseN = scalar(n).inverse()
  for basisIndex in 0..<n:
    var forward = newSeq[Scalar](n)
    var backward = newSeq[Scalar](n)
    forward[basisIndex] = scalar(1)
    backward[basisIndex] = scalar(1)
    forward.fft()
    backward.fft(invert = true)
    for i in 0..<n:
      check(forward[i].equals(root.power(uint64(i*basisIndex))), "forward DFT basis vector")
      check(backward[i].equals(inverseRoot.power(uint64(i*basisIndex)) * inverseN), "inverse DFT basis vector")

for count in [1, 2, 3, 4, 7, 8, 15, 16, 31, 32, 33, 255, 256, 257,
    1023, 1024, 1025, 8191, 8192, 8193]:
  let circuit = fixture(count)
  let n = powerOfTwoCeil(count)
  let actual = qapQuotient(circuit, n)
  check(actual.len == n-1, "QAP degree")
  check(same(actual, referenceQuotient(circuit, n)), "coset/2n quotient coefficients")
  if n <= 32:
    check(same(actual, referenceQuotient(circuit, n, quadratic = true)), "quadratic quotient coefficients")

var zeroCircuit = initCircuit()
for _ in 0..<3: zeroCircuit.constrain(constant(0), constant(0), constant(0))
for value in qapQuotient(zeroCircuit, 4): check(value.zero(), "zero quotient")

template rejects(body: untyped) =
  block:
    var rejected = false
    try: body
    except ValueError: rejected = true
    check(rejected, "invalid QAP or FFT input rejected")

let valid = fixture(3)
rejects: discard qapQuotient(valid, 2)
rejects: discard qapQuotient(valid, 8)
rejects: discard qapQuotient(initCircuit(), 1)
var changed = valid
changed.values[0] = scalar(2)
rejects: discard qapQuotient(changed, 4)
changed = valid
changed.values[^1] += scalar(1)
rejects: discard qapQuotient(changed, 4)
changed = valid
changed.constraints[0].a[0].wire = changed.values.len
rejects: discard qapQuotient(changed, 4)
changed = valid
changed.constraints[0].a[0].wire = -1
rejects: discard qapQuotient(changed, 4)
var invalidFft = @[scalar(1), scalar(2), scalar(3)]
let before = invalidFft
rejects: invalidFft.cosetFft(scalar(7))
check(same(invalidFft, before), "invalid transform leaves coefficients unchanged")
invalidFft = @[scalar(1), scalar(2)]
rejects: invalidFft.cosetFft(scalar(0))
echo "zkbuild coset QAP: PASS (20 domain boundaries, direct evaluation, quadratic reference, invalid inputs)"
