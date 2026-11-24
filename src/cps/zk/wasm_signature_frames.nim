## Authenticated control-frame signature descriptors, separate from floors and
## reachability. Compose with the ordinary control and instruction relations.
import ../wasm/[types, validate]
import r1cs, range_check, memory_consistency
import wasm_instruction_events, wasm_operand_events

type
  SignatureFrameWitness* = object
    reads*, sources*: seq[uint64]
    memory*: MemoryWitness
  FrameDescriptorWires* = object
    token*, kind*, descriptor*, index*: Linear
    isType*, isFunction*, isEmpty*, isValue*: Linear
  FrameInstructionFlags* = object
    blockOp*, loopOp*, ifOp*, elseOp*, endOp*, tryOp*, brOp*, brIfOp*, returnOp*: Linear
    opening*, branching*, closing*, control*: Linear
  SignatureFrameProjection* = object
    source*: seq[FrameDescriptorWires]
    flags*: seq[FrameInstructionFlags]
    rootPush*: seq[Linear]

func rootSignatureToken*(functionIndex: uint32): uint64 = uint64(functionIndex)*16+4

func blockSignatureToken*(code: uint16, pad: uint64): uint64 =
  let descriptor = if pad == 0: 2'u64
    elif pad <= 7: uint64(pad-1)*4+3
    elif pad >= 0x100: uint64(pad-0x100)*4
    else: 0'u64 # Invalid pads yield an unsatisfied circuit, not a host bypass.
  let kind = if code == uint16(ord(opLoop)): 1'u64
    elif code == uint16(ord(opIf)): 2'u64 else: 0'u64
  descriptor*4+kind

proc buildSignatureFrameWitness*(rows: openArray[InstructionEventRow],
    primary: openArray[uint32], pads: openArray[uint64],
    labelDepths: openArray[uint32] = []): SignatureFrameWitness =
  if rows.len == 0 or rows.len != primary.len or rows.len != pads.len or rows.len > high(int) div 2:
    raise newException(ValueError, "signature-frame witness dimensions differ")
  if labelDepths.len != 0 and labelDepths.len != rows.len:
    raise newException(ValueError, "signature-frame label dimensions differ")
  var frames: seq[uint64]
  var source = 0'u64
  var pad = 0'u64
  var rootPending = false
  var accesses: seq[MemoryAccess]
  for i, row in rows:
    let event = row.control.operand
    let kind = event.kind
    let top = if frames.len == 0: 0'u64 else: frames[^1]
    let space = uint64(event.functionIndex) shl 32
    var read, write: MemoryAccess
    if kind == uint8(ord(veInstructionBegin)) and row.opcode in [uint16(ord(opEnd)), uint16(ord(opElse))] and frames.len != 0:
      read = MemoryAccess(active: true, address: space+uint64(frames.len-1), value: top)
    let branching = row.opcode in [uint16(ord(opBr)), uint16(ord(opBrIf)), uint16(ord(opReturn))]
    var target = 0'u64
    if kind == uint8(ord(veInstructionBegin)) and branching:
      let slot = if row.opcode == uint16(ord(opReturn)): 0'i64
        else: int64(frames.len)-1-int64(primary[i])
      if slot >= 0 and slot < int64(frames.len): target = frames[int(slot)]
      read = MemoryAccess(active: true, address: space+uint64(max(slot, 0)), value: target)
    if kind == uint8(ord(veLabelCheck)) and labelDepths.len != 0:
      let slot = int64(frames.len)-1-int64(labelDepths[i])
      if slot >= 0 and slot < int64(frames.len): target = frames[int(slot)]
      read = MemoryAccess(active: true, address: space+uint64(max(slot, 0)), value: target)
    if kind == uint8(ord(veFunctionBegin)):
      source = rootSignatureToken(event.functionIndex)
      pad = 0
    elif kind == uint8(ord(veInstructionBegin)):
      pad = pads[i]
      source = if row.opcode in [uint16(ord(opBlock)), uint16(ord(opLoop)), uint16(ord(opIf)), uint16(ord(opTryTable))]:
          blockSignatureToken(row.opcode, pad)
        elif branching: target
        elif row.opcode in [uint16(ord(opElse)), uint16(ord(opEnd))]: top
        else: 0'u64
    elif kind == uint8(ord(veLabelCheck)) and labelDepths.len != 0: source = target
    result.reads.add read.value
    result.sources.add source
    if kind == uint8(ord(veControlPush)):
      let token = if rootPending: rootSignatureToken(event.functionIndex)
        elif row.opcode == uint16(ord(opElse)): (source div 4)*4+3
        else: blockSignatureToken(row.opcode, pad)
      write = MemoryAccess(active: true, write: true, address: space+uint64(frames.len), value: token)
      frames.add token
    elif kind == uint8(ord(veControlPop)) and frames.len != 0: frames.setLen(frames.len-1)
    accesses.add read
    accesses.add write
    rootPending = kind == uint8(ord(veFunctionBegin))
  result.memory = buildMemoryWitness(accesses)

