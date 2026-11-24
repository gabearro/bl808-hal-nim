## Bind compressed locals to the function's parameter signature. Complete
## per-body totals authenticate the final declaration even for unused locals.
import std/tables
import ../wasm/types
import r1cs, range_check, read_only_memory, memory_consistency
import wasm_type_environment, wasm_signature_environment, wasm_indexed_signatures

type
  LocalDeclarationEnvironment* = object
    totals*: seq[ReadOnlyEntry] # function -> local count32 | declaration count32
  LocalDeclarationWires* = object
    totals*: seq[ReadOnlyWires]
  LocalDeclarationWitness* = object
    metadata*, lengths*, members*, totals*, last*: seq[ReadOnlyEntry]
    signatureMemory*, lengthMemory*, memberMemory*, totalMemory*, rangeMemory*: MemoryWitness

proc buildLocalDeclarationEnvironment*(module: WasmModule,
    environment: TypeEnvironment, capacity = 0): LocalDeclarationEnvironment =
  var first = 0'u64
  for item in module.imports:
    if item.kind == ikFunc: inc first
  var totals: Table[uint64, uint64]
  for entry in environment.localRanges:
    if entry.active:
      let count = (entry.value and 0xffffffff'u64)+(entry.value shr 32)
      let declarations = (entry.address and 0xffffffff'u64)+1
      if count > uint64(high(uint32)) or declarations > uint64(high(uint32)):
        raise newException(ValueError, "local declaration total overflow")
      totals[entry.address shr 32] = count+(declarations shl 32)
  for i in 0..<module.codes.len:
    let index = first+uint64(i)
    result.totals.add ReadOnlyEntry(active: true, address: index, value: totals.getOrDefault(index))
  if capacity != 0:
    if capacity < result.totals.len: raise newException(ValueError, "local totals profile overflow")
    result.totals.setLen(capacity)

proc contents(entries: openArray[ReadOnlyEntry]): Table[uint64, uint64] =
  for entry in entries:
    if entry.active: result[entry.address] = entry.value

proc buildLocalDeclarationWitness*(declarations: LocalDeclarationEnvironment,
    environment: TypeEnvironment, signatures: SignatureEnvironment,
    indexed: IndexedSignatureEnvironment): LocalDeclarationWitness =
  let signatureMap = contents(signatures.signatures)
  let lengths = contents(indexed.lengths)
  let members = contents(indexed.members)
  let ranges = contents(environment.localRanges)
  let totals = contents(declarations.totals)
  template signature(activeFlag: bool, functionIndex: uint64) =
    block:
      let address = 2*functionIndex
      let metadata = signatureMap.getOrDefault(address)
      let head = metadata and 0xffffffff'u64
      result.metadata.add(if activeFlag: ReadOnlyEntry(active: true, address: address, value: metadata) else: ReadOnlyEntry())
      result.lengths.add(if activeFlag: ReadOnlyEntry(active: true, address: head, value: lengths.getOrDefault(head)) else: ReadOnlyEntry())
  for row in environment.localRanges:
    let function = row.address shr 32
    let ordinal = row.address and 0xffffffff'u64
    signature(row.active, function)
    let head = result.metadata[^1].value and 0xffffffff'u64
    let length = result.lengths[^1].value
    let parameter = row.active and ordinal < length
    let member = if parameter: signatureMemberAddress(uint32(head), uint32(length-1-ordinal)) else: 0'u64
    result.members.add(if parameter: ReadOnlyEntry(active: true, address: member, value: members.getOrDefault(member)) else: ReadOnlyEntry())
    result.totals.add(if row.active: ReadOnlyEntry(active: true, address: function, value: totals.getOrDefault(function)) else: ReadOnlyEntry())
  for row in declarations.totals:
    signature(row.active, row.address)
    let count = row.value shr 32
    let address = if count != 0: (row.address shl 32)+count-1 else: 0'u64
    result.last.add(if row.active and count != 0: ReadOnlyEntry(active: true, address: address,
      value: ranges.getOrDefault(address)) else: ReadOnlyEntry())
  result.signatureMemory = buildReadOnlyWitness(signatures.signatures, result.metadata)
  result.lengthMemory = buildReadOnlyWitness(indexed.lengths, result.lengths)
  result.memberMemory = buildReadOnlyWitness(indexed.members, result.members)
  result.totalMemory = buildReadOnlyWitness(declarations.totals, result.totals)
  result.rangeMemory = buildReadOnlyWitness(environment.localRanges, result.last)

proc read(c: var Circuit, enabled, key: Linear, value: uint64): ReadOnlyWires =
  ReadOnlyWires(active: enabled, address: c.multiply(enabled, key), value: c.allocate(scalar(value)))

proc constrainLocalDeclarations*(c: var Circuit, declarations: LocalDeclarationWires,
    environment: TypeEnvironmentWires, signatures: SignatureEnvironmentWires,
    indexed: IndexedSignatureWires, firstFunction, functionCount: Linear,
    witness: LocalDeclarationWitness) =
  when defined(zkbuildBodySourceAudit):
    let programMarker = c.beginSourceProgram()
    var localAudit = LocalDeclarationAudit(firstFunction: copyAuditExpressions([firstFunction])[0],
      functionCount: copyAuditExpressions([functionCount])[0])
    for row in environment.localRanges: localAudit.ranges.add copyAuditExpressions([row.active,row.address,row.value])
    for row in environment.rangeTypes: localAudit.tags.add copyAuditExpressions([row.active,row.address,row.value])
    for row in declarations.totals: localAudit.totals.add copyAuditExpressions([row.active,row.address,row.value])
  let ranges = environment.localRanges.len
  if environment.rangeTypes.len != ranges or witness.metadata.len != ranges+declarations.totals.len or
      witness.lengths.len != witness.metadata.len or witness.members.len != ranges or
      witness.totals.len != ranges or witness.last.len != declarations.totals.len:
    raise newException(ValueError, "local declaration dimensions differ")
  var metadataQueries, lengthQueries, memberQueries, totalQueries, lastQueries: seq[ReadOnlyWires]
  template parameterLength(enabled, function: Linear, position: int): tuple[head, length: Linear] =
    block:
      let metadata = c.read(enabled, function.scale(scalar(2)), witness.metadata[position].value)
      metadataQueries.add metadata
      let head = c.splitSignatureHeads(metadata.value).params
      let length = c.read(enabled, head, witness.lengths[position].value)
      lengthQueries.add length
      (head, length.value)
  for i, row in environment.localRanges:
    let key = c.splitSignatureHeads(row.address)
    let span = c.splitSignatureHeads(row.value)
    discard c.constrainUnsigned(c.multiply(row.active, key.results-firstFunction), 32)
    discard c.constrainUnsigned(c.multiply(row.active, functionCount-key.results-constant(1)), 32)
    let parameter = parameterLength(row.active, key.results, i)
    let difference = c.constrainUnsigned(key.params+constant(1'u64 shl 32)-parameter.length, 33)
    let isParameter = c.multiply(row.active, constant(1)-difference[32])
    c.constrain(isParameter, span.results-constant(1), constant(0))
    let member = c.constrainSignatureMemberQuery(isParameter, parameter.head,
      parameter.length-key.params-constant(1), witness.members[i].value)
    memberQueries.add member
    let tag = c.splitSignatureNode(member.value).tag
    c.constrain(isParameter, environment.rangeTypes[i].value-tag, constant(0))
    let total = c.read(row.active, key.results, witness.totals[i].value)
    totalQueries.add total
    let declared = c.splitSignatureHeads(total.value)
    discard c.constrainUnsigned(c.multiply(row.active, declared.results-key.params-constant(1)), 32)
  var count = constant(0)
  var previous = constant(1)
  for i, row in declarations.totals:
    c.constrainBoolean(row.active)
    c.constrain(row.active, constant(1)-previous, constant(0))
    c.constrain(row.active, row.address-firstFunction-constant(i), constant(0))
    let total = c.splitSignatureHeads(row.value)
    let parameter = parameterLength(row.active, row.address, ranges+i)
    discard c.constrainUnsigned(c.multiply(row.active, total.params-parameter.length), 32)
    discard c.constrainUnsigned(c.multiply(row.active, total.results-parameter.length), 32)
    let nonempty = c.multiply(row.active, constant(1)-c.zeroIndicator(total.results))
    c.constrain(row.active-nonempty, total.params, constant(0))
    let address = row.address.scale(scalar(1'u64 shl 32))+total.results-constant(1)
    let last = c.read(nonempty, address, witness.last[i].value)
    lastQueries.add last
    let span = c.splitSignatureHeads(last.value)
    c.constrain(nonempty, total.params-span.params-span.results, constant(0))
    count = c.materialize(count+row.active)
    previous = row.active
  c.assertEqual(count, functionCount-firstFunction)
  when defined(zkbuildBodySourceAudit): localAudit.program = c.endSourceProgram(programMarker)
  when defined(zkbuildBodySourceAudit): localAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(signatures.signatures, metadataQueries, witness.signatureMemory, 33, 64)
  when defined(zkbuildBodySourceAudit): localAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(indexed.lengths, lengthQueries, witness.lengthMemory, 32, 32)
  when defined(zkbuildBodySourceAudit): localAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(indexed.members, memberQueries, witness.memberMemory, 64, 35)
  when defined(zkbuildBodySourceAudit): localAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(declarations.totals, totalQueries, witness.totalMemory, 32, 64)
  when defined(zkbuildBodySourceAudit): localAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(environment.localRanges, lastQueries, witness.rangeMemory, 64, 64)
  when defined(zkbuildBodySourceAudit): c.localDeclarationRecords.add localAudit
