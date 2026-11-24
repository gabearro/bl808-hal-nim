## Structured-control and simple-branch typing from authenticated frame
## descriptors and indexed signatures. br_table/catch clauses remain separate.
import std/tables
import ../wasm/validate
import r1cs, range_check, read_only_memory, memory_consistency
import wasm_instruction_events, wasm_operand_events, wasm_signature_frames
import wasm_signature_environment, wasm_indexed_signatures

type
  ControlTypingWitness* = object
    metadataQueries*: seq[ReadOnlyEntry]
    indexedQueries*: IndexedSignatureQueries
    metadata*: MemoryWitness
    indexed*: IndexedSignatureWitness
  ControlTypingQueries* = object
    metadata*: seq[ReadOnlyWires]
    indexed*: IndexedSignatureQueryWires

proc contents(entries: openArray[ReadOnlyEntry]): Table[uint64, uint64] =
  for entry in entries:
    if entry.active: result[entry.address] = entry.value

func controlCode(code: uint16): bool = code in [2'u16, 3, 4, 5, 0x0b, 0x0c, 0x0d, 0x0f, 0x1f]

proc buildControlTypingWitness*(signatures: SignatureEnvironment,
    indexed: IndexedSignatureEnvironment, rows: openArray[InstructionEventRow],
    frames: SignatureFrameWitness, includeLookupWitnesses = true): ControlTypingWitness =
  if rows.len != frames.sources.len: raise newException(ValueError, "control type witness dimensions differ")
  let metadata = contents(signatures.signatures)
  let lengths = contents(indexed.lengths)
  let members = contents(indexed.members)
  let singles = contents(indexed.singletons)
  result.metadataQueries.setLen(rows.len)
  result.indexedQueries.lengths.setLen(2*rows.len)
  result.indexedQueries.members.setLen(2*rows.len)
  result.indexedQueries.singletons.setLen(rows.len)
  var pHead, rHead, pLen, rLen: uint64
  var pops, pushes: int64
  var pending = false
  for i, row in rows:
    let kind = row.control.operand.kind
    let code = row.opcode
    let token = frames.sources[i]
    let frameKind = token and 3
    if kind in [uint8(ord(veFunctionBegin)), uint8(ord(veInstructionBegin))]:
      pHead = 0; rHead = 0; pLen = 0; rLen = 0
      pops = 0; pushes = 0
      pending = code in [4'u16, 0x0d] and kind == uint8(ord(veInstructionBegin))
      if kind == uint8(ord(veFunctionBegin)) or controlCode(code):
        let family = (token shr 2) and 3
        let index = token shr 4
        if family <= 1:
          let address = 2*index+uint64(ord(family == 0))
          let value = metadata.getOrDefault(address)
          result.metadataQueries[i] = ReadOnlyEntry(active: true, address: address, value: value)
          if family == 0: pHead = value and 0xffffffff'u64
          rHead = value shr 32
        elif family == 3:
          let head = singles.getOrDefault(index)
          result.indexedQueries.singletons[i] = ReadOnlyEntry(active: true, address: index, value: head)
          rHead = head
        pLen = lengths.getOrDefault(pHead)
        rLen = lengths.getOrDefault(rHead)
        result.indexedQueries.lengths[2*i] = ReadOnlyEntry(active: true, address: pHead, value: pLen)
        result.indexedQueries.lengths[2*i+1] = ReadOnlyEntry(active: true, address: rHead, value: rLen)
    if not controlCode(code): continue
    let opening = code in [2'u16, 3, 4, 0x1f]
    let branching = code in [0x0c'u16, 0x0d, 0x0f]
    if kind == uint8(ord(veOperandPop)):
      if pending: pending = false
      else:
        let parameters = opening or (branching and frameKind == 1)
        let head = if parameters: pHead else: rHead
        let ordinal = if parameters: pops else: int64(rLen)-1-pops
        let address = signatureMemberAddress(uint32(head and 0xffffffff'u64), uint32(max(ordinal, 0)))
        result.indexedQueries.members[2*i] = ReadOnlyEntry(active: true, address: address, value: members.getOrDefault(address))
        if code == 0x0b and frameKind == 2:
          let compare = signatureMemberAddress(uint32(pHead), uint32(pops))
          result.indexedQueries.members[2*i+1] = ReadOnlyEntry(active: true, address: compare, value: members.getOrDefault(compare))
        inc pops
    elif kind == uint8(ord(veOperandPush)):
      let parameters = opening or code == 5 or (code == 0x0d and frameKind == 1)
      let head = if parameters: pHead else: rHead
      let ordinal = if parameters: int64(pLen)-1-pushes else: pushes
      let address = signatureMemberAddress(uint32(head and 0xffffffff'u64), uint32(max(ordinal, 0)))
      result.indexedQueries.members[2*i] = ReadOnlyEntry(active: true, address: address, value: members.getOrDefault(address))
      inc pushes
  # A combined relation authenticates merged queries once, without building
  # unused standalone routing witnesses for each component.
  if includeLookupWitnesses:
    result.metadata = buildReadOnlyWitness(signatures.signatures, result.metadataQueries)
    result.indexed = buildIndexedSignatureWitness(indexed, signatures, result.indexedQueries)

proc read(c: var Circuit, active, address: Linear, value: uint64): ReadOnlyWires =
  ReadOnlyWires(active: active, address: c.multiply(active, address), value: c.allocate(scalar(value)))

proc constrainControlTypingQueries*(c: var Circuit, rows: openArray[InstructionEventWires],
    operand: OperandEventProjection, frames: SignatureFrameProjection,
    signatures: SignatureEnvironmentWires, indexed: IndexedSignatureWires,
    witness: ControlTypingWitness): ControlTypingQueries =
  ## Returns unverified lookup queries. The caller must authenticate both
  ## metadata and indexed queries against the supplied signature tables.
  if rows.len != operand.flags.len or rows.len != frames.source.len or
      rows.len != frames.flags.len or rows.len != frames.rootPush.len or
      rows.len != witness.metadataQueries.len or
      witness.indexedQueries.lengths.len != 2*rows.len or
      witness.indexedQueries.members.len != 2*rows.len or witness.indexedQueries.singletons.len != rows.len:
    raise newException(ValueError, "control type circuit dimensions differ")
  when defined(zkbuildStructuredControlAudit):
    let marker = c.beginSourceProgram()
  var metadata: seq[ReadOnlyWires]
  var queries: IndexedSignatureQueryWires
  var pHead, rHead, pLen, rLen, pops, pushes, pending, pushed, popped, cleared = constant(0)
  for i, row in rows:
    let flags = operand.flags[i]
    let op = frames.flags[i]
    let frame = frames.source[i]
    let reset = flags.functionBegin+flags.instructionBegin
    let lookup = flags.functionBegin+c.multiply(flags.instructionBegin, op.control)
    let metaActive = c.multiply(lookup, frame.isType+frame.isFunction)
    let metaQuery = c.read(metaActive, frame.index.scale(scalar(2))+frame.isType, witness.metadataQueries[i].value)
    metadata.add metaQuery
    let heads = c.splitSignatureHeads(metaQuery.value)
    let singleQuery = c.read(c.multiply(lookup, frame.isValue), frame.index, witness.indexedQueries.singletons[i].value)
    queries.singletons.add singleQuery
    c.constrain(c.multiply(lookup, frame.isEmpty), frame.index, constant(0))
    pHead = c.selectWire(reset, c.multiply(frame.isType, heads.params), pHead)
    rHead = c.selectWire(reset, heads.results+singleQuery.value, rHead)
    let paramLength = c.read(lookup, pHead, witness.indexedQueries.lengths[2*i].value)
    let resultLength = c.read(lookup, rHead, witness.indexedQueries.lengths[2*i+1].value)
    queries.lengths.add paramLength
    queries.lengths.add resultLength
    pLen = c.selectWire(reset, paramLength.value, pLen)
    rLen = c.selectWire(reset, resultLength.value, rLen)
    pops = c.selectWire(reset, constant(0), pops)
    pushes = c.selectWire(reset, constant(0), pushes)
    pushed = c.selectWire(reset, constant(0), pushed)
    popped = c.selectWire(reset, constant(0), popped)
    cleared = c.selectWire(reset, constant(0), cleared)
    pending = c.selectWire(reset, op.ifOp+op.brIfOp, pending)
    let loopFrame = c.zeroIndicator(frame.kind-constant(1))
    let ifFrame = c.zeroIndicator(frame.kind-constant(2))
    let parameterInput = op.opening+c.multiply(op.branching, loopFrame)
    let inputHead = c.selectWire(parameterInput, pHead, rHead)
    let inputLength = c.selectWire(parameterInput, pLen, rLen)
    let parameterOutput = op.opening+op.elseOp+c.multiply(op.brIfOp, loopFrame)
    let resultOutput = c.multiply(op.endOp, constant(1)-frame.isFunction)+c.multiply(op.brIfOp, constant(1)-loopFrame)
    let outputLength = c.multiply(parameterOutput, pLen)+c.multiply(resultOutput, rLen)
    let outputHead = c.selectWire(parameterOutput, pHead, rHead)
    let pop = c.multiply(op.control, flags.operandPop)
    let indexPop = c.multiply(pop, pending)
    let argumentPop = pop-indexPop
    let push = c.multiply(op.control, flags.operandPush)
    let actual = row.control.operand.valueType
    let unknown = c.zeroIndicator(actual-constant(7))
    c.constrain(indexPop, constant(1)-unknown-c.zeroIndicator(actual), constant(0))
    c.constrain(pop, pushes+pushed+popped+cleared, constant(0))
    let inputOrdinal = c.selectWire(parameterInput, pops, rLen-constant(1)-pops)
    let outputOrdinal = c.selectWire(parameterOutput, pLen-constant(1)-pushes, pushes)
    let queryHead = c.multiply(argumentPop, inputHead)+c.multiply(push, outputHead)
    let ordinal = c.multiply(argumentPop, inputOrdinal)+c.multiply(push, outputOrdinal)
    let member = c.constrainSignatureMemberQuery(argumentPop+push, queryHead, ordinal,
      witness.indexedQueries.members[2*i].value)
    queries.members.add member
    let memberParts = c.splitSignatureNode(member.value)
    c.constrain(argumentPop, constant(1)-unknown-c.zeroIndicator(actual-memberParts.tag), constant(0))
    c.constrain(push, actual-memberParts.tag, constant(0))
    c.constrain(push, pops-inputLength, constant(0))
    c.constrain(push, pending+cleared, constant(0))
    c.constrain(push, pushed-op.opening-op.elseOp, constant(0))
    c.constrain(push, popped-op.closing, constant(0))

    let implicitElse = c.multiply(op.endOp, ifFrame)
    c.constrain(c.multiply(flags.instructionBegin, implicitElse), pLen-rLen, constant(0))
    let compare = c.constrainSignatureMemberQuery(c.multiply(argumentPop, implicitElse), pHead, pops,
      witness.indexedQueries.members[2*i+1].value)
    queries.members.add compare
    let compareParts = c.splitSignatureNode(compare.value)
    c.constrain(compare.active, compareParts.tag-memberParts.tag, constant(0))
    let controlPush = c.multiply(op.control, flags.controlPush)
    let controlPop = c.multiply(op.control, flags.controlPop)
    c.constrain(controlPush+controlPop, pops-inputLength, constant(0))
    c.constrain(controlPush+controlPop, pending+pushes+cleared, constant(0))
    c.constrain(controlPush, pushed, constant(0))
    c.constrain(controlPush, popped-op.elseOp, constant(0))
    c.constrain(controlPop, pushed+popped, constant(0))
    let clear = c.multiply(op.control, flags.clear)
    c.constrain(clear, constant(1)-op.brOp-op.returnOp, constant(0))
    c.constrain(clear, pops-inputLength, constant(0))
    c.constrain(clear, pending+pushes+pushed+popped+cleared, constant(0))
    pops = c.materialize(pops+argumentPop)
    pushes = c.materialize(pushes+push)
    pending = c.materialize(pending-indexPop)
    pushed = c.materialize(pushed+flags.controlPush)
    popped = c.materialize(popped+flags.controlPop)
    cleared = c.materialize(cleared+clear)
    let finish = c.multiply(op.control, flags.instructionEnd)
    c.constrain(finish, pops-inputLength, constant(0))
    c.constrain(finish, pending, constant(0))
    c.constrain(finish, pushes-outputLength, constant(0))
    c.constrain(finish, pushed-op.opening-op.elseOp, constant(0))
    c.constrain(finish, popped-op.closing, constant(0))
    c.constrain(finish, cleared-op.brOp-op.returnOp, constant(0))
  result = ControlTypingQueries(metadata: metadata, indexed: queries)
  when defined(zkbuildStructuredControlAudit):
    c.structuredControlRecords.add DynamicTypingStageAudit(kind: 4,rows: captureInstructionRows(rows),
      flags: captureEventFlags(operand.flags),selectors: captureFrames(frames),outputs: captureTypingQueries(result),
      program: c.endSourceProgram(marker))

proc constrainControlTyping*(c: var Circuit, rows: openArray[InstructionEventWires],
    operand: OperandEventProjection, frames: SignatureFrameProjection,
    signatures: SignatureEnvironmentWires, indexed: IndexedSignatureWires,
    witness: ControlTypingWitness) =
  let queries = c.constrainControlTypingQueries(rows, operand, frames, signatures, indexed, witness)
  c.constrainReadOnly(signatures.signatures, queries.metadata, witness.metadata, 33, 64)
  c.constrainIndexedSignatures(indexed, signatures, witness.indexed, queries.indexed)
