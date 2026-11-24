## Structured validation including br_table. This is a component composition,
## not a general-module or raw-byte kernel admission certificate.
import r1cs, range_check, memory_consistency, read_only_memory
import wasm_instruction_events, wasm_operand_events, wasm_control_events
import wasm_type_environment, wasm_variable_events, wasm_signature_environment, wasm_call_events
import wasm_indexed_signatures, wasm_signature_frames, wasm_control_typing
import wasm_branch_environment, wasm_branch_typing
import wasm_parametric_events

type BranchValidationWitness* = object
  stacks*: StackMemoryWitness
  types*: TypeEnvironmentWitness
  calls*: SignatureEnvironmentWitness
  branches*: BranchEnvironmentWitness
  frames*: SignatureFrameWitness
  control*: ControlTypingWitness
  branchTypes*: BranchTypingWitness
  metadata*: MemoryWitness
  indexed*: IndexedSignatureWitness

proc merge(a, b: ReadOnlyEntry): ReadOnlyEntry =
  if a.active and b.active: raise newException(ValueError, "overlapping control and branch lookups")
  if a.active: a else: b

proc merge(c: var Circuit, a, b: ReadOnlyWires): ReadOnlyWires =
  # Addresses are already active-gated by the query constructors. Values are
  # private allocations: each inactive value must be zero BEFORE summing, or
  # an inactive query could cancel an incorrect active query's value.
  c.constrain(a.active, b.active, constant(0))
  c.constrain(constant(1)-a.active, a.value, constant(0))
  c.constrain(constant(1)-b.active, b.value, constant(0))
  ReadOnlyWires(active: a.active+b.active, address: a.address+b.address, value: a.value+b.value)

