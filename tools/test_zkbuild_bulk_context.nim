import std/[os, osproc, strutils]
import cps/wasm/[types, validate, binary_order]
import cps/zk/[r1cs, prover, read_only_memory, wasm_bulk_context,
  wasm_type_environment, wasm_instruction_events, wasm_validation_witness]
import zkbuild_bulk_test_helpers

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc configuration(index: int): seq[ValType] =
  case index
  of 0: @[]
  of 1: @[vtFuncRef]
  of 2: @[vtExternRef]
  else: @[vtFuncRef, vtExternRef]

proc fixture(code, memory, has, declared, data, ei, ti, p, s: int): WasmModule =
  result = bulkFixture(Opcode(code), uint32(p), uint32(s))
  result.memories.setLen(memory)
  result.dataCount = if has == 1: int64(declared) else: -1'i64
  result.datas = @[]
  for i in 0..<data: result.datas.add DataSegment(mode: dataPassive)
  result.elements = @[]
  for value in configuration(ei): result.elements.add ElemSegment(mode: elemPassive, elemType: value)
  result.tables = @[]
  for value in configuration(ti): result.tables.add TableType(elemType: value, limits: Limits(min: 1))

proc accepted(module: WasmModule): bool =
  try: validateModule(module); true
  except ValidationError: false

proc checkOracle(exporter, work: string): tuple[finite, host, matrix: int] =
  createDir(work)
  let path = absolutePath(work/"bulk-context.txt")
  let orders = absolutePath(work/"section-orders.txt")
  require(execCmd(quoteShell(absolutePath(exporter)) & " " & quoteShell(path) & " " & quoteShell(orders)) == 0, "Lean bulk export")
  let input = open(path)
  defer: input.close()
  require(input.readLine() == "ZKBULK1 36288", "bulk context export header")
  var shape: Circuit
  while not input.endOfFile():
    let line = input.readLine()
    if line.len == 0: continue
    let parts = line.splitWhitespace()
    require(parts.len == 10, "bulk oracle arity")
    var values: array[10, int]
    for i in 0..<10: values[i] = parseInt(parts[i])
    let module = fixture(values[0], values[1], values[2], values[3], values[4],
      values[5], values[6], values[7], values[8])
    let expected = values[9] == 1
    if values[2] != 0 or values[3] == 0:
      require(accepted(module) == expected, "Nim/Lean bulk validation " & line)
      inc result.host
    var env = buildBulkEnvironment(module, 2)
    env.declaredDataCount = uint32(values[3]) # Include noncanonical absent headers.
    if result.finite mod 37 == 0:
      let objects = buildTypeEnvironment(module, objectCapacity = 2).objects
      let circuit = buildBulkUnit(uint64(values[0]), uint64(values[7]), uint64(values[8]), uint32(values[1]), env, objects)
      require(circuit.satisfied() == expected, "R1CS/Lean bulk context " & line)
      if result.matrix == 0: shape = circuit
      else: require(circuit.sameShape(shape), "bulk context matrix depends on values")
      inc result.matrix
    inc result.finite
  require(result.finite == 36288 and result.host == 24192, "bulk oracle coverage")
  let sectionLines = readFile(orders).splitLines()
  require(sectionLines[0] == "ZKSECTIONS1 256", "section oracle header")
  for id in 0..255:
    let row = sectionLines[id+1].splitWhitespace()
    require(parseInt(row[0]) == id and binarySectionOrder(id) == parseInt(row[1]), "Nim/Lean section order")

proc check(module: WasmModule): int =
  let rows = branchRows(module)
  var env = buildBulkEnvironment(module)
  require(fullBulk(module, rows, env).satisfied(), "valid full bulk composition")
  1

proc forged(module: WasmModule, rows: seq[InstructionEventRow], env: var BulkEnvironment, message: string) =
  require(fullBulk(module, rows, env, false).satisfied(), message & " preceding partial relation")
  require(not fullBulk(module, rows, env).satisfied(), message)

