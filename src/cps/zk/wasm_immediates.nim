## Full-width instruction metadata extracted at original validation PCs.
## This is witness construction, not an authenticated binary parser.
import ../wasm/[types, validate, block_types]
import wasm_instruction_events

proc instructionImmediates*(module: WasmModule, rows: openArray[InstructionEventRow],
    firstFunction = 0'u32): tuple[p, s: seq[uint32], pads: seq[uint64]] =
  result.p.setLen(rows.len)
  result.s.setLen(rows.len)
  result.pads.setLen(rows.len)
  for i, row in rows:
    let event = row.control.operand
    if event.kind == uint8(ord(veInstructionBegin)):
      if event.functionIndex < firstFunction or
          uint64(event.functionIndex-firstFunction) >= uint64(module.codes.len):
        raise newException(ValueError, "instruction metadata function index out of range")
      let body = int(event.functionIndex-firstFunction)
      let expression = module.codes[body].code
      if uint64(row.pc) < uint64(expression.code.len):
        let instruction = expression.code[int(row.pc)]
        result.p[i] = instruction.imm1
        result.s[i] = instruction.imm2
        result.pads[i] = normalizedBlockPad(expression, int(row.pc))
