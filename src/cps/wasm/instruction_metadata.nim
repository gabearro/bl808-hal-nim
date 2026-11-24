## Immediate/context metadata for the instruction subset in this runtime.
## Scalar and SIMD memargs deliberately retain their existing IR layouts.
import static_typing

type InstructionMetadata* = object
  memoryRequired*, memoryArgument*, vectorArgument*, memoryIndex*, vectorConstant*: bool
  maxAlignment*, laneBits*: uint8

func instructionMetadata*(code: uint16): InstructionMetadata =
  case int(code)
  of 0x28, 0x2a, 0x34, 0x35, 0x36, 0x38, 0x3e:
    result.memoryArgument = true
    result.maxAlignment = 2
  of 0x29, 0x2b, 0x37, 0x39:
    result.memoryArgument = true
    result.maxAlignment = 3
  of 0x2c, 0x2d, 0x30, 0x31, 0x3a, 0x3c:
    result.memoryArgument = true
  of 0x2e, 0x2f, 0x32, 0x33, 0x3b, 0x3d:
    result.memoryArgument = true
    result.maxAlignment = 1
  of 0x300, 0x301:
    result.memoryArgument = true
    result.vectorArgument = true
    result.maxAlignment = 4
  of 0x3f, 0x40: result.memoryIndex = true
  of 0x302: result.vectorConstant = true
  else: discard
  result.memoryRequired = result.memoryArgument or result.memoryIndex or
    code in [0x108'u16, 0x10a, 0x10b]
  case simdLaneCount(code)
  of 2: result.laneBits = 1
  of 4: result.laneBits = 2
  of 8: result.laneBits = 3
  of 16: result.laneBits = 4
  else: discard
