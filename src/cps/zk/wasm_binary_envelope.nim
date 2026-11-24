## Authenticate the complete section envelope before binding its payloads.
## Every source byte belongs to the header or exactly one declared section.
## Payload grammar and declaration/instruction binding are separate layers.
import ../wasm/binary_order
import r1cs, range_check, wasm_binary_source, opcode_lookup

type
  BinarySection* = object
    active*: bool
    id*, start*, body*, size*, finish*, firstWord*: uint32
    sizeRead*, wordRead*: BinaryRead
  BinaryEnvelope* = object
    sections*: seq[BinarySection]
  BinarySectionWires* = object
    active*, id*, start*, body*, size*, finish*, firstWord*: Linear
  BinaryEnvelopeWires* = object
    sections*: seq[BinarySectionWires]
    present*, firstWords*: array[14, Linear]
    payloadStarts*, ends*: array[14, Linear]

proc sectionPolicy(): OpcodeLookup[2] =
  var values = newSeq[array[2, int]](65536)
  for i in 0..255:
    let rank = binarySectionOrder(i)
    if rank >= 0: values[i] = [1, rank]
  buildOpcodeLookup(values)

let sectionLookup = sectionPolicy()

proc buildBinaryEnvelope*(data: openArray[byte], capacity = 0): BinaryEnvelope =
  const Header = [0'u8, 97, 115, 109, 1, 0, 0, 0]
  if data.len < 8: raise newException(ValueError, "truncated WASM header")
  for i, value in Header:
    if data[i] != value: raise newException(ValueError, "invalid WASM header")
  var cursor = 8'u64
  var lastRank = 0
  while cursor < uint64(data.len):
    if cursor > uint64(high(uint32)): raise newException(ValueError, "binary position overflow")
    let id = uint32(data[int(cursor)])
    let rank = binarySectionOrder(int(id))
    if rank < 0 or (id != 0 and rank <= lastRank):
      raise newException(ValueError, "unknown, duplicate or reordered WASM section")
    if id != 0: lastRank = rank
    let size = readBinaryToken(data, uint32(cursor)+1, brU32)
    let body = cursor+1+uint64(size.length)
    let finish = body+size.value
    if finish > uint64(data.len) or finish > uint64(high(uint32)):
      raise newException(ValueError, "section exceeds source")
    var word: BinaryRead
    if id != 0:
      word = readBinaryToken(data, uint32(body), brU32)
      if body+uint64(word.length) > finish: raise newException(ValueError, "section header exceeds payload")
    result.sections.add BinarySection(active: true, id: id, start: uint32(cursor), body: uint32(body),
      size: uint32(size.value), finish: uint32(finish), firstWord: uint32(word.value), sizeRead: size, wordRead: word)
    cursor = finish
  if capacity != 0:
    if capacity < result.sections.len: raise newException(ValueError, "section profile capacity exceeded")
    result.sections.setLen(capacity)

proc allocateBinaryEnvelope*(c: var Circuit, envelope: BinaryEnvelope): BinaryEnvelopeWires =
  ## Metadata is private and derived by the relation; allocate before reads.
  for row in envelope.sections:
    result.sections.add BinarySectionWires(active: c.allocate(scalar(ord(row.active))),
      id: c.allocate(scalar(row.id)), start: c.allocate(scalar(row.start)),
      body: c.allocate(scalar(row.body)), size: c.allocate(scalar(row.size)),
      finish: c.allocate(scalar(row.finish)), firstWord: c.allocate(scalar(row.firstWord)))

proc constrainBinaryEnvelope*(c: var Circuit, source: var BinarySource,
    envelope: var BinaryEnvelopeWires, hint: BinaryEnvelope) =
  if envelope.sections.len != hint.sections.len: raise newException(ValueError, "section dimensions differ")
  when defined(zkbuildEnvelopeAudit):
    var evidence = EnvelopeAudit(sourceIndex: source.auditSourceIndex,firstWire: c.values.len,firstGate: c.constraints.len,sourceLength: source.length)
  const Header = [0'u8, 97, 115, 109, 1, 0, 0, 0]
  for i, value in Header:
    when defined(zkbuildEnvelopeAudit): evidence.headerTokens.add c.tokenRecords.len
    let token = source.readToken(uint32(i), brByte)
    discard c.constrainBinaryRead(source, brByte, constant(1), constant(i), constant(value), token)
  var cursor = constant(8)
  var rank = constant(0)
  var previous = constant(1)
  for id in 0..13:
    envelope.present[id] = constant(0)
    envelope.firstWords[id] = constant(0)
    envelope.payloadStarts[id] = constant(0)
    envelope.ends[id] = constant(0)
  for i, row in envelope.sections:
    when defined(zkbuildEnvelopeAudit):
      var auditRow = EnvelopeRowAudit(fields: @[row.active,row.id,row.start,row.body,row.size,row.finish,row.firstWord])
    c.constrainBoolean(row.active)
    c.constrain(row.active, constant(1)-previous, constant(0))
    for value in [row.id, row.start, row.body, row.size, row.finish, row.firstWord]:
      discard c.constrainUnsigned(value, 32)
      when defined(zkbuildEnvelopeAudit): auditRow.ranges.add c.snapshotRangeUse()
      c.constrain(constant(1)-row.active, value, constant(0))
    c.constrain(row.active, row.start-cursor, constant(0))
    let token = if hint.sections[i].active: source.readToken(hint.sections[i].start, brByte) else: BinaryRead()
    when defined(zkbuildEnvelopeAudit): auditRow.idToken = c.tokenRecords.len
    discard c.constrainBinaryRead(source, brByte, row.active, row.start, row.id, token)
    let sizePosition = c.multiply(row.active, row.start+constant(1))
    when defined(zkbuildEnvelopeAudit):
      auditRow.sizePosition = sizePosition
      auditRow.sizeToken = c.tokenRecords.len
    let sizeLength = c.constrainBinaryRead(source, brU32, row.active,
      sizePosition, row.size, hint.sections[i].sizeRead)
    c.constrain(row.active, row.body-row.start-constant(1)-sizeLength, constant(0))
    c.constrain(row.active, row.finish-row.body-row.size, constant(0))
    let remaining = c.multiply(row.active, source.length-row.finish)
    discard c.constrainUnsigned(remaining, 32)
    when defined(zkbuildEnvelopeAudit):
      auditRow.remaining = remaining
      auditRow.remainingRange = c.snapshotRangeUse()
    let policy = c.constrainLookup(sectionLookup, row.id)
    when defined(zkbuildEnvelopeAudit):
      auditRow.lookup = c.lookupRecords[^1]
    c.constrain(row.active, policy[0]-constant(1), constant(0))
    when defined(zkbuildEnvelopeAudit): auditRow.standardStart = c.values.len
    let standard = c.multiply(row.active, constant(1)-c.zeroIndicator(row.id))
    let rankGap = c.multiply(standard, policy[1]-rank-constant(1))
    discard c.constrainUnsigned(rankGap, 4)
    when defined(zkbuildEnvelopeAudit):
      auditRow.standard = standard
      auditRow.rankGap = rankGap
      auditRow.rankGapRange = c.snapshotRangeUse()
    rank = c.selectWire(standard, policy[1], rank)
    when defined(zkbuildEnvelopeAudit):
      auditRow.nextRank = rank
      auditRow.wordToken = c.tokenRecords.len
    let wordLength = c.constrainBinaryRead(source, brU32, standard, row.body, row.firstWord, hint.sections[i].wordRead)
    let wordGap = c.multiply(standard, row.finish-row.body-wordLength)
    discard c.constrainUnsigned(wordGap, 32)
    when defined(zkbuildEnvelopeAudit):
      auditRow.wordGap = wordGap
      auditRow.wordGapRange = c.snapshotRangeUse()
      auditRow.aggregateStart = c.values.len
    for id in 0..13:
      let matches = c.multiply(row.active, c.zeroIndicator(row.id-constant(id)))
      envelope.present[id] = c.materialize(envelope.present[id]+matches)
      envelope.firstWords[id] = c.materialize(envelope.firstWords[id]+c.multiply(matches, row.firstWord))
      envelope.payloadStarts[id] = c.materialize(envelope.payloadStarts[id]+c.multiply(matches, row.body+wordLength))
      envelope.ends[id] = c.materialize(envelope.ends[id]+c.multiply(matches, row.finish))
    cursor = c.selectWire(row.active, row.finish, cursor)
    previous = row.active
    when defined(zkbuildEnvelopeAudit):
      auditRow.cursor = cursor
      evidence.rows.add auditRow
  c.assertEqual(cursor, source.length)
  when defined(zkbuildEnvelopeAudit):
    evidence.lastWire = c.values.len
    evidence.lastGate = c.constraints.len
    for id in 0..13:
      for value in [envelope.present[id],envelope.firstWords[id],envelope.payloadStarts[id],envelope.ends[id]]:
        evidence.outputs.add value
    c.envelopeRecords.add evidence
