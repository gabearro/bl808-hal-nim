## Complete source-table/SHA matrix export, independent of witness values.
import std/[os,strutils]
import zkbuild_payload_fixture
import cps/zk/[r1cs,gadget_audit,binary_source_audit,sha256_circuit,
  wasm_binary_source,wasm_digest_claim,wasm_module_validation,wasm_module_prover]

proc fixture(): seq[byte] =
  @[0'u8,97,115,109,1,0,0,0,0,2,0,255,1,5,1,96,0,1,127,
    2,8,1,1,104,1,103,3,127,0,3,2,1,0,7,7,1,3,114,117,110,0,0,
    10,6,1,4,0,65,42,11]

proc standalone(capacity, length: int, disconnected = false): Circuit =
  result = initCircuit(reuseRangeWitnesses = true)
  var bytes = newSeq[byte](length)
  for i in 0..<length: bytes[i] = byte((i*131+255) and 255)
  var hashedBytes = newSeq[byte](length)
  for i in 0..<length: hashedBytes[i] = bytes[i]
  if disconnected: hashedBytes[0] = hashedBytes[0] xor 1
  let digest = wasmDigestInputs(hashedBytes)
  let output = [result.publicInput(digest[0]),result.publicInput(digest[1])]
  let claim = result.allocateBinarySourceClaim(bytes,capacity,publicInputs = false)
  var source = result.constrainBinarySource(bytes,capacity,claim)
  if disconnected:
    let otherClaim = result.allocateBinarySourceClaim(hashedBytes,capacity,publicInputs = false)
    source = result.constrainBinarySource(hashedBytes,capacity,otherClaim)
    when defined(zkbuildSourceAudit): result.binarySourceRecords.setLen(1)
  var inputs: seq[Linear]
  for row in source.entries: inputs.add row.value
  result.constrainSha256(inputs,source.length,output)

proc main() =
  if paramCount() != 3: quit("usage: zkbuild_audit_source source-N|empty-N|full-N|module|full METADATA AUDIT_OR_DASH",1)
  let mode = paramStr(1)
  let circuit = if '-' in mode:
      block:
        let parts = mode.split('-')
        let capacity = parseInt(parts[1])
        let length = if parts[0] == "empty": 0 elif parts[0] == "full": capacity else: capacity div 2
        standalone(capacity,length)
    elif mode == "disconnected": standalone(32,16,true)
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
    else: raise newException(ValueError,"unknown source audit mode")
  doAssert circuit.satisfied()
  let hashes = circuit.fingerprints()
  writeFile(paramStr(2),$circuit.values.len & " " & $circuit.publicCount & " " & $circuit.constraints.len &
    "\n" & hashes.matrix & "\n" & hashes.witness & "\n")
  if paramStr(3) != "-": writeSourceHashAudit(paramStr(3),circuit)
  echo "source audit ",mode," constraints=",circuit.constraints.len

main()
