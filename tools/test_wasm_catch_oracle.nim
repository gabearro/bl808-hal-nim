import std/[os, osproc, strutils]
import cps/wasm/[types, validate, exception_typing]
import test_wasm_catch_typing

const ValueTypes = [vtI32, vtI64, vtF32, vtF64, vtV128, vtFuncRef, vtExternRef]
const Vectors* = [newSeq[uint8](), @[0'u8], @[1'u8], @[6'u8], @[0'u8, 1], @[0'u8, 1, 6]]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc caseModule*(v: openArray[int], skeleton = false): WasmModule =
  var target: seq[ValType]
  for tag in Vectors[v[3]]: target.add ValueTypes[int(tag)]
  result = fixture(target)
  if skeleton: return
  var params: seq[ValType]
  for i in 0..<v[1]: params.add ValueTypes[(v[2]+i) mod 7]
  result.types[1].params = params
  if v[5] == 0: result.tagDefs = @[]
  elif v[5] == 2: result.types[1].results = @[vtI32]
  result.codes[0].code.catchTables[0][0].kind =
    case v[0]
    of 0: ckCatch
    of 1: ckCatchRef
    of 2: ckCatchAll
    else: ckCatchAllRef
  result.codes[0].code.catchTables[0][0].labelDepth = uint32(v[4])

proc main() =
  require(paramCount() == 2, "usage: test_wasm_catch_oracle EXPORTER WORK_DIR")
  createDir(paramStr(2))
  let path = paramStr(2) / "catch.txt"
  require(execCmd(quoteShell(paramStr(1)) & " " & quoteShell(path)) == 0, "catch oracle exporter")
  let lines = readFile(path).splitLines()
  require(lines[0] == "ZKCATCH1 7560", "catch oracle header")
  var count, host: int
  for line in lines[1..^1]:
    if line.len == 0: continue
    var v: seq[int]
    for column in line.splitWhitespace(): v.add parseInt(column)
    if v[0] == 4:
      require(v[6] == 0, "invalid catch kind oracle")
    else:
      let module = caseModule(v)
      let payload = catchPayload(module, module.codes[0].code.catchTables[0][0])
      let expected = v[6] == 1
      let matches = payload.present and v[4] < 2 and payload.inputs ==
        (if v[4] == 0: Vectors[v[3]] else: newSeq[uint8]())
      require(matches == expected, "Nim/Lean catch payload " & line)
      var accepted = true
      try: validateModule(module)
      except ValidationError: accepted = false
      require(accepted == (expected and v[5] != 2), "Nim/Lean full catch context " & line)
      inc host
    inc count
  require(count == 7560 and host == 6048, "catch oracle coverage")
  echo "WASM catch oracle: PASS (", count, " Lean cases; ", host, " host signatures and module validations)"

when isMainModule: main()
