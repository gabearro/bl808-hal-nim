## Type discipline for local/global/table instructions, composed with an
## authenticated type environment. This is still a partial WASM relation.
import r1cs, range_check, wasm_type_environment, wasm_instruction_events, wasm_operand_events

proc constrainVariableEvents*(c: var Circuit, rows: openArray[InstructionEventWires],
    operand: OperandEventProjection, selectors: openArray[VariableSelectors],
    declaredTypes: openArray[Linear]) =
  ## Selectors and declaredTypes must originate from the same row wires and
  ## constrainTypeEnvironment. A free declared-type annotation is insufficient.
  if rows.len != operand.flags.len or rows.len != selectors.len or rows.len != declaredTypes.len:
    raise newException(ValueError, "variable-event dimensions differ")
  when defined(zkbuildDynamicTypingAudit):
    let auditMarker = c.beginSourceProgram()
  var pops, pushes = constant(0)
  for i, row in rows:
    let flags = operand.flags[i]
    let s = selectors[i]
    let reset = flags.functionBegin+flags.instructionBegin
    let beforePops = c.selectWire(reset, constant(0), pops)
    let beforePushes = c.selectWire(reset, constant(0), pushes)
    let inputCount = s.localSet+s.localTee+s.globalSet+s.tableGet+
      (s.tableSet+s.tableGrow).scale(scalar(2))+s.tableFill.scale(scalar(3))
    let outputCount = s.localGet+s.localTee+s.globalGet+s.tableGet+s.tableGrow+s.tableSize
    let contextOutput = s.localGet+s.localTee+s.globalGet+s.tableGet
    let outputType = c.multiply(contextOutput, declaredTypes[i])
    let first = c.zeroIndicator(beforePops)
    let second = c.zeroIndicator(beforePops-constant(1))
    let contextInput = c.multiply(first, s.localSet+s.localTee+s.globalSet+s.tableSet)+
      c.multiply(second, s.tableGrow+s.tableFill)
    let inputType = c.multiply(contextInput, declaredTypes[i])
    let actual = row.control.operand.valueType
    let matches = c.zeroIndicator(actual-inputType)+c.zeroIndicator(actual-constant(7))
    let typedPop = c.multiply(s.present, flags.operandPop)
    let typedPush = c.multiply(s.present, flags.operandPush)
    c.constrain(typedPop, constant(1)-matches, constant(0))
    c.constrain(typedPop, beforePushes, constant(0))
    c.constrain(typedPush, actual-outputType, constant(0))
    c.constrain(typedPush, constant(1)-outputCount, constant(0))
    c.constrain(typedPush, beforePops-inputCount, constant(0))
    c.constrain(typedPush, beforePushes, constant(0))
    c.constrain(s.present, flags.controlPush+flags.controlPop+flags.clear, constant(0))
    let finish = c.multiply(s.present, flags.instructionEnd)
    c.constrain(finish, beforePops-inputCount, constant(0))
    c.constrain(finish, beforePushes-outputCount, constant(0))
    pops = c.materialize(beforePops+flags.operandPop)
    pushes = c.materialize(beforePushes+flags.operandPush)
  when defined(zkbuildDynamicTypingAudit):
    var audit = DynamicTypingStageAudit(kind: 2,rows: captureInstructionRows(rows),
      flags: captureEventFlags(operand.flags),selectors: captureVariableSelectors(selectors),
      program: c.endSourceProgram(auditMarker))
    for value in declaredTypes: audit.inputs.add copyAuditExpressions([value])
    c.dynamicTypingRecords.add audit
