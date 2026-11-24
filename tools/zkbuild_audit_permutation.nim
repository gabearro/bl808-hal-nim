## Exact switch-network evidence in standalone, RAM, and complete WASM circuits.
import std/[os,strutils]
import zkbuild_payload_fixture
import cps/zk/[r1cs,gadget_audit,permutation_audit,permutation,memory_consistency,
  wasm_module_validation,wasm_module_prover]

proc network(n: int, target: seq[int]): Circuit =
  result = initCircuit(reuseRangeWitnesses = true)
  var inputs: seq[Linear]
  for i in 0..<n: inputs.add result.publicInput(scalar(i mod 7))
  let output = result.constrainPermutation(inputs,permutationRoute(target))
  doAssert result.satisfied()
  for i in 0..<n: doAssert output[i].evaluate(result.values).equals(scalar(target[i] mod 7))

proc standalone(depth: int): Circuit =
  let n = 1 shl depth
  var identity, reverse, rotate: seq[int]
  for i in 0..<n:
    identity.add i
    reverse.add n-i-1
    rotate.add (i+1) mod n
  result = network(n,reverse)
  doAssert result.sameShape(network(n,identity))
  doAssert result.sameShape(network(n,rotate))

proc memory(): Circuit =
  let accesses = @[
    MemoryAccess(active: true,write: true,address: 7,value: 42),
    MemoryAccess(active: true,write: true,address: 2,value: 13),
    MemoryAccess(active: true,address: 7,value: 42),
    MemoryAccess(active: true,write: true,address: 7,value: 9),
    MemoryAccess(active: true,address: 2,value: 13),
    MemoryAccess(active: true,address: 7,value: 9),MemoryAccess(),MemoryAccess()]
  result = initCircuit(reuseRangeWitnesses = true)
  var inputs: seq[MemoryAccessWires]
  for row in accesses:
    inputs.add MemoryAccessWires(active: result.publicInput(scalar(ord(row.active))),
      write: result.publicInput(scalar(ord(row.write))),address: result.publicInput(scalar(row.address)),
      value: result.publicInput(scalar(row.value)))
  discard result.constrainMemory(inputs,buildMemoryWitness(accesses),8,8)

proc fixture(): seq[byte] =
  @[0'u8,97,115,109,1,0,0,0,0,2,0,255,1,5,1,96,0,1,127,
    2,8,1,1,104,1,103,3,127,0,3,2,1,0,7,7,1,3,114,117,110,0,0,
    10,6,1,4,0,65,42,11]

proc main() =
  if paramCount() != 3: quit("usage: zkbuild_audit_permutation network-DEPTH|memory|module|full META AUDIT_OR_DASH",1)
  let mode = paramStr(1)
  let circuit = if mode.startsWith("network-"): standalone(parseInt(mode[8..^1]))
    elif mode == "memory": memory()
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
    else: raise newException(ValueError,"unknown permutation audit mode")
  doAssert circuit.satisfied()
  let hashes = circuit.fingerprints()
  writeFile(paramStr(2),$circuit.values.len & " " & $circuit.publicCount & " " & $circuit.constraints.len &
    "\n" & hashes.matrix & "\n" & hashes.witness & "\n")
  if paramStr(3) != "-": writePermutationAudit(paramStr(3),circuit)
  echo "permutation audit ",mode," constraints=",circuit.constraints.len

main()
