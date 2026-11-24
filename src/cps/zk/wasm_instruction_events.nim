## Instruction scheduling and fixed-signature type discipline over events.
## This composes with both authenticated stacks. Dynamic opcode signatures,
## module/environment lookups, and raw binary binding remain separate work.
import r1cs, range_check, static_lookup, memory_consistency
import ../wasm/[types, validate]
import wasm_operand_events, wasm_control_events

type
  InstructionEventRow* = object
    control*: ControlEventRow
    opcode*: uint16
    pc*: uint32
  InstructionEventWires* = object
    control*: ControlEventWires
    opcode*, pc*: Linear

proc buildInstructionEventRows*(events: openArray[ValidationEvent],
    capacity = 0): seq[InstructionEventRow] =
  let controls = buildControlEventRows(events, capacity)
  for i, control in controls:
    var row = InstructionEventRow(control: control)
    if i < events.len:
      row.opcode = uint16(ord(events[i].opcode))
      row.pc = events[i].instructionIndex
    result.add row

proc constrainInstructionEvents*(c: var Circuit, rows: openArray[InstructionEventWires],
    operand: OperandEventProjection, labelChecks = false, catchChecks = false) =
  ## The supplied selectors must originate from these same operand row wires.
  if rows.len == 0 or operand.flags.len != rows.len:
    raise newException(ValueError, "instruction-event dimensions do not match")
  when defined(zkbuildValidationEventAudit):
    let auditMarker = c.beginSourceProgram()
  var opened = constant(0)
  var rootPending = constant(0)
  var nextPc = constant(0)
  var opcode = constant(ord(opBlock))
  var pops = constant(0)
  var pushes = constant(0)
  var clears = constant(0)
  for i, row in rows:
    let flags = operand.flags[i]
    let event = row.control.operand
    let begin = flags.instructionBegin
    let finish = flags.instructionEnd
    let newInstruction = flags.functionBegin+begin
    discard c.constrainUnsigned(row.pc, 32)
    c.constrain(rootPending, constant(1)-flags.controlPush, constant(0))
    c.constrain(rootPending, opened, constant(0))
    c.constrain(begin, opened, constant(0))
    c.constrain(finish, constant(1)-opened, constant(0))
    c.constrain(flags.functionBegin+flags.functionEnd+flags.padding, opened, constant(0))
    var middle = flags.operandPush+flags.operandPop+flags.controlPush+flags.controlPop+flags.clear
    if labelChecks:
      middle = middle+flags.labelCheck
      if catchChecks:
        c.constrain(flags.labelCheck, constant(1)-c.zeroIndicator(row.opcode-constant(ord(opBrTable)))-
          c.zeroIndicator(row.opcode-constant(ord(opTryTable))), constant(0))
      else: c.constrain(flags.labelCheck, row.opcode-constant(ord(opBrTable)), constant(0))
    c.constrain(middle-rootPending, constant(1)-opened, constant(0))

    let pc = c.selectWire(flags.functionBegin, constant(0), nextPc)
    c.constrain(constant(1)-flags.padding, row.pc-pc+flags.functionEnd, constant(0))
    c.constrain(flags.padding, row.pc, constant(0))
    nextPc = c.materialize(pc+finish)
    opcode = c.selectWire(newInstruction, row.opcode, opcode)
    c.constrain(constant(1)-flags.padding, row.opcode-opcode, constant(0))
    c.constrain(flags.functionBegin, row.opcode-constant(ord(opBlock)), constant(0))
    c.constrain(flags.functionEnd, row.opcode-constant(ord(opEnd)), constant(0))
    c.constrain(flags.padding, row.opcode, constant(0))

    let beforePops = c.selectWire(newInstruction, constant(0), pops)
    let beforePushes = c.selectWire(newInstruction, constant(0), pushes)
    let beforeClears = c.selectWire(newInstruction, constant(0), clears)
    let rule = c.constrainStaticRule(row.opcode, beforePops, event.valueType)
    let typedPop = c.multiply(rule.present, flags.operandPop)
    let typedPush = c.multiply(rule.present, flags.operandPush)
    c.constrain(typedPop, beforePops-rule.inputIndex, constant(0))
    c.constrain(typedPop, constant(1)-rule.allowedInput, constant(0))
    c.constrain(typedPop, beforePushes, constant(0))
    c.constrain(typedPush, event.valueType-rule.outputType, constant(0))
    c.constrain(typedPush, constant(1)-rule.outputCount, constant(0))
    c.constrain(typedPush, beforePops-rule.inputCount, constant(0))
    c.constrain(typedPush, beforePushes, constant(0))
    c.constrain(rule.present, flags.controlPush+flags.controlPop, constant(0))
    let typedClear = c.multiply(rule.present, flags.clear)
    c.constrain(typedClear, constant(1)-rule.clearCount, constant(0))
    c.constrain(typedClear, beforeClears, constant(0))
    let typedEnd = c.multiply(rule.present, finish)
    c.constrain(typedEnd, beforePops-rule.inputCount, constant(0))
    c.constrain(typedEnd, beforePushes-rule.outputCount, constant(0))
    c.constrain(typedEnd, beforeClears-rule.clearCount, constant(0))
    pops = c.materialize(beforePops+flags.operandPop)
    pushes = c.materialize(beforePushes+flags.operandPush)
    clears = c.materialize(beforeClears+flags.clear)
    opened = c.materialize(opened+begin-finish)
    rootPending = flags.functionBegin
  c.assertEqual(opened, constant(0))
  c.assertEqual(rootPending, constant(0))
  when defined(zkbuildValidationEventAudit):
    c.validationStageRecords.add ValidationStageAudit(kind: 3,rows: captureInstructionRows(rows),
      flags: captureEventFlags(operand.flags),program: c.endSourceProgram(auditMarker))

proc constrainValidationEventTrace*(c: var Circuit, rows: openArray[InstructionEventWires],
    witness: StackMemoryWitness, firstFunctionIndex: Linear) =
  ## Partial full-module relation: event schedule, authenticated operand/control
  ## stacks, and fixed opcode signatures. This is not kernel admission.
  var operands: seq[OperandEventWires]
  var controls: seq[ControlEventWires]
  for row in rows:
    operands.add row.control.operand
    controls.add row.control
  let projection = c.constrainOperandEventProjection(operands)
  let control = c.constrainControlEvents(controls, projection, firstFunctionIndex)
  c.constrainInstructionEvents(rows, projection)
  discard c.constrainMemory(projection.accesses, witness.operand, 64, 3)
  discard c.constrainMemory(control, witness.control, 64, 33)
