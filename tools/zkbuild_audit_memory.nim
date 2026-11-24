## Complete RAM evidence: access bounds, packing, permutation, and sorted reads.
import std/[os,strutils,tables]
import zkbuild_payload_fixture
import cps/zk/[r1cs,range_check,gadget_audit,memory_audit,memory_consistency,
  wasm_module_validation,wasm_module_prover]

proc mask(width: int): uint64 =
  if width == 64: high(uint64) else: (1'u64 shl width)-1

proc memory(depth: int, style: string): Circuit =
  let n = 1 shl depth
  let width = if style == "wide": 64 elif style == "word": 32 else: 8
  var rows: seq[MemoryAccess]
  var state = initTable[uint64,uint64]()
  let writes = max(1,n div 2)
  for i in 0..<n:
    let address = (high(uint64)-uint64((i mod writes) mod 4)) and mask(width)
    if i < writes:
      let value = (high(uint64)-uint64(i*13)) and mask(width)
      state[address] = value
      rows.add MemoryAccess(active: true,write: true,address: address,value: value)
    elif i+1 == n and n > 2: rows.add MemoryAccess()
    else: rows.add MemoryAccess(active: true,address: address,value: state[address])
  result = initCircuit(reuseRangeWitnesses = true)
  var inputs: seq[MemoryAccessWires]
  for row in rows:
    if style == "literal":
      inputs.add MemoryAccessWires(active: constant(ord(row.active)),write: constant(ord(row.write)),
        address: constant(row.address),value: constant(row.value))
    else:
      let active = result.publicInput(scalar(ord(row.active)))
      let write = result.publicInput(scalar(ord(row.write)))
      let address = result.publicInput(scalar(row.address))
      let value = result.publicInput(scalar(row.value))
      inputs.add MemoryAccessWires(active: active,write: write,address: address,value: value)
      if style == "mixed":
        inputs[^1].write = if row.write: active else: constant(0)
        inputs[^1].address = active.scale(scalar(row.address))
        inputs[^1].value = if row.active: value else: constant(0)
  if style == "cached":
    for input in inputs:
      discard result.constrainUnsigned(input.address,width)
      discard result.constrainUnsigned(input.value,width)
  let witness = buildMemoryWitness(rows)
  discard result.constrainMemory(inputs,witness,width,width)
  if style == "detached":
    discard result.constrainMemory(inputs,witness,width,width)
    when defined(zkbuildMemoryAudit):
      result.memoryRecords[0].network = result.memoryRecords[1].network
      result.memoryRecords.setLen(1)

proc fixture(): seq[byte] =
  @[0'u8,97,115,109,1,0,0,0,0,2,0,255,1,5,1,96,0,1,127,
    2,8,1,1,104,1,103,3,127,0,3,2,1,0,7,7,1,3,114,117,110,0,0,
    10,6,1,4,0,65,42,11]

proc main() =
  if paramCount() != 3: quit("usage: zkbuild_audit_memory STYLE-DEPTH|module|full META AUDIT_OR_DASH",1)
  let mode = paramStr(1)
  let circuit = if '-' in mode:
      block:
        let parts = mode.split('-')
        memory(parseInt(parts[1]),parts[0])
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
    else: raise newException(ValueError,"unknown memory audit mode")
  doAssert circuit.satisfied()
  let hashes = circuit.fingerprints()
  writeFile(paramStr(2),$circuit.values.len & " " & $circuit.publicCount & " " & $circuit.constraints.len &
    "\n" & hashes.matrix & "\n" & hashes.witness & "\n")
  if paramStr(3) != "-": writeMemoryAudit(paramStr(3),circuit)
  echo "RAM audit ",mode," constraints=",circuit.constraints.len

main()