proc main() =
  require(paramCount() == 2, "usage: test_bulk_context EXPORTER WORK_DIR")
  let oracle = checkOracle(paramStr(1), paramStr(2))
  var cases, forgeries: int
  for code in [opMemoryInit, opDataDrop, opMemoryCopy, opMemoryFill, opTableInit, opElemDrop, opTableCopy]:
    cases += check(bulkFixture(code))
  cases += check(bulkFixture(opTableInit, 1, 1))
  cases += check(bulkFixture(opTableCopy, 1, 1))
  cases += check(bulkFixture(opElemDrop, 1))
  block:
    var module = bulkFixture(opMemoryInit)
    module.memories = @[]
    module.imports = @[Import(kind: ikMemory, memType: MemType(limits: Limits(min: 1))),
      Import(kind: ikFunc, funcTypeIdx: 0)]
    cases += check(module)
  block:
    var module = bulkFixture(opTableInit, 1, 2)
    module.imports = @[Import(kind: ikTable, tableType: TableType(elemType: vtFuncRef, limits: Limits(min: 1))),
      Import(kind: ikFunc, funcTypeIdx: 0)]
    cases += check(module)
  for item in [(opMemoryInit, 1'u32, 0'u32), (opMemoryCopy, 0'u32, 1'u32),
      (opMemoryFill, 1'u32, 0'u32), (opTableInit, 2'u32, 0'u32),
      (opTableInit, 0'u32, 2'u32), (opTableInit, 1'u32, 0'u32),
      (opTableCopy, 0'u32, 1'u32), (opElemDrop, 2'u32, 0'u32)]:
    var module = bulkFixture(item[0])
    let rows = branchRows(module)
    var env = buildBulkEnvironment(module)
    module.codes[0].code.code[1].imm1 = item[1]
    module.codes[0].code.code[1].imm2 = item[2]
    forged(module, rows, env, "bulk immediate/type forgery " & $item[0])
    inc forgeries
  block:
    let module = bulkFixture(opDataDrop)
    let rows = branchRows(module)
    for mutation in 0..2:
      var env = buildBulkEnvironment(module)
      if mutation == 0: env.hasDataCount = false; env.declaredDataCount = 0
      elif mutation == 1: env.declaredDataCount = 0
      else: env.declaredDataCount = high(uint32)
      forged(module, rows, env, "data count/header forgery")
      inc forgeries
  block:
    var module = bulkFixture(opTableInit)
    let rows = branchRows(module)
    module.tables = @[]
    module.globals = @[GlobalDef(globalType: GlobalType(valType: vtFuncRef, mut: mutConst),
      init: Expr(code: @[Instr(op: opRefNull, imm1: 0x70)]))]
    var env = buildBulkEnvironment(module)
    forged(module, rows, env, "global/table namespace alias")
    inc forgeries
  block:
    var module = bulkFixture(opElemDrop)
    module.elements.setLen(1)
    let rows = branchRows(module)
    var env = buildBulkEnvironment(module)
    env.elements[0].address = 1
    module.codes[0].code.code[1].imm1 = 1
    # A bare table lookup accepts this sparse key; list enumeration must not.
    var bare = initCircuit()
    let entry = ReadOnlyWires(active: constant(1), address: constant(1), value: constant(5))
    bare.constrainReadOnly([entry], [entry], buildReadOnlyWitness(env.elements,
      @[ReadOnlyEntry(active: true, address: 1, value: 5)]), 32, 3)
    require(bare.satisfied(), "sparse element bare lookup fixture")
    forged(module, rows, env, "sparse element key forged a list index")
    inc forgeries
  let emptyObjects = newSeq[ReadOnlyEntry]()
  let large = BulkEnvironment(hasDataCount: true, declaredDataCount: high(uint32), dataCount: high(uint32))
  require(buildBulkUnit(0x109, uint64(high(uint32))-1, 0, 0, large, emptyObjects).satisfied(), "full u32 data bound")
  require(not buildBulkUnit(0x109, uint64(high(uint32)), 0, 0, large, emptyObjects).satisfied(), "one-past-u32 data bound")
  require(not buildBulkUnit(0x109, 1'u64 shl 32, 0, 0, large, emptyObjects).satisfied(), "wide data index alias")
  forgeries += 2
  let base = @[0'u8, 97, 115, 109, 1, 0, 0, 0, 1, 4, 1, 0x60, 0, 0, 3, 2, 1, 0]
  let dataBytes = base & @[12'u8, 1, 1, 10, 7, 1, 5, 0, 0xfc, 9, 0, 0x0b, 11, 3, 1, 1, 0]
  let elemBytes = base & @[9'u8, 4, 1, 1, 0, 0, 10, 7, 1, 5, 0, 0xfc, 13, 0, 0x0b]
  let aWitness = buildFullValidationWitness(dataBytes, labelChecks = true)
  let bWitness = buildFullValidationWitness(elemBytes, labelChecks = true)
  var aEnv = buildBulkEnvironment(aWitness.module, 1)
  var bEnv = buildBulkEnvironment(bWitness.module, 1)
  let a = fullBulk(aWitness.module, buildInstructionEventRows(aWitness.events, 16), aEnv)
  let b = fullBulk(bWitness.module, buildInstructionEventRows(bWitness.events, 16), bEnv)
  require(a.satisfied() and b.satisfied() and a.sameShape(b), "data/element profile matrix")
  let key = setup(a)
  for circuit in [a, b]:
    let proof = encodeProof(prove(key, circuit))
    require(proof.len == 192 and decodeAndVerify(key.verificationKey, proof,
      circuit.values[1..circuit.publicCount]), "bulk Groth16 proof")
    for index in [0, circuit.publicCount div 2, circuit.publicCount-1]:
      var changed = circuit.values[1..circuit.publicCount]
      changed[index] = changed[index]+scalar(1)
      require(not decodeAndVerify(key.verificationKey, proof, changed), "bulk public claim substitution")
  echo "zkbuild bulk context: PASS (", oracle.finite, " Lean cases; ", oracle.host, " host validations; ",
    oracle.matrix, " R1CS shapes; 256 section ranks; ", cases, " composed traces; ", forgeries,
    " coherent/bound forgeries rejected; ", a.constraints.len, " constraints/16 rows; QAP ",
    key.domainSize, "; two 192-byte proofs)"

main()
