## Module type tables and constrained queries for locals, globals, and tables.
## The tables and instruction immediates still need a binary decoder binding.
import std/[tables, sets, algorithm]
import r1cs, range_check, read_only_memory, memory_consistency
import wasm_instruction_events, wasm_operand_events
import ../wasm/[types, validate, variable_typing]

type
  TypeEnvironment* = object
    locals*, objects*: seq[ReadOnlyEntry]
    localRanges*, rangeTypes*: seq[ReadOnlyEntry]
  TypeEnvironmentWires* = object
    locals*, objects*: seq[ReadOnlyWires]
    localRanges*, rangeTypes*: seq[ReadOnlyWires]
  TypeEnvironmentWitness* = object
    localQueries*, objectQueries*: seq[ReadOnlyEntry]
    locals*, objects*: MemoryWitness
  VariableSelectors* = object
    localGet*, localSet*, localTee*, globalGet*, globalSet*: Linear
    tableGet*, tableSet*, tableGrow*, tableSize*, tableFill*: Linear
    local*, global*, table*, present*: Linear

func localTypeAddress*(functionIndex, localIndex: uint32): uint64 =
  (uint64(functionIndex) shl 32) or uint64(localIndex)

func globalTypeAddress*(index: uint32): uint64 = uint64(index)*2
func tableTypeAddress*(index: uint32): uint64 = uint64(index)*2+1

proc buildTypeEnvironment*(module: WasmModule, localCapacity = 0, objectCapacity = 0,
    maxLocals = 1_048_576, compressedLocals = false, rangeCapacity = 0): TypeEnvironment =
  ## maxLocals is a host resource limit, not an implicit circuit bound.
  ## Explicit capacities fix the proof profile and include inactive padding.
  if localCapacity < 0 or objectCapacity < 0 or maxLocals < 0 or rangeCapacity < 0 or
      module.funcTypeIdxs.len != module.codes.len:
    raise newException(ValueError, "invalid type environment dimensions")
  var imports: uint64
  var globals: seq[GlobalType]
  var tableTypes: seq[TableType]
  for item in module.imports:
    case item.kind
    of ikFunc: inc imports
    of ikGlobal: globals.add item.globalType
    of ikTable: tableTypes.add item.tableType
    else: discard
  for item in module.globals: globals.add item.globalType
  tableTypes.add module.tables
  if imports+uint64(module.codes.len) > uint64(high(uint32)) or
      uint64(globals.len) > uint64(high(uint32)) or uint64(tableTypes.len) > uint64(high(uint32)):
    raise newException(ValueError, "type environment index overflow")
  for body, code in module.codes:
    let typeIndex = module.funcTypeIdxs[body]
    if uint64(typeIndex) >= uint64(module.types.len):
      raise newException(ValueError, "invalid function type in environment")
    var next: uint64
    var declarations: seq[tuple[first, count: uint64, tag: uint8]]
    let functionIndex = uint32(imports+uint64(body))
    if compressedLocals:
      template range(localValueType: ValType, amount: uint32) =
        if declarations.len >= maxLocals or uint64(declarations.len) > uint64(high(uint32)) or
            next+uint64(amount) > uint64(high(uint32)):
          raise newException(ValueError, "compressed local declaration overflow")
        let address = localTypeAddress(functionIndex, uint32(declarations.len))
        result.localRanges.add ReadOnlyEntry(active: true, address: address, value: next+(uint64(amount) shl 32))
        result.rangeTypes.add ReadOnlyEntry(active: true, address: address, value: uint64(stackTypeTag(localValueType)))
        declarations.add (next, uint64(amount), stackTypeTag(localValueType))
        next += uint64(amount)
      for param in module.types[int(typeIndex)].params: range(param, 1)
      for declaration in code.locals: range(declaration.valType, declaration.count)
      var used: HashSet[uint32]
      for instruction in code.code.code:
        if instruction.op in {opLocalGet, opLocalSet, opLocalTee}: used.incl instruction.imm1
      var ordered: seq[uint32]
      for index in used: ordered.add index
      ordered.sort()
      for index in ordered:
        if uint64(index) >= next: continue # A missing ROM entry rejects a forged query.
        var low = 0
        var limit = declarations.len
        while low < limit:
          let middle = low+(limit-low) div 2
          if declarations[middle].first+declarations[middle].count <= uint64(index): low = middle+1
          else: limit = middle
        result.locals.add ReadOnlyEntry(active: true, address: localTypeAddress(functionIndex, index), value: uint64(declarations[low].tag))
      continue
    template addLocal(localType: ValType) =
      if result.locals.len >= maxLocals or next > uint64(high(uint32)):
        raise newException(ValueError, "type environment local capacity exceeded")
      result.locals.add ReadOnlyEntry(active: true,
        address: localTypeAddress(uint32(imports+uint64(body)), uint32(next)),
        value: uint64(stackTypeTag(localType)))
      inc next
    for param in module.types[typeIndex.int].params: addLocal(param)
    for declaration in code.locals:
      if uint64(declaration.count) > uint64(maxLocals-result.locals.len):
        raise newException(ValueError, "type environment local capacity exceeded")
      for _ in 0'u32..<declaration.count: addLocal(declaration.valType)
  for i in 0..<max(globals.len, tableTypes.len):
    if i < globals.len:
      result.objects.add ReadOnlyEntry(active: true, address: globalTypeAddress(uint32(i)),
        value: uint64(stackTypeTag(globals[i].valType))+8*uint64(ord(globals[i].mut == mutVar)))
    if i < tableTypes.len:
      if tableTypes[i].elemType notin {vtFuncRef, vtExternRef}:
        raise newException(ValueError, "table environment requires a reference type")
      result.objects.add ReadOnlyEntry(active: true, address: tableTypeAddress(uint32(i)),
        value: uint64(stackTypeTag(tableTypes[i].elemType)))
  if localCapacity != 0:
    if result.locals.len > localCapacity: raise newException(ValueError, "local table profile overflow")
    result.locals.setLen(localCapacity)
  if objectCapacity != 0:
    if result.objects.len > objectCapacity: raise newException(ValueError, "object table profile overflow")
    result.objects.setLen(objectCapacity)
  if rangeCapacity != 0:
    if result.localRanges.len > rangeCapacity: raise newException(ValueError, "compressed local range profile overflow")
    result.localRanges.setLen(rangeCapacity)
    result.rangeTypes.setLen(rangeCapacity)

