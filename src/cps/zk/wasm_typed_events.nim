## Composed partial validation relation: authenticated stacks, fixed signatures,
## and module-backed local/global/table types. Binary binding is still required.
import r1cs, memory_consistency
import wasm_instruction_events, wasm_operand_events, wasm_control_events
import wasm_type_environment, wasm_variable_events
import wasm_signature_environment, wasm_call_events

proc constrainTypedValidationEvents*(c: var Circuit, rows: openArray[InstructionEventWires],
    environment: TypeEnvironmentWires, immediates: openArray[Linear],
    typeWitness: TypeEnvironmentWitness, stackWitness: StackMemoryWitness,
    firstFunctionIndex: Linear) =
  var operands: seq[OperandEventWires]
  var controls: seq[ControlEventWires]
  var selectors: seq[VariableSelectors]
  for row in rows:
    operands.add row.control.operand
    controls.add row.control
    selectors.add c.variableSelectors(row.opcode)
  let projection = c.constrainOperandEventProjection(operands)
  let control = c.constrainControlEvents(controls, projection, firstFunctionIndex)
  c.constrainInstructionEvents(rows, projection)
  let declared = c.constrainTypeEnvironment(environment, rows, immediates, projection, typeWitness, selectors)
  c.constrainVariableEvents(rows, projection, selectors, declared)
  discard c.constrainMemory(projection.accesses, stackWitness.operand, 64, 3)
  discard c.constrainMemory(control, stackWitness.control, 64, 33)

proc constrainValidationWithCalls*(c: var Circuit, rows: openArray[InstructionEventWires],
    environment: TypeEnvironmentWires, primary, secondary: openArray[Linear],
    typeWitness: TypeEnvironmentWitness, signatures: SignatureEnvironmentWires,
    signatureWitness: SignatureEnvironmentWitness, stackWitness: StackMemoryWitness,
    firstFunctionIndex: Linear) =
  ## Extends the partial relation with normal and tail-call signatures. Raw
  ## binary/module binding and authenticated control signatures remain open.
  var operands: seq[OperandEventWires]
  var controls: seq[ControlEventWires]
  var selectors: seq[VariableSelectors]
  for row in rows:
    operands.add row.control.operand
    controls.add row.control
    selectors.add c.variableSelectors(row.opcode)
  let projection = c.constrainOperandEventProjection(operands)
  let control = c.constrainControlEvents(controls, projection, firstFunctionIndex)
  c.constrainInstructionEvents(rows, projection)
  let declared = c.constrainTypeEnvironment(environment, rows, primary, projection, typeWitness, selectors)
  c.constrainVariableEvents(rows, projection, selectors, declared)
  c.constrainCallEvents(rows, primary, secondary, projection, signatures, environment.objects, signatureWitness)
  discard c.constrainMemory(projection.accesses, stackWitness.operand, 64, 3)
  discard c.constrainMemory(control, stackWitness.control, 64, 33)
