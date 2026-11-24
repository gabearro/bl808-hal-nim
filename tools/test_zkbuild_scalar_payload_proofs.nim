## One reusable key covers all four scalar section loops and U32 padding.
import std/times
import zkbuild_payload_fixture
import cps/zk/[wasm_module_prover,wasm_module_verifier]

proc main() =
  let profile = ModuleValidationProfile(eventCapacity: 8,sourceCapacity: 128,
    sectionCapacity: 6,digestClaim: true,instructionCapacity: 1,
    declarations: DeclarationProfile(enabled: true),
    payloads: PayloadProfile(enabled: true,tables: 3,memories: 2,globals: 3,exports: 5,nameBytes: 8))
  let start = cpuTime()
  let key = setupModuleValidation(scalarPayloadFixture(),profile)
  echo "scalar payload setup: constraints=",key.shape.constraints.len," seconds=",cpuTime()-start
  stdout.flushFile()
  for nonminimal in [false,true]:
    let source = scalarPayloadFixture(nonminimal)
    let started = cpuTime()
    let proof = proveModuleValidation(key,source,profile)
    let proving = cpuTime()-started
    doAssert proof.len == 192
    doAssert verifyModuleDigest(key.verificationKey,source,proof)
    doAssert not verifyModuleDigest(key.verificationKey,scalarPayloadFixture(not nonminimal),proof)
    doAssert not verifyModuleDigest(key.verificationKey,source & @[0'u8],proof)
    doAssert not verifyModuleDigest(key.verificationKey,source,proof & @[0'u8])
    echo "scalar payload nonminimal=",nonminimal," proof_bytes=",proof.len," prove_seconds=",proving
    stdout.flushFile()
  echo "scalar payload proofs PASS: one key; two 192-byte proofs; changed source/length/encoding rejected"
main()
