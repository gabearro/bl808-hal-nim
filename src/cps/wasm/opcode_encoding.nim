## Binary layouts for every unfused opcode admitted by the current runtime.
## The proving decoder uses this catalog; the owning decoder remains an
## independent implementation for exhaustive conformance tests.
import opcode_policy, simd_encoding, instruction_metadata

type
  ImmediateForm* = enum
    efNone, efU32, efPair, efBlock, efBranchTable, efTryTable, efTypedSelect,
    efS32, efS64, efLittle32, efLittle64, efReferenceType, efLane, efVector16
  OpcodeEncoding* = object
    present*, prefixed*, swapPair*: bool
    prefix*: uint8
    subopcode*: uint32
    form*: ImmediateForm

func opcodeEncoding*(code: uint16): OpcodeEncoding =
  if not admittedOpcode(code): return
  result.present = true
  if code < 256:
    result.prefix = uint8(code)
    case code
    of 2, 3, 4: result.form = efBlock
    of 0x1f: result.form = efTryTable
    of 0x0e: result.form = efBranchTable
    of 8, 12, 13, 16, 18, 0x20..0x26, 0x3f, 0x40, 0xd2: result.form = efU32
    of 17, 19: result.form = efPair
    of 0x28..0x3e: result.form = efPair; result.swapPair = true
    of 0x1c: result.form = efTypedSelect
    of 0x41: result.form = efS32
    of 0x42: result.form = efS64
    of 0x43: result.form = efLittle32
    of 0x44: result.form = efLittle64
    of 0xd0: result.form = efReferenceType
    else: discard
  elif code in 0x100'u16..0x111'u16:
    result.prefix = 0xfc
    result.prefixed = true
    result.subopcode = uint32(code)-0x100
    case code
    of 0x108, 0x10a, 0x10c, 0x10e: result.form = efPair
    of 0x109, 0x10b, 0x10d, 0x10f..0x111: result.form = efU32
    else: discard
  else:
    result.present = false
    for subopcode in 0'u32..243'u32:
      if simdOpcode(subopcode) == code:
        result.present = true
        result.prefix = 0xfd
        result.prefixed = true
        result.subopcode = subopcode
        if code in [0x300'u16, 0x301]: result.form = efPair
        elif code == 0x302: result.form = efVector16
        elif instructionMetadata(code).laneBits != 0: result.form = efLane
        break
