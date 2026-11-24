## Memory/SIMD metadata checks. These tables still require module-byte binding;
## stack effects and event scheduling come from the composed validation path.
import std/tables
import ../wasm/[types, validate]
import r1cs, range_check, read_only_memory, memory_consistency, instruction_lookup
import wasm_instruction_events, wasm_operand_events

type
  MemoryEnvironment* = object
    memoryCount*: uint32
    vectorCounts*: seq[ReadOnlyEntry]
  MemoryEnvironmentWires* = object
    memoryCount*: Linear
    vectorCounts*: seq[ReadOnlyWires]
  MemoryMetadataWitness* = object
    queries*: seq[ReadOnlyEntry]
    vectors*: MemoryWitness

proc buildMemoryEnvironment*(module: WasmModule, vectorCapacity = 0): MemoryEnvironment =
  if vectorCapacity < 0: raise newException(ValueError, "invalid vector-count capacity")
  var first, memories: uint64
  for item in module.imports:
    if item.kind == ikFunc: inc first
    elif item.kind == ikMemory: inc memories
  memories += uint64(module.memories.len)
  if memories > uint64(high(uint32)) or first+uint64(module.codes.len) > uint64(high(uint32)):
    raise newException(ValueError, "memory metadata namespace overflow")
  result.memoryCount = uint32(memories)
  for body, code in module.codes:
    if uint64(code.code.v128Consts.len) > uint64(high(uint32)):
      raise newException(ValueError, "vector constant-count overflow")
    result.vectorCounts.add ReadOnlyEntry(active: true, address: first+uint64(body),
      value: uint64(code.code.v128Consts.len))
  if vectorCapacity != 0:
    if result.vectorCounts.len > vectorCapacity: raise newException(ValueError, "vector-count profile overflow")
    result.vectorCounts.setLen(vectorCapacity)

proc buildMemoryMetadataWitness*(environment: MemoryEnvironment,
    rows: openArray[InstructionEventRow]): MemoryMetadataWitness =
  var counts: Table[uint64, uint64]
  for entry in environment.vectorCounts:
    if entry.active: counts[entry.address] = entry.value
  for row in rows:
    result.queries.add(if row.control.operand.kind == uint8(ord(veInstructionBegin)) and
      row.opcode == uint16(ord(opV128Const)):
      ReadOnlyEntry(active: true, address: uint64(row.control.operand.functionIndex),
        value: counts.getOrDefault(uint64(row.control.operand.functionIndex))) else: ReadOnlyEntry())
  result.vectors = buildReadOnlyWitness(environment.vectorCounts, result.queries)

proc constrainMemoryMetadata*(c: var Circuit, rows: openArray[InstructionEventWires],
    primary, secondary: openArray[Linear], operand: OperandEventProjection,
    environment: MemoryEnvironmentWires, witness: MemoryMetadataWitness) =
  if rows.len == 0 or rows.len != primary.len or rows.len != secondary.len or
      rows.len != operand.flags.len or rows.len != witness.queries.len:
    raise newException(ValueError, "memory metadata circuit dimensions differ")
  when defined(zkbuildRuntimeContextAudit):
    let marker = c.beginSourceProgram()
  # The current runtime/module validator supports a single 32-bit memory.
  c.constrainBoolean(environment.memoryCount)
  var queries: seq[ReadOnlyWires]
  for i, row in rows:
    let begin = operand.flags[i].instructionBegin
    let metadata = c.constrainInstructionMetadata(row.opcode)
    let primaryBits = c.constrainUnsigned(primary[i], 32)
    discard c.constrainUnsigned(secondary[i], 32)
    c.constrain(constant(1)-begin, primary[i], constant(0))
    c.constrain(constant(1)-begin, secondary[i], constant(0))
    c.constrain(c.multiply(begin, metadata.memoryRequired), constant(1)-environment.memoryCount, constant(0))
    c.constrain(c.multiply(begin, metadata.memoryIndex), primary[i], constant(0))
    let alignment = c.selectWire(metadata.vectorArgument, primary[i], secondary[i])
    let alignmentGap = c.multiply(c.multiply(begin, metadata.memoryArgument), metadata.maxAlignment-alignment)
    discard c.constrainUnsigned(alignmentGap, 3)
    var low: Linear
    for bits in 1..4:
      low = low+primaryBits[bits-1].scale(scalar(1 shl (bits-1)))
      let lane = c.multiply(begin, c.zeroIndicator(metadata.laneBits-constant(bits)))
      c.constrain(lane, primary[i]-low, constant(0))
    let active = c.multiply(begin, metadata.vectorConstant)
    let query = ReadOnlyWires(active: active,
      address: c.multiply(active, row.control.operand.functionIndex), value: c.allocate(scalar(witness.queries[i].value)))
    queries.add query
    let available = c.multiply(active, query.value-primary[i]-constant(1))
    discard c.constrainUnsigned(available, 32)
  when defined(zkbuildRuntimeContextAudit):
    var audit = DynamicTypingStageAudit(kind: 0,rows: captureInstructionRows(rows),flags: captureEventFlags(operand.flags),
      auxiliary: @[copyAuditExpressions([environment.memoryCount])],program: c.endSourceProgram(marker),banks: @[c.readOnlyRecords.len])
    for i in 0..<rows.len: audit.inputs.add copyAuditExpressions([primary[i],secondary[i]])
    c.runtimeContextRecords.add audit
  c.constrainReadOnly(environment.vectorCounts, queries, witness.vectors, 32, 32)
