## Complete immutable table evidence, including the production module tables.
import std/[os,strutils]
import zkbuild_payload_fixture
import cps/zk/[r1cs,range_check,gadget_audit,readonly_audit,read_only_memory,
  wasm_module_validation,wasm_module_prover]

when defined(zkbuildEnvelopeAudit):
  import cps/zk/module_tables_audit
when defined(zkbuildDeclarationAudit):
  import cps/zk/declaration_audit

proc table(style: string): Circuit =
  let width = if style.endsWith("64"): 64 elif style.endsWith("32"): 32 else: 8
  var entries = @[ReadOnlyEntry(active: true,address: 1,value: 11),
    ReadOnlyEntry(active: true,address: 3,value: 22),ReadOnlyEntry(active: true,address: 250,value: 33),ReadOnlyEntry()]
  if width == 64:
    for i in 0..2:
      entries[i].address = high(uint64)-uint64(10-i*5)
      entries[i].value = high(uint64)-uint64(i)
  elif width == 32:
    for i in 0..2:
      entries[i].address = uint64(high(uint32))-uint64(10-i*5)
      entries[i].value = uint64(high(uint32))-uint64(i)
  var queries = @[entries[2],entries[0],entries[2],ReadOnlyEntry()]
  if style == "empty": entries = @[]; queries = @[]
  if style == "inactive":
    entries = @[ReadOnlyEntry(),ReadOnlyEntry()]
    queries = @[ReadOnlyEntry(),ReadOnlyEntry()]
  if style == "no-queries": queries = @[]
  case style
  of "bad-value": queries[0].value = 99
  of "bad-missing": queries[0].address = 99
  of "bad-duplicate": entries[1].address = entries[0].address
  of "bad-order": swap(entries[0],entries[1])
  of "bad-gap": entries[1] = ReadOnlyEntry()
  else: discard
  result = initCircuit(reuseRangeWitnesses = true)
  proc allocate(raw: seq[ReadOnlyEntry]): seq[ReadOnlyWires] =
    for row in raw:
      if style.startsWith("literal"):
        result.add ReadOnlyWires(active: constant(ord(row.active)),address: constant(row.address),value: constant(row.value))
      else:
        result.add ReadOnlyWires(active: @[],address: @[],value: @[])
  # Keep circuit mutation outside the nested allocator (Nim aliasing rules).
  var source = allocate(entries)
  var reads = allocate(queries)
  if not style.startsWith("literal"):
    for i,row in entries:
      source[i] = ReadOnlyWires(active: result.publicInput(scalar(ord(row.active))),
        address: result.publicInput(scalar(row.address)),value: result.publicInput(scalar(row.value)))
    for i,row in queries:
      reads[i] = ReadOnlyWires(active: result.publicInput(scalar(ord(row.active))),
        address: result.publicInput(scalar(row.address)),value: result.publicInput(scalar(row.value)))
  if style.startsWith("cached"):
    for row in source & reads:
      discard result.constrainUnsigned(row.address,width)
      discard result.constrainUnsigned(row.value,width)
  result.constrainReadOnly(source,reads,buildReadOnlyWitness(entries,queries),width,width)

proc fixture(): seq[byte] =
  @[0'u8,97,115,109,1,0,0,0,0,2,0,255,1,5,1,96,0,1,127,
    2,8,1,1,104,1,103,3,127,0,3,2,1,0,7,7,1,3,114,117,110,0,0,
    10,6,1,4,0,65,42,11]

proc main() =
  if paramCount() != 3: quit("usage: zkbuild_audit_readonly STYLE|module|full META AUDIT_OR_DASH",1)
  let mode = paramStr(1)
  let circuit = if mode != "module" and mode != "full": table(mode)
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
  if mode.startsWith("bad-"):
    doAssert not circuit.satisfied(),"invalid immutable-table witness satisfied the circuit"
    echo "rejected invalid table witness ",mode
    return
  doAssert circuit.satisfied()
  let hashes = circuit.fingerprints()
  writeFile(paramStr(2),$circuit.values.len & " " & $circuit.publicCount & " " & $circuit.constraints.len &
    "\n" & hashes.matrix & "\n" & hashes.witness & "\n")
  if paramStr(3) != "-":
    when defined(zkbuildDeclarationAudit):
      writeDeclarationAudit(paramStr(3),circuit)
    elif defined(zkbuildEnvelopeAudit):
      if mode in ["module","full"]: writeModuleTablesAudit(paramStr(3),circuit)
      else: writeReadOnlyAudit(paramStr(3),circuit)
    else: writeReadOnlyAudit(paramStr(3),circuit)
  echo "immutable-table audit ",mode," constraints=",circuit.constraints.len

main()
