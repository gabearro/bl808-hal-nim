## Test/benchmark reference only. Keep this 2n convolution out of the prover.
import cps/zk/[r1cs, fft]

proc referenceInverseFft*(a: var seq[Scalar]) =
  ## Preserve the original inverse DIT implementation as an independent
  ## regression reference for the production inverse DIF implementation.
  let n = a.len
  if n == 0 or (n and (n-1)) != 0: raise newException(ValueError, "reference FFT size")
  var j = 0
  for i in 1..<n:
    var bit = n shr 1
    while (j and bit) != 0:
      j = j xor bit
      bit = bit shr 1
    j = j xor bit
    if i < j: swap(a[i], a[j])
  var width = 2
  while width <= n:
    let root = rootOfUnity(width).inverse()
    for start in countup(0, n-1, width):
      var weight = scalar(1)
      for offset in 0..<width div 2:
        let left = a[start+offset]
        let right = a[start+offset+width div 2] * weight
        a[start+offset] = left+right
        a[start+offset+width div 2] = left-right
        weight *= root
    if width == n: break
    width = width shl 1
  let invN = scalar(n).inverse()
  for value in a.mitems: value *= invN

proc referenceQuotient*(circuit: Circuit, n: int, quadratic = false): seq[Scalar] =
  if n <= 0 or n != powerOfTwoCeil(circuit.constraints.len) or not circuit.satisfied():
    raise newException(ValueError, "invalid reference QAP")
  var a = newSeq[Scalar](n)
  var b = newSeq[Scalar](n)
  var c = newSeq[Scalar](n)
  for i, gate in circuit.constraints:
    a[i] = gate.a.evaluate(circuit.values)
    b[i] = gate.b.evaluate(circuit.values)
    c[i] = gate.c.evaluate(circuit.values)
  a.referenceInverseFft()
  b.referenceInverseFft()
  c.referenceInverseFft()
  var numerator: seq[Scalar]
  if quadratic:
    numerator = newSeq[Scalar](2*n)
    for i in 0..<n:
      for j in 0..<n: numerator[i+j] += a[i] * b[j]
  else:
    a.setLen(2*n)
    b.setLen(2*n)
    a.fft()
    b.fft()
    for i in 0..<2*n: a[i] *= b[i]
    a.referenceInverseFft()
    numerator = move(a)
  for i in 0..<n: numerator[i] -= c[i]
  for i in 0..<n:
    if not (numerator[i] + numerator[n+i]).zero():
      raise newException(ValueError, "nonzero reference QAP remainder")
  result = numerator[n..<2*n-1]
