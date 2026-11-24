## Bind code-body framing and compressed local declarations to source bytes.
## Instruction spans are exported for the instruction-decoder binding layer.
import std/tables
import ../wasm/[types, variable_typing]
import r1cs, range_check, read_only_memory
import wasm_binary_source, wasm_binary_envelope, wasm_type_environment
import wasm_signature_environment, wasm_indexed_signatures, wasm_local_declarations
import wasm_declaration_profile

type
  SourceLocal* = object
    count*: uint32
    tag*: uint8
    countRead*, typeRead*: BinaryRead
  SourceBody* = object
    active*: bool
    size*, localCount*, localsStart*, instructions*, finish*: uint32
    sizeRead*, countRead*, endRead*: BinaryRead
    locals*: seq[SourceLocal]
  CodeSource* = object
    bodies*: seq[SourceBody]
    flat*: bool
    locals*: seq[FlatSourceLocal]
  FlatSourceLocal* = object
    active*: bool
    owner*, ordinal*: uint32
    local*: SourceLocal
  CodeSpans* = object
    instructions*: seq[ReadOnlyWires] # function -> first byte32 | end byte32

proc buildCodeSource*(module: WasmModule, data: openArray[byte], envelope: BinaryEnvelope,
    profile = DeclarationProfile()): CodeSource =
  profile.validate()
  var cursor = 0'u32
  for section in envelope.sections:
    if section.active and section.id == 10: cursor = section.body+uint32(section.wordRead.length)
  for code in module.codes:
    var body = SourceBody(active: true)
    body.sizeRead = readBinaryToken(data, cursor, brU32)
    body.size = uint32(body.sizeRead.value)
    cursor += uint32(body.sizeRead.length)
    let finish = uint64(cursor)+uint64(body.size)
    if finish == 0 or finish > uint64(data.len) or finish > uint64(high(uint32)):
      raise newException(ValueError, "code body extends beyond source")
    body.finish = uint32(finish)
    body.countRead = readBinaryToken(data, cursor, brU32)
    body.localCount = uint32(body.countRead.value)
    cursor += uint32(body.countRead.length)
    body.localsStart = cursor
    for local in code.locals:
      let count = readBinaryToken(data, cursor, brU32)
      cursor += uint32(count.length)
      let valueType = readBinaryToken(data, cursor, brByte)
      inc cursor
      body.locals.add SourceLocal(count: uint32(count.value), tag: stackTypeTag(local.valType),
        countRead: count, typeRead: valueType)
    body.instructions = cursor
    body.endRead = readBinaryToken(data, body.finish-1, brByte)
    result.bodies.add body
    cursor = body.finish
  if profile.enabled:
    result.flat = true
    for owner, body in result.bodies.mpairs:
      for ordinal, local in body.locals:
        result.locals.add FlatSourceLocal(active: true,owner: uint32(owner),ordinal: uint32(ordinal),local: local)
      body.locals = @[]
    result.bodies.padDeclarations(profile.functions)
    result.locals.padDeclarations(profile.localGroups)

proc contents(entries: openArray[ReadOnlyEntry]): Table[uint64, uint64] =
  for entry in entries:
    if entry.active: result[entry.address] = entry.value

