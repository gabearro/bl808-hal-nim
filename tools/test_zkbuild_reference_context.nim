import std/[os, osproc, strutils]
import cps/wasm/[types, validate, reference_context]
import cps/zk/[r1cs, prover, range_check, read_only_memory, wasm_operand_events,
  wasm_control_events, wasm_instruction_events, wasm_reference_context,
  wasm_branch_environment, wasm_memory_metadata, wasm_bulk_context, wasm_validation_witness]
import zkbuild_branch_test_helpers

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc accepted(module: WasmModule): bool =
  try: validateModule(module); true
  except ValidationError: false

proc fixture(functions, mask: int, primary: uint32): WasmModule =
  result = WasmModule(startFunc: -1, dataCount: -1,
    types: @[FuncType(results: @[vtFuncRef])], funcTypeIdxs: @[0'u32],
    codes: @[FuncBody(code: Expr(code: @[Instr(op: opRefFunc, imm1: primary)]))])
  for i in 1..<functions: result.imports.add Import(kind: ikFunc, funcTypeIdx: 0)
  for i in 0..<4:
    if (mask and (1 shl i)) != 0: result.exports.add Export(name: "f" & $i, kind: ekFunc, idx: uint32(i))

proc entries(mask: int, capacity = 4): seq[ReadOnlyEntry] =
  for i in 0..<4:
    if (mask and (1 shl i)) != 0: result.add ReadOnlyEntry(active: true, address: uint64(i), value: 1)
  result.setLen(capacity)

proc unit(code, primary, functions: uint64, declarations: seq[ReadOnlyEntry],
    begin = true): Circuit =
  result = initCircuit(reuseRangeWitnesses = true)
  let op = result.publicInput(scalar(code))
  let p = result.publicInput(scalar(primary))
  let count = result.publicInput(scalar(functions))
  let enabled = result.publicInput(scalar(ord(begin)))
  result.constrainBoolean(enabled)
  var environment = ReferenceEnvironmentWires(functionCount: count)
  for entry in declarations:
    environment.declarations.add ReadOnlyWires(active: result.publicInput(scalar(ord(entry.active))),
      address: result.publicInput(scalar(entry.address)), value: result.publicInput(scalar(entry.value)))
  let rows = @[InstructionEventRow(opcode: uint16(code and 65535), control: ControlEventRow(operand:
    OperandEventRow(kind: uint8(ord(if begin: veInstructionBegin else: veInstructionEnd)))))]
  let witness = buildReferenceContextWitness(ReferenceEnvironment(declarations: declarations), rows,
    [uint32(primary and 0xffffffff'u64)])
  result.constrainReferenceContext([InstructionEventWires(opcode: op)], [p],
    OperandEventProjection(flags: @[OperandEventFlags(instructionBegin: enabled)]), environment, witness)

proc full(module: WasmModule, rows: seq[InstructionEventRow], references: var ReferenceEnvironment,
    binding = true): Circuit =
  var memory = buildMemoryEnvironment(module)
  var bulk = buildBulkEnvironment(module)
  buildBranchTypes(module, rows, buildBranchEnvironment(module), memory = addr memory,
    bulk = addr bulk, references = addr references, referenceBinding = binding)

proc forged(module: WasmModule, rows: seq[InstructionEventRow], references: var ReferenceEnvironment, message: string) =
  require(full(module, rows, references, false).satisfied(), message & " preceding partial relation")
  require(not full(module, rows, references).satisfied(), message)

proc main() =
  require(paramCount() == 2, "usage: test_reference_context EXPORTER WORK_DIR")
  createDir(paramStr(2))
  let path = paramStr(2) / "references.txt"
  require(execCmd(quoteShell(paramStr(1)) & " " & quoteShell(path)) == 0, "reference oracle exporter")
  let lines = readFile(path).splitLines()
  require(lines[0] == "ZKREF1 2560", "reference oracle header")
  var finite, host, cases, forgeries: int
  var shape: Circuit
  for line in lines[1..^1]:
    if line.len == 0: continue
    let columns = line.splitWhitespace()
    var v: seq[int]
    for item in columns: v.add parseInt(item)
    let expected = v[4] == 1
    let circuit = unit(uint64(v[0]), uint64(v[3]), uint64(v[1]), entries(v[2]))
    require(circuit.satisfied() == expected, "R1CS/Lean reference case " & line)
    if finite == 0: shape = circuit
    else: require(circuit.sameShape(shape), "reference matrix depends on values")
    if v[0] == 210 and v[1] > 0:
      require(accepted(fixture(v[1], v[2], uint32(v[3]))) == expected, "Nim/Lean reference case " & line)
      inc host
    inc finite
  require(finite == 2560 and host == 512, "reference oracle coverage")
  # Each supported declaration origin, duplicate declarations and import offsets.
  for origin in 0..4:
    var module = fixture(2, 0, 0)
    let refExpr = Expr(code: @[Instr(op: opRefFunc)])
    case origin
    of 0: module.exports = @[Export(name: "f", kind: ekFunc, idx: 0)]
    of 1: module.globals = @[GlobalDef(globalType: GlobalType(valType: vtFuncRef), init: refExpr)]
    of 2: module.elements = @[ElemSegment(mode: elemPassive, elemType: vtFuncRef, init: @[refExpr])]
    of 3: module.elements = @[ElemSegment(mode: elemDeclarative, elemType: vtFuncRef, init: @[refExpr, refExpr])]
    else:
      module.tables = @[TableType(elemType: vtFuncRef, limits: Limits(min: 1))]
      module.elements = @[ElemSegment(mode: elemActive, elemType: vtFuncRef,
        offset: Expr(code: @[Instr(op: opI32Const)]), init: @[refExpr])]
      module.exports = @[Export(name: "f", kind: ekFunc, idx: 0)]
    require(declaredFunctionReferences(module) == @[0'u32] and accepted(module), "reference declaration origin")
    var references = buildReferenceEnvironment(module)
    require(full(module, branchRows(module), references).satisfied(), "composed reference origin")
    inc cases
  block:
    var module = fixture(2, 1, 0)
    module.globals = @[GlobalDef(globalType: GlobalType(valType: vtFuncRef),
      init: Expr(code: @[Instr(op: opRefFunc, imm1: 1)]))]
    module.elements = @[ElemSegment(mode: elemDeclarative, elemType: vtFuncRef,
      init: @[Expr(code: @[Instr(op: opRefFunc, imm1: 1)]), Expr(code: @[Instr(op: opRefFunc)])])]
    require(declaredFunctionReferences(module) == @[0'u32, 1'u32] and accepted(module), "sorted unique declarations")
    var references = buildReferenceEnvironment(module)
    require(full(module, branchRows(module), references).satisfied(), "composed sorted declarations")
    inc cases
  block:
    var module = fixture(1, 0, 0)
    require(not accepted(module), "self body is not declaration")
    module.startFunc = 0
    require(declaredFunctionReferences(module).len == 0, "start is not declaration")
    module.startFunc = -1
    module.codes[0].code.code = @[Instr(op: opUnreachable), Instr(op: opCall), Instr(op: opDrop), Instr(op: opRefFunc)]
    require(not accepted(module) and declaredFunctionReferences(module).len == 0, "call is not declaration")
    var imported = fixture(2, 0, 0)
    require(not accepted(imported), "import is not declaration")
    cases += 3
  block:
    var module = fixture(2, 1, 0)
    let rows = branchRows(module)
    var references = buildReferenceEnvironment(module)
    module.codes[0].code.code[0].imm1 = 1
    forged(module, rows, references, "existing but undeclared function")
    inc forgeries
    module.codes[0].code.code[0].imm1 = 2
    forged(module, rows, references, "nonexistent function")
    inc forgeries
  block:
    let module = fixture(2, 1, 0)
    let rows = branchRows(module)
    var references = buildReferenceEnvironment(module)
    references.functionCount = 0
    forged(module, rows, references, "declaration outside function count")
    inc forgeries
    references = buildReferenceEnvironment(module)
    references.declarations[0].value = 0
    forged(module, rows, references, "false declaration value")
    inc forgeries
    references = buildReferenceEnvironment(module)
    references.declarations[0].active = false
    references.declarations[0].value = 0
    forged(module, rows, references, "missing declaration")
    inc forgeries
  for origin in 0..1:
    var module = fixture(1, 1, 0)
    let rows = branchRows(module)
    let invalid = Expr(code: @[Instr(op: opRefFunc, imm1: high(uint32))])
    if origin == 0:
      module.globals = @[GlobalDef(globalType: GlobalType(valType: vtFuncRef), init: invalid)]
    else:
      module.elements = @[ElemSegment(mode: elemDeclarative, elemType: vtFuncRef, init: @[invalid])]
    require(not accepted(module), "invalid function reference outside body")
    var references = buildReferenceEnvironment(module)
    forged(module, rows, references, "out-of-range declaration initializer")
    inc forgeries
  for item in [(210'u64, 1'u64 shl 32, 1'u64), (210'u64, 0'u64, 1'u64 shl 32),
      (65746'u64, 0'u64, 1'u64)]:
    require(not unit(item[0], item[1], item[2], entries(1)).satisfied(), "wide reference field alias")
    inc forgeries
  let last = @[ReadOnlyEntry(active: true, address: uint64(high(uint32))-1, value: 1)]
  require(unit(210, uint64(high(uint32))-1, uint64(high(uint32)), last).satisfied(), "full u32 reference bounds")
  require(not unit(210, uint64(high(uint32)), uint64(high(uint32)),
    @[ReadOnlyEntry(active: true, address: uint64(high(uint32)), value: 1)]).satisfied(), "reference one past count")
  require(unit(210, 0, 0, entries(0), false).satisfied(), "inactive reference query")
  require(not unit(210, 1, 0, entries(0), false).satisfied(), "inactive primary must be zero")
  forgeries += 2
  # Ordinary binary decoding and validation, then the production composition.
  let base = @[0'u8, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 0x60, 0, 1, 0x70, 3, 2, 1, 0]
  let aBytes = base & @[7'u8, 5, 1, 1, 0x66, 0, 0, 10, 6, 1, 4, 0, 0xd2, 0, 0x0b]
  let bBytes = base & @[9'u8, 5, 1, 3, 0, 1, 0, 10, 6, 1, 4, 0, 0xd2, 0, 0x0b]
  let aw = buildFullValidationWitness(aBytes, labelChecks = true)
  let bw = buildFullValidationWitness(bBytes, labelChecks = true)
  var ae = buildReferenceEnvironment(aw.module, 1)
  var be = buildReferenceEnvironment(bw.module, 1)
  # Equal profile dimensions include the element table even when unused.
  proc binaryCircuit(witness: FullValidationWitness, refs: var ReferenceEnvironment): Circuit =
    var memory = buildMemoryEnvironment(witness.module)
    var bulk = buildBulkEnvironment(witness.module, 1)
    buildBranchTypes(witness.module, buildInstructionEventRows(witness.events, 16),
      buildBranchEnvironment(witness.module), memory = addr memory, bulk = addr bulk, references = addr refs)
  let a = binaryCircuit(aw, ae)
  let b = binaryCircuit(bw, be)
  require(a.satisfied() and b.satisfied() and a.sameShape(b), "reference binary profile")
  let key = setup(a)
  for circuit in [a, b]:
    let proof = encodeProof(prove(key, circuit))
    require(proof.len == 192 and decodeAndVerify(key.verificationKey, proof,
      circuit.values[1..circuit.publicCount]), "reference Groth16 proof")
    for index in [0, circuit.publicCount div 2, circuit.publicCount-1]:
      var changed = circuit.values[1..circuit.publicCount]
      changed[index] = changed[index]+scalar(1)
      require(not decodeAndVerify(key.verificationKey, proof, changed), "reference public substitution")
  echo "zkbuild reference context: PASS (", finite, " Lean/R1CS shapes; ", host,
    " host validations; ", cases, " origin/context cases; ", forgeries, " forgeries rejected; ",
    a.constraints.len, " constraints/16 rows; QAP ", key.domainSize, "; two 192-byte proofs)"

main()
