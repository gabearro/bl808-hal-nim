## Fixed BLS12-381/Groth16 vectors generated and checked independently with
## py_ecc 8.0.0. This regression test itself is entirely Nim.
import std/[os, json, strutils]
import cps/zk/[wire, blinding]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc unhex(value: string): seq[byte] =
  require(value.len mod 2 == 0, "odd fixture hex length")
  for i in countup(0, value.len-1, 2):
    result.add byte(parseHexInt(value[i..i+1]))

proc scalarFromHex(value: string): Scalar =
  let raw = unhex(value)
  require(raw.len == 32, "fixture scalar width")
  var encoded: array[32, byte]
  for i in 0..<32: encoded[i] = raw[i]
  require(decodeScalar(encoded, result), "noncanonical fixture scalar")

let path = if paramCount() == 1: paramStr(1) else: "tools/ref/zkbuild_crypto_vectors.json"
let fixtures = parseFile(path)
require(fixtures["format"].getStr() == "zkbuild-crypto-vectors-v1", "fixture format")
require(fixtures["reference"].getStr() == "py_ecc 8.0.0", "independent reference version")
var groupCount, proofCount, acceptedCount, exportCount: int
var infinityC = false
for vector in fixtures["groups"]:
  let scalar = scalarFromHex(vector["scalar"].getStr())
  var one: array[48, byte]
  var two: array[96, byte]
  let status1 = serialize_g1_compressed(one, generator1().multiply(scalar))
  let status2 = serialize_g2_compressed(two, generator2().multiply(scalar))
  require(status1 == cttCodecEcc_Success and status2 == cttCodecEcc_Success, "group serialization")
  require(@one == unhex(vector["g1"].getStr()), "independent G1 multiplication/encoding")
  require(@two == unhex(vector["g2"].getStr()), "independent G2 multiplication/encoding")
  inc groupCount
for vector in fixtures["proofs"]:
  let name = vector["name"].getStr()
  let keyBytes = unhex(vector["key"].getStr())
  let proofBytes = unhex(vector["proof"].getStr())
  var inputs: seq[Scalar]
  for value in vector["inputs"]: inputs.add scalarFromHex(value.getStr())
  var key: VerificationKey
  var mode: ProofMode
  require(decodeKey(keyBytes, key, mode), name & ": reference key decode")
  require(mode == pmValidateBytes, name & ": reference arity")
  require(encodeKey(key, mode) == keyBytes, name & ": canonical key roundtrip")
  let expected = vector["valid"].getBool()
  require(decodeAndVerify(key, proofBytes, inputs) == expected, name & ": independent pairing equation")
  var proof: Proof
  let decoded = decodeProof(proofBytes, proof)
  require(decoded == vector["decode"].getBool(), name & ": proof decode result")
  if decoded:
    let encoded = encodeProof(proof)
    require(@encoded == proofBytes, name & ": canonical proof roundtrip")
    require(verify(key, proof, inputs) == expected, name & ": typed verifier")
  if expected:
    inc acceptedCount
    infinityC = infinityC or bool(proof.c.isNeutral())
    for index in 0..<inputs.len:
      var changed = inputs
      changed[index] += scalar(1)
      require(not decodeAndVerify(key, proofBytes, changed), name & ": each public input is bound")
  inc proofCount
require(groupCount == 8 and proofCount == 11 and acceptedCount == 3 and infinityC,
  "complete independent fixture set")
var modes: set[ProofMode]
for vector in fixtures["nim_exports"]:
  let name = vector["name"].getStr()
  let keyBytes = unhex(vector["verification_key"].getStr())
  let wasm = unhex(vector["wasm"].getStr())
  let native = unhex(vector["native"].getStr())
  let proof = unhex(vector["proof"].getStr())
  var key: VerificationKey
  var mode: ProofMode
  require(decodeKey(keyBytes, key, mode), name & ": exported key")
  require(ord(mode) == vector["mode"].getInt(), name & ": exported claim")
  let derived = publicInputs(mode, wasm, native)
  require(derived.len == vector["public_inputs"].len, name & ": exported public arity")
  for i, value in derived:
    require(value.equals(scalarFromHex(vector["public_inputs"][i].getStr())),
      name & ": independent byte packing")
  require(verifyArtifacts(key, mode, wasm, native, proof), name & ": independently verified Nim proof")
  var changed = wasm
  changed[^1] = changed[^1] xor 1
  require(not verifyArtifacts(key, mode, changed, native, proof), name & ": changed artifact")
  modes.incl mode
  inc exportCount
require(exportCount == 7 and modes == {pmValidate, pmCompile, pmValidateBytes, pmCompileBytes}, "all exported claims")

# Force the rare cancellation branch rather than waiting for a random draw
# with probability about 1/r. Zero, cancellation, then a valid nonce.
var draws = 0
let blind1 = sampleBlinding(generator1().multiply(scalar(-1)), generator1(), proc(): Scalar =
  inc draws
  scalar(if draws == 1: 0 elif draws == 2: 1 else: 2))
require(draws == 3 and blind1.nonce.equals(scalar(2)) and
  bool(blind1.point == generator1()), "G1 blinding retries cancellation")
draws = 0
let blind2 = sampleBlinding(generator2().multiply(scalar(-1)), generator2(), proc(): Scalar =
  inc draws
  scalar(if draws == 1: 0 elif draws == 2: 1 else: 2))
require(draws == 3 and blind2.nonce.equals(scalar(2)) and
  bool(blind2.point == generator2()), "G2 blinding retries cancellation")
draws = 0
var exhausted = false
try:
  discard sampleBlinding(generator1(), generator1(), proc(): Scalar =
    inc draws
    scalar(0))
except ValueError: exhausted = true
require(exhausted and draws == 128, "broken blinding source fails with bounded retries")
echo "zkbuild independent crypto vectors: PASS (", groupCount, " group vectors, ", proofCount,
  " proof cases, ", exportCount, " independently checked Nim proofs; blinding retries)"
