## Partial structured validation relation. All executable components are Nim.
## Raw binary binding, br_table targets, catch clauses, and remaining module
## rules are still required before general kernel admission.
import r1cs, memory_consistency
import wasm_instruction_events, wasm_operand_events, wasm_control_events
import wasm_type_environment, wasm_variable_events, wasm_signature_environment, wasm_call_events
import wasm_indexed_signatures, wasm_signature_frames, wasm_control_typing
import wasm_parametric_events

type StructuredValidationWitness* = object
  stacks*: StackMemoryWitness
  types*: TypeEnvironmentWitness
  calls*: SignatureEnvironmentWitness
  frames*: SignatureFrameWitness
  control*: ControlTypingWitness

proc buildStructuredValidationWitness*(environment: TypeEnvironment, signatures: SignatureEnvironment,
    indexed: IndexedSignatureEnvironment, rows: openArray[InstructionEventRow],
    primary, secondary: openArray[uint32], pads: openArray[uint64]): StructuredValidationWitness =
  var controls: seq[ControlEventRow]
  for row in rows: controls.add row.control
  result.stacks = buildStackMemoryWitness(controls)
  result.types = buildTypeEnvironmentWitness(environment, rows, primary)
  result.calls = buildSignatureWitness(signatures, environment.objects, rows, primary, secondary)
  result.frames = buildSignatureFrameWitness(rows, primary, pads)
  result.control = buildControlTypingWitness(signatures, indexed, rows, result.frames)

proc constrainStructuredValidation*(c: var Circuit, rows: openArray[InstructionEventWires],
    primary, secondary, pads: openArray[Linear], environment: TypeEnvironmentWires,
    signatures: SignatureEnvironmentWires, indexed: IndexedSignatureWires,
    firstFunctionIndex: Linear, witness: StructuredValidationWitness, reuseRanges = true) =
  # This new profile shares existing range certificates. Other entry points
  # retain their original matrix construction unless explicitly opted in.
  c.reuseRangeWitnesses = reuseRanges
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
  let declared = c.constrainTypeEnvironment(environment, rows, primary, projection, witness.types, selectors)
  c.constrainVariableEvents(rows, projection, selectors, declared)
  c.constrainCallEvents(rows, primary, secondary, projection, signatures, environment.objects, witness.calls)
  c.constrainParametricEvents(rows, primary, projection)
  let frames = c.constrainSignatureFrames(rows, primary, pads, projection, witness.frames)
  c.constrainControlTyping(rows, projection, frames, signatures, indexed, witness.control)
  discard c.constrainMemory(projection.accesses, witness.stacks.operand, 64, 3)
  discard c.constrainMemory(control, witness.stacks.control, 64, 33)
