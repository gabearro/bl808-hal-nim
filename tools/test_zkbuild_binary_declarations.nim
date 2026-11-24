import cps/wasm/[types, binary, validate]
import cps/zk/[r1cs, wasm_module_validation, wasm_catch_environment]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc leb(value: int): seq[byte] =
  var v = value
  while true:
    let low = byte(v and 127)
    v = v shr 7
    result.add low or (if v == 0: 0'u8 else: 128'u8)
    if v == 0: return

proc section(bytes: var seq[byte], id: byte, content: seq[byte]) =
  bytes.add id
  bytes.add leb(content.len)
  bytes.add content

proc fixture(): seq[byte] =
  result = @[0'u8,97,115,109,1,0,0,0]
  result.section(1, @[4'u8,
    96,2,127,111,2,123,126,
    96,3,125,124,112,0,
    96,7,127,126,125,124,123,112,111,0,
    96,0,7,127,126,125,124,123,112,111])
  result.section(2, @[1'u8,4,104,111,115,116,1,102,0,0])
  result.section(3, @[1'u8,0])
  result.section(13, @[1'u8,0,1])
  result.section(10, @[1'u8,7,2,0,123,3,124,0,11])

proc circuit(module: WasmModule, bytes: seq[byte]): Circuit =
  let rows = moduleValidationRows(module, 32)
  buildModuleValidationCircuit(module, rows, buildCatchEnvironment(module), sourceBytes = bytes,
    sourceCapacity = 128, sectionCapacity = 8)

proc rejected(module: WasmModule, bytes: seq[byte]): bool =
  try: not circuit(module, bytes).satisfied()
  except ValueError: true

proc main() =
  let empty = @[0'u8,97,115,109,1,0,0,0]
  require(buildModuleValidationCircuit(empty, 1).satisfied(), "empty module with a padded event row")
  let bytes = fixture()
  let original = decodeModule(bytes, optimize = false)
  validateModule(original)
  let checked = circuit(original, bytes)
  require(checked.satisfied(), "all value-type source bytes and imported function offset")
  var bad = decodeModule(bytes, optimize = false)
  bad.types[2].params[3] = vtI32
  require(rejected(bad, bytes), "coherent substituted parameter type")
  bad = decodeModule(bytes, optimize = false)
  bad.types[3].results[2] = vtI32
  require(rejected(bad, bytes), "coherent substituted result type")
  bad = decodeModule(bytes, optimize = false)
  bad.types[2].params.setLen(6)
  require(rejected(bad, bytes), "omitted final type member")
  bad = decodeModule(bytes, optimize = false)
  bad.funcTypeIdxs[0] = 1
  require(rejected(bad, bytes), "coherent substituted function type index")
  bad = decodeModule(bytes, optimize = false)
  bad.tagDefs[0].typeIdx = 2
  require(rejected(bad, bytes), "coherent substituted tag type index")
  bad = decodeModule(bytes, optimize = false)
  bad.types.setLen(3)
  require(rejected(bad, bytes), "omitted source type declaration")
  bad = decodeModule(bytes, optimize = false)
  bad.codes[0].locals[1].count = 4
  require(rejected(bad, bytes), "coherent substituted local count")
  bad = decodeModule(bytes, optimize = false)
  bad.codes[0].locals[1].valType = vtI32
  require(rejected(bad, bytes), "coherent substituted local type")
  bad = decodeModule(bytes, optimize = false)
  bad.codes[0].locals.setLen(1)
  require(rejected(bad, bytes), "omitted local declaration")
  var wide = @[0'u8,97,115,109,1,0,0,0]
  wide.section(1, @[1'u8,96,0,1,127])
  wide.section(3, @[1'u8,0])
  wide.section(10, @[1'u8,9,1,255,255,255,255,15,127,0,11])
  let wideModule = decodeModule(wide, optimize = false)
  require(circuit(wideModule, wide).satisfied(), "full-u32 source local count without expansion")
  bad = decodeModule(wide, optimize = false)
  dec bad.codes[0].locals[0].count
  require(rejected(bad, wide), "unused large-local count forgery")
  echo "zkbuild binary declarations: PASS (all 7 types; source-order vectors; imported namespace; code/local framing; full-u32 local count; 10 coherent source/metadata forgeries; ", checked.constraints.len, " constraints)"

main()
