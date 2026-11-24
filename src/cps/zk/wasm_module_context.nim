## Module-wide constraints over decoded declarations. This binds the shared
## function/object/segment/reference tables to one module context. Raw bytes
## and their commitment still need an authenticated parser relation.
import std/[tables, algorithm]
import ../wasm/[types,variable_typing]
import r1cs, range_check, read_only_memory, memory_consistency
import wasm_type_environment, wasm_signature_environment, wasm_memory_metadata
import wasm_bulk_context, wasm_reference_context, wasm_names
import wasm_payload_profile, wasm_owned_stream

type
  ConstantRecord* = object
    active*: bool
    count*, opcode*, immediate*, vectors*: uint32
  ConstantWires* = object
    active*, count*, opcode*, immediate*, vectors*: Linear
  LimitRecord* = object
    active*, hasMax*: bool
    minimum*, maximum*: uint32
  LimitWires* = object
    active*, hasMax*, minimum*, maximum*: Linear
  ElementRecord* = object
    active*: bool
    mode*, tableIndex*, itemCount*, itemType*: uint32
    offset*: ConstantRecord
    items*: seq[ConstantRecord]
  ElementWires* = object
    active*, mode*, tableIndex*, itemCount*, itemType*: Linear
    offset*: ConstantWires
    items*: seq[ConstantWires]
  FlatElementRecord* = object
    owner*, ordinal*: uint32
    value*: ConstantRecord
  FlatElementWires* = object
    owner*, ordinal*: Linear
    value*: ConstantWires
  DataRecord* = object
    active*, passive*: bool
    memoryIndex*: uint32
    offset*: ConstantRecord
  DataWires* = object
    active*, passive*, memoryIndex*: Linear
    offset*: ConstantWires
  ExportRecord* = object
    active*: bool
    kind*, index*: uint32
  ExportWires* = object
    active*, kind*, index*: Linear
  ModuleEnvironment* = object
    functions*, types*, globals*, tables*, importedFunctions*, importedGlobals*: uint32
    importedTables*, importedMemories*: uint32
    hasStart*: bool
    start*: uint32
    memories*, tableLimits*: seq[LimitRecord]
    globalInitializers*: seq[ConstantRecord]
    elements*: seq[ElementRecord]
    datas*: seq[DataRecord]
    exports*: seq[ExportRecord]
    flat*: bool
    elementItems*: seq[FlatElementRecord]
    names*: NameEnvironment # Exports first, followed by import/custom names.
    uniqueExports*: seq[ReadOnlyEntry] # name head -> export ordinal, sorted.
  ModuleEnvironmentWires* = object
    functions*, types*, globals*, tables*, importedFunctions*, importedGlobals*: Linear
    importedTables*, importedMemories*: Linear
    hasStart*, start*: Linear
    memories*, tableLimits*: seq[LimitWires]
    globalInitializers*: seq[ConstantWires]
    elements*: seq[ElementWires]
    datas*: seq[DataWires]
    exports*: seq[ExportWires]
    flat*: bool
    elementItems*: seq[FlatElementWires]
    names*: NameEnvironmentWires
    uniqueExports*: seq[ReadOnlyWires]
  ModuleContextWitness* = object
    objects*, signatures*, sources*, declarations*, exports*: seq[ReadOnlyEntry]
    objectMemory*, signatureMemory*, sourceMemory*, declarationMemory*, exportMemory*: MemoryWitness
    uniqueMemory*, elementMemory*: MemoryWitness
    elementQueries*: seq[ReadOnlyEntry]
    names*: NameWitness

proc constantRecord(expression: Expr, active = true): ConstantRecord =
  if not active: return
  result = ConstantRecord(active: true, count: uint32(expression.code.len), vectors: uint32(expression.v128Consts.len))
  if expression.code.len != 0:
    result.opcode = uint32(ord(expression.code[0].op))
    result.immediate = expression.code[0].imm1

proc limitRecord(value: Limits): LimitRecord =
  LimitRecord(active: true, hasMax: value.hasMax, minimum: value.min,
    maximum: (if value.hasMax: value.max else: 0))

