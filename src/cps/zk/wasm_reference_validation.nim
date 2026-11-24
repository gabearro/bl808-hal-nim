## General validation components through ref.func context checks. This profile
## still requires complete module/EH rules and a raw-binary binding.
import r1cs, wasm_operand_events
import wasm_instruction_events, wasm_type_environment, wasm_signature_environment
import wasm_indexed_signatures, wasm_branch_environment, wasm_memory_metadata
import wasm_bulk_context, wasm_bulk_validation, wasm_reference_context

type ReferenceValidationWitness* = object
  bulk*: BulkValidationWitness
  references*: ReferenceContextWitness

proc buildReferenceValidationWitness*(environment: TypeEnvironment, signatures: SignatureEnvironment,
    indexed: IndexedSignatureEnvironment, banks: BranchEnvironment, memory: MemoryEnvironment,
    bulk: BulkEnvironment, references: ReferenceEnvironment, rows: openArray[InstructionEventRow],
    primary, secondary: openArray[uint32], pads: openArray[uint64]): ReferenceValidationWitness =
  result.bulk = buildBulkValidationWitness(environment, signatures, indexed, banks, memory, bulk, rows, primary, secondary, pads)
  result.references = buildReferenceContextWitness(references, rows, primary)

proc constrainReferenceValidation*(c: var Circuit, rows: openArray[InstructionEventWires],
    primary, secondary, pads: openArray[Linear], environment: TypeEnvironmentWires,
    signatures: SignatureEnvironmentWires, indexed: IndexedSignatureWires,
    banks: BranchEnvironmentWires, memory: MemoryEnvironmentWires, bulk: BulkEnvironmentWires,
    references: ReferenceEnvironmentWires, firstFunctionIndex: Linear,
    witness: ReferenceValidationWitness): OperandEventProjection {.discardable.} =
  result = c.constrainBulkValidation(rows, primary, secondary, pads, environment, signatures,
    indexed, banks, memory, bulk, firstFunctionIndex, witness.bulk)
  c.constrainReferenceContext(rows, primary, result, references, witness.references)
