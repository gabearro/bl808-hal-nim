import cps/wasm/[types, validate]
import cps/zk/[r1cs, read_only_memory, memory_consistency, wasm_operand_events,
  wasm_control_events, wasm_instruction_events, wasm_type_environment,
  wasm_signature_environment, wasm_indexed_signatures, wasm_signature_frames,
  wasm_control_typing, wasm_variable_events, wasm_call_events,
  wasm_branch_environment, wasm_branch_validation, wasm_parametric_events,
  wasm_memory_metadata, wasm_memory_validation, wasm_bulk_context, wasm_bulk_validation,
  wasm_reference_context, wasm_reference_validation, wasm_throw_events, wasm_throw_validation]
import zkbuild_control_type_test_helpers
export zkbuild_control_type_test_helpers

proc inputs(c: var Circuit, entries: openArray[ReadOnlyEntry]): seq[ReadOnlyWires] =
  for entry in entries:
    result.add ReadOnlyWires(active: c.publicInput(scalar(ord(entry.active))),
      address: c.publicInput(scalar(entry.address)), value: c.publicInput(scalar(entry.value)))

proc buildBranchTypes*(module: WasmModule, rows: openArray[InstructionEventRow],
    banks: BranchEnvironment, typed = true, cancelMetadata = false,
    memory: ptr MemoryEnvironment = nil, memoryBinding = true,
    bulk: ptr BulkEnvironment = nil, bulkBinding = true,
    references: ptr ReferenceEnvironment = nil, referenceBinding = true,
    tags: ptr TagEnvironment = nil, throwBinding = true): Circuit =
  if bulk != nil and memory == nil:
    raise newException(ValueError, "bulk validation requires memory metadata")
  if references != nil and bulk == nil:
    raise newException(ValueError, "reference validation requires bulk metadata")
  if tags != nil and references == nil:
    raise newException(ValueError, "throw validation requires reference metadata")
  result = initCircuit(reuseRangeWitnesses = true)
  var firstFunction = 0'u32
  for item in module.imports:
    if item.kind == ikFunc: inc firstFunction
  let im = instructionImmediates(module, rows, firstFunction)
  let environment = buildTypeEnvironment(module)
  let signatures = buildSignatureEnvironment(module, includeSingletons = true)
  let indexed = buildIndexedSignatures(signatures)
  let first = result.publicInput(scalar(firstFunction))
  let typeWires = TypeEnvironmentWires(locals: result.inputs(environment.locals), objects: result.inputs(environment.objects))
  var signatureWires = SignatureEnvironmentWires()
  for i, entry in signatures.signatures:
    signatureWires.signatures.add ReadOnlyWires(active: result.publicInput(scalar(ord(entry.active))),
      address: result.publicInput(scalar(entry.address)), value: result.publicInput(scalar(entry.value)))
    signatureWires.typeIndices.add result.publicInput(scalar(signatures.typeIndices[i]))
  signatureWires.nodes = result.inputs(signatures.nodes)
  let indexWires = IndexedSignatureWires(lengths: result.inputs(indexed.lengths),
    members: result.inputs(indexed.members), singletons: result.inputs(indexed.singletons))
  let branchWires = BranchEnvironmentWires(banks: result.inputs(banks.banks), nodes: result.inputs(banks.nodes))
  var memoryWires: MemoryEnvironmentWires
  if memory != nil:
    memoryWires.memoryCount = result.publicInput(scalar(memory[].memoryCount))
    memoryWires.vectorCounts = result.inputs(memory[].vectorCounts)
  var bulkWires: BulkEnvironmentWires
  if bulk != nil:
    bulkWires.hasDataCount = result.publicInput(scalar(ord(bulk[].hasDataCount)))
    bulkWires.dataCount = result.publicInput(scalar(bulk[].dataCount))
    bulkWires.declaredDataCount = result.publicInput(scalar(bulk[].declaredDataCount))
    bulkWires.elements = result.inputs(bulk[].elements)
  var referenceWires: ReferenceEnvironmentWires
  if references != nil:
    referenceWires.functionCount = result.publicInput(scalar(references[].functionCount))
    referenceWires.declarations = result.inputs(references[].declarations)
  var tagWires: TagEnvironmentWires
  if tags != nil:
    tagWires.tags = result.inputs(tags[].tags)
    for index in tags[].typeIndices: tagWires.typeIndices.add result.publicInput(scalar(index))
  var wires: seq[InstructionEventWires]
  var operands: seq[OperandEventWires]
  var controls: seq[ControlEventWires]
  var primary, secondary, pads: seq[Linear]
  for i, row in rows:
    let e = row.control.operand
    let operand = OperandEventWires(kind: result.publicInput(scalar(e.kind)),
      functionIndex: result.publicInput(scalar(e.functionIndex)), height: result.publicInput(scalar(e.height)),
      floor: result.publicInput(scalar(e.floor)), valueType: result.publicInput(scalar(e.valueType)),
      polymorphic: result.publicInput(scalar(ord(e.polymorphic))), unreachable: result.publicInput(scalar(ord(e.unreachable))))
    let control = ControlEventWires(operand: operand, depth: result.publicInput(scalar(row.control.depth)))
    wires.add InstructionEventWires(control: control, opcode: result.publicInput(scalar(row.opcode)), pc: result.publicInput(scalar(row.pc)))
    primary.add result.publicInput(scalar(im.p[i]))
    secondary.add result.publicInput(scalar(im.s[i]))
    pads.add result.publicInput(scalar(im.pads[i]))
    operands.add operand
    controls.add control
  var witness = buildBranchValidationWitness(environment, signatures, indexed, banks, rows, im.p, im.s, im.pads)
  if cancelMetadata:
    var changed = false
    for i, row in rows:
      if row.control.operand.kind == uint8(ord(veLabelCheck)) and
          witness.branchTypes.metadataQueries[i].value > 0:
        # Preserve the merged ROM value while corrupting its two inputs.
        witness.control.metadataQueries[i].value = 1
        dec witness.branchTypes.metadataQueries[i].value
        changed = true
        break
    if not changed: raise newException(ValueError, "metadata cancellation fixture")
  if typed:
    if memory != nil and memoryBinding:
      let combined = MemoryValidationWitness(branch: witness, memory: buildMemoryMetadataWitness(memory[], rows))
      if bulk != nil and bulkBinding:
        let full = BulkValidationWitness(memory: combined,
          bulk: buildBulkContextWitness(bulk[], environment.objects, rows, im.p, im.s))
        if references != nil and referenceBinding:
          let referenced = ReferenceValidationWitness(bulk: full,
            references: buildReferenceContextWitness(references[], rows, im.p))
          if tags != nil and throwBinding:
            let thrown = ThrowValidationWitness(references: referenced,
              throwing: buildThrowEventsWitness(tags[], signatures, rows, im.p))
            result.constrainThrowValidation(wires, primary, secondary, pads,
              typeWires, signatureWires, indexWires, branchWires, memoryWires, bulkWires, referenceWires, tagWires, first, thrown)
          else:
            result.constrainReferenceValidation(wires, primary, secondary, pads,
              typeWires, signatureWires, indexWires, branchWires, memoryWires, bulkWires, referenceWires, first, referenced)
        else:
          result.constrainBulkValidation(wires, primary, secondary, pads,
            typeWires, signatureWires, indexWires, branchWires, memoryWires, bulkWires, first, full)
      else:
        result.constrainMemoryValidation(wires, primary, secondary, pads,
          typeWires, signatureWires, indexWires, branchWires, memoryWires, first, combined)
    else:
      result.constrainBranchValidation(wires, primary, secondary, pads,
        typeWires, signatureWires, indexWires, branchWires, first, witness)
  else:
    # Same composition except the new type relation, for coherent-forgery tests.
    var selectors: seq[VariableSelectors]
    for row in wires: selectors.add result.variableSelectors(row.opcode)
    let projection = result.constrainOperandEventProjection(operands, labelChecks = true)
    let controlMemory = result.constrainControlEvents(controls, projection, first)
    result.constrainInstructionEvents(wires, projection, labelChecks = true)
    let declared = result.constrainTypeEnvironment(typeWires, wires, primary, projection, witness.types, selectors)
    result.constrainVariableEvents(wires, projection, selectors, declared)
    result.constrainCallEvents(wires, primary, secondary, projection, signatureWires, typeWires.objects, witness.calls)
    result.constrainParametricEvents(wires, primary, projection)
    let branch = result.constrainBranchEnvironment(branchWires, wires, primary, projection, witness.branches)
    let frames = result.constrainSignatureFrames(wires, primary, pads, projection, witness.frames, branch.depths)
    let standalone = buildControlTypingWitness(signatures, indexed, rows, witness.frames)
    result.constrainControlTyping(wires, projection, frames, signatureWires, indexWires, standalone)
    discard result.constrainMemory(projection.accesses, witness.stacks.operand, 64, 3)
    discard result.constrainMemory(controlMemory, witness.stacks.control, 64, 33)

proc branchRows*(module: WasmModule, capacity = 0): seq[InstructionEventRow] =
  buildInstructionEventRows(traceModuleValidation(module, labelChecks = true), capacity)
