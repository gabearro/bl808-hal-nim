## BLS12-381 groups. Variable-time MSM is for public verification inputs or
## the experimental prover; it is not a side-channel-hardened prover API.
import field
import constantine/named/zoo_generators
import constantine/math/[extension_fields, ec_shortweierstrass]
import constantine/math/elliptic/ec_scalar_mul_vartime
import constantine/math/pairings/pairings_generic
import constantine/serialization/codecs_bls12_381

export field, extension_fields, ec_shortweierstrass, codecs_bls12_381

type
  Point1* = EC_ShortW_Aff[Fp[BLS12_381], G1]
  Point2* = EC_ShortW_Aff[Fp2[BLS12_381], G2]
  Jac1 = EC_ShortW_Jac[Fp[BLS12_381], G1]
  Jac2 = EC_ShortW_Jac[Fp2[BLS12_381], G2]

func generator1*(): Point1 = BLS12_381.getGenerator("G1")
func generator2*(): Point2 = BLS12_381.getGenerator("G2")

proc multiply*(p: Point1, x: Scalar): Point1 =
  var j: Jac1
  j.fromAffine(p)
  j.scalarMul_vartime(x.toBig())
  result.affine(j)

proc multiply*(p: Point2, x: Scalar): Point2 =
  var j: Jac2
  j.fromAffine(p)
  j.scalarMul_vartime(x.toBig())
  result.affine(j)

proc add*(a, b: Point1): Point1 =
  var x, y: Jac1
  x.fromAffine(a)
  y.fromAffine(b)
  x += y
  result.affine(x)

proc add*(a, b: Point2): Point2 =
  var x, y: Jac2
  x.fromAffine(a)
  y.fromAffine(b)
  x += y
  result.affine(x)

func pairingProductIsOne*(a: array[4, Point1], b: array[4, Point2]): bool =
  var product: Fp12[BLS12_381]
  product.pairing(a, b)
  bool(product.isOne())
