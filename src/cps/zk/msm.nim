## Host prover acceleration, separated from the embedded verifier.
import groups
import constantine/math/elliptic/ec_multi_scalar_mul

proc msm*(points: openArray[Point1], scalars: openArray[Scalar]): Point1 =
  if points.len != scalars.len: raise newException(ValueError, "MSM length mismatch")
  if points.len == 0:
    result.setNeutral()
    return
  var coefficients = newSeq[BigInt[255]](scalars.len)
  for i, s in scalars: coefficients[i] = s.toBig()
  var j: EC_ShortW_Jac[Fp[BLS12_381], G1]
  j.multiScalarMul_vartime(coefficients, points)
  result.affine(j)

proc msm*(points: openArray[Point2], scalars: openArray[Scalar]): Point2 =
  if points.len != scalars.len: raise newException(ValueError, "MSM length mismatch")
  if points.len == 0:
    result.setNeutral()
    return
  var coefficients = newSeq[BigInt[255]](scalars.len)
  for i, s in scalars: coefficients[i] = s.toBig()
  var j: EC_ShortW_Jac[Fp2[BLS12_381], G2]
  j.multiScalarMul_vartime(coefficients, points)
  result.affine(j)