proc variableSelectors*(c: var Circuit, opcode: Linear): VariableSelectors =
  result.localGet = c.zeroIndicator(opcode-constant(0x20))
  result.localSet = c.zeroIndicator(opcode-constant(0x21))
  result.localTee = c.zeroIndicator(opcode-constant(0x22))
  result.globalGet = c.zeroIndicator(opcode-constant(0x23))
  result.globalSet = c.zeroIndicator(opcode-constant(0x24))
  result.tableGet = c.zeroIndicator(opcode-constant(0x25))
  result.tableSet = c.zeroIndicator(opcode-constant(0x26))
  result.tableGrow = c.zeroIndicator(opcode-constant(0x10f))
  result.tableSize = c.zeroIndicator(opcode-constant(0x110))
  result.tableFill = c.zeroIndicator(opcode-constant(0x111))
  result.local = result.localGet+result.localSet+result.localTee
  result.global = result.globalGet+result.globalSet
  result.table = result.tableGet+result.tableSet+result.tableGrow+result.tableSize+result.tableFill
  result.present = result.local+result.global+result.table

proc buildTypeEnvironmentWitness*(environment: TypeEnvironment,
    rows: openArray[InstructionEventRow], immediates: openArray[uint32]): TypeEnvironmentWitness =
  if rows.len != immediates.len: raise newException(ValueError, "type query dimensions differ")
  var localMap, objectMap: Table[uint64, uint64]
  for entry in environment.locals:
    if entry.active: localMap[entry.address] = entry.value
  for entry in environment.objects:
    if entry.active: objectMap[entry.address] = entry.value
  result.localQueries.setLen(rows.len)
  result.objectQueries.setLen(rows.len)
  for i, row in rows:
    if row.control.operand.kind != uint8(ord(veInstructionBegin)): continue
    case typeEnvironmentKind(row.opcode)
    of tekLocal:
      let address = localTypeAddress(row.control.operand.functionIndex, immediates[i])
      result.localQueries[i] = ReadOnlyEntry(active: true, address: address,
        value: localMap.getOrDefault(address))
    of tekGlobal, tekTable:
      let address = if typeEnvironmentKind(row.opcode) == tekGlobal:
        globalTypeAddress(immediates[i]) else: tableTypeAddress(immediates[i])
      result.objectQueries[i] = ReadOnlyEntry(active: true, address: address,
        value: objectMap.getOrDefault(address))
    else: discard
  result.locals = buildReadOnlyWitness(environment.locals, result.localQueries)
  result.objects = buildReadOnlyWitness(environment.objects, result.objectQueries)

