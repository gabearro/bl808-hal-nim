## Shared valid-module fixtures; production validation supplies the event traces.
import cps/wasm/[types, variable_typing, validate]
import cps/zk/wasm_instruction_events
import zkbuild_static_test_modules

proc initializer(tag: uint8): Expr =
  let opcode = case tag
    of 0: opI32Const
    of 1: opI64Const
    of 2: opF32Const
    of 3: opF64Const
    of 4: opV128Const
    else: opRefNull
  let immediate = if tag == 5: 0x70'u32 elif tag == 6: 0x6f'u32 else: 0'u32
  Expr(code: @[Instr(op: opcode, imm1: immediate)], v128Consts: @[default(array[16, byte])])

proc moduleForVariable*(code: uint16, declared: uint8, polymorphic = false): WasmModule =
  let rule = variableRuleForCode(code, declared)
  if not rule.present: raise newException(ValueError, "invalid variable-rule fixture")
  var params: seq[ValType]
  var instructions: seq[Instr]
  for i in countdown(int(rule.inputCount)-1, 0): params.add ValueTypes[int(rule.inputs[i])]
  if polymorphic: instructions.add Instr(op: opUnreachable)
  else:
    for i in 0..<params.len: instructions.add Instr(op: opLocalGet, imm1: uint32(i))
  let target = if typeEnvironmentKind(code) == tekLocal: uint32(params.len) else: 1'u32
  instructions.add Instr(op: Opcode(code), imm1: target)
  let results = if rule.outputCount == 0: newSeq[ValType]() else: @[ValueTypes[int(rule.outputType)]]
  let tableType = if declared in [5'u8, 6]: ValueTypes[int(declared)] else: vtFuncRef
  result = WasmModule(startFunc: -1, dataCount: -1,
    types: @[FuncType(params: params, results: results)], funcTypeIdxs: @[0'u32],
    imports: @[Import(kind: ikGlobal, module: "host", name: "global",
        globalType: GlobalType(valType: vtI32, mut: mutConst)),
      Import(kind: ikTable, module: "host", name: "table",
        tableType: TableType(elemType: vtFuncRef, limits: Limits(min: 1)))],
    globals: @[GlobalDef(globalType: GlobalType(valType: ValueTypes[int(declared)], mut: mutVar),
      init: initializer(declared))],
    tables: @[TableType(elemType: tableType, limits: Limits(min: 1))],
    codes: @[FuncBody(locals: @[LocalDecl(count: 1, valType: ValueTypes[int(declared)])],
      code: Expr(code: instructions))])

proc variableImmediates*(module: WasmModule, rows: openArray[InstructionEventRow], imports = 0'u32): seq[uint32] =
  result.setLen(rows.len)
  for i, row in rows:
    if row.control.operand.kind == uint8(ord(veInstructionBegin)):
      let body = int(row.control.operand.functionIndex-imports)
      if int(row.pc) < module.codes[body].code.code.len:
        result[i] = module.codes[body].code.code[int(row.pc)].imm1

