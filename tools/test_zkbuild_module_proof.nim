## Real Groth16 proof of a module containing code and non-code payloads. The
## verifier imports only the curve verifier and packed byte-claim encoder.
import cps/zk/[wasm_module_prover, wasm_module_verifier, wasm_binary_claim]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc fixture(value: byte): seq[byte] =
  @[0'u8,97,115,109,1,0,0,0,
    0,3,1,120,255,                 # custom "x", opaque byte
    1,4,1,96,0,0,                 # () -> ()
    3,2,1,0,                      # function type 0
    4,4,1,112,0,1,                # one funcref table
    5,3,1,0,1,                    # one memory
    6,6,1,127,0,65,value,11,       # immutable i32 global
    7,5,1,1,102,0,0,              # export f
    9,7,1,0,65,0,11,1,0,         # active legacy element
    10,4,1,2,0,11,                # empty function body
    11,8,1,0,65,0,11,2,0,255]    # active data

proc main() =
  let profile = ModuleValidationProfile(eventCapacity: 16, sourceCapacity: 128, sectionCapacity: 12)
  let first = fixture(42)
  let second = fixture(43)
  let key = setupModuleValidation(first, profile)
  require(key.verificationKey.inputs.len == binarySourceInputs(first, profile.sourceCapacity).len+1,
    "key includes only source bytes and length")
  for source in [first, second]:
    let proof = proveModuleValidation(key, source, profile)
    require(proof.len == 192, "compressed proof size")
    require(verifyModuleValidation(key.verificationKey, source, proof, profile.sourceCapacity), "valid module proof")
    let other = if source == first: second else: first
    require(not verifyModuleValidation(key.verificationKey, other, proof, profile.sourceCapacity), "changed global bytes")
    require(not verifyModuleValidation(key.verificationKey, source, proof & @[0'u8], profile.sourceCapacity), "trailing proof byte")
    require(not verifyModuleValidation(key.verificationKey, source, proof[0..190], profile.sourceCapacity), "truncated proof")
    require(not verifyModuleValidation(key.verificationKey, source, proof, 124), "wrong public-input dimensions")
  var wrongProfile = profile
  wrongProfile.sectionCapacity = 13
  var rejected = false
  try: discard proveModuleValidation(key, first, wrongProfile)
  except ValueError: rejected = true
  require(rejected, "prover rejects a different circuit profile")
  echo "zkbuild module proof: PASS (private metadata; 6 public inputs; two 192-byte proofs; source/proof/profile mutations rejected; ",
    key.shape.constraints.len, " constraints)"

main()
