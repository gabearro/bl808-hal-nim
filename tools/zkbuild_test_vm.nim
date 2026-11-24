## Independent, test-only execution of the emitted standard RV32 instructions.
## Decodes bytes; does not call the compiler's instruction helpers.
proc runRv32*(code: openArray[byte], a, b: uint32): uint32 =
  var registers: array[32, uint32]
  registers[10] = a
  registers[11] = b
  for pc in countup(0, code.len-4, 4):
    var instruction = 0'u32
    for i in 0 ..< 4: instruction = instruction or (code[pc+i].uint32 shl (8*i))
    let opcode = instruction and 0x7f
    let rd = int((instruction shr 7) and 31)
    let rs1 = int((instruction shr 15) and 31)
    let rs2 = int((instruction shr 20) and 31)
    let funct3 = (instruction shr 12) and 7
    let funct7 = instruction shr 25
    case opcode
    of 0x37: registers[rd] = instruction and 0xfffff000'u32
    of 0x13:
      if funct3 != 0: raise newException(ValueError, "unsupported RV32 immediate instruction")
      let immediate = cast[uint32](cast[int32](instruction) shr 20)
      registers[rd] = registers[rs1] + immediate
    of 0x33:
      let left = registers[rs1]
      let right = registers[rs2]
      case (funct7 shl 3) or funct3
      of 0: registers[rd] = left + right
      of 0x100: registers[rd] = left - right
      of 8: registers[rd] = uint32((left.uint64*right.uint64) and 0xffffffff'u64)
      of 7: registers[rd] = left and right
      of 6: registers[rd] = left or right
      of 4: registers[rd] = left xor right
      else: raise newException(ValueError, "unsupported RV32 register instruction")
    of 0x67:
      if instruction != 0x00008067'u32: raise newException(ValueError, "unexpected return")
      if pc != code.len-4: raise newException(ValueError, "early return")
      return registers[10]
    else: raise newException(ValueError, "unsupported RV32 opcode")
    registers[0] = 0
  raise newException(ValueError, "missing return")