proc pack(c: var Circuit, bits: openArray[Linear]): Linear =
  var sum: Linear
  var weight = scalar(1)
  for bit in bits:
    sum = sum+bit.scale(weight)
    weight = weight+weight
  c.materialize(sum)

proc splitFrameDescriptor*(c: var Circuit, token: Linear): FrameDescriptorWires =
  let bits = c.constrainUnsigned(token, 36)
  result.token = token
  result.kind = bits[0]+bits[1].scale(scalar(2))
  result.descriptor = c.pack(bits[2..35])
  result.index = c.pack(bits[4..35])
  let both = c.multiply(bits[2], bits[3])
  result.isType = constant(1)-bits[2]-bits[3]+both
  result.isFunction = bits[2]-both
  result.isEmpty = bits[3]-both
  result.isValue = both

proc frameInstructionFlags(c: var Circuit, opcode: Linear): FrameInstructionFlags =
  result.blockOp = c.zeroIndicator(opcode-constant(ord(opBlock)))
  result.loopOp = c.zeroIndicator(opcode-constant(ord(opLoop)))
  result.ifOp = c.zeroIndicator(opcode-constant(ord(opIf)))
  result.elseOp = c.zeroIndicator(opcode-constant(ord(opElse)))
  result.endOp = c.zeroIndicator(opcode-constant(ord(opEnd)))
  result.tryOp = c.zeroIndicator(opcode-constant(ord(opTryTable)))
  result.brOp = c.zeroIndicator(opcode-constant(ord(opBr)))
  result.brIfOp = c.zeroIndicator(opcode-constant(ord(opBrIf)))
  result.returnOp = c.zeroIndicator(opcode-constant(ord(opReturn)))
  result.opening = result.blockOp+result.loopOp+result.ifOp+result.tryOp
  result.branching = result.brOp+result.brIfOp+result.returnOp
  result.closing = result.elseOp+result.endOp
  result.control = result.opening+result.branching+result.closing