proc constrainTypeEnvironment*(c: var Circuit, environment: TypeEnvironmentWires,
    rows: openArray[InstructionEventWires], immediates: openArray[Linear],
    operand: OperandEventProjection, witness: TypeEnvironmentWitness,
    selectors: openArray[VariableSelectors]): seq[Linear] =
  ## Returns the authenticated declared type, held through each instruction.
  ## immediates are nonzero only at instruction-begin rows; the decoder must
  ## bind them there. Selectors must be generated from these same opcodes.
  if rows.len != immediates.len or rows.len != operand.flags.len or
      rows.len != selectors.len or rows.len != witness.localQueries.len or
      rows.len != witness.objectQueries.len:
    raise newException(ValueError, "type environment circuit dimensions differ")
  when defined(zkbuildDynamicTypingAudit):
    let auditMarker = c.beginSourceProgram()
    var audit = DynamicTypingStageAudit(kind: 1,rows: captureInstructionRows(rows),
      flags: captureEventFlags(operand.flags),selectors: captureVariableSelectors(selectors))
    for value in immediates: audit.inputs.add copyAuditExpressions([value])
  for entry in environment.locals:
    c.assertEqual(c.zeroIndicator(entry.value-constant(7)), constant(0))
  let inverseTwo = scalar(2).inverse()
  for entry in environment.objects:
    let valueBits = c.constrainUnsigned(entry.value, 4)
    let tag = valueBits[0]+valueBits[1].scale(scalar(2))+valueBits[2].scale(scalar(4))
    c.assertEqual(c.zeroIndicator(tag-constant(7)), constant(0))
    # Recover the key category with a bounded quotient, so the prover cannot
    # reinterpret an odd table key as an even global key in the scalar field.
    let encoded = encodeScalar(entry.address.evaluate(c.values))
    let category = c.bit((encoded[31] and 1) != 0)
    let half = c.allocate((entry.address.evaluate(c.values)-category.evaluate(c.values))*inverseTwo)
    when defined(zkbuildDynamicTypingAudit): audit.auxiliary.add copyAuditExpressions([category,half])
    discard c.constrainUnsigned(half, 32)
    c.assertEqual(entry.address, half.scale(scalar(2))+category)
    c.constrain(category, valueBits[3], constant(0))
    c.constrain(category, c.multiply(tag-constant(5), tag-constant(6)), constant(0))
  var locals, objects: seq[ReadOnlyWires]
  var declared = constant(0)
  for i, row in rows:
    let flags = operand.flags[i]
    let s = selectors[i]
    discard c.constrainUnsigned(immediates[i], 32)
    c.constrain(constant(1)-flags.instructionBegin, immediates[i], constant(0))
    let localQuery = c.multiply(flags.instructionBegin, s.local)
    let objectQuery = c.multiply(flags.instructionBegin, s.global+s.table)
    let tableQuery = c.multiply(flags.instructionBegin, s.table)
    let localValue = c.allocate(scalar(witness.localQueries[i].value))
    let objectValue = c.allocate(scalar(witness.objectQueries[i].value))
    locals.add ReadOnlyWires(active: localQuery,
      address: c.multiply(localQuery, row.control.operand.functionIndex.scale(scalar(1'u64 shl 32))+immediates[i]),
      value: localValue)
    objects.add ReadOnlyWires(active: objectQuery,
      address: c.multiply(objectQuery, immediates[i].scale(scalar(2))+s.table), value: objectValue)
    let bits = c.constrainUnsigned(localValue+objectValue, 4)
    let tag = bits[0]+bits[1].scale(scalar(2))+bits[2].scale(scalar(4))
    c.assertEqual(c.zeroIndicator(tag-constant(7)), constant(0))
    c.constrain(localQuery+tableQuery, bits[3], constant(0))
    c.constrain(c.multiply(flags.instructionBegin, s.globalSet), constant(1)-bits[3], constant(0))
    c.constrain(tableQuery, c.multiply(tag-constant(5), tag-constant(6)), constant(0))
    declared = c.selectWire(flags.functionBegin+flags.instructionBegin, tag, declared)
    result.add declared
  when defined(zkbuildDynamicTypingAudit):
    audit.program = c.endSourceProgram(auditMarker)
    for value in result: audit.outputs.add copyAuditExpressions([value])
    audit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(environment.locals, locals, witness.locals, 64, 3)
  when defined(zkbuildDynamicTypingAudit): audit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(environment.objects, objects, witness.objects, 33, 4)
  when defined(zkbuildDynamicTypingAudit): c.dynamicTypingRecords.add audit
