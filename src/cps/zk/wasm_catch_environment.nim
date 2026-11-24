## Interned catch lists. A marker is mandatory for every clause, including
## empty payloads. Depth/tag fields retain the complete u32 namespace.
import std/tables
import ../wasm/[types, validate]
import r1cs, range_check, read_only_memory, memory_consistency
import wasm_instruction_events, wasm_operand_events, wasm_signature_environment

type
  CatchEnvironment* = object
    banks*, links*, clauses*: seq[ReadOnlyEntry]
  CatchEnvironmentWires* = object
    banks*, links*, clauses*: seq[ReadOnlyWires]
  CatchEnvironmentWitness* = object
    bankQueries*, linkQueries*, clauseQueries*, references*: seq[ReadOnlyEntry]
    depths*: seq[uint32]
    banks*, links*, clauses*: MemoryWitness
  CatchProjection* = object
    marks*, depths*, tags*, tagged*, references*: seq[Linear]

func catchBankAddress*(functionIndex, bank: uint32): uint64 =
  (uint64(functionIndex) shl 32)+uint64(bank)

proc buildCatchEnvironment*(module: WasmModule, bankCapacity = 0, nodeCapacity = 0,
    maxNodes = 1_048_576): CatchEnvironment =
  if bankCapacity < 0 or nodeCapacity < 0 or maxNodes < 0:
    raise newException(ValueError, "invalid catch environment dimensions")
  var first = 0'u64
  for item in module.imports:
    if item.kind == ikFunc: inc first
  if first+uint64(module.codes.len) > uint64(high(uint32)):
    raise newException(ValueError, "catch function namespace overflow")
  var interned: Table[tuple[kind: uint8, tag, depth, next: uint32], uint32]
  for body, code in module.codes:
    if uint64(code.code.catchTables.len) > uint64(high(uint32)):
      raise newException(ValueError, "catch bank namespace overflow")
    for bank, clauses in code.code.catchTables:
      var cursor = 0'u32
      for i in countdown(clauses.high, 0):
        let clause = clauses[i]
        let tag = if clause.kind in {ckCatch, ckCatchRef}: clause.tagIdx else: 0'u32
        let key = (uint8(ord(clause.kind)), tag, clause.labelDepth, cursor)
        if interned.hasKey(key): cursor = interned[key]
        else:
          if result.links.len >= maxNodes or uint64(result.links.len) >= uint64(high(uint32)):
            raise newException(ValueError, "catch node capacity exceeded")
          let id = uint32(result.links.len+1)
          result.links.add ReadOnlyEntry(active: true, address: uint64(id), value: uint64(key[0])+4*uint64(cursor))
          result.clauses.add ReadOnlyEntry(active: true, address: uint64(id),
            value: uint64(tag)+(uint64(clause.labelDepth) shl 32))
          interned[key] = id
          cursor = id
      result.banks.add ReadOnlyEntry(active: true,
        address: catchBankAddress(uint32(first+uint64(body)), uint32(bank)), value: uint64(cursor))
  if bankCapacity != 0:
    if result.banks.len > bankCapacity: raise newException(ValueError, "catch bank profile overflow")
    result.banks.setLen(bankCapacity)
  if nodeCapacity != 0:
    if result.links.len > nodeCapacity: raise newException(ValueError, "catch node profile overflow")
    result.links.setLen(nodeCapacity)
    result.clauses.setLen(nodeCapacity)

proc contents(entries: openArray[ReadOnlyEntry]): Table[uint64, uint64] =
  for entry in entries:
    if entry.active: result[entry.address] = entry.value

proc reference(active: bool, id: uint64, values: Table[uint64, uint64]): ReadOnlyEntry =
  if active and id != 0: ReadOnlyEntry(active: true, address: id, value: values.getOrDefault(id)) else: ReadOnlyEntry()

proc buildCatchWitness*(environment: CatchEnvironment, rows: openArray[InstructionEventRow],
    secondary: openArray[uint32]): CatchEnvironmentWitness =
  if rows.len != secondary.len or environment.links.len != environment.clauses.len:
    raise newException(ValueError, "catch witness dimensions differ")
  let banks = contents(environment.banks)
  let links = contents(environment.links)
  let clauses = contents(environment.clauses)
  for entry in environment.banks: result.references.add reference(entry.active, entry.value, links)
  for entry in environment.links: result.references.add reference(entry.active, entry.value shr 2, links)
  var cursor = 0'u64
  for i, row in rows:
    var bank, link, clause: ReadOnlyEntry
    if row.control.operand.kind in [uint8(ord(veFunctionBegin)), uint8(ord(veInstructionBegin))]:
      cursor = 0
      if row.control.operand.kind == uint8(ord(veInstructionBegin)) and row.opcode == uint16(ord(opTryTable)):
        let address = catchBankAddress(row.control.operand.functionIndex, secondary[i])
        bank = ReadOnlyEntry(active: true, address: address, value: banks.getOrDefault(address))
        cursor = bank.value
    elif row.control.operand.kind == uint8(ord(veLabelCheck)) and row.opcode == uint16(ord(opTryTable)):
      link = ReadOnlyEntry(active: true, address: cursor, value: links.getOrDefault(cursor))
      clause = ReadOnlyEntry(active: true, address: cursor, value: clauses.getOrDefault(cursor))
      cursor = link.value shr 2
    result.bankQueries.add bank
    result.linkQueries.add link
    result.clauseQueries.add clause
    result.depths.add uint32(clause.value shr 32)
  result.banks = buildReadOnlyWitness(environment.banks, result.bankQueries)
  result.links = buildReadOnlyWitness(environment.links, result.references & result.linkQueries)
  result.clauses = buildReadOnlyWitness(environment.clauses, result.clauseQueries)

