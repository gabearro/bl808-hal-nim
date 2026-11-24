## Allocation-free Groth16 equation schedule. Group operations are supplied
## statically by the concrete point types; no curve or OS dependency lives here.

proc accumulatePublic*[P, S](coefficients: openArray[P], inputs: openArray[S],
                             output: var P): bool {.inline.} =
  mixin add, multiply
  if coefficients.len == 0 or coefficients.len - 1 != inputs.len: return false
  var accumulation = coefficients[0]
  for i, input in inputs:
    accumulation = accumulation.add(coefficients[i+1].multiply(input))
  output = accumulation
  true

proc verifyEquationCore*[P, Q, S](alpha: P, beta, gamma, delta: Q,
    coefficients: openArray[P], proofA: P, proofB: Q, proofC: P,
    inputs: openArray[S]): bool {.inline.} =
  ## Equation only: the caller validates point encodings and subgroup membership.
  mixin neg, pairingProductIsOne
  var accumulation: P
  if not accumulatePublic(coefficients, inputs, accumulation): return false
  var negativeA = proofA
  negativeA.neg()
  pairingProductIsOne([negativeA, alpha, accumulation, proofC],
                      [proofB, beta, gamma, delta])