proc buildModuleEnvironment*(module: WasmModule, nameCapacity = 0,
    profile = PayloadProfile()): ModuleEnvironment =
  profile.validate()
  result.flat = profile.enabled
  result.types = uint32(module.types.len)
  var names: seq[string]
  for item in module.exports:
    if item.kind == ekTag:
      raise newException(ValueError, "proof profile does not support tag exports")
    names.add item.name
    result.exports.add ExportRecord(active: true, kind: uint32(ord(item.kind)), index: item.idx)
  for item in module.imports:
    names.add item.module
    names.add item.name
    case item.kind
    of ikFunc: inc result.importedFunctions
    of ikGlobal: inc result.importedGlobals
    of ikMemory:
      inc result.importedMemories
      result.memories.add limitRecord(item.memType.limits)
    of ikTable:
      inc result.importedTables
      result.tableLimits.add limitRecord(item.tableType.limits)
    of ikTag:
      raise newException(ValueError, "proof profile does not support tag imports")
  result.functions = result.importedFunctions+uint32(module.funcTypeIdxs.len)
  result.globals = result.importedGlobals+uint32(module.globals.len)
  for value in module.tables: result.tableLimits.add limitRecord(value.limits)
  result.tables = uint32(result.tableLimits.len)
  for value in module.memories: result.memories.add limitRecord(value.limits)
  result.hasStart = module.startFunc >= 0
  if result.hasStart: result.start = uint32(module.startFunc)
  for value in module.globals: result.globalInitializers.add constantRecord(value.init)
  for owner, segment in module.elements:
    var row = ElementRecord(active: true, itemCount: uint32(segment.init.len), itemType: uint32(stackTypeTag(segment.elemType)), mode: uint32(ord(segment.mode)),
      tableIndex: (if segment.mode == elemActive: segment.tableIdx else: 0),
      offset: constantRecord(segment.offset, segment.mode == elemActive))
    for ordinal, expression in segment.init:
      if profile.enabled:
        result.elementItems.add FlatElementRecord(owner: uint32(owner),ordinal: uint32(ordinal),value: constantRecord(expression))
      else: row.items.add constantRecord(expression)
    result.elements.add row
  for segment in module.datas:
    result.datas.add DataRecord(active: true, passive: segment.mode == dataPassive,
      memoryIndex: (if segment.mode == dataActive: segment.memIdx else: 0),
      offset: constantRecord(segment.offset, segment.mode == dataActive))
  for section in module.customSections: names.add section.name
  result.names = buildNameEnvironment(names, nameCapacity)
  for i in 0..<module.exports.len:
    result.uniqueExports.add ReadOnlyEntry(active: true, address: uint64(result.names.heads[i]), value: uint64(i))
  result.uniqueExports.sort(proc(a, b: ReadOnlyEntry): int = cmp(a.address, b.address))
  if profile.enabled:
    if uint64(result.importedFunctions)+uint64(result.importedGlobals)+uint64(result.importedTables)+uint64(result.importedMemories) > uint64(profile.imports) or
        uint64(result.globals) > uint64(profile.globals) or uint64(result.tables) > uint64(profile.tables):
      raise newException(ValueError,"module namespace exceeds payload profile")
    result.memories.padDeclarations(profile.memories)
    result.tableLimits.padDeclarations(profile.tables)
    result.globalInitializers.padDeclarations(profile.globals)
    result.exports.padDeclarations(profile.exports)
    result.uniqueExports.padDeclarations(profile.exports)
    result.elements.padDeclarations(profile.elements)
    result.elementItems.padDeclarations(profile.elementItems)
    result.datas.padDeclarations(profile.datas)
    result.names.heads.padDeclarations(profile.nameCapacity())
    result.names.nodes.padDeclarations(profile.nameBytes)
    result.names.canonical.padDeclarations(profile.nameBytes)


proc contents(entries: openArray[ReadOnlyEntry]): Table[uint64, uint64] =
  for entry in entries:
    if entry.active: result[entry.address] = entry.value

