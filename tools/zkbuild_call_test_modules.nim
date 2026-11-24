## Shared direct/indirect and ordinary/tail call fixtures.
import cps/wasm/types

proc moduleForCall*(code: uint16, params, results: seq[ValType], polymorphic = false): WasmModule =
  let indirect = code in [0x11'u16, 0x13]
  var callerParams = params
  if indirect: callerParams.add vtI32
  var instructions: seq[Instr]
  if polymorphic: instructions.add Instr(op: opUnreachable)
  else:
    for i in 0..<callerParams.len: instructions.add Instr(op: opLocalGet, imm1: uint32(i))
  instructions.add Instr(op: Opcode(code), imm1: 0, imm2: uint32(ord(indirect)))
  WasmModule(startFunc: -1, dataCount: -1,
    types: @[FuncType(params: params, results: results), FuncType(params: callerParams, results: results)],
    imports: @[Import(kind: ikFunc, module: "host", name: "callee", funcTypeIdx: 0),
      Import(kind: ikTable, module: "host", name: "external", tableType: TableType(elemType: vtExternRef, limits: Limits(min: 1)))],
    tables: @[TableType(elemType: vtFuncRef, limits: Limits(min: 1))], funcTypeIdxs: @[1'u32],
    codes: @[FuncBody(code: Expr(code: instructions))])

