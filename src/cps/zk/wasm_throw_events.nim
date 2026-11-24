## Exception tag and throw payload checks, relative to the shared validated
## signature tables. Catch clauses and raw-byte binding remain separate.
import std/tables
import ../wasm/[types, validate]
import r1cs, range_check, read_only_memory, memory_consistency
import wasm_instruction_events, wasm_operand_events, wasm_signature_environment

type
  TagEnvironment* = object
    tags*: seq[ReadOnlyEntry]
    typeIndices*: seq[uint32]
  TagEnvironmentWires* = object
    tags*: seq[ReadOnlyWires]
    typeIndices*: seq[Linear]
  ThrowEventsWitness* = object
    tagQueries*, operandQueries*: seq[ReadOnlyEntry]
    origins*, tags*, nodes*: MemoryWitness

proc buildTagEnvironment*(module: WasmModule, signatures: SignatureEnvironment,
    tagCapacity = 0): TagEnvironment =
  if tagCapacity < 0 or uint64(module.tagDefs.len) > uint64(high(uint32)):
    raise newException(ValueError, "invalid exception tag dimensions")
  var metadata: Table[uint64, uint64]
  for entry in signatures.signatures:
    if entry.active: metadata[entry.address] = entry.value
  for i, tag in module.tagDefs:
    result.tags.add ReadOnlyEntry(active: true, address: uint64(i), value: metadata.getOrDefault(typeSignatureAddress(tag.typeIdx)))
    result.typeIndices.add tag.typeIdx
  if tagCapacity != 0:
    if result.tags.len > tagCapacity: raise newException(ValueError, "exception tag profile overflow")
    result.tags.setLen(tagCapacity)
    result.typeIndices.setLen(tagCapacity)

proc buildThrowEventsWitness*(environment: TagEnvironment, signatures: SignatureEnvironment,
    rows: openArray[InstructionEventRow], primary: openArray[uint32]): ThrowEventsWitness =
  if environment.tags.len != environment.typeIndices.len or rows.len != primary.len:
    raise newException(ValueError, "throw witness dimensions differ")
  var tags, nodes: Table[uint64, uint64]
  var origins: seq[ReadOnlyEntry]
  for i, entry in environment.tags:
    if entry.active:
      tags[entry.address] = entry.value
      origins.add ReadOnlyEntry(active: true, address: typeSignatureAddress(environment.typeIndices[i]), value: entry.value)
    else: origins.add ReadOnlyEntry()
  for entry in signatures.nodes:
    if entry.active: nodes[entry.address] = entry.value
  var params = 0'u64
  for i, row in rows:
    var tag, operand: ReadOnlyEntry
    if row.control.operand.kind == uint8(ord(veInstructionBegin)):
      params = 0
      if row.opcode == uint16(ord(opThrow)):
        tag = ReadOnlyEntry(active: true, address: uint64(primary[i]), value: tags.getOrDefault(uint64(primary[i])))
        params = tag.value and 0xffffffff'u64
    elif row.opcode == uint16(ord(opThrow)) and row.control.operand.kind == uint8(ord(veOperandPop)):
      operand = ReadOnlyEntry(active: true, address: params, value: nodes.getOrDefault(params))
      params = operand.value shr 3
    result.tagQueries.add tag
    result.operandQueries.add operand
  result.origins = buildReadOnlyWitness(signatures.signatures, origins)
  result.tags = buildReadOnlyWitness(environment.tags, result.tagQueries)
  result.nodes = buildReadOnlyWitness(signatures.nodes, result.operandQueries)

