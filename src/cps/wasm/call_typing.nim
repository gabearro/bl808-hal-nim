## Direct resolution for independent validation-transcript replay.
## Parameter tags are in pop order; result tags remain in source order.
import types, variable_typing

type CallRule* = object
  present*, tail*, indirect*: bool
  inputs*, outputs*: seq[uint8]

proc callRule*(module: WasmModule, body: int, instruction: Instr): CallRule =
  if instruction.op notin {opCall, opCallIndirect, opReturnCall, opReturnCallIndirect}: return
  if body < 0 or body >= module.funcTypeIdxs.len: return
  let current = module.funcTypeIdxs[body]
  if uint64(current) >= uint64(module.types.len): return
  result.tail = instruction.op in {opReturnCall, opReturnCallIndirect}
  result.indirect = instruction.op in {opCallIndirect, opReturnCallIndirect}
  var typeIndex: uint32
  if result.indirect:
    var tableIndex = uint64(instruction.imm2)
    var tableType: ValType
    var found = false
    for item in module.imports:
      if item.kind == ikTable:
        if tableIndex == 0:
          tableType = item.tableType.elemType
          found = true
          break
        dec tableIndex
    if not found and tableIndex < uint64(module.tables.len):
      tableType = module.tables[int(tableIndex)].elemType
      found = true
    if not found or tableType != vtFuncRef: return
    typeIndex = instruction.imm1
    result.inputs.add 0
  else:
    var functionIndex = uint64(instruction.imm1)
    var found = false
    for item in module.imports:
      if item.kind == ikFunc:
        if functionIndex == 0:
          typeIndex = item.funcTypeIdx
          found = true
          break
        dec functionIndex
    if not found:
      if functionIndex >= uint64(module.funcTypeIdxs.len): return
      typeIndex = module.funcTypeIdxs[int(functionIndex)]
  if uint64(typeIndex) >= uint64(module.types.len): return
  let signature = module.types[int(typeIndex)]
  if result.tail and signature.results != module.types[int(current)].results: return
  for i in countdown(signature.params.high, 0): result.inputs.add stackTypeTag(signature.params[i])
  if not result.tail:
    for value in signature.results: result.outputs.add stackTypeTag(value)
  result.present = true
