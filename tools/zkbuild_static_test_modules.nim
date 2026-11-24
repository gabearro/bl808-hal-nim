import cps/wasm/[types, static_typing]

const ValueTypes* = [vtI32, vtI64, vtF32, vtF64, vtV128, vtFuncRef, vtExternRef]

proc moduleForStaticRule*(code: uint16, polymorphic = false, wildcard = 0'u8): WasmModule =
  let rule = staticRuleForCode(code)
  var params: seq[ValType]
  var instructions: seq[Instr]
  if polymorphic:
    instructions.add Instr(op: opUnreachable)
  else:
    for i in countdown(int(rule.inputCount)-1, 0):
      let input = rule.inputs[i]
      let actual = if input == AnyStackType: wildcard
        elif input == ReferenceStackType: (if wildcard in [5'u8, 6]: wildcard else: 5'u8)
        else: input
      params.add ValueTypes[int(actual)]
    for i in 0..<params.len: instructions.add Instr(op: opLocalGet, imm1: uint32(i))
  instructions.add Instr(op: Opcode(code))
  let results = if rule.outputCount == 0: newSeq[ValType]() else: @[ValueTypes[int(rule.outputType)]]
  result = WasmModule(startFunc: -1, dataCount: 1,
    types: @[FuncType(params: params, results: results)], funcTypeIdxs: @[0'u32],
    memories: @[MemType(limits: Limits(min: 1))],
    tables: @[TableType(elemType: vtFuncRef, limits: Limits(min: 1))],
    datas: @[DataSegment(mode: dataPassive)],
    elements: @[ElemSegment(mode: elemPassive, elemType: vtFuncRef,
      init: @[Expr(code: @[Instr(op: opRefFunc, imm1: 0)])])],
    codes: @[FuncBody(code: Expr(code: instructions, v128Consts: @[default(array[16, byte])]))])
