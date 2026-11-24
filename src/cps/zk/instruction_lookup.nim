## Opcode metadata used by the memory/SIMD immediate checks.
import ../wasm/instruction_metadata
import r1cs, opcode_lookup

type InstructionMetadataWires* = object
  memoryRequired*, memoryArgument*, vectorArgument*, maxAlignment*, memoryIndex*, vectorConstant*, laneBits*: Linear

func instructionPayload*(code: uint16): array[7, int] =
  let rule = instructionMetadata(code)
  [ord(rule.memoryRequired), ord(rule.memoryArgument), ord(rule.vectorArgument),
    int(rule.maxAlignment), ord(rule.memoryIndex), ord(rule.vectorConstant), int(rule.laneBits)]

proc buildTable(): OpcodeLookup[7] =
  var values = newSeq[array[7, int]](65536)
  for i in 0..<values.len: values[i] = instructionPayload(uint16(i))
  buildOpcodeLookup(values)

let table = buildTable()

proc instructionLookupBranches*(): int = table.lookupBranches()
proc lookupInstructionValue*(code: uint16): array[7, int] = table.lookupValue(code)

proc constrainInstructionMetadata*(c: var Circuit, opcode: Linear): InstructionMetadataWires =
  let values = c.constrainLookup(table, opcode)
  InstructionMetadataWires(memoryRequired: values[0], memoryArgument: values[1], vectorArgument: values[2],
    maxAlignment: values[3], memoryIndex: values[4], vectorConstant: values[5], laneBits: values[6])
