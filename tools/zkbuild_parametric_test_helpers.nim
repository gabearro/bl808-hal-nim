import cps/zk/[r1cs, memory_consistency, wasm_operand_events, wasm_control_events,
  wasm_instruction_events, wasm_parametric_events]

proc buildParametric*(rows: openArray[InstructionEventRow], primary: openArray[uint32],
    binding = true): Circuit =
  result = initCircuit(reuseRangeWitnesses = true)
  let first = result.publicInput(scalar(0))
  var wires: seq[InstructionEventWires]
  var operands: seq[OperandEventWires]
  var controls: seq[ControlEventWires]
  var controlValues: seq[ControlEventRow]
  var immediates: seq[Linear]
  for i, row in rows:
    let e = row.control.operand
    let operand = OperandEventWires(kind: result.publicInput(scalar(e.kind)),
      functionIndex: result.publicInput(scalar(e.functionIndex)), height: result.publicInput(scalar(e.height)),
      floor: result.publicInput(scalar(e.floor)), valueType: result.publicInput(scalar(e.valueType)),
      polymorphic: result.publicInput(scalar(ord(e.polymorphic))), unreachable: result.publicInput(scalar(ord(e.unreachable))))
    let control = ControlEventWires(operand: operand, depth: result.publicInput(scalar(row.control.depth)))
    wires.add InstructionEventWires(control: control, opcode: result.publicInput(scalar(row.opcode)), pc: result.publicInput(scalar(row.pc)))
    immediates.add result.publicInput(scalar(primary[i]))
    operands.add operand
    controls.add control
    controlValues.add row.control
  let stacks = buildStackMemoryWitness(controlValues)
  let projection = result.constrainOperandEventProjection(operands)
  let memory = result.constrainControlEvents(controls, projection, first)
  result.constrainInstructionEvents(wires, projection)
  if binding: result.constrainParametricEvents(wires, immediates, projection)
  discard result.constrainMemory(projection.accesses, stacks.operand, 64, 3)
  discard result.constrainMemory(memory, stacks.control, 64, 33)