proc allocateModuleEnvironment*(c: var Circuit, environment: ModuleEnvironment,
    publicInputs = false): ModuleEnvironmentWires =
  template input(number: untyped): Linear =
    (if publicInputs: c.publicInput(scalar(number)) else: c.allocate(scalar(number)))
  template constantRow(row: ConstantRecord): ConstantWires =
    ConstantWires(active: input(ord(row.active)), count: input(row.count), opcode: input(row.opcode),
      immediate: input(row.immediate), vectors: input(row.vectors))
  template limitRow(row: LimitRecord): LimitWires =
    LimitWires(active: input(ord(row.active)), hasMax: input(ord(row.hasMax)),
      minimum: input(row.minimum), maximum: input(row.maximum))
  result.flat = environment.flat
  result.functions = input(environment.functions)
  result.types = input(environment.types)
  result.globals = input(environment.globals)
  result.tables = input(environment.tables)
  result.importedFunctions = input(environment.importedFunctions)
  result.importedGlobals = input(environment.importedGlobals)
  result.importedTables = input(environment.importedTables)
  result.importedMemories = input(environment.importedMemories)
  result.hasStart = input(ord(environment.hasStart))
  result.start = input(environment.start)
  for row in environment.memories: result.memories.add limitRow(row)
  for row in environment.tableLimits: result.tableLimits.add limitRow(row)
  for row in environment.globalInitializers: result.globalInitializers.add constantRow(row)
  for row in environment.elements:
    var output = ElementWires(active: input(ord(row.active)), mode: input(row.mode),
      tableIndex: input(row.tableIndex), itemCount: input(row.itemCount), itemType: input(row.itemType), offset: constantRow(row.offset))
    for item in row.items: output.items.add constantRow(item)
    result.elements.add output
  for row in environment.elementItems:
    result.elementItems.add FlatElementWires(owner: input(row.owner),ordinal: input(row.ordinal),value: constantRow(row.value))
  for row in environment.datas:
    result.datas.add DataWires(active: input(ord(row.active)), passive: input(ord(row.passive)),
      memoryIndex: input(row.memoryIndex), offset: constantRow(row.offset))
  for row in environment.exports:
    result.exports.add ExportWires(active: input(ord(row.active)), kind: input(row.kind), index: input(row.index))
  result.names = c.allocateNames(environment.names, publicInputs)
  for row in environment.uniqueExports:
    result.uniqueExports.add ReadOnlyWires(active: input(ord(row.active)), address: input(row.address), value: input(row.value))

proc buildModuleContextWitness*(module: ModuleEnvironment, environment: TypeEnvironment,
    signatures: SignatureEnvironment, references: ReferenceEnvironment): ModuleContextWitness =
  let objects = contents(environment.objects)
  let metadata = contents(signatures.signatures)
  var sources, exportEntries: seq[ReadOnlyEntry]
  template objectQuery(enabledFlag: bool, queryKey: uint64) =
    result.objects.add(if enabledFlag: ReadOnlyEntry(active: true, address: queryKey,
      value: objects.getOrDefault(queryKey)) else: ReadOnlyEntry())
  template source(enabledFlag: bool, functionIndex: uint32) =
    sources.add ReadOnlyEntry(active: true, address: uint64(sources.len),
      value: (if enabledFlag: 1+2*uint64(functionIndex) else: 0))
    result.declarations.add(if enabledFlag: ReadOnlyEntry(active: true, address: uint64(functionIndex), value: 1) else: ReadOnlyEntry())
  template expression(row: ConstantRecord) =
    objectQuery(row.active and row.opcode == uint32(ord(opGlobalGet)), globalTypeAddress(row.immediate))
    source(row.active and row.opcode == uint32(ord(opRefFunc)), row.immediate)
  for i, row in module.globalInitializers:
    objectQuery(row.active, globalTypeAddress(module.importedGlobals+uint32(i)))
    expression(row)
  for row in module.elements:
    objectQuery(row.active and row.mode == uint32(ord(elemActive)), tableTypeAddress(row.tableIndex))
    expression(row.offset)
    for item in row.items: expression(item)
  for item in module.elementItems:
    expression(item.value)
    result.elementQueries.add(if item.value.active: ReadOnlyEntry(active: true,address: uint64(item.owner),value: uint64(module.elements[int(item.owner)].itemType)) else: ReadOnlyEntry())
  for row in module.datas: expression(row.offset)
  for i, row in module.exports:
    source(row.active and row.kind == uint32(ord(ekFunc)), row.index)
    exportEntries.add ReadOnlyEntry(active: row.active, address: (if row.active: uint64(i) else: 0),
      value: (if row.active: uint64(module.names.heads[i]) else: 0))
  result.signatures.add(if module.hasStart: ReadOnlyEntry(active: true,
    address: functionSignatureAddress(module.start), value: metadata.getOrDefault(functionSignatureAddress(module.start))) else: ReadOnlyEntry())
  var origins: Table[uint64, uint64]
  for entry in sources:
    if (entry.value and 1) != 0: origins[entry.value shr 1] = entry.address
  for entry in references.declarations:
    result.sources.add(if entry.active: ReadOnlyEntry(active: true,
      address: origins.getOrDefault(entry.address), value: 1+2*entry.address) else: ReadOnlyEntry())
  for entry in module.uniqueExports:
    result.exports.add(if entry.active: ReadOnlyEntry(active: true, address: entry.value,
      value: entry.address) else: ReadOnlyEntry())
  result.objectMemory = buildReadOnlyWitness(environment.objects, result.objects)
  result.signatureMemory = buildReadOnlyWitness(signatures.signatures, result.signatures)
  result.sourceMemory = buildReadOnlyWitness(sources, result.sources)
  result.declarationMemory = buildReadOnlyWitness(references.declarations, result.declarations)
  result.exportMemory = buildReadOnlyWitness(exportEntries, result.exports)
  result.uniqueMemory = buildReadOnlyWitness(module.uniqueExports, [])
  var elementTypes: seq[ReadOnlyEntry]
  for i, row in module.elements:
    elementTypes.add(if row.active: ReadOnlyEntry(active: true,address: uint64(i),value: uint64(row.itemType)) else: ReadOnlyEntry())
  result.elementMemory = buildReadOnlyWitness(elementTypes,result.elementQueries)
  result.names = buildNameWitness(module.names)

