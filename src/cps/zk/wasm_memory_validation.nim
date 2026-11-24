## Structured/branch validation with memory and SIMD metadata. Raw-byte,
## remaining environment/module, and exception obligations remain separate.
import r1cs
import wasm_instruction_events, wasm_type_environment, wasm_signature_environment
import wasm_indexed_signatures, wasm_branch_environment, wasm_branch_validation
import wasm_memory_metadata
import wasm_operand_events

type MemoryValidationWitness* = object
  branch*: BranchValidationWitness
  memory*: MemoryMetadataWitness

proc buildMemoryValidationWitness*(environment: TypeEnvironment, signatures: SignatureEnvironment,
    indexed: IndexedSignatureEnvironment, banks: BranchEnvironment, memory: MemoryEnvironment,
    rows: openArray[InstructionEventRow], primary, secondary: openArray[uint32],
    pads: openArray[uint64]): MemoryValidationWitness =
  result.branch = buildBranchValidationWitness(environment, signatures, indexed, banks, rows, primary, secondary, pads)
  result.memory = buildMemoryMetadataWitness(memory, rows)

proc constrainMemoryValidation*(c: var Circuit, rows: openArray[InstructionEventWires],
    primary, secondary, pads: openArray[Linear], environment: TypeEnvironmentWires,
    signatures: SignatureEnvironmentWires, indexed: IndexedSignatureWires,
    banks: BranchEnvironmentWires, memory: MemoryEnvironmentWires,
    firstFunctionIndex: Linear, witness: MemoryValidationWitness): OperandEventProjection {.discardable.} =
  let projection = c.constrainBranchValidation(rows, primary, secondary, pads,
    environment, signatures, indexed, banks, firstFunctionIndex, witness.branch)
  c.constrainMemoryMetadata(rows, primary, secondary, projection, memory, witness.memory)
  result = projection
