## Shared immutable br_table lists. Every list includes the default as its
## final node. Table provenance from raw module bytes remains a separate proof.
import std/tables
import ../wasm/[types, validate]
import r1cs, range_check, read_only_memory, memory_consistency
import wasm_instruction_events, wasm_operand_events, wasm_signature_environment

type
  BranchEnvironment* = object
    banks*, nodes*: seq[ReadOnlyEntry]
  BranchEnvironmentWires* = object
    banks*, nodes*: seq[ReadOnlyWires]
  BranchEnvironmentWitness* = object
    bankQueries*, nodeQueries*, references*: seq[ReadOnlyEntry]
    depths*: seq[uint32]
    last*: seq[bool]
    banks*, nodes*: MemoryWitness
  BranchProjection* = object
    depths*, last*: seq[Linear]

func branchBankAddress*(functionIndex, bankIndex: uint32): uint64 =
  (uint64(functionIndex) shl 32)+uint64(bankIndex)

proc buildBranchEnvironment*(module: WasmModule, bankCapacity = 0,
    nodeCapacity = 0, maxNodes = 1_048_576): BranchEnvironment =
  if bankCapacity < 0 or nodeCapacity < 0 or maxNodes < 0:
    raise newException(ValueError, "invalid branch environment dimensions")
  var first = 0'u64
  for item in module.imports:
    if item.kind == ikFunc: inc first
  if first+uint64(module.codes.len) > uint64(high(uint32)):
    raise newException(ValueError, "branch function namespace overflow")
  var interned: Table[tuple[depth, next: uint32], uint32]
  template cons(depth: uint32, cursor: var uint32) =
    let key = (depth, cursor)
    if interned.hasKey(key): cursor = interned[key]
    else:
      if result.nodes.len >= maxNodes or uint64(result.nodes.len) >= uint64(high(uint32)):
        raise newException(ValueError, "branch node capacity exceeded")
      let id = uint32(result.nodes.len+1)
      result.nodes.add ReadOnlyEntry(active: true, address: uint64(id),
        value: uint64(depth)+(uint64(cursor) shl 32))
      interned[key] = id
      cursor = id
  for body, code in module.codes:
    if uint64(code.code.brTables.len) > uint64(high(uint32)):
      raise newException(ValueError, "branch bank namespace overflow")
    for index, bank in code.code.brTables:
      var cursor = 0'u32
      cons(bank.defaultLabel, cursor)
      for i in countdown(bank.labels.high, 0): cons(bank.labels[i], cursor)
      result.banks.add ReadOnlyEntry(active: true,
        address: branchBankAddress(uint32(first+uint64(body)), uint32(index)), value: uint64(cursor))
  if bankCapacity != 0:
    if result.banks.len > bankCapacity: raise newException(ValueError, "branch bank profile overflow")
    result.banks.setLen(bankCapacity)
  if nodeCapacity != 0:
    if result.nodes.len > nodeCapacity: raise newException(ValueError, "branch node profile overflow")
    result.nodes.setLen(nodeCapacity)

proc contents(entries: openArray[ReadOnlyEntry]): Table[uint64, uint64] =
  for entry in entries:
    if entry.active: result[entry.address] = entry.value

