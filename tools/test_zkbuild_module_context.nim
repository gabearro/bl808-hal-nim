## Whole-module context composition, exact names, and coherent forgeries.
import std/[strutils]
import cps/wasm/[types, validate, utf8_names]
import cps/zk/[r1cs, prover, read_only_memory, wasm_type_environment,
  wasm_signature_environment, wasm_memory_metadata, wasm_bulk_context,
  wasm_reference_context, wasm_module_context, wasm_names, wasm_catch_environment]
import cps/zk/wasm_module_validation
import zkbuild_catch_test_helpers

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc fixture(value = 42'u32): WasmModule =
  result = WasmModule(startFunc: 0, dataCount: 1,
    types: @[FuncType(), FuncType(params: @[vtI32])], funcTypeIdxs: @[0'u32],
    imports: @[Import(kind: ikGlobal, module: "host", name: "offset",
      globalType: GlobalType(valType: vtI32, mut: mutConst))],
    codes: @[FuncBody(code: Expr(code: @[Instr(op: opNop)]))],
    memories: @[MemType(limits: Limits(min: 1, max: 2, hasMax: true))],
    tables: @[TableType(elemType: vtFuncRef, limits: Limits(min: 1, max: 3, hasMax: true))])
  for tag, kind in [vtI32, vtI64, vtF32, vtF64, vtV128, vtFuncRef, vtExternRef]:
    let code = [opI32Const, opI64Const, opF32Const, opF64Const, opV128Const, opRefFunc, opRefNull][tag]
    var expression = Expr(code: @[Instr(op: code, imm1: (if kind == vtExternRef: uint32(ord(kind)) elif code == opI32Const: value else: 0))])
    if kind == vtV128: expression.v128Consts.add default(array[16, byte])
    result.globals.add GlobalDef(globalType: GlobalType(valType: kind), init: expression)
  result.globals.add GlobalDef(globalType: GlobalType(valType: vtI32),
    init: Expr(code: @[Instr(op: opGlobalGet, imm1: 1)]))
  result.elements = @[ElemSegment(mode: elemActive, elemType: vtFuncRef,
    offset: Expr(code: @[Instr(op: opGlobalGet, imm1: 1)]), init: @[
      Expr(code: @[Instr(op: opRefFunc)]), Expr(code: @[Instr(op: opRefNull, imm1: uint32(ord(vtFuncRef)))]),
      Expr(code: @[Instr(op: opGlobalGet, imm1: 6)])])]
  result.datas = @[DataSegment(mode: dataActive, offset: Expr(code: @[Instr(op: opI32Const)]))]
  result.exports = @[Export(name: "run", kind: ekFunc), Export(name: "t\xc3\xa9", kind: ekTable),
    Export(name: "memory", kind: ekMemory), Export(name: "\xf4\x8f\xbf\xbf", kind: ekGlobal, idx: 1)]
  result.customSections.add (name: "\0meta", data: newSeq[byte]())

proc inputs(c: var Circuit, entries: openArray[ReadOnlyEntry]): seq[ReadOnlyWires] =
  for entry in entries:
    result.add ReadOnlyWires(active: c.publicInput(scalar(ord(entry.active))),
      address: c.publicInput(scalar(entry.address)), value: c.publicInput(scalar(entry.value)))

proc contextCircuit(module: WasmModule): Circuit =
  let env = buildTypeEnvironment(module, compressedLocals = true)
  let sig = buildSignatureEnvironment(module)
  let memory = buildMemoryEnvironment(module)
  let bulk = buildBulkEnvironment(module)
  let refs = buildReferenceEnvironment(module)
  let context = buildModuleEnvironment(module)
  let witness = buildModuleContextWitness(context, env, sig, refs)
  result = initCircuit(reuseRangeWitnesses = true)
  let envW = TypeEnvironmentWires(objects: result.inputs(env.objects))
  let sigW = SignatureEnvironmentWires(signatures: result.inputs(sig.signatures))
  let memW = MemoryEnvironmentWires(memoryCount: result.publicInput(scalar(memory.memoryCount)), vectorCounts: result.inputs(memory.vectorCounts))
  let bulkW = BulkEnvironmentWires(dataCount: result.publicInput(scalar(bulk.dataCount)), elements: result.inputs(bulk.elements))
  let refW = ReferenceEnvironmentWires(functionCount: result.publicInput(scalar(refs.functionCount)), declarations: result.inputs(refs.declarations))
  let first = result.publicInput(scalar(context.importedFunctions))
  let contextW = result.allocateModuleEnvironment(context, publicInputs = true)
  result.constrainModuleContext(contextW, envW, sigW, memW, bulkW, refW, first, witness)

proc rejected(module: WasmModule): bool =
  try: not contextCircuit(module).satisfied()
  except ValueError: true

proc nameCircuit(environment: NameEnvironment): Circuit =
  let witness = buildNameWitness(environment)
  result = initCircuit(reuseRangeWitnesses = true)
  let wires = result.allocateNames(environment, publicInputs = true)
  result.constrainNames(wires, witness)

proc main() =
  var utf8Cases: int
  for a in 0..255:
    for b in 0..255:
      let name = $char(a) & $char(b)
      var accepts = true
      try: discard buildNameEnvironment([name])
      except ValueError: accepts = false
      require(accepts == validWasmName(name), "two-byte UTF-8 scalar oracle")
      inc utf8Cases
  for name in ["", "ascii\0", "\xc2\x80", "\xdf\xbf", "\xe0\xa0\x80", "\xed\x9f\xbf", "\xf0\x90\x80\x80", "\xf4\x8f\xbf\xbf"]:
    require(nameCircuit(buildNameEnvironment([name, name])).satisfied(), "UTF-8 shared node constraints")
  var forged = buildNameEnvironment(["a"])
  forged.nodes[0].value = 0x80
  forged.canonical[0].address = 0x80
  require(not nameCircuit(forged).satisfied(), "orphan continuation forgery")
  forged = buildNameEnvironment(["a", "b"])
  forged.nodes[1].value = forged.nodes[0].value
  forged.canonical[1].address = forged.canonical[0].address
  require(not nameCircuit(forged).satisfied(), "noncanonical duplicate byte/tail forgery")
  let original = fixture()
  validateModule(original)
  require(contextCircuit(original).satisfied(), "module initializer/limit/name context")
  let bytes = @[0'u8, 97, 115, 109, 1, 0, 0, 0, 1, 4, 1, 0x60, 0, 0,
    3, 2, 1, 0, 10, 4, 1, 2, 0, 0x0b]
  require(buildModuleValidationCircuit(bytes, 16).satisfied(), "production raw-input witness/circuit API")
  let empty = WasmModule(startFunc: -1, dataCount: -1)
  let omitted = fullCatch(original, catchRows(empty, 16), buildCatchEnvironment(original), moduleChecks = true)
  require(not omitted.satisfied(), "omitted function validation transcript")
  var invalidCases: int
  template invalid(change: untyped) =
    block:
      var candidate {.inject.} = fixture()
      change
      require(rejected(candidate), astToStr(change))
      inc invalidCases
  invalid: candidate.memories[0].limits.min = 65537
  invalid: candidate.tables[0].limits.min = 4
  invalid: candidate.globals[0].init.code[0].op = opI64Const
  invalid: candidate.globals[7].init.code[0].imm1 = 8
  invalid: candidate.globals[0].globalType.mut = mutVar
  invalid: candidate.globals[4].init.code[0].imm1 = 1
  invalid: candidate.globals[5].init.code[0].imm1 = 1
  invalid: candidate.globals[6].init.code[0].imm1 = 0
  invalid: candidate.globals[0].init.code.add Instr(op: opI32Const)
  invalid: candidate.elements[0].tableIdx = 1
  invalid: candidate.elements[0].init[0].code[0].op = opI32Const
  invalid: candidate.datas[0].offset.code[0].op = opI64Const
  invalid: candidate.exports[0].idx = 1
  invalid: candidate.exports[1].name = candidate.exports[0].name
  invalid: candidate.customSections[0].name = "\xed\xa0\x80"
  invalid: candidate.startFunc = 1
  invalid:
    candidate.types[0].params = @[vtI32]
  let parameters = WasmModule(startFunc: -1, dataCount: -1,
    types: @[FuncType(params: @[vtI32, vtExternRef, vtI64])], funcTypeIdxs: @[0'u32],
    codes: @[FuncBody(locals: @[LocalDecl(count: 0, valType: vtV128), LocalDecl(count: 3, valType: vtF64)],
      code: Expr(code: @[Instr(op: opLocalGet, imm1: 1), Instr(op: opDrop)]))])
  require(fullCatch(parameters, catchRows(parameters, 16), buildCatchEnvironment(parameters), moduleChecks = true).satisfied(),
    "source-order parameter ranges and zero-count declarations")
  let second = fixture(43)
  let a = fullCatch(original, catchRows(original, 16), buildCatchEnvironment(original), moduleChecks = true)
  let b = fullCatch(second, catchRows(second, 16), buildCatchEnvironment(second), moduleChecks = true)
  require(a.satisfied() and b.satisfied() and a.sameShape(b), "full module/event composition and shape")
  let key = setup(a)
  for circuit in [a, b]:
    let proof = encodeProof(prove(key, circuit))
    require(proof.len == 192 and decodeAndVerify(key.verificationKey, proof, circuit.values[1..circuit.publicCount]), "module proof")
  echo "zkbuild module context: PASS (", utf8Cases, " UTF-8 cases; 8 name circuits; 2 name forgeries; ",
    invalidCases, " coherent module forgeries; omitted-function transcript rejected; ", a.constraints.len, " constraints/16 rows; two 192-byte proofs)"

main()
