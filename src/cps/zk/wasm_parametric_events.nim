## Parameter-dependent select/reference stack effects. Compose with the
## instruction schedule and authenticated operand stack from the same rows.
import ../wasm/types
import r1cs, range_check
import wasm_instruction_events, wasm_operand_events

proc constrainParametricEvents*(c: var Circuit, rows: openArray[InstructionEventWires],
    primary: openArray[Linear], operand: OperandEventProjection) =
  if rows.len == 0 or rows.len != primary.len or rows.len != operand.flags.len:
    raise newException(ValueError, "parametric event dimensions differ")
  when defined(zkbuildValidationEventAudit):
    let auditMarker = c.beginSourceProgram()
  var pops, pushes, first, second, declared = constant(0)
  for i, row in rows:
    let flags = operand.flags[i]
    let untyped = c.zeroIndicator(row.opcode-constant(ord(opSelect)))
    let typed = c.zeroIndicator(row.opcode-constant(ord(opSelectTyped)))
    let reference = c.zeroIndicator(row.opcode-constant(ord(opRefNull)))
    let selectOp = untyped+typed
    let present = selectOp+reference
    let reset = flags.functionBegin+flags.instructionBegin
    discard c.constrainUnsigned(primary[i], 32)
    c.constrain(constant(1)-flags.instructionBegin, primary[i], constant(0))
    var validType, tag: Linear
    var references: Linear
    for index, code in [0x7f, 0x7e, 0x7d, 0x7c, 0x7b, 0x70, 0x6f]:
      let selected = c.zeroIndicator(primary[i]-constant(code))
      validType = validType+selected
      tag = tag+selected.scale(scalar(index))
      if index >= 5: references = references+selected
    c.constrain(c.multiply(flags.instructionBegin, typed), constant(1)-validType, constant(0))
    c.constrain(c.multiply(flags.instructionBegin, reference), constant(1)-references, constant(0))
    c.constrain(c.multiply(flags.instructionBegin, untyped), primary[i], constant(0))
    declared = c.selectWire(reset, tag, declared)
    pops = c.selectWire(reset, constant(0), pops)
    pushes = c.selectWire(reset, constant(0), pushes)
    first = c.selectWire(reset, constant(0), first)
    second = c.selectWire(reset, constant(0), second)
    let pop = c.multiply(present, flags.operandPop)
    let push = c.multiply(present, flags.operandPush)
    let index0 = c.zeroIndicator(pops)
    let index1 = c.zeroIndicator(pops-constant(1))
    let index2 = c.zeroIndicator(pops-constant(2))
    c.constrain(pop, constant(1)-selectOp, constant(0))
    c.constrain(pop, constant(1)-index0-index1-index2, constant(0))
    c.constrain(pop, pushes, constant(0))
    let condition = c.multiply(pop, index0)
    let valuePop = pop-condition
    let actual = row.control.operand.valueType
    let unknown = c.zeroIndicator(actual-constant(7))
    c.constrain(condition, constant(1)-unknown-c.zeroIndicator(actual), constant(0))
    let declaredPop = c.multiply(typed, valuePop)
    c.constrain(c.multiply(declaredPop, constant(1)-unknown), actual-declared, constant(0))
    let inferredPop = c.multiply(untyped, valuePop)
    c.constrain(inferredPop, c.zeroIndicator(actual-constant(5))+c.zeroIndicator(actual-constant(6)), constant(0))
    let firstPop = c.multiply(pop, index1)
    let secondPop = c.multiply(pop, index2)
    first = c.selectWire(firstPop, actual, first)
    second = c.selectWire(secondPop, actual, second)
    let firstUnknown = c.zeroIndicator(first-constant(7))
    let bothKnown = c.multiply(constant(1)-firstUnknown, constant(1)-unknown)
    c.constrain(c.multiply(c.multiply(untyped, secondPop), bothKnown), first-actual, constant(0))
    let inferred = c.selectWire(firstUnknown, second, first)
    let expected = c.multiply(untyped, inferred)+c.multiply(typed+reference, declared)
    c.constrain(push, actual-expected, constant(0))
    c.constrain(push, pops-selectOp.scale(scalar(3)), constant(0))
    c.constrain(push, pushes, constant(0))
    c.constrain(present, flags.controlPush+flags.controlPop+flags.clear+flags.labelCheck, constant(0))
    pops = c.materialize(pops+pop)
    pushes = c.materialize(pushes+push)
    let finish = c.multiply(present, flags.instructionEnd)
    c.constrain(finish, pops-selectOp.scale(scalar(3)), constant(0))
    c.constrain(finish, pushes-constant(1), constant(0))

  when defined(zkbuildValidationEventAudit):
    var inputs: seq[seq[Linear]]
    for value in primary: inputs.add copyAuditExpressions([value])
    c.validationStageRecords.add ValidationStageAudit(kind: 4,rows: captureInstructionRows(rows),
      flags: captureEventFlags(operand.flags),inputs: inputs,program: c.endSourceProgram(auditMarker))