proc constrainThrowEvents*(c: var Circuit, rows: openArray[InstructionEventWires],
    primary: openArray[Linear], operand: OperandEventProjection, environment: TagEnvironmentWires,
    signatures: SignatureEnvironmentWires, witness: ThrowEventsWitness) =
  if rows.len == 0 or rows.len != primary.len or rows.len != operand.flags.len or
      rows.len != witness.tagQueries.len or rows.len != witness.operandQueries.len or
      environment.tags.len != environment.typeIndices.len or uint64(environment.tags.len) > uint64(high(uint32)):
    raise newException(ValueError, "throw circuit dimensions differ")
  when defined(zkbuildStructuredControlAudit):
    let marker = c.beginSourceProgram()
    var audit = DynamicTypingStageAudit(kind: 9,rows: captureInstructionRows(rows),flags: captureEventFlags(operand.flags))
    for value in primary: audit.inputs.add copyAuditExpressions([value])
    for value in environment.typeIndices: audit.auxiliary.add copyAuditExpressions([value])
  var origins, tags, nodes: seq[ReadOnlyWires]
  for i, entry in environment.tags:
    c.constrain(entry.active, entry.address-constant(i), constant(0))
    discard c.constrainUnsigned(environment.typeIndices[i], 32)
    c.constrain(constant(1)-entry.active, environment.typeIndices[i], constant(0))
    let heads = c.splitSignatureHeads(entry.value)
    c.constrain(entry.active, heads.results, constant(0))
    origins.add ReadOnlyWires(active: entry.active,
      address: c.multiply(entry.active, environment.typeIndices[i].scale(scalar(2))+constant(1)), value: entry.value)
  var params = constant(0)
  var cleared = constant(0)
  for i, row in rows:
    let flags = operand.flags[i]
    let tagged = c.zeroIndicator(row.opcode-constant(ord(opThrow)))
    let opaque = c.zeroIndicator(row.opcode-constant(ord(opThrowRef)))
    let throwing = tagged+opaque
    discard c.constrainUnsigned(row.opcode, 16)
    discard c.constrainUnsigned(primary[i], 32)
    c.constrain(constant(1)-flags.instructionBegin, primary[i], constant(0))
    let query = c.multiply(tagged, flags.instructionBegin)
    let metadata = c.allocate(scalar(witness.tagQueries[i].value))
    tags.add ReadOnlyWires(active: query, address: c.multiply(query, primary[i]), value: metadata)
    let heads = c.splitSignatureHeads(metadata)
    let reset = flags.functionBegin+flags.instructionBegin
    params = c.selectWire(reset, heads.params+c.multiply(opaque, flags.instructionBegin), params)
    cleared = c.selectWire(reset, constant(0), cleared)
    let pop = c.multiply(throwing, flags.operandPop)
    let taggedPop = c.multiply(tagged, flags.operandPop)
    let opaquePop = c.multiply(opaque, flags.operandPop)
    let clear = c.multiply(throwing, flags.clear)
    let finish = c.multiply(throwing, flags.instructionEnd)
    c.constrain(throwing, flags.operandPush+flags.controlPush+flags.controlPop, constant(0))
    c.constrain(pop, cleared, constant(0))
    let payload = c.allocate(scalar(witness.operandQueries[i].value))
    nodes.add ReadOnlyWires(active: taggedPop, address: c.multiply(taggedPop, params), value: payload)
    let node = c.splitSignatureNode(payload)
    let actual = row.control.operand.valueType
    let unknown = c.zeroIndicator(actual-constant(7))
    c.constrain(taggedPop, c.zeroIndicator(node.tag-constant(7)), constant(0))
    c.constrain(taggedPop, constant(1)-unknown-c.zeroIndicator(actual-node.tag), constant(0))
    c.constrain(opaquePop, constant(1)-unknown-c.zeroIndicator(actual-constant(6)), constant(0))
    c.constrain(opaquePop, params-constant(1), constant(0))
    params = c.materialize(c.selectWire(taggedPop, node.next, params)-opaquePop)
    c.constrain(clear, params+cleared, constant(0))
    cleared = c.materialize(cleared+clear)
    c.constrain(finish, params, constant(0))
    c.constrain(finish, cleared-constant(1), constant(0))
  when defined(zkbuildStructuredControlAudit):
    audit.program = c.endSourceProgram(marker)
    audit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(signatures.signatures, origins, witness.origins, 33, 64)
  when defined(zkbuildStructuredControlAudit): audit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(environment.tags, tags, witness.tags, 32, 64)
  when defined(zkbuildStructuredControlAudit): audit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(signatures.nodes, nodes, witness.nodes, 32, 35)
  when defined(zkbuildStructuredControlAudit): c.structuredControlRecords.add audit
