import cps/zk/[r1cs, memory_consistency, read_only_memory, wasm_operand_events,
  wasm_control_events, wasm_instruction_events, wasm_type_environment,
  wasm_signature_environment, wasm_call_events, wasm_typed_events]

proc buildCalls*(rows: openArray[InstructionEventRow], environment: TypeEnvironment,
    signatures: SignatureEnvironment, primary, secondary: openArray[uint32],
    firstFunction = 1'u32, full = false): Circuit =
  result = initCircuit()
  let first = result.publicInput(scalar(firstFunction))
  var typeWires: TypeEnvironmentWires
  var signatureWires: SignatureEnvironmentWires
  for entry in environment.locals:
    typeWires.locals.add ReadOnlyWires(active: result.publicInput(scalar(ord(entry.active))),
      address: result.publicInput(scalar(entry.address)), value: result.publicInput(scalar(entry.value)))
  for entry in environment.objects:
    typeWires.objects.add ReadOnlyWires(active: result.publicInput(scalar(ord(entry.active))),
      address: result.publicInput(scalar(entry.address)), value: result.publicInput(scalar(entry.value)))
  for i, entry in signatures.signatures:
    signatureWires.signatures.add ReadOnlyWires(active: result.publicInput(scalar(ord(entry.active))),
      address: result.publicInput(scalar(entry.address)), value: result.publicInput(scalar(entry.value)))
    signatureWires.typeIndices.add result.publicInput(scalar(signatures.typeIndices[i]))
  for entry in signatures.nodes:
    signatureWires.nodes.add ReadOnlyWires(active: result.publicInput(scalar(ord(entry.active))),
      address: result.publicInput(scalar(entry.address)), value: result.publicInput(scalar(entry.value)))
  var wires: seq[InstructionEventWires]
  var operands: seq[OperandEventWires]
  var controls: seq[ControlEventRow]
  var p, s: seq[Linear]
  for i, row in rows:
    let e = row.control.operand
    let operand = OperandEventWires(kind: result.publicInput(scalar(e.kind)),
      functionIndex: result.publicInput(scalar(e.functionIndex)), height: result.publicInput(scalar(e.height)),
      floor: result.publicInput(scalar(e.floor)), valueType: result.publicInput(scalar(e.valueType)),
      polymorphic: result.publicInput(scalar(ord(e.polymorphic))), unreachable: result.publicInput(scalar(ord(e.unreachable))))
    let control = ControlEventWires(operand: operand, depth: result.publicInput(scalar(row.control.depth)))
    wires.add InstructionEventWires(control: control, opcode: result.publicInput(scalar(row.opcode)), pc: result.publicInput(scalar(row.pc)))
    p.add result.publicInput(scalar(primary[i]))
    s.add result.publicInput(scalar(secondary[i]))
    operands.add operand
    controls.add row.control
  let witness = buildSignatureWitness(signatures, environment.objects, rows, primary, secondary)
  if full:
    var stacks: StackMemoryWitness
    try: stacks = buildStackMemoryWitness(controls)
    except ValueError:
      stacks.operand = buildMemoryWitness(newSeq[MemoryAccess](rows.len))
      stacks.control = buildMemoryWitness(newSeq[MemoryAccess](2*rows.len))
    let typeWitness = buildTypeEnvironmentWitness(environment, rows, primary)
    result.constrainValidationWithCalls(wires, typeWires, p, s, typeWitness,
      signatureWires, witness, stacks, first)
  else:
    let projection = result.constrainOperandEventProjection(operands)
    result.constrainInstructionEvents(wires, projection)
    result.constrainCallEvents(wires, p, s, projection, signatureWires, typeWires.objects, witness)
