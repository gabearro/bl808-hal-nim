## Bulk-memory/table context rules. Module-byte binding and segment initializer
## validation remain separate obligations. Operand effects use fixed signatures.
import std/tables
import ../wasm/[types, validate, variable_typing]
import r1cs, range_check, read_only_memory, memory_consistency
import wasm_instruction_events, wasm_operand_events, wasm_type_environment

type
  BulkEnvironment* = object
    hasDataCount*: bool
    dataCount*, declaredDataCount*: uint32
    elements*: seq[ReadOnlyEntry]
  BulkEnvironmentWires* = object
    hasDataCount*, dataCount*, declaredDataCount*: Linear
    elements*: seq[ReadOnlyWires]
  BulkContextWitness* = object
    elements*, destinations*, sources*: seq[ReadOnlyEntry]
    elementMemory*, tables*: MemoryWitness

proc buildBulkEnvironment*(module: WasmModule, elementCapacity = 0): BulkEnvironment =
  if elementCapacity < 0 or module.dataCount < -1 or module.dataCount > int64(high(uint32)) or
      uint64(module.datas.len) > uint64(high(uint32)) or uint64(module.elements.len) > uint64(high(uint32)):
    raise newException(ValueError, "invalid bulk context dimensions")
  result.hasDataCount = module.dataCount >= 0
  result.dataCount = uint32(module.datas.len)
  if result.hasDataCount: result.declaredDataCount = uint32(module.dataCount)
  for i, segment in module.elements:
    result.elements.add ReadOnlyEntry(active: true, address: uint64(i), value: uint64(stackTypeTag(segment.elemType)))
  if elementCapacity != 0:
    if result.elements.len > elementCapacity: raise newException(ValueError, "element context profile overflow")
    result.elements.setLen(elementCapacity)

proc buildBulkContextWitness*(environment: BulkEnvironment, objects: openArray[ReadOnlyEntry],
    rows: openArray[InstructionEventRow], primary, secondary: openArray[uint32]): BulkContextWitness =
  if rows.len != primary.len or rows.len != secondary.len:
    raise newException(ValueError, "bulk context witness dimensions differ")
  var elements, tables: Table[uint64, uint64]
  for entry in environment.elements:
    if entry.active: elements[entry.address] = entry.value
  for entry in objects:
    if entry.active: tables[entry.address] = entry.value
  result.elements.setLen(rows.len)
  result.destinations.setLen(rows.len)
  result.sources.setLen(rows.len)
  for i, row in rows:
    if row.control.operand.kind != uint8(ord(veInstructionBegin)): continue
    if row.opcode in [uint16(ord(opTableInit)), uint16(ord(opElemDrop))]:
      result.elements[i] = ReadOnlyEntry(active: true, address: uint64(primary[i]),
        value: elements.getOrDefault(uint64(primary[i])))
    if row.opcode in [uint16(ord(opTableInit)), uint16(ord(opTableCopy))]:
      let index = if row.opcode == uint16(ord(opTableInit)): secondary[i] else: primary[i]
      let address = tableTypeAddress(index)
      result.destinations[i] = ReadOnlyEntry(active: true, address: address, value: tables.getOrDefault(address))
    if row.opcode == uint16(ord(opTableCopy)):
      let address = tableTypeAddress(secondary[i])
      result.sources[i] = ReadOnlyEntry(active: true, address: address, value: tables.getOrDefault(address))
  result.elementMemory = buildReadOnlyWitness(environment.elements, result.elements)
  result.tables = buildReadOnlyWitness(objects, result.destinations & result.sources)

proc read(c: var Circuit, active, address: Linear, value: uint64): ReadOnlyWires =
  ReadOnlyWires(active: active, address: c.multiply(active, address), value: c.allocate(scalar(value)))

