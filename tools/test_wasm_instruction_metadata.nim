import cps/wasm/[types, validate, binary, static_typing, instruction_metadata]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc fixture(instruction: Instr, memories = 1, constants = 0): WasmModule =
  var code = @[Instr(op: opUnreachable), instruction]
  if staticRule(instruction.op).outputCount != 0: code.add Instr(op: opDrop)
  result = WasmModule(startFunc: -1, dataCount: -1, types: @[FuncType()], funcTypeIdxs: @[0'u32],
    codes: @[FuncBody(code: Expr(code: code))])
  result.codes[0].code.v128Consts.setLen(constants)
  for i in 0..<memories: result.memories.add MemType(limits: Limits(min: 1))

proc accepted(module: WasmModule): bool =
  try: validateModule(module); true
  except ValidationError: false

proc addLeb(bytes: var seq[byte], value: uint32) =
  var n = value
  while true:
    let low = byte(n and 127)
    n = n shr 7
    bytes.add low or (if n == 0: 0'u8 else: 128'u8)
    if n == 0: break

proc main() =
  var cases = 0
  const Alignments = [2, 3, 2, 3, 0, 0, 1, 1, 0, 0, 1, 1, 2, 2, 2, 3, 2, 3, 0, 1, 0, 1, 2]
  for code in 0x28..0x3e:
    require(instructionMetadata(uint16(code)).maxAlignment == uint8(Alignments[code-0x28]), "scalar metadata alignment")
    for alignment in [0'u32, uint32(Alignments[code-0x28]), uint32(Alignments[code-0x28]+1), high(uint32)]:
      let instruction = Instr(op: Opcode(code), imm1: high(uint32), imm2: alignment)
      require(accepted(fixture(instruction)) == (alignment <= uint32(Alignments[code-0x28])), "scalar alignment validation " & $code)
      inc cases
    require(not accepted(fixture(Instr(op: Opcode(code)), memories = 0)), "scalar memory presence")
    inc cases
  for code in [opV128Load, opV128Store]:
    for alignment in [0'u32, 4, 5, high(uint32)]:
      require(accepted(fixture(Instr(op: code, imm1: alignment, imm2: high(uint32)))) == (alignment <= 4), "SIMD alignment validation")
      inc cases
    require(not accepted(fixture(Instr(op: code), memories = 0)), "SIMD memory presence")
    inc cases
  for code in [opMemorySize, opMemoryGrow]:
    for memories in 0..1:
      for index in [0'u32, 1, high(uint32)]:
        require(accepted(fixture(Instr(op: code, imm1: index), memories)) == (memories == 1 and index == 0), "memory index validation")
        inc cases
  for code in 0x300..0x342:
    let lanes = simdLaneCount(uint16(code))
    if lanes == 0: continue
    for index in [0'u32, lanes-1, lanes, high(uint32)]:
      require(accepted(fixture(Instr(op: Opcode(code), imm1: index))) == (index < lanes), "SIMD lane validation")
      inc cases
  for count in [0, 1, 3]:
    for index in [0'u32, 1, 3, high(uint32)]:
      require(accepted(fixture(Instr(op: opV128Const, imm1: index), constants = count)) == (uint64(index) < uint64(count)), "SIMD pool validation")
      inc cases
  let scalar = decodeExprBytes([0'u8, 0x28, 2, 17, 0x1a, 0x0b], optimize = false)
  let vector = decodeExprBytes([0'u8, 0xfd, 0, 4, 17, 0x1a, 0x0b], optimize = false)
  require(scalar.code[1].imm1 == 17 and scalar.code[1].imm2 == 2, "scalar decoder memarg layout")
  require(vector.code[1].imm1 == 4 and vector.code[1].imm2 == 17, "SIMD decoder memarg layout")
  for fusion in 0..2:
    for alignment in [0'u32, 2, 3, high(uint32)]:
      var bytes: seq[byte]
      if fusion != 0: bytes.add @[0x41'u8, 0]
      bytes.add @[0x20'u8, 0, (if fusion == 2: 0x36'u8 else: 0x28'u8)]
      bytes.addLeb(alignment)
      bytes.add 0'u8
      if fusion == 1: bytes.add 0x6a'u8
      if fusion != 2: bytes.add 0x1a'u8
      bytes.add 0x0b'u8
      for optimize in [false, true]:
        var module = WasmModule(startFunc: -1, dataCount: -1,
          types: @[FuncType(params: @[vtI32])], funcTypeIdxs: @[0'u32],
          memories: @[MemType(limits: Limits(min: 1))],
          codes: @[FuncBody(code: decodeExprBytes(bytes, optimize))])
        require(accepted(module) == (alignment <= 2), "peephole erased invalid alignment")
        if optimize and alignment <= 2:
          let wanted = if fusion == 0: opLocalGetI32Load
            elif fusion == 1: opLocalGetI32LoadI32Add else: opLocalGetI32Store
          var found = false
          for instruction in module.codes[0].code.code:
            if instruction.op == wanted: found = true
          require(found, "valid memory fusion regressed")
        inc cases
  echo "WASM instruction metadata: PASS (", cases, " alignment/index/lane/pool cases; scalar and SIMD binary layouts)"

main()
