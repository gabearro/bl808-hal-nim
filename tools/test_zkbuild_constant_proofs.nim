## One full digest/profile key must prove scalar, SIMD and legacy initializers.
import std/times
import cps/zk/[wasm_module_prover,wasm_module_verifier]

proc fixture(mode: int): seq[byte] =
  result = @[0'u8,97,115,109,1,0,0,0]
  if mode == 2:
    result.add @[1'u8,4,1,96,0,0,2,7,1,1,104,1,102,0,0,9,5,1,1,0,1,0]
  elif mode == 0:
    result.add @[6'u8,10,1,127,0,65,255,255,255,255,127,11]
  else:
    result.add @[6'u8,23,1,123,0,253,140,0]
    for i in 0..15: result.add byte(i)
    result.add 11

proc main() =
  let profile = ModuleValidationProfile(eventCapacity: 8,sourceCapacity: 128,
    sectionCapacity: 5,digestClaim: true,instructionCapacity: 1,
    declarations: DeclarationProfile(enabled: true,types: 1),
    payloads: PayloadProfile(enabled: true,imports: 1,globals: 2,elements: 1,elementItems: 1,nameBytes: 4))
  let start = cpuTime()
  let key = setupModuleValidation(fixture(0),profile)
  echo "constant profile setup: constraints=",key.shape.constraints.len," seconds=",cpuTime()-start
  stdout.flushFile()
  for mode in 0..2:
    let source = fixture(mode)
    let started = cpuTime()
    let proof = proveModuleValidation(key,source,profile)
    let proving = cpuTime()-started
    doAssert proof.len == 192
    doAssert verifyModuleDigest(key.verificationKey,source,proof)
    doAssert not verifyModuleDigest(key.verificationKey,fixture((mode+1) mod 3),proof)
    doAssert not verifyModuleDigest(key.verificationKey,source & @[0'u8],proof)
    doAssert not verifyModuleDigest(key.verificationKey,source,proof & @[0'u8])
    echo "constant profile mode=",mode," proof_bytes=",proof.len," prove_seconds=",proving
    stdout.flushFile()
  echo "constant profile proofs PASS: one key; scalar, SIMD and legacy; three 192-byte proofs; source/length/encoding mutations rejected"

main()