proc constrainSignatureFrames*(c: var Circuit, rows: openArray[InstructionEventWires],
    primary, pads: openArray[Linear], operand: OperandEventProjection,
    witness: SignatureFrameWitness, labelDepths: openArray[Linear] = []): SignatureFrameProjection =
  ## The control relation must bind depth transitions and function namespaces,
  ## and the instruction relation must bind event ordering/opcode continuity.
  if rows.len == 0 or rows.len != primary.len or rows.len != pads.len or
      rows.len != operand.flags.len or rows.len != witness.reads.len:
    raise newException(ValueError, "signature-frame circuit dimensions differ")
  if labelDepths.len != 0 and labelDepths.len != rows.len:
    raise newException(ValueError, "signature-frame label circuit dimensions differ")
  when defined(zkbuildStructuredControlAudit):
    let marker = c.beginSourceProgram()
  var accesses: seq[MemoryAccessWires]
  var beforeDepth, rootPending, heldPad, source = constant(0)
  for i, row in rows:
    let event = row.control.operand
    let flags = operand.flags[i]
    let op = c.frameInstructionFlags(row.opcode)
    result.flags.add op
    discard c.constrainUnsigned(pads[i], 33)
    discard c.constrainUnsigned(primary[i], 32)
    c.constrain(constant(1)-flags.instructionBegin, pads[i], constant(0))
    c.constrain(constant(1)-flags.instructionBegin, primary[i], constant(0))
    c.constrain(rootPending, constant(1)-flags.controlPush, constant(0))
    let rootPush = c.multiply(rootPending, flags.controlPush)
    result.rootPush.add rootPush
    c.constrain(flags.controlPush-rootPush, constant(1)-op.opening-op.elseOp, constant(0))
    c.constrain(flags.controlPop, constant(1)-op.closing, constant(0))
    let nonempty = constant(1)-c.zeroIndicator(beforeDepth)
    let space = event.functionIndex.scale(scalar(1'u64 shl 32))
    var readActive = c.multiply(flags.instructionBegin, op.branching+op.closing)
    var depth = c.multiply(op.branching, primary[i])
    if labelDepths.len != 0:
      readActive = readActive+flags.labelCheck
      depth = c.selectWire(flags.labelCheck, labelDepths[i], depth)
    c.constrain(readActive, constant(1)-nonempty, constant(0))
    let targetSlot = c.multiply(readActive,
      c.selectWire(op.returnOp, constant(0), beforeDepth-constant(1)-depth))
    discard c.constrainUnsigned(targetSlot, 32)
    let observed = c.allocate(scalar(witness.reads[i]))
    accesses.add MemoryAccessWires(active: readActive, write: constant(0),
      address: c.multiply(readActive, space)+targetSlot, value: observed)
    heldPad = c.selectWire(flags.functionBegin+flags.instructionBegin, pads[i], heldPad)
    let emptyPad = c.zeroIndicator(heldPad)
    var singleton, singletonKey: Linear
    for tag in 0..6:
      let selected = c.zeroIndicator(heldPad-constant(tag+1))
      singleton = singleton+selected
      singletonKey = singletonKey+selected.scale(scalar(4*tag+3))
    let typeIndex = c.multiply(constant(1)-emptyPad-singleton, heldPad-constant(0x100))
    discard c.constrainUnsigned(typeIndex, 32)
    let blockKey = emptyPad.scale(scalar(2))+singletonKey+typeIndex.scale(scalar(4))
    let blockKind = op.loopOp+op.ifOp.scale(scalar(2))
    let proposed = c.materialize(blockKey.scale(scalar(4))+blockKind)
    let rootToken = event.functionIndex.scale(scalar(16))+constant(4)
    let instructionSource = c.multiply(op.opening, proposed)+c.multiply(op.branching+op.closing, observed)
    source = c.selectWire(flags.functionBegin+flags.instructionBegin,
      c.selectWire(flags.functionBegin, rootToken, instructionSource), source)
    if labelDepths.len != 0: source = c.selectWire(flags.labelCheck, observed, source)
    let descriptor = c.splitFrameDescriptor(source)
    result.source.add descriptor
    c.constrain(c.multiply(flags.instructionBegin, op.elseOp), descriptor.kind-constant(2), constant(0))
    let nestedToken = c.selectWire(op.elseOp, descriptor.descriptor.scale(scalar(4))+constant(3), proposed)
    let writtenToken = c.selectWire(rootPush, rootToken, nestedToken)
    accesses.add MemoryAccessWires(active: flags.controlPush, write: flags.controlPush,
      address: c.multiply(flags.controlPush, space+beforeDepth),
      value: c.multiply(flags.controlPush, writtenToken))
    beforeDepth = row.control.depth
    rootPending = flags.functionBegin
  c.assertEqual(rootPending, constant(0))
  when defined(zkbuildStructuredControlAudit):
    var audit = DynamicTypingStageAudit(kind: 3,rows: captureInstructionRows(rows),flags: captureEventFlags(operand.flags),
      outputs: captureFrames(result),program: c.endSourceProgram(marker))
    for i in 0..<rows.len: audit.inputs.add copyAuditExpressions([primary[i],pads[i],
      (if labelDepths.len == 0: constant(0) else: labelDepths[i])])
    c.structuredControlRecords.add audit
    c.structuredControlMemories.add c.memoryRecords.len
  discard c.constrainMemory(accesses, witness.memory, 64, 36)