proc constrainBulkContext*(c: var Circuit, rows: openArray[InstructionEventWires],
    primary, secondary: openArray[Linear], operand: OperandEventProjection,
    memoryCount: Linear, environment: BulkEnvironmentWires, objects: openArray[ReadOnlyWires],
    witness: BulkContextWitness) =
  if rows.len == 0 or rows.len != primary.len or rows.len != secondary.len or
      rows.len != operand.flags.len or rows.len != witness.elements.len or
      rows.len != witness.destinations.len or rows.len != witness.sources.len or
      uint64(environment.elements.len) > uint64(high(uint32)):
    raise newException(ValueError, "bulk context circuit dimensions differ")
  when defined(zkbuildRuntimeContextAudit):
    let marker = c.beginSourceProgram()
  c.constrainBoolean(memoryCount)
  c.constrainBoolean(environment.hasDataCount)
  discard c.constrainUnsigned(environment.dataCount, 32)
  discard c.constrainUnsigned(environment.declaredDataCount, 32)
  c.constrain(constant(1)-environment.hasDataCount, environment.declaredDataCount, constant(0))
  c.constrain(environment.hasDataCount, environment.declaredDataCount-environment.dataCount, constant(0))
  for i, entry in environment.elements:
    c.constrain(entry.active, entry.address-constant(i), constant(0))
    c.constrain(entry.active, c.multiply(entry.value-constant(5), entry.value-constant(6)), constant(0))
  var elements, destinations, sources: seq[ReadOnlyWires]
  for i, row in rows:
    let begin = operand.flags[i].instructionBegin
    discard c.constrainUnsigned(row.opcode, 16)
    discard c.constrainUnsigned(primary[i], 32)
    discard c.constrainUnsigned(secondary[i], 32)
    c.constrain(constant(1)-begin, primary[i], constant(0))
    c.constrain(constant(1)-begin, secondary[i], constant(0))
    let memoryInit = c.zeroIndicator(row.opcode-constant(ord(opMemoryInit)))
    let dataDrop = c.zeroIndicator(row.opcode-constant(ord(opDataDrop)))
    let memoryCopy = c.zeroIndicator(row.opcode-constant(ord(opMemoryCopy)))
    let memoryFill = c.zeroIndicator(row.opcode-constant(ord(opMemoryFill)))
    let tableInit = c.zeroIndicator(row.opcode-constant(ord(opTableInit)))
    let elemDrop = c.zeroIndicator(row.opcode-constant(ord(opElemDrop)))
    let tableCopy = c.zeroIndicator(row.opcode-constant(ord(opTableCopy)))
    let usesData = c.multiply(begin, memoryInit+dataDrop)
    c.constrain(usesData, constant(1)-environment.hasDataCount, constant(0))
    let available = c.multiply(usesData, environment.dataCount-primary[i]-constant(1))
    discard c.constrainUnsigned(available, 32)
    let usesMemory = c.multiply(begin, memoryInit+memoryCopy+memoryFill)
    c.constrain(usesMemory, constant(1)-memoryCount, constant(0))
    c.constrain(c.multiply(begin, memoryCopy+memoryFill), primary[i], constant(0))
    c.constrain(c.multiply(begin, memoryInit+memoryCopy), secondary[i], constant(0))
    let element = c.read(c.multiply(begin, tableInit+elemDrop), primary[i], witness.elements[i].value)
    elements.add element
    let destinationIndex = c.selectWire(tableInit, secondary[i], primary[i])
    let destination = c.read(c.multiply(begin, tableInit+tableCopy), destinationIndex.scale(scalar(2))+constant(1),
      witness.destinations[i].value)
    destinations.add destination
    let source = c.read(c.multiply(begin, tableCopy), secondary[i].scale(scalar(2))+constant(1), witness.sources[i].value)
    sources.add source
    c.constrain(destination.active, c.multiply(destination.value-constant(5), destination.value-constant(6)), constant(0))
    c.constrain(source.active, c.multiply(source.value-constant(5), source.value-constant(6)), constant(0))
    c.constrain(c.multiply(begin, tableInit), element.value-destination.value, constant(0))
    c.constrain(source.active, source.value-destination.value, constant(0))
  when defined(zkbuildRuntimeContextAudit):
    var audit = DynamicTypingStageAudit(kind: 1,rows: captureInstructionRows(rows),flags: captureEventFlags(operand.flags),
      auxiliary: @[copyAuditExpressions([memoryCount,environment.hasDataCount,environment.dataCount,environment.declaredDataCount])],
      program: c.endSourceProgram(marker),banks: @[c.readOnlyRecords.len])
    for i in 0..<rows.len: audit.inputs.add copyAuditExpressions([primary[i],secondary[i]])
  c.constrainReadOnly(environment.elements, elements, witness.elementMemory, 32, 3)
  when defined(zkbuildRuntimeContextAudit): audit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(objects, destinations & sources, witness.tables, 33, 4)

  when defined(zkbuildRuntimeContextAudit): c.runtimeContextRecords.add audit
