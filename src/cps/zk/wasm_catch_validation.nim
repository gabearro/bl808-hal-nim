## Complete catch/throw context composition over validation events. This does
## not supply raw-byte admission or standard exnref object semantics.
import r1cs, read_only_memory, wasm_signature_frames
import wasm_instruction_events, wasm_operand_events, wasm_type_environment
import wasm_signature_environment, wasm_indexed_signatures, wasm_branch_environment
import wasm_branch_validation, wasm_memory_metadata, wasm_bulk_context
import wasm_reference_context, wasm_throw_events, wasm_catch_environment
import wasm_type_reversals, wasm_catch_typing
import wasm_opcode_policy
import wasm_local_ranges

type CatchValidationWitness* = object
  branch*: BranchValidationWitness
  memory*: MemoryMetadataWitness
  bulk*: BulkContextWitness
  references*: ReferenceContextWitness
  throwing*: ThrowEventsWitness
  catches*: CatchEnvironmentWitness
  reversed*: TypeReversalWitness
  catchTypes*: CatchTypingWitness
  locals*: LocalRangeWitness

proc buildCatchValidationWitness*(environment: TypeEnvironment, signatures: SignatureEnvironment,
    indexed: IndexedSignatureEnvironment, banks: BranchEnvironment, memory: MemoryEnvironment,
    bulk: BulkEnvironment, references: ReferenceEnvironment, tags: TagEnvironment,
    catches: CatchEnvironment, rows: openArray[InstructionEventRow],
    primary, secondary: openArray[uint32], pads: openArray[uint64]): CatchValidationWitness =
  result.catches = buildCatchWitness(catches, rows, secondary)
  result.locals = buildLocalRangeWitness(environment)
  result.branch = buildBranchValidationWitness(environment, signatures, indexed, banks,
    rows, primary, secondary, pads, result.catches.depths)
  result.memory = buildMemoryMetadataWitness(memory, rows)
  result.bulk = buildBulkContextWitness(bulk, environment.objects, rows, primary, secondary)
  result.references = buildReferenceContextWitness(references, rows, primary)
  result.throwing = buildThrowEventsWitness(tags, signatures, rows, primary)
  result.reversed = buildTypeReversalWitness(signatures.reversals, indexed)
  result.catchTypes = buildCatchTypingWitness(signatures, indexed, tags, rows, result.branch.frames, result.catches)

proc constrainCatchValidationCore*(c: var Circuit, rows: openArray[InstructionEventWires],
    primary, secondary, pads: openArray[Linear], environment: TypeEnvironmentWires,
    signatures: SignatureEnvironmentWires, indexed: IndexedSignatureWires,
    banks: BranchEnvironmentWires, memory: MemoryEnvironmentWires, bulk: BulkEnvironmentWires,
    references: ReferenceEnvironmentWires, tags: TagEnvironmentWires, catches: CatchEnvironmentWires,
    reversals: openArray[ReadOnlyWires], firstFunctionIndex: Linear,
    witness: CatchValidationWitness): tuple[catches: CatchProjection, frames: SignatureFrameProjection] =
  ## Partial composition; the caller must additionally constrainCatchTyping.
  c.reuseRangeWitnesses = true
  c.constrainAdmittedOpcodes(rows)
  c.constrainLocalRanges(environment, witness.locals)
  var selectors: seq[VariableSelectors]
  var operands: seq[OperandEventWires]
  when defined(zkbuildDynamicTypingAudit):
    let selectorMarker = c.beginSourceProgram()
  for row in rows:
    selectors.add c.variableSelectors(row.opcode)
    operands.add row.control.operand
  when defined(zkbuildDynamicTypingAudit):
    c.dynamicTypingRecords.add DynamicTypingStageAudit(kind: 0,rows: captureInstructionRows(rows),
      outputs: captureVariableSelectors(selectors),program: c.endSourceProgram(selectorMarker))
  let projection = c.constrainOperandEventProjection(operands, labelChecks = true)
  let catchProjection = c.constrainCatchEnvironment(catches, rows, secondary, projection, witness.catches)
  let frames = c.constrainBranchValidationCore(rows, primary, secondary, pads, environment, signatures,
    indexed, banks, firstFunctionIndex, witness.branch, projection, selectors, catchProjection.depths)
  c.constrainMemoryMetadata(rows, primary, secondary, projection, memory, witness.memory)
  c.constrainBulkContext(rows, primary, secondary, projection, memory.memoryCount, bulk, environment.objects, witness.bulk)
  c.constrainReferenceContext(rows, primary, projection, references, witness.references)
  c.constrainThrowEvents(rows, primary, projection, tags, signatures, witness.throwing)
  c.constrainTypeReversals(reversals, indexed, witness.reversed)
  result = (catchProjection, frames)

proc constrainCatchValidation*(c: var Circuit, rows: openArray[InstructionEventWires],
    primary, secondary, pads: openArray[Linear], environment: TypeEnvironmentWires,
    signatures: SignatureEnvironmentWires, indexed: IndexedSignatureWires,
    banks: BranchEnvironmentWires, memory: MemoryEnvironmentWires, bulk: BulkEnvironmentWires,
    references: ReferenceEnvironmentWires, tags: TagEnvironmentWires, catches: CatchEnvironmentWires,
    reversals: openArray[ReadOnlyWires], firstFunctionIndex: Linear, witness: CatchValidationWitness) =
  let checked = c.constrainCatchValidationCore(rows, primary, secondary, pads, environment, signatures,
    indexed, banks, memory, bulk, references, tags, catches, reversals, firstFunctionIndex, witness)
  c.constrainCatchTyping(checked.catches, checked.frames, signatures, indexed, tags, reversals, witness.catchTypes)
