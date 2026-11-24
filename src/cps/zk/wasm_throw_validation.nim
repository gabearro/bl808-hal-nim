## Composes throw payload checks with reference/bulk/control validation.
## Catch clauses, module initialization and binary binding remain open.
import r1cs, wasm_operand_events, wasm_throw_events
import wasm_instruction_events, wasm_type_environment, wasm_signature_environment
import wasm_indexed_signatures, wasm_branch_environment, wasm_memory_metadata
import wasm_bulk_context, wasm_reference_context, wasm_reference_validation

type ThrowValidationWitness* = object
  references*: ReferenceValidationWitness
  throwing*: ThrowEventsWitness

proc buildThrowValidationWitness*(environment: TypeEnvironment, signatures: SignatureEnvironment,
    indexed: IndexedSignatureEnvironment, banks: BranchEnvironment, memory: MemoryEnvironment,
    bulk: BulkEnvironment, references: ReferenceEnvironment, tags: TagEnvironment,
    rows: openArray[InstructionEventRow], primary, secondary: openArray[uint32],
    pads: openArray[uint64]): ThrowValidationWitness =
  result.references = buildReferenceValidationWitness(environment, signatures, indexed, banks, memory,
    bulk, references, rows, primary, secondary, pads)
  result.throwing = buildThrowEventsWitness(tags, signatures, rows, primary)

proc constrainThrowValidation*(c: var Circuit, rows: openArray[InstructionEventWires],
    primary, secondary, pads: openArray[Linear], environment: TypeEnvironmentWires,
    signatures: SignatureEnvironmentWires, indexed: IndexedSignatureWires,
    banks: BranchEnvironmentWires, memory: MemoryEnvironmentWires, bulk: BulkEnvironmentWires,
    references: ReferenceEnvironmentWires, tags: TagEnvironmentWires, firstFunctionIndex: Linear,
    witness: ThrowValidationWitness): OperandEventProjection {.discardable.} =
  result = c.constrainReferenceValidation(rows, primary, secondary, pads, environment, signatures,
    indexed, banks, memory, bulk, references, firstFunctionIndex, witness.references)
  c.constrainThrowEvents(rows, primary, result, tags, signatures, witness.throwing)