proc buildBranchValidationWitness*(environment: TypeEnvironment, signatures: SignatureEnvironment,
    indexed: IndexedSignatureEnvironment, banks: BranchEnvironment,
    rows: openArray[InstructionEventRow], primary, secondary: openArray[uint32],
    pads: openArray[uint64], catchDepths: openArray[uint32] = []): BranchValidationWitness =
  if catchDepths.len != 0 and catchDepths.len != rows.len:
    raise newException(ValueError, "catch frame depth dimensions differ")
  var controls: seq[ControlEventRow]
  for row in rows: controls.add row.control
  result.stacks = buildStackMemoryWitness(controls)
  result.types = buildTypeEnvironmentWitness(environment, rows, primary)
  result.calls = buildSignatureWitness(signatures, environment.objects, rows, primary, secondary)
  result.branches = buildBranchWitness(banks, rows, primary, catchChecks = catchDepths.len != 0)
  var depths: seq[uint32]
  for i, depth in result.branches.depths:
    depths.add depth+(if catchDepths.len == 0: 0'u32 else: catchDepths[i])
  result.frames = buildSignatureFrameWitness(rows, primary, pads, depths)
  result.control = buildControlTypingWitness(signatures, indexed, rows, result.frames, includeLookupWitnesses = false)
  result.branchTypes = buildBranchTypingWitness(signatures, indexed, rows, result.frames, result.branches,
    includeLookupWitnesses = false, catchChecks = catchDepths.len != 0)
  var metadata: seq[ReadOnlyEntry]
  var queries: IndexedSignatureQueries
  for i in 0..<rows.len:
    metadata.add merge(result.control.metadataQueries[i], result.branchTypes.metadataQueries[i])
    queries.lengths.add merge(result.control.indexedQueries.lengths[2*i], result.branchTypes.indexedQueries.lengths[i])
    queries.lengths.add result.control.indexedQueries.lengths[2*i+1]
    queries.members.add merge(result.control.indexedQueries.members[2*i], result.branchTypes.indexedQueries.members[i])
    queries.members.add result.control.indexedQueries.members[2*i+1]
    queries.singletons.add merge(result.control.indexedQueries.singletons[i], result.branchTypes.indexedQueries.singletons[i])
  result.metadata = buildReadOnlyWitness(signatures.signatures, metadata)
  result.indexed = buildIndexedSignatureWitness(indexed, signatures, queries)

proc constrainBranchValidationCore*(c: var Circuit, rows: openArray[InstructionEventWires],
    primary, secondary, pads: openArray[Linear], environment: TypeEnvironmentWires,
    signatures: SignatureEnvironmentWires, indexed: IndexedSignatureWires,
    banks: BranchEnvironmentWires, firstFunctionIndex: Linear,
    witness: BranchValidationWitness, projection: OperandEventProjection,
    selectors: openArray[VariableSelectors], catchDepths: openArray[Linear] = []): SignatureFrameProjection =
  ## projection and selectors must be derived from these same public rows.
  if catchDepths.len != 0 and catchDepths.len != rows.len:
    raise newException(ValueError, "catch frame circuit dimensions differ")
  var controls: seq[ControlEventWires]
  for row in rows: controls.add row.control
  let control = c.constrainControlEvents(controls, projection, firstFunctionIndex)
  c.constrainInstructionEvents(rows, projection, labelChecks = true, catchChecks = catchDepths.len != 0)
  let declared = c.constrainTypeEnvironment(environment, rows, primary, projection, witness.types, selectors)
  c.constrainVariableEvents(rows, projection, selectors, declared)
  c.constrainCallEvents(rows, primary, secondary, projection, signatures, environment.objects, witness.calls)
  c.constrainParametricEvents(rows, primary, projection)
  var branchProjection = projection
  if catchDepths.len != 0:
    branchProjection.flags = @(projection.flags)
    when defined(zkbuildStructuredControlAudit):
      let marker = c.beginSourceProgram()
    for i, row in rows:
      branchProjection.flags[i].labelCheck = c.multiply(projection.flags[i].labelCheck,
        c.zeroIndicator(row.opcode-constant(0x0e)))
    when defined(zkbuildStructuredControlAudit):
      c.structuredControlRecords.add DynamicTypingStageAudit(kind: 1,rows: captureInstructionRows(rows),
        flags: captureEventFlags(projection.flags),outputs: captureEventFlags(branchProjection.flags),
        program: c.endSourceProgram(marker))
  let branch = c.constrainBranchEnvironment(banks, rows, primary, branchProjection, witness.branches)
  var depths: seq[Linear]
  for i, depth in branch.depths: depths.add depth+(if catchDepths.len == 0: constant(0) else: catchDepths[i])
  let frames = c.constrainSignatureFrames(rows, primary, pads, projection, witness.frames, depths)
  let structured = c.constrainControlTypingQueries(rows, projection, frames, signatures, indexed, witness.control)
  let branchTypes = c.constrainBranchTypingQueries(rows, branchProjection, frames, branch, signatures, indexed, witness.branchTypes)
  var metadata: seq[ReadOnlyWires]
  var queries: IndexedSignatureQueryWires
  when defined(zkbuildStructuredControlAudit):
    let mergeMarker = c.beginSourceProgram()
  for i in 0..<rows.len:
    metadata.add c.merge(structured.metadata[i], branchTypes.metadata[i])
    queries.lengths.add c.merge(structured.indexed.lengths[2*i], branchTypes.indexed.lengths[i])
    queries.lengths.add structured.indexed.lengths[2*i+1]
    queries.members.add c.merge(structured.indexed.members[2*i], branchTypes.indexed.members[i])
    queries.members.add structured.indexed.members[2*i+1]
    queries.singletons.add c.merge(structured.indexed.singletons[i], branchTypes.indexed.singletons[i])
  when defined(zkbuildStructuredControlAudit):
    var audit = DynamicTypingStageAudit(kind: 6,rows: captureInstructionRows(rows),
      selectors: captureTypingQueries(structured),inputs: captureTypingQueries(branchTypes,true),
      outputs: captureTypingQueries(ControlTypingQueries(metadata: metadata,indexed: queries)),
      program: c.endSourceProgram(mergeMarker))
    audit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(signatures.signatures, metadata, witness.metadata, 33, 64)
  when defined(zkbuildStructuredControlAudit): c.structuredControlRecords.add audit
  c.constrainIndexedSignatures(indexed, signatures, witness.indexed, queries)
  when defined(zkbuildValidationEventAudit):
    if c.validationTraceRecords.len == 1: c.validationTraceRecords[0].memories.add c.memoryRecords.len
  discard c.constrainMemory(projection.accesses, witness.stacks.operand, 64, 3)
  when defined(zkbuildValidationEventAudit):
    if c.validationTraceRecords.len == 1: c.validationTraceRecords[0].memories.add c.memoryRecords.len
  discard c.constrainMemory(control, witness.stacks.control, 64, 33)
  result = frames

proc constrainBranchValidation*(c: var Circuit, rows: openArray[InstructionEventWires],
    primary, secondary, pads: openArray[Linear], environment: TypeEnvironmentWires,
    signatures: SignatureEnvironmentWires, indexed: IndexedSignatureWires,
    banks: BranchEnvironmentWires, firstFunctionIndex: Linear,
    witness: BranchValidationWitness): OperandEventProjection {.discardable.} =
  c.reuseRangeWitnesses = true
  var operands: seq[OperandEventWires]
  var selectors: seq[VariableSelectors]
  for row in rows:
    operands.add row.control.operand
    selectors.add c.variableSelectors(row.opcode)
  result = c.constrainOperandEventProjection(operands, labelChecks = true)
  discard c.constrainBranchValidationCore(rows, primary, secondary, pads, environment, signatures,
    indexed, banks, firstFunctionIndex, witness, result, selectors)
