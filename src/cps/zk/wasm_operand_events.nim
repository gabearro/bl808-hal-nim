## Operand-event constraints for the general WASM proof relation.
## Each row derives its RAM record inside R1CS. wasm_control_events can bind
## its contexts to frame memory; opcode rules and module bytes remain separate.
import ../wasm/validate
import r1cs, range_check, memory_consistency, permutation

const OperandPaddingKind* = 15'u8
const EventKinds = [ord(veFunctionBegin), ord(veInstructionBegin), ord(veOperandPush),
  ord(veOperandPop), ord(veControlPush), ord(veControlPop), ord(veUnreachable),
  ord(veInstructionEnd), ord(veFunctionEnd), int(OperandPaddingKind)]
const LabelEventKinds = [0, 1, 2, 3, 4, 5, 6, 7, 8, ord(veLabelCheck), int(OperandPaddingKind)]

static:
  for i in 0..<EventKinds.high: doAssert EventKinds[i] == i
  for i in 0..<LabelEventKinds.high: doAssert LabelEventKinds[i] == i
  doAssert ord(low(StackVal)) == 0 and ord(high(StackVal)) == 7
  doAssert ord(svUnknown) == 7

type
  OperandEventRow* = object
    kind*: uint8
    functionIndex*, height*, floor*: uint32
    valueType*: uint8
    polymorphic*, unreachable*: bool
  OperandEventWires* = object
    kind*, functionIndex*, height*, floor*, valueType*, polymorphic*, unreachable*: Linear
  OperandEventFlags* = object
    functionBegin*, functionEnd*, controlPush*, controlPop*, clear*, padding*: Linear
    instructionBegin*, instructionEnd*, operandPush*, operandPop*: Linear
    labelCheck*: Linear
  OperandEventProjection* = object
    accesses*: seq[MemoryAccessWires]
    flags*: seq[OperandEventFlags]

proc buildOperandEventRows*(events: openArray[ValidationEvent], capacity = 0): seq[OperandEventRow] =
  var controls: seq[tuple[floor: uint32, unreachable: bool]]
  for event in events:
    if event.operandHeight < 0 or uint64(event.operandHeight) > uint64(uint32.high) or
        event.frameHeight < 0 or uint64(event.frameHeight) > uint64(uint32.high):
      raise newException(ValueError, "operand-event height is out of range")
    var row = OperandEventRow(kind: uint8(ord(event.kind)), functionIndex: event.functionIndex,
      height: uint32(event.operandHeight), valueType: uint8(ord(event.valueType)),
      polymorphic: event.polymorphic)
    if controls.len > 0:
      row.floor = controls[^1].floor
      row.unreachable = controls[^1].unreachable
    result.add row
    case event.kind
    of veControlPush:
      controls.add (uint32(event.frameHeight), event.frameUnreachable)
    of veControlPop:
      if controls.len == 0: raise newException(ValueError, "missing operand control context")
      controls.setLen(controls.len-1)
    of veUnreachable:
      if controls.len == 0: raise newException(ValueError, "missing unreachable control context")
      controls[^1].unreachable = true
    else: discard
  var size = capacity
  if size == 0:
    size = 1
    while size < result.len:
      if size > int.high div 2: raise newException(ValueError, "operand-event capacity overflows")
      size *= 2
  discard routeSwitchCount(size)
  if result.len > size: raise newException(ValueError, "operand-event capacity is too small")
  while result.len < size:
    result.add OperandEventRow(kind: OperandPaddingKind, valueType: uint8(ord(svUnknown)))

proc operandEventAccesses*(rows: openArray[OperandEventRow]): seq[MemoryAccess] =
  ## Honest private witness only. The circuit derives this projection again.
  for row in rows:
    var access: MemoryAccess
    if row.kind == uint8(ord(veOperandPush)) or
        (row.kind == uint8(ord(veOperandPop)) and not row.polymorphic):
      let push = row.kind == uint8(ord(veOperandPush))
      if push and row.height == 0:
        raise newException(ValueError, "operand-event push underflows its slot index")
      access.active = true
      access.write = push
      access.address = (uint64(row.functionIndex) shl 32) or (uint64(row.height)-uint64(ord(push)))
      access.value = uint64(row.valueType)
    result.add access

