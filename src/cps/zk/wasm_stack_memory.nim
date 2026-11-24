## Private operand-RAM witness extraction from the WASM validation transcript.
## Event-to-access correspondence still needs constraints in the full circuit.
import ../wasm/validate
import memory_consistency, permutation

type OperandMemoryWitness* = object
  accesses*: seq[MemoryAccess]
  eventIndices*: seq[int] # -1 for padding; not itself an authenticated binding
  memory*: MemoryWitness

proc buildOperandMemory*(events: openArray[ValidationEvent], capacity = 0): OperandMemoryWitness =
  for i, event in events:
    if event.kind notin {veOperandPush, veOperandPop}: continue
    if event.kind == veOperandPop and event.polymorphic: continue
    if event.operandHeight < 0 or
        (event.kind == veOperandPush and event.operandHeight == 0):
      raise newException(ValueError, "invalid operand memory height")
    let index = event.operandHeight - ord(event.kind == veOperandPush)
    if index < 0 or uint64(index) > uint64(uint32.high):
      raise newException(ValueError, "operand memory address out of range")
    let address = (uint64(event.functionIndex) shl 32) or uint64(index)
    result.accesses.add MemoryAccess(active: true, write: event.kind == veOperandPush,
      address: address, value: uint64(ord(event.valueType)))
    result.eventIndices.add i
  var size = capacity
  if size == 0:
    size = 1
    while size < result.accesses.len:
      if size > int.high div 2:
        raise newException(ValueError, "operand memory capacity overflows")
      size *= 2
  discard routeSwitchCount(size)
  if size < result.accesses.len:
    raise newException(ValueError, "operand memory capacity is too small")
  let actual = result.accesses.len
  result.accesses.setLen(size)
  result.eventIndices.setLen(size)
  for i in actual..<size: result.eventIndices[i] = -1
  result.memory = buildMemoryWitness(result.accesses)
