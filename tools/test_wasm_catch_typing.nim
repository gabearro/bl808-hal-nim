import cps/wasm/[types, binary, validate, runtime]
import cps/zk/wasm_trace_check

const Types = [vtI32, vtI64, vtF32, vtF64, vtV128, vtFuncRef, vtExternRef]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc accepted(module: WasmModule): bool =
  try: validateModule(module); true
  except ValidationError: false

proc fixture*(params: seq[ValType], kind = ckCatch, loop = false): WasmModule =
  var target: seq[ValType]
  if kind in {ckCatch, ckCatchRef}: target = params
  if kind in {ckCatchRef, ckCatchAllRef}: target.add vtExternRef
  let frameType = if loop: FuncType(params: target) else: FuncType(results: target)
  var code: seq[Instr]
  if loop: code.add Instr(op: opUnreachable)
  code.add Instr(op: (if loop: opLoop else: opBlock), pad: 0x102)
  code.add @[Instr(op: opTryTable), Instr(op: opUnreachable), Instr(op: opEnd),
    Instr(op: opUnreachable), Instr(op: opEnd)]
  if not loop:
    for _ in target: code.add Instr(op: opDrop)
  WasmModule(startFunc: -1, dataCount: -1,
    types: @[FuncType(), FuncType(params: params), frameType], funcTypeIdxs: @[0'u32],
    tagDefs: @[WasmTagDef(typeIdx: 1)],
    codes: @[FuncBody(code: Expr(code: code, catchTables: @[@[CatchClause(kind: kind)]]))])

proc execute(bytes: seq[byte], types: seq[FuncType], expected: int32, locals: seq[LocalDecl] = @[]): int =
  var module = WasmModule(startFunc: -1, dataCount: -1, types: types,
    funcTypeIdxs: @[0'u32], tagDefs: @[WasmTagDef(typeIdx: 1)],
    exports: @[Export(name: "run", kind: ekFunc, idx: 0)],
    codes: @[FuncBody(locals: locals, code: decodeExprBytes(bytes, optimize = false))])
  validateModule(module)
  var vm = initWasmVM()
  let index = vm.instantiate(module, [])
  let output = vm.invoke(index, "run", [])
  require(output.len == 1 and output[0].i32 == expected, "catch runtime result")
  vm.destroyWasmVM()
  1

proc main() =
  var cases, rejected, executions: int
  for count in 0..3:
    for seed in 0..6:
      var params: seq[ValType]
      for i in 0..<count: params.add Types[(seed+i) mod 7]
      for kind in [ckCatch, ckCatchRef, ckCatchAll, ckCatchAllRef]:
        for loop in [false, true]:
          let module = fixture(params, kind, loop)
          require(accepted(module), "valid catch type vector")
          let events = traceModuleValidation(module, labelChecks = true, catchChecks = true)
          require(checkValidationTraceStructure(module, events, true, true).accepted, "catch trace replay")
          var count = 0
          for event in events:
            if event.kind == veLabelCheck: inc count
          require(count == 1, "exactly one catch marker including empty payload")
          inc cases
  for mutation in 0..5:
    var module = fixture(@[vtI32])
    case mutation
    of 0: module.codes[0].code.catchTables[0][0].labelDepth = high(uint32)
    of 1: module.codes[0].code.catchTables[0][0].tagIdx = high(uint32)
    of 2: module.codes[0].code.code[1].imm2 = 1
    of 3: module.types[2].results = @[vtI64]
    of 4: module.types[2].results = @[]
    else: module.codes[0].code.catchTables[0][0].kind = ckCatchRef
    require(not accepted(module), "invalid catch type/depth/tag/table")
    inc rejected
  block:
    var module = fixture(@[vtI32])
    let events = traceModuleValidation(module, true, true)
    var omitted: seq[ValidationEvent]
    for event in events:
      if event.kind != veLabelCheck: omitted.add event
    require(not checkValidationTraceStructure(module, omitted, true, true).accepted, "omitted catch marker")
    module.codes[0].code.catchTables[0][0].labelDepth = 1
    require(not checkValidationTraceStructure(module, events, true, true).accepted, "changed catch target")
    rejected += 2
  let types = @[FuncType(results: @[vtI32]), FuncType(params: @[vtI32])]
  executions += execute(@[0x02'u8, 0x7f, 0x1f, 0x40, 1, 0, 0, 0,
    0x41, 42, 8, 0, 0x0b, 0, 0x0b, 0x0b], types, 42)
  executions += execute(@[0x02'u8, 0x40, 0x1f, 0x40, 1, 2, 0,
    0x41, 42, 8, 0, 0x0b, 0, 0x0b, 0x41, 7, 0x0b], types, 7)
  executions += execute(@[2'u8, 2, 0x1f, 0x40, 1, 1, 0, 0,
    0x41, 42, 8, 0, 0x0b, 0, 0x0b, 0x1a, 0x0b],
    types & @[FuncType(results: @[vtI32, vtExternRef])], 42)
  executions += execute(@[2'u8, 0x6f, 0x1f, 0x40, 1, 3, 0,
    0x41, 42, 8, 0, 0x0b, 0, 0x0b, 0x1a, 0x41, 7, 0x0b], types, 7)
  executions += execute(@[2'u8, 2, 0x1f, 0x40, 1, 0, 0, 0,
    0x41, 1, 0x41, 2, 8, 0, 0x0b, 0, 0x0b, 0x6b, 0x0b],
    @[types[0], FuncType(params: @[vtI32, vtI32]), FuncType(results: @[vtI32, vtI32])], -1)
  executions += execute(@[0x41'u8, 0, 0x03, 2, 0x22, 0, 0x41, 1, 0x6a,
    0x22, 0, 0x41, 2, 0x48, 0x04, 0x40, 0x1f, 0x40, 1, 0, 0, 1,
    0x20, 0, 8, 0, 0x0b, 0x0b, 0x20, 0, 0x0c, 1, 0x0b, 0x0b],
    types & @[FuncType(params: @[vtI32], results: @[vtI32])], 2,
    @[LocalDecl(count: 1, valType: vtI32)])
  block:
    var module = WasmModule(startFunc: -1, dataCount: -1,
      types: types & @[FuncType()], funcTypeIdxs: @[0'u32, 2], tagDefs: @[WasmTagDef(typeIdx: 1)],
      exports: @[Export(name: "run", kind: ekFunc, idx: 0)], codes: @[
        FuncBody(code: decodeExprBytes(@[2'u8, 0x7f, 0x1f, 0x40, 1, 0, 0, 0,
          0x10, 1, 0x0b, 0, 0x0b, 0x0b], optimize = false)),
        FuncBody(code: decodeExprBytes(@[0x41'u8, 42, 8, 0, 0x0b], optimize = false))])
    validateModule(module)
    var vm = initWasmVM()
    let index = vm.instantiate(module, [])
    require(vm.invoke(index, "run", [])[0].i32 == 42, "catch unwinds child call frame")
    vm.destroyWasmVM()
    inc executions
  echo "WASM catch typing: PASS (", cases, " typed block/loop clauses; ", rejected,
    " type/context/trace rejections; ", executions, " runtime handler executions)"

when isMainModule: main()
