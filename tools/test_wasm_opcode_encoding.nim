import cps/wasm/[types, binary, opcode_policy, opcode_encoding]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc leb(value: uint32): seq[byte] =
  var remaining = value
  while true:
    let payload = byte(remaining and 127)
    remaining = remaining shr 7
    result.add payload or (if remaining == 0: 0'u8 else: 128'u8)
    if remaining == 0: return

proc main() =
  var supported: int
  for code in 0..65535:
    let encoding = opcodeEncoding(uint16(code))
    require(encoding.present == admittedOpcode(uint16(code)), "missing admitted opcode encoding " & $code)
    if not encoding.present: continue
    inc supported
    if code == 11:
      require(decodeExprBytes([11'u8], optimize = false).code.len == 0, "root end encoding")
      continue
    if code == 5:
      let expression = decodeExprBytes([4'u8,64,5,11,11], optimize = false)
      require(expression.code[1].op == opElse, "else encoding")
      continue
    var bytes = @[encoding.prefix]
    if encoding.prefixed: bytes.add leb(encoding.subopcode)
    case encoding.form
    of efNone: discard
    of efU32: bytes.add leb(128)
    of efPair: bytes.add @[1'u8,2]
    of efBlock: bytes.add 64
    of efBranchTable: bytes.add @[2'u8,0,1,2]
    of efTryTable: bytes.add @[64'u8,4,0,0,0,1,1,1,2,2,3,3]
    of efTypedSelect: bytes.add @[1'u8,126]
    of efS32, efS64: bytes.add 42
    of efLittle32: bytes.add @[1'u8,2,3,4]
    of efLittle64: bytes.add @[1'u8,2,3,4,5,6,7,8]
    of efReferenceType: bytes.add 111
    of efLane: bytes.add 0
    of efVector16:
      for value in 0..15: bytes.add byte(value)
    if encoding.form in {efBlock, efTryTable}: bytes.add 11
    bytes.add 11
    let expression = decodeExprBytes(bytes, optimize = false)
    require(expression.code.len != 0 and uint16(ord(expression.code[0].op)) == uint16(code), "binary/IR opcode disagreement " & $code)
    if encoding.form == efPair:
      require(expression.code[0].imm1 == (if encoding.swapPair: 2'u32 else: 1'u32) and
        expression.code[0].imm2 == (if encoding.swapPair: 1'u32 else: 2'u32), "binary/IR immediate order disagreement " & $code)
  echo "WASM opcode encoding: PASS (65536 catalog cases; ", supported, " independent owning-decoder round trips)"

main()
