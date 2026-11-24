## Compare ordinary and instrumented matrices, including real WASM profiles.
import std/os
import zkbuild_payload_fixture
import cps/zk/[r1cs,range_check,gadget_audit,sha256_audit,sha256_circuit,
  wasm_digest_claim,wasm_module_validation,wasm_module_prover]

proc fixture(): seq[byte] =
  @[0'u8,97,115,109,1,0,0,0,0,2,0,255,1,5,1,96,0,1,127,
    2,8,1,1,104,1,103,3,127,0,3,2,1,0,7,7,1,3,114,117,110,0,0,
    10,6,1,4,0,65,42,11]

proc standalone(cached, gap: bool): Circuit =
  result = initCircuit(reuseRangeWitnesses = true)
  let bytes = @[97'u8,98,99]
  let digests = wasmDigestInputs(bytes)
  let output = [result.publicInput(digests[0]),result.publicInput(digests[1])]
  let length = result.allocate(scalar(bytes.len))
  var input: seq[Linear]
  for i in 0..<8: input.add result.allocate(scalar(if i < bytes.len: bytes[i] else: 0'u8))
  if cached: discard result.constrainUnsigned(length,32)
  if gap:
    for i in 0..<7: discard result.materialize(result.bit((i mod 2) == 0)+constant(i))
  result.constrainSha256(input,length,output)

proc main() =
  if paramCount() != 3: quit("usage: zkbuild_audit_sha fresh|cached|gap|module|full METADATA AUDIT_OR_DASH",1)
  let mode = paramStr(1)
  let circuit = if mode in ["fresh","cached","gap"]: standalone(mode != "fresh",mode == "gap")
    elif mode == "module": buildModuleValidationCircuit(fixture(),eventCapacity = 16,sourceCapacity = 64,
      sectionCapacity = 6,digestClaim = true,instructionCapacity = 3,
      declarationProfile = DeclarationProfile(enabled: true,types: 1,functions: 1,results: 1),
      payloadProfile = PayloadProfile(enabled: true,imports: 1,globals: 1,exports: 1,
        customSections: 1,nameBytes: 8))
    elif mode == "full": buildModuleValidationCircuit(fullPayloadFixture(),eventCapacity = 16,
      sourceCapacity = 1024,sectionCapacity = 20,digestClaim = true,instructionCapacity = 8,
      branchCapacity = 2,catchCapacity = 2,
      declarationProfile = DeclarationProfile(enabled: true,types: 2,functions: 2,
        parameters: 2,results: 2,tags: 1,localGroups: 2,localRanges: 4),
      payloadProfile = PayloadProfile(enabled: true,imports: 6,globals: 13,tables: 3,
        memories: 1,exports: 6,elements: 8,elementItems: 16,datas: 3,
        customSections: 3,nameBytes: 80))
    else: raise newException(ValueError,"unknown SHA audit mode")
  doAssert circuit.satisfied()
  let hashes = circuit.fingerprints()
  writeFile(paramStr(2),$circuit.values.len & " " & $circuit.publicCount & " " & $circuit.constraints.len &
    "\n" & hashes.matrix & "\n" & hashes.witness & "\n")
  if paramStr(3) != "-": writeSha256Audit(paramStr(3),circuit)
  echo "SHA audit ",mode," constraints=",circuit.constraints.len

main()