proc selectors(c: var Circuit, kind: Linear, codes: openArray[int]): seq[Linear] =
  let value = kind.evaluate(c.values)
  var total, packed: Linear
  for code in codes:
    let selected = c.bit(value.equals(scalar(code)))
    result.add selected
    total = total+selected
    if code != 0: packed = packed+selected.scale(scalar(code))
  c.assertEqual(total, constant(1))
  c.assertEqual(kind, packed)

proc constrainOperandEventProjection*(c: var Circuit,
    rows: openArray[OperandEventWires], labelChecks = false): OperandEventProjection =
  ## Closed transcript with an initially empty operand stack. The matrix
  ## depends on row capacity alone. Padding is canonical and forms a suffix.
  if rows.len == 0: raise newException(ValueError, "empty operand-event circuit")
  when defined(zkbuildValidationEventAudit):
    let auditMarker = c.beginSourceProgram()
  var previousHeight = constant(0)
  var previousPadding = constant(0)
  for row in rows:
    let tags = if labelChecks: c.selectors(row.kind, LabelEventKinds)
      else: c.selectors(row.kind, EventKinds)
    let push = tags[ord(veOperandPush)]
    let pop = tags[ord(veOperandPop)]
    let clear = tags[ord(veUnreachable)]
    let padding = tags[^1]
    discard c.constrainUnsigned(row.functionIndex, 32)
    discard c.constrainUnsigned(row.height, 32)
    discard c.constrainUnsigned(row.floor, 32)
    discard c.constrainUnsigned(row.valueType, 3)
    c.constrainBoolean(row.polymorphic)
    c.constrainBoolean(row.unreachable)
    c.constrain(row.polymorphic, constant(1)-pop, constant(0))
    c.constrain(row.polymorphic, row.valueType-constant(ord(svUnknown)), constant(0))
    c.constrain(constant(1)-push-pop, row.valueType-constant(ord(svUnknown)), constant(0))
    c.constrain(row.polymorphic, previousHeight-row.floor, constant(0))
    c.constrain(row.polymorphic, constant(1)-row.unreachable, constant(0))
    let realPop = pop-row.polymorphic
    let available = c.multiply(pop+clear, previousHeight-row.floor)-realPop
    discard c.constrainUnsigned(available, 32)
    let discarded = c.multiply(clear, previousHeight-row.floor)
    c.assertEqual(row.height, previousHeight+push-realPop-discarded)
    c.constrain(tags[ord(veFunctionBegin)]+tags[ord(veFunctionEnd)], row.height, constant(0))
    c.constrain(previousPadding, constant(1)-padding, constant(0))
    c.constrain(padding, row.functionIndex, constant(0))
    c.constrain(padding, row.floor, constant(0))
    c.constrain(padding, row.unreachable, constant(0))
    let active = push+realPop
    let address = c.multiply(active,
      row.functionIndex.scale(scalar(1'u64 shl 32))+row.height-push)
    let value = c.multiply(active, row.valueType)
    result.accesses.add MemoryAccessWires(active: active, write: push, address: address, value: value)
    result.flags.add OperandEventFlags(functionBegin: tags[ord(veFunctionBegin)],
      functionEnd: tags[ord(veFunctionEnd)], controlPush: tags[ord(veControlPush)],
      controlPop: tags[ord(veControlPop)], clear: clear, padding: padding,
      instructionBegin: tags[ord(veInstructionBegin)], instructionEnd: tags[ord(veInstructionEnd)],
      operandPush: push, operandPop: pop,
      labelCheck: (if labelChecks: tags[ord(veLabelCheck)] else: constant(0)))
    previousHeight = row.height
    previousPadding = padding
  c.assertEqual(previousHeight, constant(0))
  when defined(zkbuildValidationEventAudit):
    c.validationStageRecords.add ValidationStageAudit(kind: 1,rows: captureOperandRows(rows),
      flags: captureEventFlags(result.flags),outputs: captureEventAccesses(result.accesses),
      program: c.endSourceProgram(auditMarker))

proc constrainOperandEvents*(c: var Circuit,
    rows: openArray[OperandEventWires]): seq[MemoryAccessWires] =
  c.constrainOperandEventProjection(rows).accesses
