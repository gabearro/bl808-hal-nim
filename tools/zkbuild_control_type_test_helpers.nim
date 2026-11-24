import cps/zk/[r1cs, read_only_memory, memory_consistency, wasm_operand_events,
  wasm_control_events, wasm_instruction_events, wasm_type_environment,
  wasm_signature_environment, wasm_indexed_signatures, wasm_signature_frames,
  wasm_control_typing, wasm_structured_validation, wasm_typed_events]

import cps/zk/wasm_immediates
export wasm_immediates

proc allocate(c: var Circuit, entries: openArray[ReadOnlyEntry]): seq[ReadOnlyWires] =
  for entry in entries:
    result.add ReadOnlyWires(active: c.publicInput(scalar(ord(entry.active))),
      address: c.publicInput(scalar(entry.address)), value: c.publicInput(scalar(entry.value)))

proc buildControlTypes*(rows: openArray[InstructionEventRow], environment: TypeEnvironment,
    signatures: SignatureEnvironment, indexed: IndexedSignatureEnvironment,
    p, s: openArray[uint32], pads: openArray[uint64], firstFunction = 0'u32,
    full = false, binding = true): Circuit =
  result = initCircuit(reuseRangeWitnesses = binding)
  let first = result.publicInput(scalar(firstFunction))
  let typeWires = TypeEnvironmentWires(locals: result.allocate(environment.locals), objects: result.allocate(environment.objects))
  var signatureWires = SignatureEnvironmentWires()
  for i, entry in signatures.signatures:
    signatureWires.signatures.add ReadOnlyWires(active: result.publicInput(scalar(ord(entry.active))),
      address: result.publicInput(scalar(entry.address)), value: result.publicInput(scalar(entry.value)))
    signatureWires.typeIndices.add result.publicInput(scalar(signatures.typeIndices[i]))
  signatureWires.nodes = result.allocate(signatures.nodes)
  let indexWires = IndexedSignatureWires(lengths: result.allocate(indexed.lengths),
    members: result.allocate(indexed.members), singletons: result.allocate(indexed.singletons))
  var wires: seq[InstructionEventWires]
  var operands: seq[OperandEventWires]
  var controls: seq[ControlEventWires]
  var controlValues: seq[ControlEventRow]
  var primary, secondary, blockPads: seq[Linear]
  for i, row in rows:
    let e = row.control.operand
    let operand = OperandEventWires(kind: result.publicInput(scalar(e.kind)),
      functionIndex: result.publicInput(scalar(e.functionIndex)), height: result.publicInput(scalar(e.height)),
      floor: result.publicInput(scalar(e.floor)), valueType: result.publicInput(scalar(e.valueType)),
      polymorphic: result.publicInput(scalar(ord(e.polymorphic))), unreachable: result.publicInput(scalar(ord(e.unreachable))))
    let control = ControlEventWires(operand: operand, depth: result.publicInput(scalar(row.control.depth)))
    wires.add InstructionEventWires(control: control, opcode: result.publicInput(scalar(row.opcode)), pc: result.publicInput(scalar(row.pc)))
    primary.add result.publicInput(scalar(p[i]))
    secondary.add result.publicInput(scalar(s[i]))
    blockPads.add result.publicInput(scalar(pads[i]))
    operands.add operand
    controls.add control
    controlValues.add row.control
  var stacks: StackMemoryWitness
  try: stacks = buildStackMemoryWitness(controlValues)
  except ValueError:
    stacks.operand = buildMemoryWitness(newSeq[MemoryAccess](rows.len))
    stacks.control = buildMemoryWitness(newSeq[MemoryAccess](2*rows.len))
  if not binding:
    result.constrainValidationWithCalls(wires, typeWires, primary, secondary,
      buildTypeEnvironmentWitness(environment, rows, p), signatureWires,
      buildSignatureWitness(signatures, environment.objects, rows, p, s), stacks, first)
  elif full:
    let frames = buildSignatureFrameWitness(rows, p, pads)
    let witness = StructuredValidationWitness(stacks: stacks,
      types: buildTypeEnvironmentWitness(environment, rows, p),
      calls: buildSignatureWitness(signatures, environment.objects, rows, p, s), frames: frames,
      control: buildControlTypingWitness(signatures, indexed, rows, frames))
    result.constrainStructuredValidation(wires, primary, secondary, blockPads,
      typeWires, signatureWires, indexWires, first, witness)
  else:
    let projection = result.constrainOperandEventProjection(operands)
    let controlMemory = result.constrainControlEvents(controls, projection, first)
    result.constrainInstructionEvents(wires, projection)
    let frameWitness = buildSignatureFrameWitness(rows, p, pads)
    let frameProjection = result.constrainSignatureFrames(wires, primary, blockPads, projection, frameWitness)
    result.constrainControlTyping(wires, projection, frameProjection, signatureWires, indexWires,
      buildControlTypingWitness(signatures, indexed, rows, frameWitness))
    discard result.constrainMemory(projection.accesses, stacks.operand, 64, 3)
    discard result.constrainMemory(controlMemory, stacks.control, 64, 33)
