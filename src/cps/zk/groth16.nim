## Groth16 verification over BLS12-381. No prover or OS imports.
import groups, verifier_core
export groups

type
  VerificationKey* = object
    alpha*: Point1
    beta*, gamma*, delta*: Point2
    inputs*: seq[Point1] # constant term, followed by public input coefficients
  Proof* = object
    a*: Point1
    b*: Point2
    c*: Point1

proc verifyEquation(key: VerificationKey, proof: Proof,
                    publicInputs: openArray[Scalar]): bool =
  verifyEquationCore(key.alpha, key.beta, key.gamma, key.delta, key.inputs,
                     proof.a, proof.b, proof.c, publicInputs)

proc verify*(key: VerificationKey, proof: Proof,
             publicInputs: openArray[Scalar]): bool =
  ## `key` must be pinned by the caller. Typed proofs may contain unchecked
  ## points, so this entry point validates them before the pairing equation.
  if validate_g1(proof.a) != cttCodecEcc_Success or
      validate_g2(proof.b) != cttCodecEcc_Success: return false
  if not bool(proof.c.isNeutral()) and validate_g1(proof.c) != cttCodecEcc_Success:
    return false
  verifyEquation(key, proof, publicInputs)

proc encodeProof*(proof: Proof): array[192, byte] =
  var a, c: array[48, byte]
  var b: array[96, byte]
  discard serialize_g1_compressed(a, proof.a)
  discard serialize_g2_compressed(b, proof.b)
  discard serialize_g1_compressed(c, proof.c)
  for i in 0 ..< 48:
    result[i] = a[i]
    result[144 + i] = c[i]
  for i in 0 ..< 96: result[48 + i] = b[i]

proc decodeProof*(bytes: openArray[byte], proof: var Proof): bool =
  if bytes.len != 192: return false
  var candidate: Proof
  var a, c: array[48, byte]
  var b: array[96, byte]
  for i in 0 ..< 48:
    a[i] = bytes[i]
    c[i] = bytes[144 + i]
  for i in 0 ..< 96: b[i] = bytes[48 + i]
  if deserialize_g1_compressed(candidate.a, a) != cttCodecEcc_Success: return false
  if deserialize_g2_compressed(candidate.b, b) != cttCodecEcc_Success: return false
  let cStatus = deserialize_g1_compressed(candidate.c, c)
  if cStatus notin {cttCodecEcc_Success, cttCodecEcc_PointAtInfinity}: return false
  proof = candidate
  true

proc decodeAndVerify*(key: VerificationKey, bytes: openArray[byte],
                      publicInputs: openArray[Scalar]): bool =
  ## Checked decoding already enforces subgroup membership. Keep the unchecked
  ## equation private and avoid performing those checks a second time.
  var proof: Proof
  decodeProof(bytes, proof) and verifyEquation(key, proof, publicInputs)
