## Exact source binding for type vectors, defined-function type indices, and
## exception tags. Other declaration payloads are not covered by this layer.
import std/tables
import ../wasm/[types, variable_typing]
import r1cs, range_check, read_only_memory
import wasm_binary_source, wasm_binary_envelope, wasm_signature_environment
import wasm_indexed_signatures, wasm_throw_events
import wasm_declaration_profile

type
  SourceType* = object
    active*: bool
    start*, paramsStart*, resultsStart*, finish*, params*, results*: uint32
    header*, paramRead*, resultRead*: BinaryRead
  SourceTypeWires* = object
    active*, start*, paramsStart*, resultsStart*, finish*, params*, results*: Linear
  DeclarationSource* = object
    types*: seq[SourceType]
    params*, results*: seq[ReadOnlyEntry] # type32 | ordinal32 -> type tag3
    functions*, tagAttributes*, tags*: seq[BinaryRead]
    functionActive*: seq[bool]
  DeclarationSourceWires* = object
    types*: seq[SourceTypeWires]
    params*, results*: seq[ReadOnlyWires]
    functionActive*: seq[Linear]

proc bodyAfterCount(envelope: BinaryEnvelope, id: uint32): uint32 =
  for row in envelope.sections:
    if row.active and row.id == id: return row.body+uint32(row.wordRead.length)

proc buildDeclarationSource*(module: WasmModule, data: openArray[byte],
    envelope: BinaryEnvelope, profile = DeclarationProfile()): DeclarationSource =
  profile.validate()
  var cursor = envelope.bodyAfterCount(1)
  for i, signature in module.types:
    var row = SourceType(active: true, start: cursor)
    row.header = readBinaryToken(data, cursor, brByte)
    row.paramRead = readBinaryToken(data, cursor+1, brU32)
    row.params = uint32(row.paramRead.value)
    row.paramsStart = cursor+1+uint32(row.paramRead.length)
    let resultPosition = uint64(row.paramsStart)+uint64(row.params)
    if resultPosition > uint64(high(uint32)): raise newException(ValueError, "type vector position overflow")
    row.resultRead = readBinaryToken(data, uint32(resultPosition), brU32)
    row.results = uint32(row.resultRead.value)
    row.resultsStart = uint32(resultPosition)+uint32(row.resultRead.length)
    let finish = uint64(row.resultsStart)+uint64(row.results)
    if finish > uint64(high(uint32)): raise newException(ValueError, "type vector end overflow")
    row.finish = uint32(finish)
    result.types.add row
    for j, value in signature.params:
      result.params.add ReadOnlyEntry(active: true, address: (uint64(i) shl 32)+uint64(j), value: uint64(stackTypeTag(value)))
    for j, value in signature.results:
      result.results.add ReadOnlyEntry(active: true, address: (uint64(i) shl 32)+uint64(j), value: uint64(stackTypeTag(value)))
    cursor = row.finish
  cursor = envelope.bodyAfterCount(3)
  for _ in module.funcTypeIdxs:
    let token = readBinaryToken(data, cursor, brU32)
    result.functions.add token
    result.functionActive.add true
    cursor += uint32(token.length)
  cursor = envelope.bodyAfterCount(13)
  for _ in module.tagDefs:
    result.tagAttributes.add readBinaryToken(data, cursor, brByte)
    inc cursor
    let token = readBinaryToken(data, cursor, brU32)
    result.tags.add token
    cursor += uint32(token.length)
  if profile.enabled:
    result.types.padDeclarations(profile.types)
    result.params.padDeclarations(profile.parameters)
    result.results.padDeclarations(profile.results)
    result.functions.padDeclarations(profile.functions)
    result.functionActive.padDeclarations(profile.functions)
    result.tags.padDeclarations(profile.tags)
    result.tagAttributes.padDeclarations(profile.tags)