proc buildBranchWitness*(environment: BranchEnvironment, rows: openArray[InstructionEventRow],
    primary: openArray[uint32], catchChecks = false): BranchEnvironmentWitness =
  if rows.len != primary.len: raise newException(ValueError, "branch witness dimensions differ")
  let banks = contents(environment.banks)
  let nodes = contents(environment.nodes)
  for entry in environment.banks:
    result.references.add(if entry.active: ReadOnlyEntry(active: true,
      address: entry.value, value: nodes.getOrDefault(entry.value)) else: ReadOnlyEntry())
  for entry in environment.nodes:
    let next = entry.value shr 32
    result.references.add(if entry.active and next != 0: ReadOnlyEntry(active: true,
      address: next, value: nodes.getOrDefault(next)) else: ReadOnlyEntry())
  result.bankQueries.setLen(rows.len)
  result.nodeQueries.setLen(rows.len)
  result.depths.setLen(rows.len)
  result.last.setLen(rows.len)
  var cursor = 0'u64
  for i, row in rows:
    let kind = row.control.operand.kind
    if kind in [uint8(ord(veFunctionBegin)), uint8(ord(veInstructionBegin))]:
      cursor = 0
      if kind == uint8(ord(veInstructionBegin)) and row.opcode == uint16(ord(opBrTable)):
        let address = branchBankAddress(row.control.operand.functionIndex, primary[i])
        cursor = banks.getOrDefault(address)
        result.bankQueries[i] = ReadOnlyEntry(active: true, address: address, value: cursor)
    elif kind == uint8(ord(veLabelCheck)) and (not catchChecks or row.opcode == uint16(ord(opBrTable))):
      let value = nodes.getOrDefault(cursor)
      result.nodeQueries[i] = ReadOnlyEntry(active: true, address: cursor, value: value)
      result.depths[i] = uint32(value and 0xffffffff'u64)
      cursor = value shr 32
      result.last[i] = cursor == 0
  result.banks = buildReadOnlyWitness(environment.banks, result.bankQueries)
  result.nodes = buildReadOnlyWitness(environment.nodes, result.references & result.nodeQueries)

proc read(c: var Circuit, active, address: Linear, value: uint64): ReadOnlyWires =
  ReadOnlyWires(active: active, address: c.multiply(active, address), value: c.allocate(scalar(value)))

proc constrainBranchEnvironment*(c: var Circuit, environment: BranchEnvironmentWires,
    rows: openArray[InstructionEventWires], primary: openArray[Linear],
    operand: OperandEventProjection, witness: BranchEnvironmentWitness): BranchProjection =
  if rows.len != primary.len or rows.len != operand.flags.len or
      rows.len != witness.bankQueries.len or rows.len != witness.nodeQueries.len or
      witness.references.len != environment.banks.len+environment.nodes.len:
    raise newException(ValueError, "branch circuit dimensions differ")
  when defined(zkbuildStructuredControlAudit):
    let marker = c.beginSourceProgram()
  var bankQueries, nodeQueries: seq[ReadOnlyWires]
  var position = 0
  for entry in environment.banks:
    discard c.constrainUnsigned(entry.value, 32)
    c.constrain(entry.active, c.zeroIndicator(entry.value), constant(0))
    nodeQueries.add c.read(entry.active, entry.value, witness.references[position].value)
    inc position
  for entry in environment.nodes:
    let parts = c.splitSignatureHeads(entry.value)
    let delta = c.selectWire(entry.active, entry.address-parts.results-constant(1), constant(0))
    discard c.constrainUnsigned(delta, 32)
    let active = c.multiply(entry.active, constant(1)-c.zeroIndicator(parts.results))
    nodeQueries.add c.read(active, parts.results, witness.references[position].value)
    inc position
  var cursor = constant(0)
  for i, row in rows:
    let flags = operand.flags[i]
    let table = c.zeroIndicator(row.opcode-constant(ord(opBrTable)))
    let begin = c.multiply(flags.instructionBegin, table)
    discard c.constrainUnsigned(primary[i], 32)
    let bank = c.read(begin, row.control.operand.functionIndex.scale(scalar(1'u64 shl 32))+primary[i],
      witness.bankQueries[i].value)
    bankQueries.add bank
    cursor = c.selectWire(flags.functionBegin+flags.instructionBegin, bank.value, cursor)
    c.constrain(flags.labelCheck, constant(1)-table, constant(0))
    c.constrain(flags.labelCheck, c.zeroIndicator(cursor), constant(0))
    let node = c.read(flags.labelCheck, cursor, witness.nodeQueries[i].value)
    nodeQueries.add node
    let parts = c.splitSignatureHeads(node.value)
    result.depths.add parts.params
    result.last.add c.multiply(flags.labelCheck, c.zeroIndicator(parts.results))
    cursor = c.selectWire(flags.labelCheck, parts.results, cursor)
    c.constrain(c.multiply(flags.instructionEnd, table), cursor, constant(0))
  c.assertEqual(cursor, constant(0))
  when defined(zkbuildStructuredControlAudit):
    var audit = DynamicTypingStageAudit(kind: 2,rows: captureInstructionRows(rows),flags: captureEventFlags(operand.flags),
      program: c.endSourceProgram(marker))
    for i in 0..<rows.len:
      audit.inputs.add copyAuditExpressions([primary[i]])
      audit.outputs.add copyAuditExpressions([result.depths[i],result.last[i]])
    audit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(environment.banks, bankQueries, witness.banks, 64, 32)
  when defined(zkbuildStructuredControlAudit): audit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(environment.nodes, nodeQueries, witness.nodes, 32, 64)
  when defined(zkbuildStructuredControlAudit): c.structuredControlRecords.add audit
