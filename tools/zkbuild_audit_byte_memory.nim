## End-to-end source/hash/byte-query interface matrix exporter.
import std/[os,strutils]
import zkbuild_payload_fixture
import cps/zk/[r1cs,gadget_audit,binary_read_audit,sha256_circuit,
  wasm_binary_source,wasm_digest_claim,wasm_module_validation,wasm_module_prover]

proc fixture(): seq[byte] =
  @[0'u8,97,115,109,1,0,0,0,0,2,0,255,1,5,1,96,0,1,127,
    2,8,1,1,104,1,103,3,127,0,3,2,1,0,7,7,1,3,114,117,110,0,0,
    10,6,1,4,0,65,42,11]

proc initializerOnly(capacity,length: int): Circuit =
  result = initCircuit(reuseRangeWitnesses = true)
  var data = newSeq[byte](length)
  for i in 0..<length: data[i] = byte(i*17)
  let digest = wasmDigestInputs(data)
  let output = [result.publicInput(digest[0]),result.publicInput(digest[1])]
  let claim = result.allocateBinarySourceClaim(data,capacity,publicInputs = false)
  let source = result.constrainBinarySource(data,capacity,claim)
  var bytes: seq[Linear]
  for row in source.entries: bytes.add row.value
  result.constrainSha256(bytes,source.length,output)
  result.finishBinaryReads(source)

proc standalone(inactive = false, detached = false): Circuit =
  result = initCircuit(reuseRangeWitnesses = true)
  let cases = @[
    (brByte,@[255'u8]), (brU32,@[255'u8,255,255,255,15]),
    (brS32,@[128'u8,128,128,128,120]), (brS33,@[255'u8,255,255,255,15]),
    (brS64,@[128'u8,128,128,128,128,128,128,128,128,127]),
    (brLittle32,@[1'u8,35,69,103]), (brLittle64,@[255'u8,238,221,204,187,170,153,136]),
    (brU32,@[128'u8,0]), (brS32,@[255'u8,127]), (brS64,@[255'u8,127])]
  var data: seq[byte]
  var offsets: seq[uint32]
  for item in cases:
    offsets.add uint32(data.len)
    data.add item[1]
  if inactive: data.setLen(0)
  let digest = wasmDigestInputs(data)
  let output = [result.publicInput(digest[0]),result.publicInput(digest[1])]
  let claim = result.allocateBinarySourceClaim(data,128,publicInputs = false)
  var source = result.constrainBinarySource(data,128,claim)
  var bytes: seq[Linear]
  for row in source.entries: bytes.add row.value
  result.constrainSha256(bytes,source.length,output)
  if detached:
    var other = data
    other[0] = other[0] xor 1
    let otherClaim = result.allocateBinarySourceClaim(other,128,publicInputs = false)
    source = result.constrainBinarySource(other,128,otherClaim)
  for i,item in cases:
    let hint = if inactive: BinaryRead() else: source.readToken(offsets[i],item[0])
    let active = result.bit(not inactive)
    let position = result.allocate(scalar(if inactive: 0'u32 else: offsets[i]))
    let value = result.allocate(scalar(hint.value))
    discard result.constrainBinaryRead(source,item[0],active,position,value,hint)
  result.finishBinaryReads(source)
  when defined(zkbuildByteMemoryAudit):
    if detached: result.binaryReadMemoryRecords[0].sourceIndex = 0

proc main() =
  if paramCount() != 3: quit("usage: zkbuild_audit_byte_memory zero|empty-table|table|active|inactive|detached|module|full METADATA AUDIT_OR_DASH",1)
  let mode = paramStr(1)
  let circuit = if mode == "zero": initializerOnly(0,0)
    elif mode == "empty-table": initializerOnly(8,0)
    elif mode == "table": initializerOnly(8,8)
    elif mode == "active": standalone()
    elif mode == "inactive": standalone(inactive = true)
    elif mode == "detached": standalone(detached = true)
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
    else: raise newException(ValueError,"unknown byte memory mode")
  doAssert circuit.satisfied()
  let hashes = circuit.fingerprints()
  writeFile(paramStr(2),$circuit.values.len & " " & $circuit.publicCount & " " & $circuit.constraints.len &
    "\n" & hashes.matrix & "\n" & hashes.witness & "\n")
  if paramStr(3) != "-": writeBinaryReadAudit(paramStr(3),circuit)
  echo "byte memory audit ",mode," constraints=",circuit.constraints.len

main()
