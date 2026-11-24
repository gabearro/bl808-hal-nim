## Concrete fixed-kind and dynamic token readers linked to source/hash/RAM.
import std/[os,strutils]
import zkbuild_payload_fixture
import cps/zk/[r1cs,gadget_audit,envelope_audit,sha256_circuit,
  wasm_binary_source,wasm_binary_envelope,wasm_digest_claim,wasm_module_validation,wasm_module_prover]

proc fixture(): seq[byte] =
  @[0'u8,97,115,109,1,0,0,0,0,2,0,255,1,5,1,96,0,1,127,
    2,8,1,1,104,1,103,3,127,0,3,2,1,0,7,7,1,3,114,117,110,0,0,
    10,6,1,4,0,65,42,11]

proc envelopeOnly(data: seq[byte], capacity, sectionCapacity: int): Circuit =
  result = initCircuit(reuseRangeWitnesses = true)
  let digest = wasmDigestInputs(data)
  let output = [result.publicInput(digest[0]),result.publicInput(digest[1])]
  let claim = result.allocateBinarySourceClaim(data,capacity,publicInputs = false)
  var source = result.constrainBinarySource(data,capacity,claim)
  var bytes: seq[Linear]
  for row in source.entries: bytes.add row.value
  result.constrainSha256(bytes,source.length,output)
  let hint = buildBinaryEnvelope(data,sectionCapacity)
  var envelope = result.allocateBinaryEnvelope(hint)
  result.constrainBinaryEnvelope(source,envelope,hint)
  result.finishBinaryReads(source)

proc envelopeFixture(mode: string): seq[byte] =
  result = @[0'u8,97,115,109,1,0,0,0]
  case mode
  of "header", "padded": discard
  of "custom": result.add @[0'u8,2,0,255,0,0,0,1,0]
  of "policy":
    # All recognized IDs, including tag/data-count ordering and custom repeats.
    for id in [1,2,3,4,5,13,6,7,8,9,12,10,11]:
      result.add @[byte(id),1,0,0,0]
  of "bad-header": result[0] = 1
  of "unknown": result.add @[14'u8,0]
  of "duplicate": result.add @[1'u8,1,0,1,1,0]
  of "reordered": result.add @[3'u8,1,0,1,1,0]
  of "truncated": result.add @[1'u8,128]
  of "overrun": result.add @[0'u8,127]
  else: raise newException(ValueError,"unknown envelope fixture")

proc main() =
  if paramCount() != 3: quit("usage: zkbuild_audit_envelope header|padded|custom|policy|module|full METADATA AUDIT_OR_DASH",1)
  let mode = paramStr(1)
  let circuit = if mode in ["header","padded","custom","policy","bad-header","unknown","duplicate","reordered","truncated","overrun"]:
      block:
        let data = envelopeFixture(mode)
        envelopeOnly(data,if mode == "padded": 32 else: data.len,
          if mode == "padded": 3 elif mode == "custom": 5 else: 0)
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
    else: raise newException(ValueError,"unknown envelope mode")
  doAssert circuit.satisfied()
  let hashes = circuit.fingerprints()
  writeFile(paramStr(2),$circuit.values.len & " " & $circuit.publicCount & " " & $circuit.constraints.len &
    "\n" & hashes.matrix & "\n" & hashes.witness & "\n")
  if paramStr(3) != "-": writeEnvelopeAudit(paramStr(3),circuit)
  echo "envelope audit ",mode," constraints=",circuit.constraints.len

main()
