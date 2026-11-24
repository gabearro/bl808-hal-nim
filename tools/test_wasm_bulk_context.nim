import cps/wasm/[types, binary, validate, flash_image, binary_order]
import zkbuild_bulk_test_helpers

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc accepted(module: WasmModule): bool =
  try: validateModule(module); true
  except ValidationError: false

proc leb(value: uint32): seq[byte] =
  var n = value
  while true:
    let b = byte(n and 127)
    n = n shr 7
    result.add b or (if n == 0: 0'u8 else: 128'u8)
    if n == 0: break

const Header = @[0'u8, 97, 115, 109, 1, 0, 0, 0]

proc main() =
  var cases: int
  for code in [opMemoryInit, opDataDrop]:
    for index in [0'u32, 1, high(uint32)]:
      require(accepted(bulkFixture(code, index)) == (index == 0), "data index bounds")
      inc cases
    var missing = bulkFixture(code)
    missing.dataCount = -1
    require(not accepted(missing), "data count section required")
    inc cases
  for code in [opMemoryInit, opMemoryCopy, opMemoryFill]:
    var module = bulkFixture(code)
    if code == opMemoryInit: module.codes[0].code.code[1].imm2 = 1
    else: module.codes[0].code.code[1].imm1 = 1
    require(not accepted(module), "bulk memory index")
    module = bulkFixture(code)
    module.memories.setLen(0)
    require(not accepted(module), "bulk memory presence")
    cases += 2
  for code in [opTableInit, opTableCopy]:
    for primary in [0'u32, 1, 2, high(uint32)]:
      for secondary in [0'u32, 1, 2, high(uint32)]:
        require(accepted(bulkFixture(code, primary, secondary)) ==
          (primary < 2 and secondary < 2 and primary == secondary), "table index/type compatibility")
        inc cases
  for index in [0'u32, 1, 2, high(uint32)]:
    require(accepted(bulkFixture(opElemDrop, index)) == (index < 2), "element index bounds")
    inc cases
  for value in [vtI32, vtI64, vtV128]:
    var module = bulkFixture(opTableInit)
    module.elements[0].elemType = value
    module.tables[0].elemType = value
    require(not accepted(module), "numeric element/table type")
    inc cases
  # The decoder must preserve the complete u32 instead of turning it into -1.
  for value in [0x7fffffff'u32, 0x80000000'u32, high(uint32)]:
    let payload = leb(value)
    let data = decodeModule(Header & @[12'u8, byte(payload.len)] & payload, optimize = false)
    require(data.dataCount == int64(value) and not accepted(data), "data count sentinel alias")
    let start = decodeModule(Header & @[8'u8, byte(payload.len)] & payload, optimize = false)
    require(start.startFunc == int64(value) and not accepted(start), "start function sentinel alias")
    for bytes in [Header & @[12'u8, byte(payload.len)] & payload, Header & @[8'u8, byte(payload.len)] & payload]:
      var rejected = false
      try: discard parseFlashWasmModule(bytes)
      except FlashWasmError: rejected = true
      require(rejected, "flash optional-u32 alias")
    cases += 4
  let validOrder = Header & @[1'u8, 4, 1, 0x60, 0, 0, 13, 3, 1, 0, 0, 6, 1, 0, 12, 1, 0, 10, 1, 0, 11, 1, 0]
  let decoded = decodeModule(validOrder, optimize = false)
  require(accepted(decoded) and decoded.tagDefs.len == 1, "tag/data-count section order")
  discard parseFlashWasmModule(validOrder)
  cases += 2
  for bytes in [Header & @[11'u8, 1, 0, 12, 1, 0], Header & @[14'u8, 0],
      Header & @[1'u8, 1, 0, 1, 1, 0], Header & @[10'u8, 0xff, 0xff, 0xff, 0xff, 0x0f]]:
    var rejected = false
    try: discard decodeModule(bytes, optimize = false)
    except WasmDecodeError: rejected = true
    require(rejected, "invalid section order/id/size")
    rejected = false
    try: discard parseFlashWasmModule(bytes)
    except FlashWasmError: rejected = true
    require(rejected, "invalid flash section order/id/size")
    cases += 2
  let ordered = [1, 2, 3, 4, 5, 13, 6, 7, 8, 9, 12, 10, 11]
  for i, id in ordered: require(binarySectionOrder(id) == i+1, "section rank")
  echo "WASM bulk context: PASS (", cases, " data/memory/table/type/section/header cases)"

main()