proc smallValue(value: Scalar): uint32 =
  let bytes = encodeScalar(value)
  for i in 28..31: result = (result shl 8) or uint32(bytes[i])

proc prefix(c: var Circuit, active, previous: Linear) =
  c.constrainBoolean(active)
  c.constrain(active, constant(1)-previous, constant(0))

proc bounded(c: var Circuit, active, index, count: Linear) =
  discard c.constrainUnsigned(c.multiply(active, count-index-constant(1)), 32)

proc limit(c: var Circuit, row: LimitWires, memory: bool) =
  c.constrainBoolean(row.active)
  c.constrainBoolean(row.hasMax)
  discard c.constrainUnsigned(row.minimum, 32)
  discard c.constrainUnsigned(row.maximum, 32)
  c.constrain(constant(1)-row.active, row.hasMax+row.minimum+row.maximum, constant(0))
  c.constrain(constant(1)-row.hasMax, row.maximum, constant(0))
  discard c.constrainUnsigned(c.multiply(row.hasMax, row.maximum-row.minimum), 32)
  if memory:
    discard c.constrainUnsigned(c.multiply(row.active, constant(65536)-row.minimum), 17)
    discard c.constrainUnsigned(c.multiply(row.hasMax, constant(65536)-row.maximum), 17)

proc constrainModuleContext*(c: var Circuit, module: ModuleEnvironmentWires,
    environment: TypeEnvironmentWires, signatures: SignatureEnvironmentWires,
    memory: MemoryEnvironmentWires, bulk: BulkEnvironmentWires,
    references: ReferenceEnvironmentWires, firstFunctionIndex: Linear,
    witness: ModuleContextWitness) =
  if module.elements.len != bulk.elements.len or module.names.heads.len < module.exports.len or
      module.uniqueExports.len != witness.exports.len or references.declarations.len != witness.sources.len:
    raise newException(ValueError, "module context dimensions differ")
  when defined(zkbuildModuleContextAudit):
    proc constantFields(row: ConstantWires): seq[Linear] =
      copyAuditExpressions([row.active,row.count,row.opcode,row.immediate,row.vectors])
    proc limitFields(row: LimitWires): seq[Linear] =
      copyAuditExpressions([row.active,row.hasMax,row.minimum,row.maximum])
    proc entryFields(row: ReadOnlyWires): seq[Linear] =
      copyAuditExpressions([row.active,row.address,row.value])
    var contextAudit = ModuleContextAudit(flat: module.flat,ownedIndex: -1,elementBank: -1,
      counts: copyAuditExpressions([module.functions,module.types,module.globals,module.tables,
        module.importedFunctions,module.importedGlobals,module.importedTables,module.importedMemories,
        module.hasStart,module.start,memory.memoryCount,references.functionCount,firstFunctionIndex,bulk.dataCount]))
    contextAudit.heads = copyAuditExpressions(module.names.heads)
    for row in module.memories: contextAudit.memories.add limitFields(row)
    for row in module.tableLimits: contextAudit.tables.add limitFields(row)
    for row in module.globalInitializers: contextAudit.globals.add constantFields(row)
    for row in module.elements:
      var saved = ModuleContextElementAudit(fields: copyAuditExpressions([row.active,row.mode,row.tableIndex,row.itemCount,row.itemType]),offset: constantFields(row.offset))
      for item in row.items: saved.items.add constantFields(item)
      contextAudit.elements.add saved
    for row in module.elementItems:
      contextAudit.items.add copyAuditExpressions([row.owner,row.ordinal]) & constantFields(row.value)
    for row in module.datas:
      contextAudit.datas.add copyAuditExpressions([row.active,row.passive,row.memoryIndex]) & constantFields(row.offset)
    for row in module.exports: contextAudit.exports.add copyAuditExpressions([row.active,row.kind,row.index])
    for row in module.uniqueExports: contextAudit.unique.add entryFields(row)
    for row in memory.vectorCounts: contextAudit.bodies.add entryFields(row)
    for row in bulk.elements: contextAudit.bulk.add entryFields(row)
    var contextFirstGate = c.constraints.len
    var contextFirstPrimitive = c.gadgets.len
    template finishContextProgram() =
      block:
        var program = ModuleContextProgramAudit(firstGate: contextFirstGate,lastGate: c.constraints.len)
        for index in contextFirstPrimitive..<c.gadgets.len:
          var primitive = RangeUseAudit(call: c.gadgets[index])
          primitive.call.inputs = copyAuditExpressions(primitive.call.inputs)
          primitive.call.outputs = copyAuditExpressions(primitive.call.outputs)
          if primitive.call.kind == gkReusedUnsigned:
            primitive.hasSource = true
            primitive.source = c.gadgets[primitive.call.reference]
            primitive.source.inputs = copyAuditExpressions(primitive.source.inputs)
            primitive.source.outputs = copyAuditExpressions(primitive.source.outputs)
          program.primitives.add primitive
        contextAudit.programs.add program
  when defined(zkbuildSignatureAudit):
    var signatureNamespace = SignatureNamespaceAudit(firstFunction: firstFunctionIndex,
      functions: module.functions,types: module.types,importedFunctions: module.importedFunctions)
  for i, value in [module.functions, module.types, module.globals, module.tables,
      module.importedFunctions, module.importedGlobals, module.importedTables, module.importedMemories, module.start]:
    discard c.constrainUnsigned(value, 32)
    when defined(zkbuildSignatureAudit):
      if i == 4: signatureNamespace.importedRange = c.snapshotRangeUse()
  when defined(zkbuildSignatureAudit):
    signatureNamespace.firstAliasStart = c.constraints.len
  c.assertEqual(firstFunctionIndex, module.importedFunctions)
  when defined(zkbuildSignatureAudit): signatureNamespace.firstAliasEnd = c.constraints.len
  c.assertEqual(module.functions, references.functionCount)
  discard c.constrainUnsigned(module.functions-module.importedFunctions, 32)
  discard c.constrainUnsigned(module.globals-module.importedGlobals, 32)
  discard c.constrainUnsigned(module.tables-module.importedTables, 32)
  discard c.constrainUnsigned(memory.memoryCount-module.importedMemories, 32)
  # Complete dense namespaces, including declarations never used by code.
  var functions, types, globals, tables = constant(0)
  for entry in signatures.signatures:
    when defined(zkbuildSignatureAudit):
      var item = SignatureNamespaceRowAudit(firstGate: c.constraints.len,
        entry: copyAuditExpressions([entry.active,entry.address,entry.value]))
    let bits = c.constrainUnsigned(entry.address, 33)
    when defined(zkbuildSignatureAudit): item.addressRange = c.snapshotRangeUse()
    let typeEntry = c.multiply(entry.active, bits[0])
    let functionEntry = entry.active-typeEntry
    let index = c.selectWire(bits[0], types, functions)
    c.constrain(entry.active, entry.address-index.scale(scalar(2))-bits[0], constant(0))
    functions = c.materialize(functions+functionEntry)
    types = c.materialize(types+typeEntry)
    when defined(zkbuildSignatureAudit):
      item.typeEntry = copyAuditExpressions([typeEntry])[0]
      item.index = copyAuditExpressions([index])[0]
      item.functions = copyAuditExpressions([functions])[0]
      item.types = copyAuditExpressions([types])[0]
      item.lastGate = c.constraints.len
      signatureNamespace.rows.add item
  when defined(zkbuildSignatureAudit): signatureNamespace.closeStart = c.constraints.len
  c.assertEqual(functions, module.functions)
  c.assertEqual(types, module.types)
  when defined(zkbuildSignatureAudit):
    signatureNamespace.closeEnd = c.constraints.len
    c.signatureNamespaceRecords.add signatureNamespace
  for entry in environment.objects:
    let bits = c.constrainUnsigned(entry.address, 33)
    let isTable = c.multiply(entry.active, bits[0])
    let isGlobal = entry.active-isTable
    let index = c.selectWire(bits[0], tables, globals)
    c.constrain(entry.active, entry.address-index.scale(scalar(2))-bits[0], constant(0))
    let valueBits = c.constrainUnsigned(entry.value, 4)
    let tag = entry.value-valueBits[3].scale(scalar(8))
    c.assertEqual(c.zeroIndicator(tag-constant(7)), constant(0))
    c.constrain(isTable, c.multiply(tag-constant(5), tag-constant(6)), constant(0))
    c.constrain(isTable, valueBits[3], constant(0))
    tables = c.materialize(tables+isTable)
    globals = c.materialize(globals+isGlobal)
  c.assertEqual(globals, module.globals)
  c.assertEqual(tables, module.tables)
  var bodies, previous = constant(0)
  previous = constant(1)
  for i, row in memory.vectorCounts:
    c.prefix(row.active, previous)
    c.constrain(row.active, row.address-module.importedFunctions-constant(i), constant(0))
    bodies = c.materialize(bodies+row.active)
    previous = row.active
  c.assertEqual(bodies, module.functions-module.importedFunctions)
  var memoryCount, tableCount = constant(0)
  previous = constant(1)
  for row in module.memories:
    c.prefix(row.active, previous)
    c.limit(row, true)
    memoryCount = c.materialize(memoryCount+row.active)
    previous = row.active
  c.assertEqual(memoryCount, memory.memoryCount)
  c.constrainBoolean(memoryCount)
  previous = constant(1)
  for row in module.tableLimits:
    c.prefix(row.active, previous)
    c.limit(row, false)
    tableCount = c.materialize(tableCount+row.active)
    previous = row.active
  c.assertEqual(tableCount, module.tables)
  var objectQueries, signatureQueries, sourceEntries, declarationQueries, exportEntries, exportQueries: seq[ReadOnlyWires]
  var objectPosition: int
  template objectQuery(enabled, key: Linear): Linear =
    block:
      if objectPosition >= witness.objects.len: raise newException(ValueError, "missing object witness")
      let data = c.allocate(scalar(witness.objects[objectPosition].value))
      inc objectPosition
      objectQueries.add ReadOnlyWires(active: enabled, address: c.multiply(enabled, key), value: data)
      data
  template source(enabled, index: Linear) =
    block:
      sourceEntries.add ReadOnlyWires(active: constant(1), address: constant(sourceEntries.len),
        value: c.multiply(enabled, constant(1)+index.scale(scalar(2))))
      declarationQueries.add ReadOnlyWires(active: enabled, address: c.multiply(enabled, index), value: enabled)
  template expression(row: ConstantWires, expected, available: Linear) =
    block:
      c.constrainBoolean(row.active)
      discard c.constrainUnsigned(row.count, 32)
      discard c.constrainUnsigned(row.opcode, 16)
      discard c.constrainUnsigned(row.immediate, 32)
      discard c.constrainUnsigned(row.vectors, 32)
      for value in [row.count, row.opcode, row.immediate, row.vectors]:
        c.constrain(constant(1)-row.active, value, constant(0))
      c.constrain(row.active, row.count-constant(1), constant(0))
      var selectors: seq[Linear]
      var sum, typeSum = constant(0)
      for code in [ord(opI32Const), ord(opI64Const), ord(opF32Const), ord(opF64Const),
          ord(opV128Const), ord(opRefNull), ord(opRefFunc), ord(opGlobalGet)]:
        let selected = c.multiply(row.active, c.zeroIndicator(row.opcode-constant(code)))
        selectors.add selected
        sum = sum+selected
      c.assertEqual(row.active, sum)
      for tag in 0..4: typeSum = typeSum+selectors[tag].scale(scalar(tag))
      let nullFunc = c.zeroIndicator(row.immediate-constant(ord(vtFuncRef)))
      let nullExtern = c.zeroIndicator(row.immediate-constant(ord(vtExternRef)))
      c.constrain(selectors[5], nullFunc+nullExtern-constant(1), constant(0))
      typeSum = typeSum+c.multiply(selectors[5], nullFunc.scale(scalar(5))+nullExtern.scale(scalar(6)))+
        selectors[6].scale(scalar(5))
      c.bounded(selectors[6], row.immediate, module.functions)
      c.bounded(selectors[4], row.immediate, row.vectors)
      c.bounded(selectors[7], row.immediate, available)
      let declared = objectQuery(selectors[7], row.immediate.scale(scalar(2)))
      discard c.constrainUnsigned(declared, 3) # immutable global only; mutVar adds 8.
      typeSum = typeSum+c.multiply(selectors[7], declared)
      c.constrain(row.active, expected-typeSum, constant(0))
      source(selectors[6], row.immediate)
  var definedGlobals = constant(0)
  previous = constant(1)
  for i, row in module.globalInitializers:
    c.prefix(row.active, previous)
    let declared = objectQuery(row.active, (module.importedGlobals+constant(i)).scale(scalar(2)))
    let bits = c.constrainUnsigned(declared, 4)
    expression(row, declared-bits[3].scale(scalar(8)), module.importedGlobals+constant(i))
    definedGlobals = c.materialize(definedGlobals+row.active)
    previous = row.active
  c.assertEqual(definedGlobals, module.globals-module.importedGlobals)
  var elementTypes: seq[ReadOnlyWires]
  var itemParents: seq[OwnedParentWires]
  previous = constant(1)
  for i, row in module.elements:
    c.prefix(row.active, previous)
    c.assertEqual(row.active, bulk.elements[i].active)
    c.constrain(row.active, bulk.elements[i].address-constant(i), constant(0))
    let tag = bulk.elements[i].value
    c.assertEqual(row.itemType,tag)
    discard c.constrainUnsigned(row.itemCount,32)
    c.constrain(constant(1)-row.active,row.itemCount,constant(0))
    elementTypes.add ReadOnlyWires(active: row.active,address: row.active.scale(scalar(i)),value: tag)
    itemParents.add OwnedParentWires(active: row.active,count: row.itemCount,start: constant(0),finish: row.itemCount)
    discard c.constrainUnsigned(row.mode, 2)
    c.assertEqual(c.zeroIndicator(row.mode-constant(3)), constant(0))
    discard c.constrainUnsigned(row.tableIndex, 32)
    c.constrain(constant(1)-row.active, row.mode, constant(0))
    let activeMode = c.multiply(row.active, c.zeroIndicator(row.mode-constant(ord(elemActive))))
    c.constrain(constant(1)-activeMode, row.tableIndex, constant(0))
    let tableType = objectQuery(activeMode, row.tableIndex.scale(scalar(2))+constant(1))
    c.constrain(activeMode, tableType-tag, constant(0))
    c.assertEqual(row.offset.active, activeMode)
    expression(row.offset, constant(0), module.globals)
    var last = row.active
    var itemCount = constant(0)
    for item in row.items:
      c.prefix(item.active, last)
      expression(item, tag, module.globals)
      last = item.active
      itemCount = itemCount+item.active
    if not module.flat: c.assertEqual(row.itemCount,itemCount)
    previous = row.active
  if module.flat:
    if module.elementItems.len != witness.elementQueries.len:
      raise newException(ValueError,"flat element context dimensions differ")
    var children: seq[OwnedChildWires]
    var childHints: seq[OwnedChild]
    var parentHints: seq[OwnedParent]
    var queries: seq[ReadOnlyWires]
    for parent in itemParents:
      parentHints.add OwnedParent(active: parent.active.evaluate(c.values).equals(scalar(1)),
        count: uint32(smallValue(parent.count.evaluate(c.values))),
        finish: uint32(smallValue(parent.count.evaluate(c.values))))
    for i, item in module.elementItems:
      let value = c.allocate(scalar(witness.elementQueries[i].value))
      queries.add ReadOnlyWires(active: item.value.active,address: item.owner,value: value)
      expression(item.value,value,module.globals)
      let finish = c.multiply(item.value.active,item.ordinal+constant(1))
      children.add OwnedChildWires(active: item.value.active,owner: item.owner,ordinal: item.ordinal,start: item.ordinal,finish: finish)
      let host = witness.elementQueries[i]
      let ordinal = uint32(smallValue(item.ordinal.evaluate(c.values)))
      childHints.add OwnedChild(active: host.active,owner: uint32(host.address),ordinal: ordinal,start: ordinal,finish: (if host.active: ordinal+1 else: 0))
    when defined(zkbuildModuleContextAudit):
      finishContextProgram()
      contextAudit.ownedIndex = c.ownedRecords.len
    c.constrainOwnedStream(itemParents,children,parentHints,childHints)
    when defined(zkbuildModuleContextAudit): contextAudit.elementBank = c.readOnlyRecords.len
    c.constrainReadOnly(elementTypes,queries,witness.elementMemory,32,3)
    when defined(zkbuildModuleContextAudit):
      contextFirstGate = c.constraints.len
      contextFirstPrimitive = c.gadgets.len
  var dataCount = constant(0)
  previous = constant(1)
  for row in module.datas:
    c.prefix(row.active, previous)
    c.constrainBoolean(row.passive)
    c.constrain(constant(1)-row.active, row.passive, constant(0))
    discard c.constrainUnsigned(row.memoryIndex, 32)
    let active = row.active-row.passive
    c.constrain(active, constant(1)-memory.memoryCount, constant(0))
    c.assertEqual(row.memoryIndex, constant(0))
    c.assertEqual(row.offset.active, active)
    expression(row.offset, constant(0), module.globals)
    dataCount = c.materialize(dataCount+row.active)
    previous = row.active
  c.assertEqual(dataCount, bulk.dataCount)
  c.constrainBoolean(module.hasStart)
  c.constrain(constant(1)-module.hasStart, module.start, constant(0))
  c.bounded(module.hasStart, module.start, module.functions)
  signatureQueries.add ReadOnlyWires(active: module.hasStart,
    address: c.multiply(module.hasStart, module.start.scale(scalar(2))), value: constant(0))
  var exportCount = constant(0)
  previous = constant(1)
  for i, row in module.exports:
    c.prefix(row.active, previous)
    discard c.constrainUnsigned(row.kind, 2)
    discard c.constrainUnsigned(row.index, 32)
    c.constrain(constant(1)-row.active, row.kind+row.index, constant(0))
    let counts = [module.functions, module.tables, memory.memoryCount, module.globals]
    for kind in 0..3:
      c.bounded(c.multiply(row.active, c.zeroIndicator(row.kind-constant(kind))), row.index, counts[kind])
    let function = c.multiply(row.active, c.zeroIndicator(row.kind-constant(ord(ekFunc))))
    source(function, row.index)
    exportEntries.add ReadOnlyWires(active: row.active, address: c.multiply(row.active, constant(i)),
      value: c.multiply(row.active, module.names.heads[i]))
    exportCount = c.materialize(exportCount+row.active)
    previous = row.active
  var uniqueCount = constant(0)
  for i, row in module.uniqueExports:
    exportQueries.add ReadOnlyWires(active: row.active, address: row.value, value: row.address)
    uniqueCount = c.materialize(uniqueCount+row.active)
  c.assertEqual(uniqueCount, exportCount)
  var sourceQueries: seq[ReadOnlyWires]
  for i, row in references.declarations:
    sourceQueries.add ReadOnlyWires(active: row.active, address: c.allocate(scalar(witness.sources[i].address)),
      value: c.multiply(row.active, constant(1)+row.address.scale(scalar(2))))
  if objectPosition != witness.objects.len or witness.signatures.len != 1:
    raise newException(ValueError, "module witness query count differs")
  when defined(zkbuildModuleContextAudit):
    finishContextProgram()
    contextAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(environment.objects, objectQueries, witness.objectMemory, 33, 4)
  when defined(zkbuildModuleContextAudit): contextAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(signatures.signatures, signatureQueries, witness.signatureMemory, 33, 64)
  when defined(zkbuildModuleContextAudit): contextAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(sourceEntries, sourceQueries, witness.sourceMemory, 32, 33)
  when defined(zkbuildModuleContextAudit): contextAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(references.declarations, declarationQueries, witness.declarationMemory, 32, 1)
  when defined(zkbuildModuleContextAudit): contextAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(exportEntries, exportQueries, witness.exportMemory, 32, 32)
  when defined(zkbuildModuleContextAudit): contextAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(module.uniqueExports, [], witness.uniqueMemory, 32, 32)
  c.constrainNames(module.names, witness.names)
  when defined(zkbuildModuleContextAudit): c.moduleContextRecords.add contextAudit
