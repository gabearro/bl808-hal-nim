## Authenticated control floors and reachability for validation events.
## Two RAM records per row: read the old top, then optionally write a pushed
## frame or mark the old top unreachable. Frame types/opcodes and module
## correspondence are separate constraints still required by the full prover.
import ../wasm/validate
import r1cs, range_check, memory_consistency, permutation, wasm_operand_events

type
  ControlEventRow* = object
    operand*: OperandEventRow
    depth*: uint32
  ControlEventWires* = object
    operand*: OperandEventWires
    depth*: Linear
  StackMemoryWitness* = object
    operand*, control*: MemoryWitness

proc buildControlEventRows*(events: openArray[ValidationEvent], capacity = 0): seq[ControlEventRow] =
  let operands = buildOperandEventRows(events, capacity)
  for i, operand in operands:
    var depth = 0'u32
    if i < events.len:
      if events[i].controlHeight < 0 or uint64(events[i].controlHeight) > uint64(uint32.high):
        raise newException(ValueError, "control-event depth is out of range")
      depth = uint32(events[i].controlHeight)
    result.add ControlEventRow(operand: operand, depth: depth)

proc controlEventAccesses*(rows: openArray[ControlEventRow]): seq[MemoryAccess] =
  var beforeDepth, beforeHeight: uint64
  for row in rows:
    let event = row.operand
    let space = uint64(event.functionIndex) shl 32
    var read, write: MemoryAccess
    if beforeDepth > 0:
      read = MemoryAccess(active: true, address: space+beforeDepth-1,
        value: 2*uint64(event.floor)+uint64(ord(event.unreachable)))
    if event.kind == uint8(ord(veControlPush)):
      write = MemoryAccess(active: true, write: true, address: space+beforeDepth,
        value: 2*beforeHeight)
    elif event.kind == uint8(ord(veUnreachable)):
      if beforeDepth == 0: raise newException(ValueError, "unreachable event has no control frame")
      write = MemoryAccess(active: true, write: true, address: space+beforeDepth-1,
        value: 2*uint64(event.floor)+1)
    result.add read
    result.add write
    beforeDepth = uint64(row.depth)
    beforeHeight = uint64(event.height)

proc constrainControlEvents*(c: var Circuit, rows: openArray[ControlEventWires],
    operand: OperandEventProjection, firstFunctionIndex: Linear): seq[MemoryAccessWires] =
  ## firstFunctionIndex must eventually be bound to the module import count.
  ## The operand projection must be generated from these same row wires.
  if rows.len == 0 or operand.flags.len != rows.len or operand.accesses.len != rows.len:
    raise newException(ValueError, "control-event dimensions do not match")
  discard routeSwitchCount(rows.len)
  when defined(zkbuildValidationEventAudit):
    let auditMarker = c.beginSourceProgram()
  discard c.constrainUnsigned(firstFunctionIndex, 32)
  var beforeDepth = constant(0)
  var beforeHeight = constant(0)
  var functionOpen = constant(0)
  var functionIndex = firstFunctionIndex
  for i, row in rows:
    let event = row.operand
    let flags = operand.flags[i]
    discard c.constrainUnsigned(row.depth, 32)
    let empty = c.zeroIndicator(beforeDepth)
    let nonempty = constant(1)-empty
    # floor is 32-bit and unreachable is Boolean, so this 33-bit packing
    # cannot cancel modulo the scalar field. One gate canonicalizes both.
    c.constrain(empty, event.floor.scale(scalar(2))+event.unreachable, constant(0))
    c.constrain(flags.controlPop+flags.clear, empty, constant(0))
    c.constrain(operand.accesses[i].active+event.polymorphic, empty, constant(0))
    c.assertEqual(row.depth, beforeDepth+flags.controlPush-flags.controlPop)
    c.constrain(flags.controlPop, event.height-event.floor, constant(0))
    c.constrain(flags.functionBegin+flags.functionEnd+flags.padding, row.depth, constant(0))

    # Function state and namespace continuity. No event can jump into an old
    # function's control memory, and only padding is allowed outside a body.
    c.constrain(flags.functionBegin+flags.padding, functionOpen, constant(0))
    c.constrain(constant(1)-flags.functionBegin-flags.padding,
      constant(1)-functionOpen, constant(0))
    c.constrain(constant(1)-flags.padding, event.functionIndex-functionIndex, constant(0))
    functionOpen = c.materialize(functionOpen+flags.functionBegin-flags.functionEnd)
    functionIndex = c.materialize(functionIndex+flags.functionEnd)

    let space = event.functionIndex.scale(scalar(1'u64 shl 32))
    let readAddress = c.multiply(nonempty, space+beforeDepth-constant(1))
    let readValue = c.multiply(nonempty, event.floor.scale(scalar(2))+event.unreachable)
    result.add MemoryAccessWires(active: nonempty, write: constant(0),
      address: readAddress, value: readValue)

    let writeActive = flags.controlPush+flags.clear
    let writeAddress = c.multiply(writeActive, space+beforeDepth-flags.clear)
    let writeFloor = c.multiply(flags.controlPush, beforeHeight)+c.multiply(flags.clear, event.floor)
    result.add MemoryAccessWires(active: writeActive, write: writeActive,
      address: writeAddress, value: writeFloor.scale(scalar(2))+flags.clear)
    beforeDepth = row.depth
    beforeHeight = event.height
  c.assertEqual(beforeDepth, constant(0))
  c.assertEqual(functionOpen, constant(0))
  when defined(zkbuildValidationEventAudit):
    c.validationStageRecords.add ValidationStageAudit(kind: 2,firstFunction: copyAuditExpressions([firstFunctionIndex])[0],
      rows: captureControlRows(rows),flags: captureEventFlags(operand.flags),inputs: captureEventAccesses(operand.accesses),
      outputs: captureEventAccesses(result),program: c.endSourceProgram(auditMarker))

proc buildStackMemoryWitness*(rows: openArray[ControlEventRow]): StackMemoryWitness =
  var operands: seq[OperandEventRow]
  for row in rows: operands.add row.operand
  result.operand = buildMemoryWitness(operandEventAccesses(operands))
  result.control = buildMemoryWitness(controlEventAccesses(rows))

proc constrainValidationStacks*(c: var Circuit, rows: openArray[ControlEventWires],
    witness: StackMemoryWitness, firstFunctionIndex: Linear) =
  ## Compose from the same event wires, so callers cannot accidentally supply
  ## control selectors or memory accesses from another transcript.
  var operands: seq[OperandEventWires]
  for row in rows: operands.add row.operand
  let projection = c.constrainOperandEventProjection(operands)
  let control = c.constrainControlEvents(rows, projection, firstFunctionIndex)
  discard c.constrainMemory(projection.accesses, witness.operand, 64, 3)
  discard c.constrainMemory(control, witness.control, 64, 33)