proc allocateDeclarationSource*(c: var Circuit, source: DeclarationSource): DeclarationSourceWires =
  for row in source.types:
    result.types.add SourceTypeWires(active: c.allocate(scalar(ord(row.active))), start: c.allocate(scalar(row.start)),
      paramsStart: c.allocate(scalar(row.paramsStart)), resultsStart: c.allocate(scalar(row.resultsStart)),
      finish: c.allocate(scalar(row.finish)), params: c.allocate(scalar(row.params)), results: c.allocate(scalar(row.results)))
  for row in source.params:
    result.params.add ReadOnlyWires(active: c.allocate(scalar(ord(row.active))),
      address: c.allocate(scalar(row.address)), value: c.allocate(scalar(row.value)))
  for row in source.results:
    result.results.add ReadOnlyWires(active: c.allocate(scalar(ord(row.active))),
      address: c.allocate(scalar(row.address)), value: c.allocate(scalar(row.value)))
  for active in source.functionActive: result.functionActive.add c.allocate(scalar(ord(active)))

proc contents(entries: openArray[ReadOnlyEntry]): Table[uint64, uint64] =
  for entry in entries:
    if entry.active: result[entry.address] = entry.value

proc constrainDeclarationSource*(c: var Circuit, bytes: var BinarySource,
    envelope: BinaryEnvelopeWires, source: DeclarationSourceWires, hint: DeclarationSource,
    signatures: SignatureEnvironmentWires, signatureValues: SignatureEnvironment,
    indexed: IndexedSignatureWires, indexedValues: IndexedSignatureEnvironment,
    tags: TagEnvironmentWires, firstFunction: Linear): void =
  if source.types.len != hint.types.len or source.params.len != hint.params.len or
      source.results.len != hint.results.len or tags.tags.len != hint.tags.len or
      tags.typeIndices.len != tags.tags.len or hint.tagAttributes.len != hint.tags.len:
    raise newException(ValueError, "source declaration dimensions differ")
  if hint.functionActive.len != hint.functions.len or source.functionActive.len != hint.functions.len:
    raise newException(ValueError,"source function flag dimensions differ")
  when defined(zkbuildDeclarationAudit):
    var evidence = DeclarationAudit(firstFunction: firstFunction,
      typeStart: envelope.payloadStarts[1],typeEnd: envelope.ends[1],typeCount: envelope.firstWords[1],
      functionStart: envelope.payloadStarts[3],functionEnd: envelope.ends[3],functionCount: envelope.firstWords[3],
      tagStart: envelope.payloadStarts[13],tagEnd: envelope.ends[13])
  let metadata = contents(signatureValues.signatures)
  let lengths = contents(indexedValues.lengths)
  let members = contents(indexedValues.members)
  var metaQueries, lengthQueries, memberQueries: seq[ReadOnlyWires]
  var metaValues, lengthValues, memberValues: seq[ReadOnlyEntry]
  var paramLocations, resultLocations: seq[ReadOnlyWires]
  var paramLocationValues, resultLocationValues: seq[ReadOnlyEntry]
  var paramQueries, resultQueries: seq[ReadOnlyWires]
  var paramValues, resultValues: seq[ReadOnlyEntry]
  template query(bank: untyped, records: untyped, lookup: untyped,
      enabled, key: Linear, hostActive: bool, hostKey: uint64): Linear =
    block:
      let actual = if hostActive: lookup.getOrDefault(hostKey) else: 0'u64
      let value = c.allocate(scalar(actual))
      bank.add ReadOnlyWires(active: enabled, address: c.multiply(enabled, key), value: value)
      records.add(if hostActive: ReadOnlyEntry(active: true, address: hostKey, value: actual) else: ReadOnlyEntry())
      value
  var cursor = envelope.payloadStarts[1]
  var activeCount, paramCount, resultCount = constant(0)
  var previous = constant(1)
  for i, row in source.types:
    let raw = hint.types[i]
    when defined(zkbuildDeclarationAudit):
      var audit = DeclarationTypeAudit(firstGate: c.constraints.len,
        fields: copyAuditExpressions([row.active,row.start,row.paramsStart,row.resultsStart,row.finish,row.params,row.results]))
    c.constrainBoolean(row.active)
    c.constrain(row.active, constant(1)-previous, constant(0))
    for field in [row.start, row.paramsStart, row.resultsStart, row.finish, row.params, row.results]:
      discard c.constrainUnsigned(field, 32)
      when defined(zkbuildDeclarationAudit): audit.ranges.add c.snapshotRangeUse()
      c.constrain(constant(1)-row.active, field, constant(0))
    c.constrain(row.active, row.start-cursor, constant(0))
    when defined(zkbuildDeclarationAudit): audit.headerToken = c.tokenRecords.len
    discard c.constrainBinaryRead(bytes, brByte, row.active, row.start, row.active.scale(scalar(0x60)), raw.header)
    let paramPosition = c.multiply(row.active, row.start+constant(1))
    when defined(zkbuildDeclarationAudit):
      audit.paramPosition = paramPosition
      audit.paramToken = c.tokenRecords.len
    let paramSize = c.constrainBinaryRead(bytes, brU32, row.active,
      paramPosition, row.params, raw.paramRead)
    c.constrain(row.active, row.paramsStart-row.start-constant(1)-paramSize, constant(0))
    let resultPosition = c.multiply(row.active, row.paramsStart+row.params)
    when defined(zkbuildDeclarationAudit):
      audit.resultPosition = resultPosition
      audit.resultToken = c.tokenRecords.len
    let resultSize = c.constrainBinaryRead(bytes, brU32, row.active,
      resultPosition, row.results, raw.resultRead)
    c.constrain(row.active, row.resultsStart-row.paramsStart-row.params-resultSize, constant(0))
    c.constrain(row.active, row.finish-row.resultsStart-row.results, constant(0))
    let remaining = c.multiply(row.active, envelope.ends[1]-row.finish)
    discard c.constrainUnsigned(remaining, 32)
    when defined(zkbuildDeclarationAudit):
      audit.remaining = remaining
      audit.remainingRange = c.snapshotRangeUse()
    let value = query(metaQueries, metaValues, metadata, row.active, constant(2*i+1), raw.active, uint64(2*i+1))
    when defined(zkbuildDeclarationAudit):
      let q = metaQueries[^1]
      audit.metadata = copyAuditExpressions([q.active,q.address,q.value])
      audit.heads = c.packedRecords.len
    let heads = c.splitSignatureHeads(value)
    let hostHeads = metadata.getOrDefault(uint64(2*i+1))
    let pLength = query(lengthQueries, lengthValues, lengths, row.active, heads.params, raw.active, hostHeads and 0xffffffff'u64)
    let rLength = query(lengthQueries, lengthValues, lengths, row.active, heads.results, raw.active, hostHeads shr 32)
    when defined(zkbuildDeclarationAudit):
      let p = lengthQueries[^2]
      let r = lengthQueries[^1]
      audit.paramLength = copyAuditExpressions([p.active,p.address,p.value])
      audit.resultLength = copyAuditExpressions([r.active,r.address,r.value])
    c.assertEqual(pLength, row.params)
    c.assertEqual(rLength, row.results)
    paramLocations.add ReadOnlyWires(active: row.active, address: row.active.scale(scalar(i)),
      value: row.paramsStart+row.params.scale(scalar(1'u64 shl 32)))
    resultLocations.add ReadOnlyWires(active: row.active, address: row.active.scale(scalar(i)),
      value: row.resultsStart+row.results.scale(scalar(1'u64 shl 32)))
    paramLocationValues.add ReadOnlyEntry(active: raw.active, address: (if raw.active: uint64(i) else: 0), value: uint64(raw.paramsStart)+(uint64(raw.params) shl 32))
    resultLocationValues.add ReadOnlyEntry(active: raw.active, address: (if raw.active: uint64(i) else: 0), value: uint64(raw.resultsStart)+(uint64(raw.results) shl 32))
    activeCount = c.materialize(activeCount+row.active)
    paramCount = c.materialize(paramCount+row.params)
    resultCount = c.materialize(resultCount+row.results)
    cursor = c.selectWire(row.active, row.finish, cursor)
    previous = row.active
    when defined(zkbuildDeclarationAudit):
      audit.counts = copyAuditExpressions([activeCount,paramCount,resultCount,cursor])
      audit.lastGate = c.constraints.len
      evidence.types.add audit
  when defined(zkbuildDeclarationAudit): evidence.typeCloseStart = c.constraints.len
  c.assertEqual(activeCount, envelope.firstWords[1])
  c.assertEqual(cursor, envelope.ends[1])
  discard c.constrainUnsigned(paramCount, 64)
  when defined(zkbuildDeclarationAudit): evidence.paramTotalRange = c.snapshotRangeUse()
  discard c.constrainUnsigned(resultCount, 64)
  when defined(zkbuildDeclarationAudit):
    evidence.resultTotalRange = c.snapshotRangeUse()
    evidence.paramTotal = paramCount
    evidence.resultTotal = resultCount
    evidence.typeCloseEnd = c.constraints.len
  let paramMap = contents(paramLocationValues)
  let resultMap = contents(resultLocationValues)
  template vector(rows: untyped, rawRows: untyped, positions: untyped,
      positionValues: untyped, positionMap: untyped, expectedCount: Linear, reverse: static bool) =
    block:
      var count = constant(0)
      var previous = constant(1)
      var previousAddress = constant(0)
      for i, row in rows:
        let raw = rawRows[i]
        when defined(zkbuildDeclarationAudit):
          var audit = DeclarationVectorAudit(firstGate: c.constraints.len,
            fields: copyAuditExpressions([row.active,row.address,row.value]))
        c.constrainBoolean(row.active)
        c.constrain(row.active, constant(1)-previous, constant(0))
        discard c.constrainUnsigned(row.address, 64)
        when defined(zkbuildDeclarationAudit): audit.addressRange = c.snapshotRangeUse()
        discard c.constrainUnsigned(row.value, 3)
        when defined(zkbuildDeclarationAudit):
          audit.valueRange = c.snapshotRangeUse()
          audit.tagZero = c.values.len
        c.assertEqual(c.zeroIndicator(row.value-constant(7)), constant(0))
        c.constrain(constant(1)-row.active, row.address, constant(0))
        c.constrain(constant(1)-row.active, row.value, constant(0))
        if i != 0:
          let orderDelta = c.multiply(row.active, row.address-previousAddress-constant(1))
          discard c.constrainUnsigned(orderDelta, 64)
          when defined(zkbuildDeclarationAudit):
            audit.hasOrder = true
            audit.orderDelta = orderDelta
            audit.orderRange = c.snapshotRangeUse()
        when defined(zkbuildDeclarationAudit): audit.keySplit = c.packedRecords.len
        let key = c.splitSignatureHeads(row.address)
        let location = query(positions, positionValues, positionMap, row.active, key.results, raw.active, raw.address shr 32)
        when defined(zkbuildDeclarationAudit):
          let locationQuery = positions[^1]
          audit.location = copyAuditExpressions([locationQuery.active,locationQuery.address,locationQuery.value])
          audit.spanSplit = c.packedRecords.len
        let span = c.splitSignatureHeads(location)
        let within = c.multiply(row.active, span.results-key.params-constant(1))
        discard c.constrainUnsigned(within, 32)
        when defined(zkbuildDeclarationAudit):
          audit.within = within
          audit.withinRange = c.snapshotRangeUse()
          audit.extendedZero = c.values.len
        let extended = c.zeroIndicator(row.value-constant(5))+c.zeroIndicator(row.value-constant(6))
        let code = c.multiply(row.active, constant(127)-row.value-extended.scale(scalar(10)))
        let rawLocation = positionMap.getOrDefault(raw.address shr 32)
        let rawPosition = (rawLocation and 0xffffffff'u64)+(raw.address and 0xffffffff'u64)
        if rawPosition > uint64(high(uint32)): raise newException(ValueError, "type member position overflow")
        let token = if raw.active: bytes.readToken(uint32(rawPosition), brByte) else: BinaryRead()
        let bytePosition = c.multiply(row.active, span.params+key.params)
        when defined(zkbuildDeclarationAudit):
          audit.code = code
          audit.position = bytePosition
          audit.token = c.tokenRecords.len
        discard c.constrainBinaryRead(bytes, brByte, row.active,
          bytePosition, code, token)
        let typeMeta = query(metaQueries, metaValues, metadata, row.active,
          key.results.scale(scalar(2))+constant(1), raw.active, 2*(raw.address shr 32)+1)
        when defined(zkbuildDeclarationAudit):
          let metadataQuery = metaQueries[^1]
          audit.metadata = copyAuditExpressions([metadataQuery.active,metadataQuery.address,metadataQuery.value])
          audit.heads = c.packedRecords.len
        let heads = c.splitSignatureHeads(typeMeta)
        let rawHeads = metadata.getOrDefault(2*(raw.address shr 32)+1)
        let head = when reverse: heads.params else: heads.results
        let hostHead = when reverse: rawHeads and 0xffffffff'u64 else: rawHeads shr 32
        let ordinal = when reverse: span.results-key.params-constant(1) else: key.params
        let hostOrdinal = if not raw.active: 0'u64
          else:
            when reverse: (rawLocation shr 32)-(raw.address and 0xffffffff'u64)-1
            else: raw.address and 0xffffffff'u64
        let memberKey = c.multiply(row.active, head.scale(scalar(1'u64 shl 32))+ordinal)
        let hostKey = (hostHead shl 32)+hostOrdinal
        let node = query(memberQueries, memberValues, members, row.active, memberKey, raw.active, hostKey)
        when defined(zkbuildDeclarationAudit):
          let memberQuery = memberQueries[^1]
          audit.memberKey = memberKey
          audit.member = copyAuditExpressions([memberQuery.active,memberQuery.address,memberQuery.value])
          audit.node = c.packedRecords.len
        c.constrain(row.active, c.splitSignatureNode(node).tag-row.value, constant(0))
        count = c.materialize(count+row.active)
        previous = row.active
        previousAddress = row.address
        when defined(zkbuildDeclarationAudit):
          audit.count = count
          audit.lastGate = c.constraints.len
          when reverse: evidence.params.add audit
          else: evidence.results.add audit
      when defined(zkbuildDeclarationAudit):
        when reverse: evidence.paramCloseStart = c.constraints.len
        else: evidence.resultCloseStart = c.constraints.len
      c.assertEqual(count, expectedCount)
      when defined(zkbuildDeclarationAudit):
        when reverse: evidence.paramCloseEnd = c.constraints.len
        else: evidence.resultCloseEnd = c.constraints.len
  vector(source.params, hint.params, paramQueries, paramValues, paramMap, paramCount, true)
  vector(source.results, hint.results, resultQueries, resultValues, resultMap, resultCount, false)
  c.constrainReadOnly(paramLocations, paramQueries, buildReadOnlyWitness(paramLocationValues, paramValues), 32, 64)
  when defined(zkbuildDeclarationAudit): evidence.tables.add c.readOnlyRecords.len-1
  c.constrainReadOnly(resultLocations, resultQueries, buildReadOnlyWitness(resultLocationValues, resultValues), 32, 64)
  when defined(zkbuildDeclarationAudit): evidence.tables.add c.readOnlyRecords.len-1
  c.constrainReadOnly(signatures.signatures, metaQueries, buildReadOnlyWitness(signatureValues.signatures, metaValues), 33, 64)
  when defined(zkbuildDeclarationAudit): evidence.tables.add c.readOnlyRecords.len-1
  c.constrainReadOnly(indexed.lengths, lengthQueries, buildReadOnlyWitness(indexedValues.lengths, lengthValues), 32, 32)
  when defined(zkbuildDeclarationAudit): evidence.tables.add c.readOnlyRecords.len-1
  c.constrainReadOnly(indexed.members, memberQueries, buildReadOnlyWitness(indexedValues.members, memberValues), 64, 35)
  when defined(zkbuildDeclarationAudit): evidence.tables.add c.readOnlyRecords.len-1
  # The signature metadata's parallel type-index column is an immutable table
  # with identical sorted keys (type entries carry zero, function entries their index).
  var indices: seq[ReadOnlyWires]
  var indexValues, functionQueries: seq[ReadOnlyEntry]
  var indexQueries: seq[ReadOnlyWires]
  for i, entry in signatures.signatures:
    indices.add ReadOnlyWires(active: entry.active, address: entry.address, value: signatures.typeIndices[i])
    let raw = signatureValues.signatures[i]
    indexValues.add ReadOnlyEntry(active: raw.active, address: raw.address, value: uint64(signatureValues.typeIndices[i]))
  cursor = envelope.payloadStarts[3]
  let firstBytes = encodeScalar(firstFunction.evaluate(c.values))
  var first: uint64
  for j in 24..31: first = (first shl 8) or uint64(firstBytes[j])
  var functionCount = constant(0)
  previous = constant(1)
  for i, token in hint.functions:
    let active = source.functionActive[i]
    when defined(zkbuildDeclarationAudit):
      var audit = DeclarationFunctionAudit(firstGate: c.constraints.len,active: active)
    c.constrainBoolean(active)
    c.constrain(active,constant(1)-previous,constant(0))
    let key = (firstFunction+constant(i)).scale(scalar(2))
    let typeIndex = c.allocate(scalar(token.value))
    when defined(zkbuildDeclarationAudit): audit.token = c.tokenRecords.len
    let size = c.constrainBinaryRead(bytes, brU32, active, cursor, typeIndex, token)
    indexQueries.add ReadOnlyWires(active: active, address: c.multiply(active,key), value: typeIndex)
    functionQueries.add(if hint.functionActive[i]: ReadOnlyEntry(active: true,
      address: 2*(first+uint64(i)), value: token.value) else: ReadOnlyEntry())
    cursor = c.materialize(cursor+size)
    functionCount = c.materialize(functionCount+active)
    previous = active
    when defined(zkbuildDeclarationAudit):
      let q = indexQueries[^1]
      audit.query = copyAuditExpressions([q.active,q.address,q.value])
      audit.cursor = cursor
      audit.count = functionCount
      audit.lastGate = c.constraints.len
      evidence.functions.add audit
  when defined(zkbuildDeclarationAudit): evidence.functionCloseStart = c.constraints.len
  c.assertEqual(functionCount, envelope.firstWords[3])
  c.assertEqual(cursor, envelope.ends[3])
  when defined(zkbuildDeclarationAudit): evidence.functionCloseEnd = c.constraints.len
  c.constrainReadOnly(indices, indexQueries, buildReadOnlyWitness(indexValues, functionQueries), 33, 32)
  when defined(zkbuildDeclarationAudit): evidence.tables.add c.readOnlyRecords.len-1
  cursor = envelope.payloadStarts[13]
  for i, row in tags.tags:
    when defined(zkbuildDeclarationAudit):
      var audit = DeclarationTagAudit(firstGate: c.constraints.len,active: row.active,typeIndex: tags.typeIndices[i],attributeToken: c.tokenRecords.len)
    discard c.constrainBinaryRead(bytes, brByte, row.active, cursor, constant(0), hint.tagAttributes[i])
    let indexPosition = c.multiply(row.active, cursor+constant(1))
    when defined(zkbuildDeclarationAudit):
      audit.position = indexPosition
      audit.indexToken = c.tokenRecords.len
    let size = c.constrainBinaryRead(bytes, brU32, row.active,
      indexPosition, tags.typeIndices[i], hint.tags[i])
    cursor = c.materialize(cursor+row.active+size)
    when defined(zkbuildDeclarationAudit):
      audit.cursor = cursor
      audit.lastGate = c.constraints.len
      evidence.tags.add audit
  when defined(zkbuildDeclarationAudit): evidence.tagCloseStart = c.constraints.len
  c.assertEqual(cursor, envelope.ends[13])
  when defined(zkbuildDeclarationAudit):
    evidence.tagCloseEnd = c.constraints.len
    c.declarationRecords.add evidence
