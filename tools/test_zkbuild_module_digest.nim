import std/[os,times]
import cps/zk/[wasm_module_prover,wasm_module_verifier,wasm_module_validation,wasm_digest_claim]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError,message)

proc fixture(value: byte): seq[byte] =
  @[0'u8,97,115,109,1,0,0,0,
    0,3,1,120,255, 1,4,1,96,0,0, 3,2,1,0,
    4,4,1,112,0,1, 5,3,1,0,1,
    6,6,1,127,0,65,value,11, 7,5,1,1,102,0,0,
    9,7,1,0,65,0,11,1,0, 10,4,1,2,0,11,
    11,8,1,0,65,0,11,2,0,255]

proc main() =
  let profile = ModuleValidationProfile(eventCapacity: 16,sourceCapacity: 128,
    sectionCapacity: 12,digestClaim: true)
  let first = fixture(42)
  let second = fixture(43)
  let a = buildModuleValidationCircuit(first,16,128,12,digestClaim = true)
  let b = buildModuleValidationCircuit(second,16,128,12,digestClaim = true)
  require(a.satisfied() and b.satisfied() and a.sameShape(b),"source+SHA+validation composition")
  require(a.publicCount == 2,"constant-size public digest")
  let claim = wasmDigestInputs(first)
  for i in 0..1: require(a.values[1+i].equals(claim[i]),"digest input order")
  if paramCount() == 1 and paramStr(1) == "--check-only":
    echo "zkbuild module digest comparison: PASS (",a.constraints.len," constraints; two public inputs)"
    return
  echo "module digest setup: ",a.constraints.len," constraints"
  stdout.flushFile()
  let before = cpuTime()
  let key = setup(a)
  echo "module digest setup_seconds=",cpuTime()-before
  stdout.flushFile()
  for source in [first,second]:
    let start = cpuTime()
    let proof = proveModuleValidation(key,source,profile)
    let proving = cpuTime()-start
    let verifyStart = cpuTime()
    require(verifyModuleDigest(key.verificationKey,source,proof),"digest proof")
    let verifying = cpuTime()-verifyStart
    let other = if source == first: second else: first
    require(not verifyModuleDigest(key.verificationKey,other,proof),"changed source digest")
    require(not verifyModuleDigest(key.verificationKey,source & @[0'u8],proof),"changed length")
    require(not verifyModuleDigest(key.verificationKey,source,proof & @[0'u8]),"trailing proof")
    require(not verifyModuleValidation(key.verificationKey,source,proof,128),"wrong public-input mode")
    echo "module digest proof_bytes=",proof.len," prove_seconds=",proving," verify_seconds=",verifying
    stdout.flushFile()
  var wrongProfile = profile
  wrongProfile.digestClaim = false
  var rejected = false
  try: discard proveModuleValidation(key,first,wrongProfile)
  except ValueError: rejected = true
  require(rejected,"prover refuses a different claim mode")
  echo "zkbuild module digest: PASS (two 192-byte proofs; two public inputs; source/length/proof/mode forgeries rejected)"

main()