proc constrainFlatCodeSource(c: var Circuit, source: var BinarySource, envelope: BinaryEnvelopeWires,
    hint: CodeSource, firstFunction: Linear, environment: TypeEnvironmentWires,
    environmentValues: TypeEnvironment, signatures: SignatureEnvironmentWires,
    signatureValues: SignatureEnvironment, indexed: IndexedSignatureWires,
    indexValues: IndexedSignatureEnvironment, declarations: LocalDeclarationWires,
    declarationValues: LocalDeclarationEnvironment): CodeSpans =
  when defined(zkbuildBodySourceAudit):
    let programMarker = c.beginSourceProgram()
    var codeAudit = CodeSourceAudit(flat: true,firstFunction: copyAuditExpressions([firstFunction])[0])
  let metadata = contents(signatureValues.signatures)
  let lengths = contents(indexValues.lengths)
  let ranges = contents(environmentValues.localRanges)
  let tags = contents(environmentValues.rangeTypes)
  let totals = contents(declarationValues.totals)
  let encoded = encodeScalar(firstFunction.evaluate(c.values))
  var first: uint64
  for i in 24..31: first = (first shl 8)+uint64(encoded[i])
  var metaQueries,lengthQueries,totalQueries,rangeQueries,tagQueries: seq[ReadOnlyWires]
  var metaReads,lengthReads,totalReads,rangeReads,tagReads: seq[ReadOnlyEntry]
  var positions,counts: seq[ReadOnlyWires]
  var positionValues,countValues: seq[ReadOnlyEntry]
  template query(bank: untyped, values: untyped, lookup: untyped,
      enabled,key: Linear, hostActive: bool, hostKey: uint64): Linear =
    block:
      let actual = if hostActive: lookup.getOrDefault(hostKey) else: 0'u64
      let value = c.allocate(scalar(actual))
      bank.add ReadOnlyWires(active: enabled,address: c.multiply(enabled,key),value: value)
      values.add(if hostActive: ReadOnlyEntry(active: true,address: hostKey,value: actual) else: ReadOnlyEntry())
      value
  var cursor = envelope.payloadStarts[10]
  var previous = constant(1)
  var bodyCount,localCount = constant(0)
  for i, body in hint.bodies:
    let active = c.allocate(scalar(ord(body.active)))
    c.constrainBoolean(active)
    c.constrain(active,constant(1)-previous,constant(0))
    let size = c.allocate(scalar(body.size))
    let declared = c.allocate(scalar(body.localCount))
    let localStart = c.allocate(scalar(body.localsStart))
    let instructions = c.allocate(scalar(body.instructions))
    let finish = c.allocate(scalar(body.finish))
    when defined(zkbuildBodySourceAudit):
      codeAudit.bodies.add CodeBodyAudit(fields: copyAuditExpressions([active,size,declared,localStart,instructions,finish]))
    for value in [size,declared,localStart,instructions,finish]:
      discard c.constrainUnsigned(value,32)
      c.constrain(constant(1)-active,value,constant(0))
    let sizeLength = c.constrainBinaryRead(source,brU32,active,cursor,size,body.sizeRead)
    let start = c.multiply(active,cursor+sizeLength)
    c.constrain(active,finish-start-size,constant(0))
    discard c.constrainUnsigned(c.multiply(active,envelope.ends[10]-finish),32)
    let countLength = c.constrainBinaryRead(source,brU32,active,start,declared,body.countRead)
    c.assertEqual(localStart,start+countLength)
    discard c.constrainUnsigned(c.multiply(active,finish-instructions-constant(1)),32)
    let fn = firstFunction+constant(i)
    let hostFn = first+uint64(i)
    let signature = query(metaQueries,metaReads,metadata,active,fn.scale(scalar(2)),body.active,hostFn*2)
    let head = c.splitSignatureHeads(signature).params
    let hostHead = metadata.getOrDefault(hostFn*2) and 0xffffffff'u64
    let parameters = query(lengthQueries,lengthReads,lengths,active,head,body.active,hostHead)
    let total = query(totalQueries,totalReads,totals,active,fn,body.active,hostFn)
    c.constrain(active,c.splitSignatureHeads(total).results-parameters-declared,constant(0))
    c.constrain(c.multiply(active,c.zeroIndicator(declared)),instructions-localStart,constant(0))
    discard c.constrainBinaryRead(source,brByte,active,c.multiply(active,finish-constant(1)),
      active.scale(scalar(11)),body.endRead)
    positions.add ReadOnlyWires(active: active,address: active.scale(scalar(i)),
      value: localStart+instructions.scale(scalar(1'u64 shl 32)))
    counts.add ReadOnlyWires(active: active,address: active.scale(scalar(i)),
      value: parameters+declared.scale(scalar(1'u64 shl 32)))
    positionValues.add(if body.active: ReadOnlyEntry(active: true,address: uint64(i),
      value: uint64(body.localsStart)+(uint64(body.instructions) shl 32)) else: ReadOnlyEntry())
    countValues.add(if body.active: ReadOnlyEntry(active: true,address: uint64(i),
      value: lengths.getOrDefault(hostHead)+(uint64(body.localCount) shl 32)) else: ReadOnlyEntry())
    result.instructions.add ReadOnlyWires(active: active,address: c.multiply(active,fn),
      value: instructions+finish.scale(scalar(1'u64 shl 32)))
    bodyCount = c.materialize(bodyCount+active)
    localCount = c.materialize(localCount+declared)
    cursor = c.selectWire(active,finish,cursor)
    previous = active
  c.assertEqual(bodyCount,envelope.firstWords[10])
  c.assertEqual(cursor,envelope.ends[10])
  let positionMap = contents(positionValues)
  let countMap = contents(countValues)
  var positionQueries,countQueries: seq[ReadOnlyWires]
  var positionReads,countReads: seq[ReadOnlyEntry]
  var ownerWires,activeWires: seq[Linear]
  for row in hint.locals:
    ownerWires.add c.allocate(scalar(row.owner))
    activeWires.add c.allocate(scalar(ord(row.active)))
  var previousOwner,previousOrdinal,previousKey,previousAfter,seen = constant(0)
  previous = constant(1)
  for i, row in hint.locals:
    let active = activeWires[i]
    let owner = ownerWires[i]
    let ordinal = c.allocate(scalar(row.ordinal))
    let position = c.allocate(scalar(row.local.countRead.position))
    let amount = c.allocate(scalar(row.local.count))
    let tag = c.allocate(scalar(row.local.tag))
    when defined(zkbuildBodySourceAudit):
      codeAudit.locals.add copyAuditExpressions([active,owner,ordinal,position,amount,tag])
    c.constrainBoolean(active)
    c.constrain(active,constant(1)-previous,constant(0))
    for value in [owner,ordinal,position,amount,tag]: c.constrain(constant(1)-active,value,constant(0))
    for value in [owner,ordinal,position]: discard c.constrainUnsigned(value,32)
    discard c.constrainUnsigned(tag,3)
    c.assertEqual(c.zeroIndicator(tag-constant(7)),constant(0))
    let key = owner.scale(scalar(1'u64 shl 32))+ordinal
    if i != 0: discard c.constrainUnsigned(c.multiply(active,key-previousKey-constant(1)),64)
    let span = c.splitSignatureHeads(query(positionQueries,positionReads,positionMap,active,owner,row.active,uint64(row.owner)))
    let counts = c.splitSignatureHeads(query(countQueries,countReads,countMap,active,owner,row.active,uint64(row.owner)))
    discard c.constrainUnsigned(c.multiply(active,counts.results-ordinal-constant(1)),32)
    let same = if i == 0: constant(0)
      else: c.multiply(c.multiply(active,previous),c.zeroIndicator(owner-previousOwner))
    let firstInGroup = active-same
    c.constrain(firstInGroup,ordinal,constant(0))
    c.constrain(firstInGroup,position-span.params,constant(0))
    c.constrain(same,ordinal-previousOrdinal-constant(1),constant(0))
    c.constrain(same,position-previousAfter,constant(0))
    let size = c.constrainBinaryRead(source,brU32,active,position,amount,row.local.countRead)
    let reference = c.zeroIndicator(tag-constant(5))+c.zeroIndicator(tag-constant(6))
    let typeLength = c.constrainBinaryRead(source,brByte,active,c.multiply(active,position+size),
      c.multiply(active,constant(127)-tag-reference.scale(scalar(10))),row.local.typeRead)
    let after = c.materialize(position+size+typeLength)
    let continues = if i+1 == hint.locals.len: constant(0)
      else: c.multiply(c.multiply(active,activeWires[i+1]),c.zeroIndicator(owner-ownerWires[i+1]))
    let last = active-continues
    c.constrain(last,ordinal+constant(1)-counts.results,constant(0))
    c.constrain(last,after-span.results,constant(0))
    let fn = c.multiply(active,firstFunction+owner)
    let declOrdinal = c.multiply(active,counts.params+ordinal)
    discard c.constrainUnsigned(fn,32)
    discard c.constrainUnsigned(declOrdinal,32)
    let address = fn.scale(scalar(1'u64 shl 32))+declOrdinal
    let rawParameters = countMap.getOrDefault(uint64(row.owner)) and 0xffffffff'u64
    let rawAddress = if row.active: ((first+uint64(row.owner)) shl 32)+rawParameters+uint64(row.ordinal) else: 0'u64
    let range = query(rangeQueries,rangeReads,ranges,active,address,row.active,rawAddress)
    c.assertEqual(c.splitSignatureHeads(range).results,amount)
    c.assertEqual(query(tagQueries,tagReads,tags,active,address,row.active,rawAddress),tag)
    seen = c.materialize(seen+active)
    previous = active
    previousOwner = owner
    previousOrdinal = ordinal
    previousKey = key
    previousAfter = after
  discard c.constrainUnsigned(localCount,64)
  c.assertEqual(seen,localCount)
  when defined(zkbuildBodySourceAudit):
    codeAudit.program = c.endSourceProgram(programMarker)
    for row in result.instructions: codeAudit.spans.add copyAuditExpressions([row.active,row.address,row.value])
  when defined(zkbuildBodySourceAudit): codeAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(positions,positionQueries,buildReadOnlyWitness(positionValues,positionReads),32,64)
  when defined(zkbuildBodySourceAudit): codeAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(counts,countQueries,buildReadOnlyWitness(countValues,countReads),32,64)
  when defined(zkbuildBodySourceAudit): codeAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(signatures.signatures,metaQueries,buildReadOnlyWitness(signatureValues.signatures,metaReads),33,64)
  when defined(zkbuildBodySourceAudit): codeAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(indexed.lengths,lengthQueries,buildReadOnlyWitness(indexValues.lengths,lengthReads),32,32)
  when defined(zkbuildBodySourceAudit): codeAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(declarations.totals,totalQueries,buildReadOnlyWitness(declarationValues.totals,totalReads),32,64)
  when defined(zkbuildBodySourceAudit): codeAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(environment.localRanges,rangeQueries,buildReadOnlyWitness(environmentValues.localRanges,rangeReads),64,64)
  when defined(zkbuildBodySourceAudit): codeAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(environment.rangeTypes,tagQueries,buildReadOnlyWitness(environmentValues.rangeTypes,tagReads),64,3)

  when defined(zkbuildBodySourceAudit): c.codeSourceRecords.add codeAudit

proc constrainCodeSource*(c: var Circuit, source: var BinarySource, envelope: BinaryEnvelopeWires,
    hint: CodeSource, firstFunction: Linear, environment: TypeEnvironmentWires,
    environmentValues: TypeEnvironment, signatures: SignatureEnvironmentWires,
    signatureValues: SignatureEnvironment, indexed: IndexedSignatureWires,
    indexValues: IndexedSignatureEnvironment, declarations: LocalDeclarationWires,
    declarationValues: LocalDeclarationEnvironment): CodeSpans =
  if hint.flat:
    return c.constrainFlatCodeSource(source,envelope,hint,firstFunction,environment,environmentValues,
      signatures,signatureValues,indexed,indexValues,declarations,declarationValues)
  when defined(zkbuildBodySourceAudit):
    let programMarker = c.beginSourceProgram()
    var codeAudit = CodeSourceAudit(flat: false,firstFunction: copyAuditExpressions([firstFunction])[0])
  let metadata = contents(signatureValues.signatures)
  let lengths = contents(indexValues.lengths)
  let ranges = contents(environmentValues.localRanges)
  let tags = contents(environmentValues.rangeTypes)
  let totals = contents(declarationValues.totals)
  var metaQueries, lengthQueries, rangeQueries, tagQueries, totalQueries: seq[ReadOnlyWires]
  var metaValues, lengthValues, rangeValues, tagValues, totalValues: seq[ReadOnlyEntry]
  let encoded = encodeScalar(firstFunction.evaluate(c.values))
  var first: uint64
  for i in 24..31: first = (first shl 8) or uint64(encoded[i])
  template query(bank: untyped, values: untyped, lookup: untyped, key: Linear, hostKey: uint64): Linear =
    block:
      let value = lookup.getOrDefault(hostKey)
      let wire = c.allocate(scalar(value))
      bank.add ReadOnlyWires(active: constant(1), address: key, value: wire)
      values.add ReadOnlyEntry(active: true, address: hostKey, value: value)
      wire
  var cursor = envelope.payloadStarts[10]
  for i, body in hint.bodies:
    let functionIndex = firstFunction+constant(i)
    let function = first+uint64(i)
    let size = c.allocate(scalar(body.size))
    let declaredLocals = c.allocate(scalar(body.localCount))
    let instructions = c.allocate(scalar(body.instructions))
    let finish = c.allocate(scalar(body.finish))
    for field in [size, declaredLocals, instructions, finish]: discard c.constrainUnsigned(field, 32)
    let sizeLength = c.constrainBinaryRead(source, brU32, constant(1), cursor, size, body.sizeRead)
    let bodyStart = c.materialize(cursor+sizeLength)
    c.assertEqual(finish, bodyStart+size)
    discard c.constrainUnsigned(envelope.ends[10]-finish, 32)
    let countLength = c.constrainBinaryRead(source, brU32, constant(1), bodyStart, declaredLocals, body.countRead)
    c.assertEqual(declaredLocals, constant(body.locals.len))
    cursor = c.materialize(bodyStart+countLength)
    when defined(zkbuildBodySourceAudit):
      codeAudit.bodies.add CodeBodyAudit(fields: copyAuditExpressions([constant(1),size,declaredLocals,cursor,instructions,finish]))
    let signature = query(metaQueries, metaValues, metadata, functionIndex.scale(scalar(2)), function*2)
    let head = c.splitSignatureHeads(signature).params
    let hostHead = metadata.getOrDefault(function*2) and 0xffffffff'u64
    let parameters = query(lengthQueries, lengthValues, lengths, head, hostHead)
    let hostParameters = lengths.getOrDefault(hostHead)
    let declaration = query(totalQueries, totalValues, totals, functionIndex, function)
    c.assertEqual(c.splitSignatureHeads(declaration).results, parameters+declaredLocals)
    for j, local in body.locals:
      let count = c.allocate(scalar(local.count))
      let typeTag = c.allocate(scalar(local.tag))
      when defined(zkbuildBodySourceAudit): codeAudit.bodies[^1].locals.add copyAuditExpressions([count,typeTag])
      discard c.constrainUnsigned(typeTag, 3)
      c.assertEqual(c.zeroIndicator(typeTag-constant(7)), constant(0))
      let countLength = c.constrainBinaryRead(source, brU32, constant(1), cursor, count, local.countRead)
      cursor = c.materialize(cursor+countLength)
      let reference = c.zeroIndicator(typeTag-constant(5))+c.zeroIndicator(typeTag-constant(6))
      discard c.constrainBinaryRead(source, brByte, constant(1), cursor,
        constant(127)-typeTag-reference.scale(scalar(10)), local.typeRead)
      cursor = c.materialize(cursor+constant(1))
      let ordinal = c.materialize(parameters+constant(j))
      discard c.constrainUnsigned(ordinal, 32)
      let address = functionIndex.scale(scalar(1'u64 shl 32))+ordinal
      let hostAddress = (function shl 32)+hostParameters+uint64(j)
      let span = query(rangeQueries, rangeValues, ranges, address, hostAddress)
      c.assertEqual(c.splitSignatureHeads(span).results, count)
      let tag = query(tagQueries, tagValues, tags, address, hostAddress)
      c.assertEqual(tag, typeTag)
    c.assertEqual(instructions, cursor)
    discard c.constrainUnsigned(finish-instructions-constant(1), 32)
    discard c.constrainBinaryRead(source, brByte, constant(1), finish-constant(1), constant(11), body.endRead)
    result.instructions.add ReadOnlyWires(active: constant(1), address: functionIndex,
      value: instructions+finish.scale(scalar(1'u64 shl 32)))
    cursor = finish
  c.assertEqual(constant(hint.bodies.len), envelope.firstWords[10])
  c.assertEqual(cursor, envelope.ends[10])
  when defined(zkbuildBodySourceAudit):
    codeAudit.program = c.endSourceProgram(programMarker)
    for row in result.instructions: codeAudit.spans.add copyAuditExpressions([row.active,row.address,row.value])
  when defined(zkbuildBodySourceAudit): codeAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(signatures.signatures, metaQueries, buildReadOnlyWitness(signatureValues.signatures, metaValues), 33, 64)
  when defined(zkbuildBodySourceAudit): codeAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(indexed.lengths, lengthQueries, buildReadOnlyWitness(indexValues.lengths, lengthValues), 32, 32)
  when defined(zkbuildBodySourceAudit): codeAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(environment.localRanges, rangeQueries, buildReadOnlyWitness(environmentValues.localRanges, rangeValues), 64, 64)
  when defined(zkbuildBodySourceAudit): codeAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(environment.rangeTypes, tagQueries, buildReadOnlyWitness(environmentValues.rangeTypes, tagValues), 64, 3)
  when defined(zkbuildBodySourceAudit): codeAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(declarations.totals, totalQueries, buildReadOnlyWitness(declarationValues.totals, totalValues), 32, 64)
  when defined(zkbuildBodySourceAudit): c.codeSourceRecords.add codeAudit
