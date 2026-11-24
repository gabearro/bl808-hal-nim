## br_table type discipline, including polymorphic pop/restore and zero-arity
## targets. Target depths and frame descriptors must come from their arguments.
import std/tables
import ../wasm/[types, validate]
import r1cs, range_check, read_only_memory, memory_consistency
import wasm_instruction_events, wasm_operand_events, wasm_signature_frames
import wasm_signature_environment, wasm_indexed_signatures, wasm_branch_environment
import wasm_control_typing

type BranchTypingWitness* = object
  metadataQueries*: seq[ReadOnlyEntry]
  indexedQueries*: IndexedSignatureQueries
  metadata*, scratch*: MemoryWitness
  indexed*: IndexedSignatureWitness

proc contents(entries: openArray[ReadOnlyEntry]): Table[uint64, uint64] =
  for entry in entries:
    if entry.active: result[entry.address] = entry.value

proc buildBranchTypingWitness*(signatures: SignatureEnvironment,
    indexed: IndexedSignatureEnvironment, rows: openArray[InstructionEventRow],
    frames: SignatureFrameWitness, branches: BranchEnvironmentWitness,
    includeLookupWitnesses = true, catchChecks = false): BranchTypingWitness =
  if rows.len != frames.sources.len or rows.len != branches.last.len:
    raise newException(ValueError, "branch type witness dimensions differ")
  let metadata = contents(signatures.signatures)
  let lengths = contents(indexed.lengths)
  let members = contents(indexed.members)
  let singletons = contents(indexed.singletons)
  result.metadataQueries.setLen(rows.len)
  result.indexedQueries.lengths.setLen(rows.len)
  result.indexedQueries.members.setLen(rows.len)
  result.indexedQueries.singletons.setLen(rows.len)
  var head, length: uint64
  var pops, pushes, popStart: int64
  var pending = false
  var accesses: seq[MemoryAccess]
  for i, row in rows:
    let kind = row.control.operand.kind
    var access: MemoryAccess
    if kind in [uint8(ord(veFunctionBegin)), uint8(ord(veInstructionBegin))]:
      head = 0; length = 0; pops = 0; pushes = 0; popStart = 0
      pending = kind == uint8(ord(veInstructionBegin)) and row.opcode == uint16(ord(opBrTable))
    if kind == uint8(ord(veLabelCheck)) and (not catchChecks or row.opcode == uint16(ord(opBrTable))):
      let token = frames.sources[i]
      let family = (token shr 2) and 3
      let index = token shr 4
      var params, results: uint64
      if family <= 1:
        let address = 2*index+uint64(ord(family == 0))
        let value = metadata.getOrDefault(address)
        result.metadataQueries[i] = ReadOnlyEntry(active: true, address: address, value: value)
        if family == 0: params = value and 0xffffffff'u64
        results = value shr 32
      elif family == 3:
        results = singletons.getOrDefault(index)
        result.indexedQueries.singletons[i] = ReadOnlyEntry(active: true, address: index, value: results)
      head = if (token and 3) == 1: params else: results
      length = lengths.getOrDefault(head)
      result.indexedQueries.lengths[i] = ReadOnlyEntry(active: true, address: head, value: length)
      pops = 0; pushes = 0; popStart = int64(i)+1
    elif row.opcode == uint16(ord(opBrTable)) and kind == uint8(ord(veOperandPop)):
      if pending: pending = false
      else:
        let loop = (frames.sources[i] and 3) == 1
        let ordinal = if loop: pops else: int64(length)-1-pops
        let address = signatureMemberAddress(uint32(head and 0xffffffff'u64), uint32(max(ordinal, 0)))
        result.indexedQueries.members[i] = ReadOnlyEntry(active: true, address: address, value: members.getOrDefault(address))
        access = MemoryAccess(active: true, write: true, address: uint64(i), value: uint64(row.control.operand.valueType))
        inc pops
    elif row.opcode == uint16(ord(opBrTable)) and kind == uint8(ord(veOperandPush)):
      let slot = popStart+int64(length)-1-pushes
      access = MemoryAccess(active: true, address: uint64(max(slot, 0)), value: uint64(row.control.operand.valueType))
      inc pushes
    accesses.add access
  if includeLookupWitnesses:
    result.metadata = buildReadOnlyWitness(signatures.signatures, result.metadataQueries)
    result.indexed = buildIndexedSignatureWitness(indexed, signatures, result.indexedQueries)
  result.scratch = buildMemoryWitness(accesses)

proc read(c: var Circuit, active, address: Linear, value: uint64): ReadOnlyWires =
  ReadOnlyWires(active: active, address: c.multiply(active, address), value: c.allocate(scalar(value)))

proc constrainBranchTypingQueries*(c: var Circuit, rows: openArray[InstructionEventWires],
    operand: OperandEventProjection, frames: SignatureFrameProjection, branches: BranchProjection,
    signatures: SignatureEnvironmentWires, indexed: IndexedSignatureWires,
    witness: BranchTypingWitness): ControlTypingQueries =
  ## Returns unverified lookup queries; scratch-memory authentication is
  ## performed here. The caller must authenticate the returned lookups.
  if rows.len == 0 or uint64(rows.len) > uint64(high(uint32)) or
      rows.len != operand.flags.len or rows.len != frames.source.len or
      rows.len != branches.last.len or rows.len != witness.metadataQueries.len or
      rows.len != witness.indexedQueries.lengths.len or
      rows.len != witness.indexedQueries.members.len or rows.len != witness.indexedQueries.singletons.len:
    raise newException(ValueError, "branch type circuit dimensions differ")
  when defined(zkbuildStructuredControlAudit):
    let marker = c.beginSourceProgram()
  var metadata: seq[ReadOnlyWires]
  var queries: IndexedSignatureQueryWires
  var scratch: seq[MemoryAccessWires]
  var head, length, arity, pops, pushes, pending, seen, last, cleared, popStart = constant(0)
  for i, row in rows:
    let flags = operand.flags[i]
    let table = c.zeroIndicator(row.opcode-constant(ord(opBrTable)))
    let reset = flags.functionBegin+flags.instructionBegin
    let mark = flags.labelCheck
    let frame = frames.source[i]
    head = c.selectWire(reset, constant(0), head)
    length = c.selectWire(reset, constant(0), length)
    arity = c.selectWire(reset, constant(0), arity)
    pops = c.selectWire(reset, constant(0), pops)
    pushes = c.selectWire(reset, constant(0), pushes)
    pending = c.selectWire(reset, c.multiply(flags.instructionBegin, table), pending)
    seen = c.selectWire(reset, constant(0), seen)
    last = c.selectWire(reset, constant(0), last)
    cleared = c.selectWire(reset, constant(0), cleared)
    popStart = c.selectWire(reset, constant(0), popStart)
    c.constrain(mark, constant(1)-table, constant(0))
    c.constrain(mark, pending+last+cleared, constant(0))
    let repeat = c.multiply(mark, seen)
    c.constrain(repeat, pops-length, constant(0))
    c.constrain(repeat, pushes-c.multiply(constant(1)-last, length), constant(0))

    let meta = c.read(c.multiply(mark, frame.isType+frame.isFunction),
      frame.index.scale(scalar(2))+frame.isType, witness.metadataQueries[i].value)
    metadata.add meta
    let heads = c.splitSignatureHeads(meta.value)
    let singleton = c.read(c.multiply(mark, frame.isValue), frame.index, witness.indexedQueries.singletons[i].value)
    queries.singletons.add singleton
    c.constrain(c.multiply(mark, frame.isEmpty), frame.index, constant(0))
    let loopFrame = c.zeroIndicator(frame.kind-constant(1))
    let selectedHead = c.selectWire(loopFrame, c.multiply(frame.isType, heads.params), heads.results+singleton.value)
    let size = c.read(mark, selectedHead, witness.indexedQueries.lengths[i].value)
    queries.lengths.add size
    c.constrain(repeat, size.value-arity, constant(0))
    let first = c.multiply(mark, constant(1)-seen)
    arity = c.selectWire(first, size.value, arity)
    head = c.selectWire(mark, selectedHead, head)
    length = c.selectWire(mark, size.value, length)
    pops = c.selectWire(mark, constant(0), pops)
    pushes = c.selectWire(mark, constant(0), pushes)
    popStart = c.selectWire(mark, constant(i+1), popStart)
    seen = c.selectWire(mark, constant(1), seen)
    last = c.selectWire(mark, branches.last[i], last)

    let pop = c.multiply(table, flags.operandPop)
    let condition = c.multiply(pop, pending)
    let argument = pop-condition
    let push = c.multiply(table, flags.operandPush)
    let clear = c.multiply(table, flags.clear)
    let actual = row.control.operand.valueType
    let unknown = c.zeroIndicator(actual-constant(7))
    c.constrain(condition, constant(1)-unknown-c.zeroIndicator(actual), constant(0))
    c.constrain(argument+push+clear, constant(1)-seen, constant(0))
    c.constrain(argument, pending+pushes+cleared, constant(0))
    c.constrain(argument, constant(i)-popStart-pops, constant(0))
    let ordinal = c.selectWire(loopFrame, pops, length-constant(1)-pops)
    let member = c.constrainSignatureMemberQuery(argument, head, ordinal, witness.indexedQueries.members[i].value)
    queries.members.add member
    let parts = c.splitSignatureNode(member.value)
    c.constrain(argument, constant(1)-unknown-c.zeroIndicator(actual-parts.tag), constant(0))
    c.constrain(push, pending+last+cleared, constant(0))
    c.constrain(push, pops-length, constant(0))
    let restoreOrdinal = c.multiply(push, length-constant(1)-pushes)
    discard c.constrainUnsigned(restoreOrdinal, 32)
    scratch.add MemoryAccessWires(active: argument+push, write: argument,
      address: argument.scale(scalar(i))+c.multiply(push, popStart+restoreOrdinal),
      value: c.multiply(argument+push, actual))
    c.constrain(clear, constant(1)-last, constant(0))
    c.constrain(clear, pending+pushes+cleared, constant(0))
    c.constrain(clear, pops-length, constant(0))
    pops = c.materialize(pops+argument)
    pushes = c.materialize(pushes+push)
    pending = c.materialize(pending-condition)
    cleared = c.materialize(cleared+clear)
    let finish = c.multiply(table, flags.instructionEnd)
    c.constrain(finish, constant(1)-seen, constant(0))
    c.constrain(finish, constant(1)-last, constant(0))
    c.constrain(finish, pending+pushes, constant(0))
    c.constrain(finish, pops-length, constant(0))
    c.constrain(finish, cleared-constant(1), constant(0))
  result = ControlTypingQueries(metadata: metadata, indexed: queries)
  when defined(zkbuildStructuredControlAudit):
    var audit = DynamicTypingStageAudit(kind: 5,rows: captureInstructionRows(rows),flags: captureEventFlags(operand.flags),
      selectors: captureFrames(frames),outputs: captureTypingQueries(result,true),program: c.endSourceProgram(marker))
    for value in branches.last: audit.inputs.add copyAuditExpressions([value])
    c.structuredControlRecords.add audit
    c.structuredControlMemories.add c.memoryRecords.len
  discard c.constrainMemory(scratch, witness.scratch, 32, 3)

proc constrainBranchTyping*(c: var Circuit, rows: openArray[InstructionEventWires],
    operand: OperandEventProjection, frames: SignatureFrameProjection, branches: BranchProjection,
    signatures: SignatureEnvironmentWires, indexed: IndexedSignatureWires,
    witness: BranchTypingWitness) =
  let queries = c.constrainBranchTypingQueries(rows, operand, frames, branches, signatures, indexed, witness)
  c.constrainReadOnly(signatures.signatures, queries.metadata, witness.metadata, 33, 64)
  c.constrainIndexedSignatures(indexed, signatures, witness.indexed, queries.indexed)
