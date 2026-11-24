## Integrated checks for the broad module/decoder/IR/prover implementation.
import cps/wasm/[types, binary, block_types, validate, runtime, flash_image, utf8_names]
import cps/wasm/jit/lower
import cps/zk/[r1cs, prover, wasm_catch_environment]
import zkbuild_catch_test_helpers

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

proc main() =
  var cases: int
  for bytes in [@[0x41'u8, 0xff, 0xff, 0xff, 0xff, 0x0f, 0x0b],
      @[0x42'u8, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 1, 0x0b]]:
    var rejected = false
    try: discard decodeExprBytes(bytes, optimize = false)
    except WasmDecodeError: rejected = true
    require(rejected, "signed LEB overflow accepted")
    inc cases
  let header = @[0'u8, 97, 115, 109, 1, 0, 0, 0]
  for bytes in [header & @[1'u8, 5, 0xff, 0xff, 0xff, 0xff, 0x1f],
      header & @[1'u8, 5, 0xff, 0xff, 0xff, 0xff, 0x0f],
      header & @[5'u8, 3, 1, 2, 0]]:
    var rejected = false
    try: discard decodeModule(bytes, optimize = false)
    except WasmDecodeError: rejected = true
    require(rejected, "invalid count/limit encoding")
    inc cases
  for value in ["", "plain", "\0", "\xc2\x80", "\xe0\xa0\x80", "\xed\x9f\xbf", "\xf4\x8f\xbf\xbf"]:
    require(validWasmName(value), "valid UTF-8 name")
    inc cases
  for value in ["\xc0\x80", "\xed\xa0\x80", "\xe0\x80\x80", "\xf4\x90\x80\x80", "\x80", "\xf0"]:
    require(not validWasmName(value), "invalid UTF-8 scalar name")
    inc cases
  for index in [65279'u32, 65280, 65536, 0x80000000'u32, high(uint32)]:
    let expr = decodeExprBytes(@[2'u8] & leb(index) & @[0x0b'u8, 0x0b], optimize = false)
    require(resolveBlockType(expr, 0).typeIdx == index, "full-width block type preservation")
    require(sizeof(Instr) == 12, "compact instruction size")
    inc cases
  block:
    var module = WasmModule(startFunc: -1, dataCount: -1,
      types: newSeq[FuncType](65537), funcTypeIdxs: @[0'u32],
      exports: @[Export(name: "run", kind: ekFunc, idx: 0)])
    module.types[0].results = @[vtI32]
    for optimize in [false, true]:
      module.codes = @[FuncBody(code: decodeExprBytes(@[2'u8] & leb(65536) &
        @[0x0b'u8, 0x41, 42, 0x0b], optimize))]
      validateModule(module)
      discard lowerFunction(module, 0)
      var vm = initWasmVM()
      let index = vm.instantiate(module, [])
      require(vm.invoke(index, "run", [])[0].i32 == 42, "wide block decoder/validator/JIT/runtime integration")
      vm.destroyWasmVM()
      inc cases
  block:
    var module = WasmModule(startFunc: -1, dataCount: -1, memories: @[MemType(limits: Limits(min: 1))],
      globals: @[GlobalDef(globalType: GlobalType(valType: vtI32), init: Expr(code: @[Instr(op: opI32Const)]))],
      datas: @[DataSegment(mode: dataActive, offset: Expr(code: @[Instr(op: opGlobalGet)]))])
    require(accepted(module), "initialized immutable global in segment offset")
    module.globals[0].globalType.mut = mutVar
    require(not accepted(module), "mutable offset global")
    cases += 2
    module.globals[0].globalType.mut = mutConst
    module.globals[0].init = Expr(code: @[Instr(op: opGlobalGet)])
    require(not accepted(module), "self-referential initializer")
    inc cases
  block:
    var module = WasmModule(startFunc: -1, dataCount: -1, imports: @[
      Import(kind: ikMemory, memType: MemType(limits: Limits(min: 65537)))])
    require(not accepted(module), "import memory page limits")
    module.imports = @[Import(kind: ikTable, tableType: TableType(elemType: vtFuncRef,
      limits: Limits(min: 2, max: 1, hasMax: true)))]
    require(not accepted(module), "import table limits")
    cases += 2
  proc localModule(count: uint32): WasmModule =
    WasmModule(startFunc: -1, dataCount: -1, types: @[FuncType(results: @[vtI32])], funcTypeIdxs: @[0'u32],
      codes: @[FuncBody(locals: @[LocalDecl(count: count, valType: vtI32)],
        code: Expr(code: @[Instr(op: opLocalGet, imm1: count-1)]))])
  let large = localModule(high(uint32))
  let small = localModule(17)
  validateModule(large)
  validateModule(small)
  let a = fullCatch(large, catchRows(large, 16), buildCatchEnvironment(large), moduleChecks = true)
  let b = fullCatch(small, catchRows(small, 16), buildCatchEnvironment(small), moduleChecks = true)
  require(a.satisfied() and b.satisfied() and a.sameShape(b), "compressed u32 local declarations")
  let key = setup(a)
  for circuit in [a, b]:
    let proof = encodeProof(prove(key, circuit))
    require(decodeAndVerify(key.verificationKey, proof, circuit.values[1..circuit.publicCount]), "large-local proof")
  echo "WASM module integration: PASS (", cases, " decoder/module/wide-IR cases; u32 locals in ",
    a.constraints.len, " constraints/16 rows; two 192-byte proofs)"

main()
