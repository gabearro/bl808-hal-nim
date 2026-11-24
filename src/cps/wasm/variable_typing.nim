## Context-dependent signatures for variable and table instructions.
## The declared type and mutability must come from authenticated module data.
import types, static_typing

type TypeEnvironmentKind* = enum tekNone, tekLocal, tekGlobal, tekTable

func typeEnvironmentKind*(code: uint16): TypeEnvironmentKind =
  case int(code)
  of 0x20..0x22: tekLocal
  of 0x23..0x24: tekGlobal
  of 0x25..0x26, 0x10f..0x111: tekTable
  else: tekNone

func stackTypeTag*(value: ValType): uint8 =
  case value
  of vtI32: 0
  of vtI64: 1
  of vtF32: 2
  of vtF64: 3
  of vtV128: 4
  of vtFuncRef: 5
  of vtExternRef: 6

func variableRuleForCode*(code: uint16, declared: uint8): StaticRule =
  if declared > 6: return
  let kind = typeEnvironmentKind(code)
  if kind == tekNone or (kind == tekTable and declared notin {5'u8, 6'u8}): return
  result.present = true
  case int(code)
  of 0x20, 0x23:
    result.outputCount = 1
    result.outputType = declared
  of 0x21, 0x24:
    result.inputCount = 1
    result.inputs[0] = declared
  of 0x22:
    result.inputCount = 1
    result.inputs[0] = declared
    result.outputCount = 1
    result.outputType = declared
  of 0x25:
    result.inputCount = 1
    result.outputCount = 1
    result.outputType = declared
  of 0x26:
    result.inputCount = 2
    result.inputs[0] = declared
  of 0x10f:
    result.inputCount = 2
    result.inputs[1] = declared
    result.outputCount = 1
  of 0x110: result.outputCount = 1
  of 0x111:
    result.inputCount = 3
    result.inputs[1] = declared
  else: discard

proc variableRule*(module: WasmModule, body: int, instruction: Instr): StaticRule =
  ## Independent direct resolution used by transcript replay. No proof-table
  ## query or sorted RAM witness participates in this computation.
  let code = uint16(ord(instruction.op))
  let index = uint64(instruction.imm1)
  case typeEnvironmentKind(code)
  of tekLocal:
    if body < 0 or body >= module.codes.len or body >= module.funcTypeIdxs.len: return
    let tid = uint64(module.funcTypeIdxs[body])
    if tid >= uint64(module.types.len): return
    let params = module.types[int(tid)].params
    if index < uint64(params.len): return variableRuleForCode(code, stackTypeTag(params[int(index)]))
    var remaining = index-uint64(params.len)
    for declaration in module.codes[body].locals:
      if remaining < uint64(declaration.count):
        return variableRuleForCode(code, stackTypeTag(declaration.valType))
      remaining -= uint64(declaration.count)
  of tekGlobal:
    var remaining = index
    template found(value: GlobalType) =
      if instruction.op == opGlobalSet and value.mut != mutVar: return
      return variableRuleForCode(code, stackTypeTag(value.valType))
    for item in module.imports:
      if item.kind == ikGlobal:
        if remaining == 0: found(item.globalType)
        dec remaining
    if remaining < uint64(module.globals.len): found(module.globals[int(remaining)].globalType)
  of tekTable:
    var remaining = index
    for item in module.imports:
      if item.kind == ikTable:
        if remaining == 0: return variableRuleForCode(code, stackTypeTag(item.tableType.elemType))
        dec remaining
    if remaining < uint64(module.tables.len):
      return variableRuleForCode(code, stackTypeTag(module.tables[int(remaining)].elemType))
  else: discard