proc read(c: var Circuit, active, address: Linear, value: uint64): ReadOnlyWires =
  ReadOnlyWires(active: active, address: c.multiply(active, address), value: c.allocate(scalar(value)))

proc split(c: var Circuit, value: Linear): tuple[all, reference, next: Linear] =
  let bits = c.constrainUnsigned(value, 34)
  result.all = bits[1]
  result.reference = bits[0]
  var weight = scalar(1)
  for i in 2..33:
    result.next = result.next+bits[i].scale(weight)
    weight = weight+weight
  result.next = c.materialize(result.next)

proc constrainCatchEnvironment*(c: var Circuit, environment: CatchEnvironmentWires,
    rows: openArray[InstructionEventWires], secondary: openArray[Linear],
    operand: OperandEventProjection, witness: CatchEnvironmentWitness): CatchProjection =
  if rows.len == 0 or rows.len != secondary.len or rows.len != operand.flags.len or
      rows.len != witness.bankQueries.len or rows.len != witness.linkQueries.len or
      rows.len != witness.clauseQueries.len or environment.links.len != environment.clauses.len or
      witness.references.len != environment.banks.len+environment.links.len:
    raise newException(ValueError, "catch circuit dimensions differ")
  when defined(zkbuildStructuredControlAudit):
    let marker = c.beginSourceProgram()
  var banks, links, clauses: seq[ReadOnlyWires]
  var position = 0
  for entry in environment.banks:
    discard c.constrainUnsigned(entry.value, 32)
    let active = c.multiply(entry.active, constant(1)-c.zeroIndicator(entry.value))
    links.add c.read(active, entry.value, witness.references[position].value)
    inc position
  for i, entry in environment.links:
    let data = environment.clauses[i]
    c.assertEqual(entry.active, data.active)
    c.assertEqual(entry.address, data.address)
    c.constrain(entry.active, entry.address-constant(i+1), constant(0))
    let parts = c.split(entry.value)
    let fields = c.splitSignatureHeads(data.value)
    c.constrain(c.multiply(entry.active, parts.all), fields.params, constant(0))
    discard c.constrainUnsigned(c.multiply(entry.active, entry.address-parts.next-constant(1)), 32)
    let active = c.multiply(entry.active, constant(1)-c.zeroIndicator(parts.next))
    links.add c.read(active, parts.next, witness.references[position].value)
    inc position
  var cursor, pushed = constant(0)
  for i, row in rows:
    let flags = operand.flags[i]
    let trying = c.zeroIndicator(row.opcode-constant(ord(opTryTable)))
    discard c.constrainUnsigned(row.opcode, 16)
    discard c.constrainUnsigned(secondary[i], 32)
    c.constrain(constant(1)-flags.instructionBegin, secondary[i], constant(0))
    let bank = c.read(c.multiply(flags.instructionBegin, trying),
      row.control.operand.functionIndex.scale(scalar(1'u64 shl 32))+secondary[i], witness.bankQueries[i].value)
    banks.add bank
    let reset = flags.functionBegin+flags.instructionBegin
    cursor = c.selectWire(reset, bank.value, cursor)
    pushed = c.selectWire(reset, constant(0), pushed)
    let mark = c.multiply(flags.labelCheck, trying)
    c.constrain(mark, pushed, constant(0))
    c.constrain(mark, c.zeroIndicator(cursor), constant(0))
    let link = c.read(mark, cursor, witness.linkQueries[i].value)
    links.add link
    let clause = c.read(mark, cursor, witness.clauseQueries[i].value)
    clauses.add clause
    let parts = c.split(link.value)
    let fields = c.splitSignatureHeads(clause.value)
    result.marks.add mark
    result.depths.add fields.results
    result.tags.add fields.params
    result.tagged.add c.multiply(mark, constant(1)-parts.all)
    result.references.add c.multiply(mark, parts.reference)
    cursor = c.selectWire(mark, parts.next, cursor)
    pushed = c.materialize(pushed+c.multiply(trying, flags.controlPush))
    c.constrain(c.multiply(trying, flags.instructionEnd), cursor, constant(0))
  c.assertEqual(cursor, constant(0))
  when defined(zkbuildStructuredControlAudit):
    var audit = DynamicTypingStageAudit(kind: 0,rows: captureInstructionRows(rows),flags: captureEventFlags(operand.flags),
      program: c.endSourceProgram(marker))
    for i in 0..<rows.len:
      audit.inputs.add copyAuditExpressions([secondary[i]])
      audit.outputs.add copyAuditExpressions([result.marks[i],result.depths[i],result.tags[i],result.tagged[i],result.references[i]])
    audit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(environment.banks, banks, witness.banks, 64, 32)
  when defined(zkbuildStructuredControlAudit): audit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(environment.links, links, witness.links, 32, 34)
  when defined(zkbuildStructuredControlAudit): audit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(environment.clauses, clauses, witness.clauses, 32, 64)
  when defined(zkbuildStructuredControlAudit): c.structuredControlRecords.add audit
