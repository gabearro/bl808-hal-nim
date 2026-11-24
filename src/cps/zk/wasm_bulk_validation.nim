## Structured, branch, memory/SIMD, and bulk context composition. Raw bytes,
## remaining module rules, references and exception validation remain open.
import r1cs
import wasm_operand_events
import wasm_instruction_events, wasm_type_environment, wasm_signature_environment
import wasm_indexed_signatures, wasm_branch_environment, wasm_memory_metadata
import wasm_memory_validation, wasm_bulk_context

type BulkValidationWitness* = object
  memory*: MemoryValidationWitness
  bulk*: BulkContextWitness

proc buildBulkValidationWitness*(environment: TypeEnvironment, signatures: SignatureEnvironment,
    indexed: IndexedSignatureEnvironment, banks: BranchEnvironment, memory: MemoryEnvironment,
    bulk: BulkEnvironment, rows: openArray[InstructionEventRow], primary, secondary: openArray[uint32],
    pads: openArray[uint64]): BulkValidationWitness =
  result.memory = buildMemoryValidationWitness(environment, signatures, indexed, banks, memory, rows, primary, secondary, pads)
  result.bulk = buildBulkContextWitness(bulk, environment.objects, rows, primary, secondary)

proc constrainBulkValidation*(c: var Circuit, rows: openArray[InstructionEventWires],
    primary, secondary, pads: openArray[Linear], environment: TypeEnvironmentWires,
    signatures: SignatureEnvironmentWires, indexed: IndexedSignatureWires,
    banks: BranchEnvironmentWires, memory: MemoryEnvironmentWires, bulk: BulkEnvironmentWires,
    firstFunctionIndex: Linear, witness: BulkValidationWitness): OperandEventProjection {.discardable.} =
  let projection = c.constrainMemoryValidation(rows, primary, secondary, pads,
    environment, signatures, indexed, banks, memory, firstFunctionIndex, witness.memory)
  c.constrainBulkContext(rows, primary, secondary, projection, memory.memoryCount, bulk, environment.objects, witness.bulk)
  result = projection
