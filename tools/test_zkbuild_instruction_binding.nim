## End-to-end typed event/source instruction compositions, including coherent
## changes that remain well typed when detached from the original bytes.
import std/os
import cps/wasm/[types, binary]
import cps/zk/[r1cs, prover, wasm_module_validation, wasm_catch_environment]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc section(bytes: var seq[byte], id: byte, data: seq[byte]) =
  require(data.len < 128, "fixture section size")
  bytes.add @[id, byte(data.len)]
  bytes.add data

proc wasm(types, functions, code: seq[byte], memory: seq[byte] = @[],
    tables: seq[byte] = @[], tags: seq[byte] = @[],
    elements: seq[byte] = @[], dataSegments: seq[byte] = @[]): seq[byte] =
  result = @[0'u8,97,115,109,1,0,0,0]
  result.section(1, types)
  result.section(3, functions)
  if tables.len != 0: result.section(4, tables)
  if memory.len != 0: result.section(5, memory)
  if tags.len != 0: result.section(13, tags)
  if elements.len != 0: result.section(9, elements)
  if dataSegments.len != 0: result.section(12, @[dataSegments[0]])
  result.section(10, code)
  if dataSegments.len != 0: result.section(11, dataSegments)

proc build(module: WasmModule, data: seq[byte], capacity = 64): Circuit =
  buildModuleValidationCircuit(module, moduleValidationRows(module, capacity), buildCatchEnvironment(module),
    sourceBytes = data, sourceCapacity = 128, sectionCapacity = 8)

proc oneBody(types, expression: seq[byte]): seq[byte] =
  let body = @[0'u8] & expression
  wasm(types, @[1'u8,0], @[1'u8,byte(body.len)] & body)

proc rejection(module: WasmModule, data: seq[byte]): bool =
  try: not build(module, data).satisfied()
  except ValueError: true

proc main() =
  let i32 = @[1'u8,96,0,1,127]
  let cases = @[
    wasm(i32, @[1'u8,0], @[1'u8,4,0,65,42,11]),
    wasm(i32, @[1'u8,0], @[1'u8,6,0,1,65,42,1,11]),
    wasm(i32, @[1'u8,0], @[1'u8,7,0,65,10,65,3,107,11]),
    wasm(i32, @[1'u8,0], @[1'u8,12,0,65,1,4,127,65,2,5,65,3,11,11]),
    wasm(i32, @[2'u8,0,0], @[2'u8,4,0,18,1,11,4,0,65,7,11]),
    wasm(i32, @[1'u8,0], @[1'u8,13,0,2,127,65,42,65,0,14,1,0,0,11,11]),
    wasm(i32, @[1'u8,0], @[1'u8,7,0,65,0,40,2,0,11], memory = @[1'u8,0,1]),
    wasm(i32, @[1'u8,0], @[1'u8,7,0,65,0,17,0,0,11], tables = @[1'u8,112,0,1]),
    wasm(@[1'u8,96,0,1,124], @[1'u8,0], @[1'u8,11,0,68,1,2,3,4,5,6,7,8,11]),
    wasm(@[1'u8,96,0,1,123], @[1'u8,0], @[1'u8,20,0,253,12,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,11]),
    wasm(@[2'u8,96,0,1,127,96,1,127,0], @[1'u8,0],
      @[1'u8,17,0,2,127,31,64,1,0,0,0,65,42,8,0,11,0,11,11], tags = @[1'u8,0,1]),
    oneBody(@[1'u8,96,0,0], @[2'u8,64,65,0,14,0,0,65,0,14,0,0,11,11]),
    oneBody(@[1'u8,96,0,0], @[2'u8,64,31,64,1,2,0,11,31,64,1,2,0,11,11,11]),
    oneBody(i32, @[2'u8,127,3,64,65,42,12,1,11,0,11,11]),
    wasm(@[1'u8,96,0,0], @[1'u8,0], @[1'u8,12,0,65,0,65,0,65,0,252,8,0,0,11],
      memory = @[1'u8,0,1], dataSegments = @[1'u8,1,0]),
    wasm(@[1'u8,96,0,0], @[1'u8,0], @[1'u8,12,0,65,0,65,0,65,0,252,12,0,0,11],
      tables = @[1'u8,112,0,1], elements = @[1'u8,1,0,0])
  ]
  var count: int
  for data in cases:
    let module = decodeModule(data, optimize = false)
    require(build(module, data).satisfied(), "typed/source composition case " & $count)
    inc count
  var bad = decodeModule(cases[0], optimize = false)
  bad.codes[0].code.code[0].imm1 = 43
  require(rejection(bad, cases[0]), "well-typed immediate substitution")
  bad = decodeModule(cases[1], optimize = false)
  bad.codes[0].code.code.delete(0)
  require(rejection(bad, cases[1]), "well-typed instruction omission")
  bad = decodeModule(cases[2], optimize = false)
  bad.codes[0].code.code[2].op = opI32Add
  require(rejection(bad, cases[2]), "well-typed opcode substitution")
  bad = decodeModule(cases[3], optimize = false)
  bad.codes[0].code.code[1].imm1 = 3
  require(rejection(bad, cases[3]), "control target substitution")
  echo "typed instruction/source comparisons: PASS (", count, " cases; 4 coherent forgeries)"
  if paramCount() == 1 and paramStr(1) == "--check-only": return
  let a = build(decodeModule(cases[0], optimize = false), cases[0], 16)
  var bBytes = @(cases[0])
  bBytes[bBytes.len-2] = 43
  let b = build(decodeModule(bBytes, optimize = false), bBytes, 16)
  require(a.sameShape(b), "source-bound module key reuse")
  let key = setup(a)
  for circuit in [a, b]:
    let proof = encodeProof(prove(key, circuit))
    require(decodeAndVerify(key.verificationKey, proof, circuit.values[1..circuit.publicCount]), "source-bound typed proof")
  echo "zkbuild instruction binding: PASS (", count, " typed compositions; 4 coherent forgeries; ",
    a.constraints.len, " constraints/16 events; two 192-byte proofs)"

main()
