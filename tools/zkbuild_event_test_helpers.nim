## Shared circuit wiring for event-proof tests. No semantic oracle lives here.
import cps/zk/[r1cs, memory_consistency, wasm_operand_events, wasm_control_events, wasm_instruction_events]

proc build*(rows: openArray[InstructionEventRow], full = false, instruction = true): Circuit =
  result = initCircuit()
  let first = result.publicInput(scalar(0))
  var wires: seq[InstructionEventWires]
  var controls: seq[ControlEventWires]
  var operands: seq[OperandEventWires]
  var controlValues: seq[ControlEventRow]
  for row in rows:
    let e = row.control.operand
    let operand = OperandEventWires(kind: result.publicInput(scalar(e.kind)),
      functionIndex: result.publicInput(scalar(e.functionIndex)), height: result.publicInput(scalar(e.height)),
      floor: result.publicInput(scalar(e.floor)), valueType: result.publicInput(scalar(e.valueType)),
      polymorphic: result.publicInput(scalar(ord(e.polymorphic))),
      unreachable: result.publicInput(scalar(ord(e.unreachable))))
    let control = ControlEventWires(operand: operand, depth: result.publicInput(scalar(row.control.depth)))
    wires.add InstructionEventWires(control: control, opcode: result.publicInput(scalar(row.opcode)),
      pc: result.publicInput(scalar(row.pc)))
    controls.add control
    operands.add operand
    controlValues.add row.control
  if full:
    var witness: StackMemoryWitness
    try: witness = buildStackMemoryWitness(controlValues)
    except ValueError:
      witness.operand = buildMemoryWitness(newSeq[MemoryAccess](rows.len))
      witness.control = buildMemoryWitness(newSeq[MemoryAccess](2*rows.len))
    if instruction: result.constrainValidationEventTrace(wires, witness, first)
    else: result.constrainValidationStacks(controls, witness, first)
  else:
    let projection = result.constrainOperandEventProjection(operands)
    result.constrainInstructionEvents(wires, projection)

