import cps/zk/[r1cs, memory_consistency, read_only_memory, wasm_operand_events,
  wasm_control_events, wasm_instruction_events, wasm_type_environment,
  wasm_variable_events, wasm_typed_events]

proc buildTyped*(rows: openArray[InstructionEventRow], environment: TypeEnvironment,
    immediates: openArray[uint32], firstFunction = 0'u32, full = false): Circuit =
  result = initCircuit()
  let first = result.publicInput(scalar(firstFunction))
  var environmentWires: TypeEnvironmentWires
  for entry in environment.locals:
    environmentWires.locals.add ReadOnlyWires(active: result.publicInput(scalar(ord(entry.active))),
      address: result.publicInput(scalar(entry.address)), value: result.publicInput(scalar(entry.value)))
  for entry in environment.objects:
    environmentWires.objects.add ReadOnlyWires(active: result.publicInput(scalar(ord(entry.active))),
      address: result.publicInput(scalar(entry.address)), value: result.publicInput(scalar(entry.value)))
  var wires: seq[InstructionEventWires]
  var operands: seq[OperandEventWires]
  var controlValues: seq[ControlEventRow]
  var primary: seq[Linear]
  for i, row in rows:
    let e = row.control.operand
    let operand = OperandEventWires(kind: result.publicInput(scalar(e.kind)),
      functionIndex: result.publicInput(scalar(e.functionIndex)), height: result.publicInput(scalar(e.height)),
      floor: result.publicInput(scalar(e.floor)), valueType: result.publicInput(scalar(e.valueType)),
      polymorphic: result.publicInput(scalar(ord(e.polymorphic))),
      unreachable: result.publicInput(scalar(ord(e.unreachable))))
    let control = ControlEventWires(operand: operand, depth: result.publicInput(scalar(row.control.depth)))
    wires.add InstructionEventWires(control: control, opcode: result.publicInput(scalar(row.opcode)),
      pc: result.publicInput(scalar(row.pc)))
    primary.add result.publicInput(scalar(immediates[i]))
    operands.add operand
    controlValues.add row.control
  let witness = buildTypeEnvironmentWitness(environment, rows, immediates)
  if full:
    var stacks: StackMemoryWitness
    try: stacks = buildStackMemoryWitness(controlValues)
    except ValueError:
      stacks.operand = buildMemoryWitness(newSeq[MemoryAccess](rows.len))
      stacks.control = buildMemoryWitness(newSeq[MemoryAccess](2*rows.len))
    result.constrainTypedValidationEvents(wires, environmentWires, primary, witness, stacks, first)
  else:
    let projection = result.constrainOperandEventProjection(operands)
    result.constrainInstructionEvents(wires, projection)
    var selectors: seq[VariableSelectors]
    for row in wires: selectors.add result.variableSelectors(row.opcode)
    let declared = result.constrainTypeEnvironment(environmentWires, wires, primary, projection, witness, selectors)
    result.constrainVariableEvents(wires, projection, selectors, declared)
