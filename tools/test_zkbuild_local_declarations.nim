import cps/wasm/[types, validate]
import cps/zk/[r1cs, read_only_memory, wasm_type_environment,
  wasm_signature_environment, wasm_indexed_signatures, wasm_local_ranges, wasm_local_declarations]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc inputs(c: var Circuit, entries: openArray[ReadOnlyEntry]): seq[ReadOnlyWires] =
  for entry in entries:
    result.add ReadOnlyWires(active: c.publicInput(scalar(ord(entry.active))),
      address: c.publicInput(scalar(entry.address)), value: c.publicInput(scalar(entry.value)))

proc build(module: WasmModule, environment: TypeEnvironment,
    declarations: LocalDeclarationEnvironment): Circuit =
  let sig = buildSignatureEnvironment(module, includeSingletons = true)
  let indexed = buildIndexedSignatures(sig)
  let witness = buildLocalDeclarationWitness(declarations, environment, sig, indexed)
  let ranges = buildLocalRangeWitness(environment)
  result = initCircuit(reuseRangeWitnesses = true)
  let envW = TypeEnvironmentWires(locals: result.inputs(environment.locals),
    localRanges: result.inputs(environment.localRanges), rangeTypes: result.inputs(environment.rangeTypes))
  let sigW = SignatureEnvironmentWires(signatures: result.inputs(sig.signatures))
  let indexW = IndexedSignatureWires(lengths: result.inputs(indexed.lengths), members: result.inputs(indexed.members))
  let declW = LocalDeclarationWires(totals: result.inputs(declarations.totals))
  result.constrainLocalRanges(envW, ranges)
  result.constrainLocalDeclarations(declW, envW, sigW, indexW, constant(0), constant(module.codes.len), witness)

proc fixture(params: seq[ValType]): WasmModule =
  result = WasmModule(startFunc: -1, dataCount: -1, types: @[FuncType(params: params)],
    funcTypeIdxs: @[0'u32], codes: @[FuncBody(locals: @[
      LocalDecl(count: 0, valType: vtV128), LocalDecl(count: 4, valType: vtF64)])])
  for index in 0..<params.len+4:
    result.codes[0].code.code.add Instr(op: opLocalGet, imm1: uint32(index))
    result.codes[0].code.code.add Instr(op: opDrop)

proc main() =
  var cases, entries: int
  for count in 0..7:
    let values = @[vtI32, vtExternRef, vtI64, vtF32, vtFuncRef, vtV128, vtF64]
    let module = fixture(values[0..<count])
    validateModule(module)
    let sparse = buildTypeEnvironment(module, compressedLocals = true)
    let expanded = buildTypeEnvironment(module)
    require(sparse.locals.len == expanded.locals.len, "sparse query coverage")
    for i, entry in sparse.locals:
      require(entry.address == expanded.locals[i].address and entry.value == expanded.locals[i].value, "binary-search local types")
      inc entries
    require(build(module, sparse, buildLocalDeclarationEnvironment(module, sparse)).satisfied(), "compressed parameter/range binding")
    inc cases
  let module = fixture(@[vtI32, vtExternRef, vtI64])
  let original = buildTypeEnvironment(module, compressedLocals = true)
  var bad = original
  bad.rangeTypes = @(original.rangeTypes)
  bad.locals = @(original.locals)
  bad.rangeTypes[0].value = 2
  bad.locals[0].value = 2
  require(not build(module, bad, buildLocalDeclarationEnvironment(module, bad)).satisfied(), "coherent forged parameter type")
  bad = original
  bad.localRanges = @(original.localRanges)
  for i in 0..<bad.localRanges.len:
    if i == 0: bad.localRanges[i].value += 1'u64 shl 32
    else: inc bad.localRanges[i].value
  require(not build(module, bad, buildLocalDeclarationEnvironment(module, bad)).satisfied(), "coherent nonunit parameter count")
  bad = original
  bad.localRanges = @(original.localRanges)
  bad.rangeTypes = @(original.rangeTypes)
  bad.localRanges.setLen(bad.localRanges.len-1)
  bad.rangeTypes.setLen(bad.rangeTypes.len-1)
  require(not build(module, bad, buildLocalDeclarationEnvironment(module, original)).satisfied(), "missing final declaration")
  let empty = WasmModule(startFunc: -1, dataCount: -1, types: @[FuncType()], funcTypeIdxs: @[0'u32], codes: @[FuncBody()])
  let env = buildTypeEnvironment(empty, compressedLocals = true)
  require(build(empty, env, buildLocalDeclarationEnvironment(empty, env)).satisfied(), "empty parameter/local namespace")
  echo "zkbuild local declarations: PASS (", cases+1, " contexts; ", entries,
    " sparse/expanded types; 3 coherent declaration forgeries)"

main()
