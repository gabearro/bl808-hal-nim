## Module-wide validation and one shared context for all function bodies.
## Constant expressions use the initialized immutable-global context.
import std/sets
import ./utf8_names
import types, reference_context

type
  ModuleValidationError* = object of CatchableError
  ModuleContext* = object
    functions*: seq[FuncType]
    tables*: seq[TableType]
    memories*: seq[MemType]
    globals*: seq[GlobalType]
    declaredReferences*: seq[uint32]
    importedFunctions*, importedGlobals*: int

proc invalid(message: string) {.noreturn.} =
  raise newException(ModuleValidationError, message)

func supportedValueType(value: ValType): bool =
  value in {vtI32, vtI64, vtF32, vtF64, vtV128, vtFuncRef, vtExternRef}

proc limits(value: Limits, maximum: uint32, name: string) =
  if value.min > maximum or (value.hasMax and (value.max > maximum or value.min > value.max)):
    invalid(name & ": invalid limits")

proc table(value: TableType) =
  if value.elemType notin {vtFuncRef, vtExternRef}: invalid("table: invalid reference type")
  limits(value.limits, high(uint32), "table")

proc global(value: GlobalType) =
  if not supportedValueType(value.valType) or value.mut notin {mutConst, mutVar}:
    invalid("global: invalid type")

proc validateTagType(module: WasmModule, index: uint32) =
  if index.uint64 >= module.types.len.uint64 or module.types[index.int].results.len != 0:
    invalid("exception tag: invalid result-free function type")

proc name(value: string) =
  if not validWasmName(value): invalid("name contains invalid UTF-8")

proc constantExpressionType*(module: WasmModule, context: ModuleContext, expression: Expr,
    availableGlobals = -1): ValType =
  if expression.code.len != 1: invalid("constant expression must produce exactly one value")
  let instruction = expression.code[0]
  case instruction.op
  of opI32Const: vtI32
  of opI64Const: vtI64
  of opF32Const: vtF32
  of opF64Const: vtF64
  of opV128Const:
    if uint64(instruction.imm1) >= uint64(expression.v128Consts.len): invalid("constant expression: invalid vector index")
    vtV128
  of opRefNull:
    if instruction.imm1 == uint32(ord(vtFuncRef)): vtFuncRef
    elif instruction.imm1 == uint32(ord(vtExternRef)): vtExternRef
    else: invalid("constant expression: invalid reference type")
  of opRefFunc:
    if uint64(instruction.imm1) >= uint64(context.functions.len): invalid("constant expression: invalid function reference")
    vtFuncRef
  of opGlobalGet:
    let available = if availableGlobals < 0: context.globals.len else: availableGlobals
    if uint64(instruction.imm1) >= uint64(available): invalid("constant expression: global is not initialized")
    let declared = context.globals[int(instruction.imm1)]
    if declared.mut != mutConst: invalid("constant expression: global must be immutable")
    declared.valType
  else: invalid("nonconstant instruction in initializer: " & $instruction.op)

proc expectConstant(module: WasmModule, context: ModuleContext, expression: Expr, expected: ValType,
    availableGlobals = -1) =
  if constantExpressionType(module, context, expression, availableGlobals) != expected: invalid("initializer type mismatch")

proc validateModuleContext*(module: WasmModule): ModuleContext =
  if module.startFunc < -1 or module.startFunc > int64(high(uint32)) or
      module.dataCount < -1 or module.dataCount > int64(high(uint32)):
    invalid("optional module header outside u32 range")
  if module.funcTypeIdxs.len != module.codes.len: invalid("function and code section counts differ")
  for signature in module.types:
    for value in signature.params:
      if not supportedValueType(value): invalid("function: invalid parameter type")
    for value in signature.results:
      if not supportedValueType(value): invalid("function: invalid result type")
  var tagCount = module.tagDefs.len
  for item in module.imports:
    name(item.module)
    name(item.name)
    case item.kind
    of ikFunc:
      if uint64(item.funcTypeIdx) >= uint64(module.types.len): invalid("import function: invalid type index")
      result.functions.add module.types[int(item.funcTypeIdx)]
      inc result.importedFunctions
    of ikTable:
      table(item.tableType)
      result.tables.add item.tableType
    of ikMemory:
      limits(item.memType.limits, 65536, "import memory")
      result.memories.add item.memType
    of ikGlobal:
      global(item.globalType)
      result.globals.add item.globalType
      inc result.importedGlobals
    of ikTag:
      module.validateTagType(item.tagTypeIdx)
      inc tagCount
  for index in module.funcTypeIdxs:
    if uint64(index) >= uint64(module.types.len): invalid("function: invalid type index")
    result.functions.add module.types[int(index)]
  for declared in module.tables:
    table(declared)
    result.tables.add declared
  for declared in module.memories:
    limits(declared.limits, 65536, "memory")
    result.memories.add declared
  if result.memories.len > 1: invalid("at most one memory allowed")
  for tag in module.tagDefs:
    module.validateTagType(tag.typeIdx)
  for declared in module.globals:
    global(declared.globalType)
    result.globals.add declared.globalType
  for i, declared in module.globals:
    expectConstant(module, result, declared.init, declared.globalType.valType, result.importedGlobals+i)
  for segment in module.elements:
    if segment.elemType notin {vtFuncRef, vtExternRef}: invalid("element segment: invalid reference type")
    for expression in segment.init: expectConstant(module, result, expression, segment.elemType)
    if segment.mode == elemActive:
      if uint64(segment.tableIdx) >= uint64(result.tables.len): invalid("element segment: invalid table index")
      if result.tables[int(segment.tableIdx)].elemType != segment.elemType: invalid("element/table type mismatch")
      expectConstant(module, result, segment.offset, vtI32)
  for segment in module.datas:
    if segment.mode == dataActive:
      if uint64(segment.memIdx) >= uint64(result.memories.len): invalid("data segment: invalid memory index")
      expectConstant(module, result, segment.offset, vtI32)
  if module.dataCount >= 0 and module.dataCount != int64(module.datas.len): invalid("data count mismatch")
  if module.startFunc >= 0:
    if uint64(module.startFunc) >= uint64(result.functions.len): invalid("start function: invalid index")
    let signature = result.functions[int(module.startFunc)]
    if signature.params.len != 0 or signature.results.len != 0: invalid("start function must have type [] -> []")
  var names: HashSet[string]
  for item in module.exports:
    name(item.name)
    if item.name in names: invalid("duplicate export name")
    names.incl item.name
    let size = case item.kind
      of ekFunc: result.functions.len
      of ekTable: result.tables.len
      of ekMemory: result.memories.len
      of ekGlobal: result.globals.len
      of ekTag: tagCount
    if uint64(item.idx) >= uint64(size): invalid("export index out of range")
  for section in module.customSections: name(section.name)
  result.declaredReferences = declaredFunctionReferences(module)
  for index in result.declaredReferences:
    if uint64(index) >= uint64(result.functions.len): invalid("declaration: invalid function reference")
  for i, body in module.codes:
    var total = uint64(result.functions[result.importedFunctions+i].params.len)
    for local in body.locals:
      if not supportedValueType(local.valType): invalid("local: invalid value type")
      total += uint64(local.count)
      if total > uint64(high(uint32)): invalid("local index space overflow")
