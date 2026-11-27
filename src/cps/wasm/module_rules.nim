## Module-wide validation and one shared context for all function bodies.
## Constant expressions use the initialized immutable-global context.
import std/sets
import ./utf8_names
import types, reference_context

type
  ModuleValidationError* = object of CatchableError
  ModuleContext* = object
    functions*: seq[FuncType]
    when defined(wasmFunctionReferences):
      functionTypeIndices*: seq[uint32]
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
  when defined(wasmSharedCoreTypes):
    if value.limits.shared and not value.elementReference.isSharedCoreReference():
      invalid("shared table requires a shared element reference type")
  limits(value.limits, high(uint32), "table")

proc global(value: GlobalType) =
  if not supportedValueType(value.valType) or value.mut notin {mutConst, mutVar}:
    invalid("global: invalid type")
  when defined(wasmSharedCoreTypes):
    if not value.hasValidGlobalSharing():
      invalid("shared global requires a shared reference type")

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
    when defined(wasmFunctionReferences):
      if instruction.imm2 != 0 and (instruction.imm1 != vtFuncRef.ord.uint32 or
          not validFunctionHeapTag(instruction.imm2, module.types.len)):
        invalid("constant expression: invalid function heap type")
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
    availableGlobals = -1, reference = CoreReferenceType(), sharedContext = false) =
  if constantExpressionType(module, context, expression, availableGlobals) != expected: invalid("initializer type mismatch")
  when defined(wasmFunctionReferences):
    let instruction = expression.code[0]
    when defined(wasmSharedCoreTypes):
      if sharedContext and instruction.op == opGlobalGet and
          not context.globals[instruction.imm1.int].shared:
        invalid("shared initializer accesses an unshared global")
    if expected.isRefType():
      let actual = case instruction.op
        of opRefNull:
          if instruction.imm2 in [0'u32, WasmNoFuncHeapTag]:
            var reference = CoreReferenceType(member: instruction.imm2)
            when defined(wasmSharedCoreTypes): reference.sharedAbstract = instruction.pad != 0
            reference
          else: module.types[instruction.imm2.int - 1].coreFunctionReference()
        of opRefFunc: context.functions[instruction.imm1.int].coreFunctionReference(nonNull = true)
        of opGlobalGet: context.globals[instruction.imm1.int].reference
        else: CoreReferenceType()
      if not matchesCoreReference(actual, reference): invalid("initializer reference type mismatch")

proc validateModuleContext*(module: WasmModule, allowMultipleMemories = false,
                            allowFunctionSubtyping = false): ModuleContext =
  if module.startFunc < -1 or module.startFunc > int64(high(uint32)) or
      module.dataCount < -1 or module.dataCount > int64(high(uint32)):
    invalid("optional module header outside u32 range")
  if module.funcTypeIdxs.len != module.codes.len: invalid("function and code section counts differ")
  for signature in module.types:
    when not defined(wasmFunctionReferences):
      if signature.definition != nil and not allowFunctionSubtyping:
        invalid("function subtyping requires the component execution profile")
    when defined(wasmSharedCoreTypes):
      if not signature.hasSharedCoreLanes():
        invalid("shared core function has an unshared parameter or result")
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
      when defined(wasmFunctionReferences): result.functionTypeIndices.add item.funcTypeIdx
      inc result.importedFunctions
    of ikTable:
      table(item.tableType)
      result.tables.add item.tableType
    of ikMemory:
      if not item.memType.limits.validMemoryLimits(): invalid("import memory: invalid limits")
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
    when defined(wasmFunctionReferences): result.functionTypeIndices.add index
  when defined(wasmFunctionReferences):
    var nextInitializer = 0
  for i, declared in module.tables:
    table(declared)
    result.tables.add declared
    when defined(wasmFunctionReferences):
      if nextInitializer < module.tableInitializers.len and
          module.tableInitializers[nextInitializer].index == i.uint32:
        expectConstant(module, result, module.tableInitializers[nextInitializer].init,
          declared.elemType, result.importedGlobals, declared.elementReference,
          (when defined(wasmSharedCoreTypes): declared.limits.shared else: false))
        inc nextInitializer
      elif declared.elementReference.nonNull:
        invalid("non-nullable table requires an explicit initializer")
  when defined(wasmFunctionReferences):
    if nextInitializer != module.tableInitializers.len:
      invalid("invalid table initializer index or order")
  for declared in module.memories:
    if not declared.limits.validMemoryLimits(): invalid("memory: invalid limits")
    result.memories.add declared
  if not allowMultipleMemories and result.memories.len > 1:
    invalid("at most one memory allowed")
  if result.memories.len > uint16.high.int + 1:
    invalid("memory count exceeds interpreter limit")
  for tag in module.tagDefs:
    module.validateTagType(tag.typeIdx)
  for declared in module.globals:
    global(declared.globalType)
    result.globals.add declared.globalType
  for i, declared in module.globals:
    let globalType {.cursor.} = declared.globalType
    expectConstant(module, result, declared.init, globalType.valType, result.importedGlobals+i,
      (when defined(wasmFunctionReferences): globalType.reference else: CoreReferenceType()),
      (when defined(wasmSharedCoreTypes): globalType.shared else: false))
  for segment in module.elements:
    if segment.elemType notin {vtFuncRef, vtExternRef}: invalid("element segment: invalid reference type")
    when defined(wasmSharedCoreTypes):
      if segment.shared and not segment.elementReference.isSharedCoreReference():
        invalid("shared element segment requires a shared reference type")
    when defined(wasmFunctionReferences):
      for expression in segment.init:
        expectConstant(module, result, expression, segment.elemType,
          reference = segment.elementReference,
          sharedContext = (when defined(wasmSharedCoreTypes): segment.shared else: false))
    else:
      for expression in segment.init: expectConstant(module, result, expression, segment.elemType)
    if segment.mode == elemActive:
      if uint64(segment.tableIdx) >= uint64(result.tables.len): invalid("element segment: invalid table index")
      let target {.cursor.} = result.tables[segment.tableIdx.int]
      if target.elemType != segment.elemType: invalid("element/table type mismatch")
      when defined(wasmSharedCoreTypes):
        if segment.shared and not target.limits.shared:
          invalid("shared element segment targets an unshared table")
      when defined(wasmFunctionReferences):
        if not matchesCoreReference(segment.elementReference, target.elementReference):
          invalid("element/table reference type mismatch")
        expectConstant(module, result, segment.offset, vtI32,
          sharedContext = (when defined(wasmSharedCoreTypes): segment.shared else: false))
      else: expectConstant(module, result, segment.offset, vtI32)
  for segment in module.datas:
    if segment.mode == dataActive:
      if uint64(segment.memIdx) >= uint64(result.memories.len): invalid("data segment: invalid memory index")
      when defined(wasmSharedCoreTypes):
        if segment.shared and not result.memories[segment.memIdx.int].limits.shared:
          invalid("shared data segment targets an unshared memory")
      expectConstant(module, result, segment.offset, vtI32,
        sharedContext = (when defined(wasmSharedCoreTypes): segment.shared else: false))
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
      when defined(wasmFunctionReferences):
        if local.functionType != 0 and (local.valType != vtFuncRef or
            not validFunctionHeapTag(local.functionType, module.types.len)):
          invalid("local: invalid function heap type")
      when defined(wasmSharedCoreTypes):
        if result.functions[result.importedFunctions+i].shared and local.valType.isRefType() and
            not module.types.isSharedCoreHeapTag(local.functionType, local.sharedReference):
          invalid("shared core function has an unshared local")
      total += uint64(local.count)
      if total > uint64(high(uint32)): invalid("local index space overflow")
