## Host-only Groth16 QAP quotient construction. The verifier does not import it.
import r1cs, fft

proc checkedValue(expression: Linear, values: openArray[Scalar]): Scalar =
  for term in expression:
    if term.wire < 0 or term.wire >= values.len:
      raise newException(ValueError, "QAP references nonexistent wire")
    result += term.coefficient * values[term.wire]

proc qapQuotient*(circuit: Circuit, n: int): seq[Scalar] =
  ## For a satisfied R1CS, recover H = (A*B-C)/(X^n-1) using one n-point
  ## multiplicative coset. Checking the original evaluations is essential:
  ## coset interpolation alone cannot establish divisibility by X^n-1.
  if circuit.constraints.len == 0 or n <= 0 or n > (1 shl 24) or
      n != powerOfTwoCeil(circuit.constraints.len):
    raise newException(ValueError, "invalid QAP domain")
  if circuit.values.len == 0 or not circuit.values[0].equals(scalar(1)):
    raise newException(ValueError, "invalid QAP constant wire")
  var a = newSeq[Scalar](n)
  var b = newSeq[Scalar](n)
  var c = newSeq[Scalar](n)
  for i, gate in circuit.constraints:
    a[i] = checkedValue(gate.a, circuit.values)
    b[i] = checkedValue(gate.b, circuit.values)
    c[i] = checkedValue(gate.c, circuit.values)
    if not (a[i] * b[i]).equals(c[i]):
      raise newException(ValueError, "unsatisfied compilation circuit")
  let shift = scalar(7)
  let vanishing = shift.power(n.uint64) - scalar(1)
  if vanishing.zero(): raise newException(ValueError, "QAP coset intersects its root domain")
  let invVanishing = vanishing.inverse()
  a.fft(invert = true)
  b.fft(invert = true)
  c.fft(invert = true)
  a.cosetFft(shift)
  b.cosetFft(shift)
  c.cosetFft(shift)
  for i in 0..<n: a[i] = (a[i] * b[i] - c[i]) * invVanishing
  a.cosetFft(shift, invert = true)
  # deg(A*B-C) <= 2n-2, hence a valid quotient has degree <= n-2.
  if not a[n-1].zero(): raise newException(ValueError, "invalid QAP quotient degree")
  a.setLen(n-1)
  result = move(a)
