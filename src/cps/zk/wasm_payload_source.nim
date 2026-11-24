## Source binding for the remaining core module payloads. Data/custom bytes
## are uninterpreted, but their lengths and complete section consumption are
## checked against the same committed source used by the instruction proof.
import std/tables
import ../wasm/types
import r1cs, range_check, read_only_memory
import wasm_binary_source, wasm_binary_envelope, wasm_names, wasm_module_context
import wasm_type_environment, wasm_signature_environment, wasm_bulk_context
import wasm_payload_profile, wasm_owned_stream

type
  SourceName* = object
    active*: bool
    text*: string
    start*, finish*: uint32
    length*: BinaryRead
  SourceLimit* = object
    active*: bool
    flags*, minimum*, maximum*: BinaryRead
  SourceConstant* = object
    opcode*, subopcode*, first*, second*, terminal*, legacy*: BinaryRead
    firstValue*, secondValue*: uint64
  SourceImport* = object
    active*: bool
    kind*: uint32
    kindRead*, functionType*, valueType*, mutable*: BinaryRead
    limits*: SourceLimit
  SourceTable* = object
    active*: bool
    valueType*: BinaryRead
    limits*: SourceLimit
  SourceGlobal* = object
    valueType*, mutable*: BinaryRead
    value*: SourceConstant
  SourceExport* = object
    kind*, index*: BinaryRead
  SourceElement* = object
    flags*, tableIndex*, elementType*, count*: BinaryRead
    offset*: SourceConstant
    items*: seq[SourceConstant]
    itemsStart*, finish*: uint32
  SourceData* = object
    flags*, memoryIndex*, length*: BinaryRead
    offset*: SourceConstant
  FlatNameByte* = object
    row*: OwnedChild
    head*: uint32
  FlatSourceElement* = object
    row*: OwnedChild
    expression*: SourceConstant
  ModulePayloadSource* = object
    flat*: bool
    nameBytes*: seq[FlatNameByte]
    elementItems*: seq[FlatSourceElement]
    names*: seq[SourceName]
    imports*: seq[SourceImport]
    tables*: seq[SourceTable]
    memories*: seq[SourceLimit]
    globals*: seq[SourceGlobal]
    exports*: seq[SourceExport]
    elements*: seq[SourceElement]
    datas*: seq[SourceData]
    customCount*, customLimit*: int
  SourceNameWires* = object
    active*, size*, start*, finish*: Linear
  ModulePayloadWires* = object
    names*: seq[SourceNameWires]

proc checkedPosition(value: uint64): uint32 =
  if value > uint64(high(uint32)): raise newException(ValueError, "payload source position overflow")
  uint32(value)

proc buildModulePayloadSource*(module: WasmModule, data: openArray[byte],
    envelope: BinaryEnvelope, profile = PayloadProfile()): ModulePayloadSource =
  profile.validate()
  result.flat = profile.enabled
  result.customLimit = profile.customSections
  var position = 0'u32
  template read(kind: BinaryReadKind): BinaryRead =
    block:
      let token = readBinaryToken(data, position, kind)
      position = checkedPosition(uint64(position)+uint64(token.length))
      token
  template beginSection(wantedId: uint32) =
    position = 0
    for section in envelope.sections:
      if section.active and section.id == wantedId:
        position = section.body+uint32(section.wordRead.length)
  var names: seq[string]
  for item in module.exports: names.add item.name
  for item in module.imports: names.add item.module; names.add item.name
  for item in module.customSections: names.add item.name
  result.names.setLen(names.len)
  template name(index: int) =
    block:
      if index < 0 or index >= names.len: raise newException(ValueError, "source name count differs")
      let start = position
      let length = read(brU32)
      position = checkedPosition(uint64(position)+length.value)
      if uint64(position) > uint64(data.len): raise newException(ValueError, "source name exceeds binary")
      result.names[index] = SourceName(active: true, text: names[index], start: start, finish: position, length: length)
  template limits(): SourceLimit =
    block:
      var value = SourceLimit(active: true)
      value.flags = read(brByte)
      if value.flags.value > 1: raise newException(ValueError, "unsupported source limits")
      value.minimum = read(brU32)
      if value.flags.value == 1: value.maximum = read(brU32)
      value
  template expression(expr: Expr, modern: bool): SourceConstant =
    block:
      var value: SourceConstant
      if expr.code.len != 0:
        let instruction = expr.code[0]
        if instruction.op in {opI64Const, opF64Const}:
          value.firstValue = uint64(instruction.imm1)+(uint64(instruction.imm2) shl 32)
        elif instruction.op == opV128Const:
          if uint64(instruction.imm1) < uint64(expr.v128Consts.len):
            for i in 0..7:
              value.firstValue = value.firstValue or (uint64(expr.v128Consts[int(instruction.imm1)][i]) shl (8*i))
              value.secondValue = value.secondValue or (uint64(expr.v128Consts[int(instruction.imm1)][i+8]) shl (8*i))
        else: value.firstValue = uint64(instruction.imm1)
      if modern:
        value.opcode = read(brByte)
        case value.opcode.value
        of 0x41: value.first = read(brS32)
        of 0x42: value.first = read(brS64)
        of 0x43: value.first = read(brLittle32)
        of 0x44: value.first = read(brLittle64)
        of 0x23, 0xd2: value.first = read(brU32)
        of 0xd0: value.first = read(brByte)
        of 0xfd:
          value.subopcode = read(brU32)
          if value.subopcode.value != 12: raise newException(ValueError, "invalid initializer SIMD opcode")
          value.first = read(brLittle64)
          value.second = read(brLittle64)
        else: raise newException(ValueError, "unsupported source constant expression")
        value.terminal = read(brByte)
      else:
        value.legacy = read(brU32)
      value
  beginSection(2)
  for i, item in module.imports:
    name(module.exports.len+2*i)
    name(module.exports.len+2*i+1)
    var value = SourceImport(active: true, kind: uint32(ord(item.kind)), kindRead: read(brByte))
    case value.kindRead.value
    of 0: value.functionType = read(brU32)
    of 1: value.valueType = read(brByte); value.limits = limits()
    of 2: value.limits = limits()
    of 3: value.valueType = read(brByte); value.mutable = read(brByte)
    else: raise newException(ValueError, "unsupported source import kind")
    result.imports.add value
  beginSection(4)
  for _ in module.tables:
    result.tables.add SourceTable(active: true, valueType: read(brByte), limits: limits())
  beginSection(5)
  for _ in module.memories: result.memories.add limits()
  beginSection(6)
  for item in module.globals:
    result.globals.add SourceGlobal(valueType: read(brByte), mutable: read(brByte), value: expression(item.init, true))
  beginSection(7)
  for i, _ in module.exports:
    name(i)
    result.exports.add SourceExport(kind: read(brByte), index: read(brU32))
  beginSection(9)
  for owner, item in module.elements:
    var value = SourceElement(flags: read(brU32))
    if value.flags.value > 7: raise newException(ValueError, "invalid source element flags")
    let flags = uint32(value.flags.value)
    if (flags and 1) == 0:
      if (flags and 2) != 0: value.tableIndex = read(brU32)
      value.offset = expression(item.offset, true)
    if (flags and 3) != 0: value.elementType = read(brByte)
    value.count = read(brU32)
    value.itemsStart = position
    for ordinal, expr in item.init:
      let start = position
      let encoded = expression(expr, (flags and 4) != 0)
      if profile.enabled:
        result.elementItems.add FlatSourceElement(row: OwnedChild(active: true,owner: uint32(owner),
          ordinal: uint32(ordinal),start: start,finish: position),expression: encoded)
      else: value.items.add encoded
    value.finish = position
    result.elements.add value
  beginSection(11)
  for item in module.datas:
    var value = SourceData(flags: read(brU32))
    if value.flags.value > 2: raise newException(ValueError, "invalid source data flags")
    if value.flags.value != 1:
      if value.flags.value == 2: value.memoryIndex = read(brU32)
      value.offset = expression(item.offset, true)
    value.length = read(brU32)
    position = checkedPosition(uint64(position)+value.length.value)
    if uint64(position) > uint64(data.len): raise newException(ValueError, "source data exceeds binary")
    result.datas.add value
  for section in envelope.sections:
    if section.active and section.id == 0:
      position = section.body
      name(module.exports.len+2*module.imports.len+result.customCount)
      inc result.customCount

  if profile.enabled:
    let nameEnvironment = buildNameEnvironment(names)
    for owner, name in result.names:
      var head = nameEnvironment.heads[owner]
      for ordinal in 0..<name.text.len:
        result.nameBytes.add FlatNameByte(row: OwnedChild(active: true,owner: uint32(owner),
          ordinal: uint32(ordinal),start: name.start+uint32(name.length.length)+uint32(ordinal),
          finish: name.start+uint32(name.length.length)+uint32(ordinal)+1),head: head)
        head = uint32((nameEnvironment.nodes[int(head)-1].value shr 8) and 0xffffffff'u64)
    if result.customCount > profile.customSections:
      raise newException(ValueError,"custom section profile capacity exceeded")
    result.names.padDeclarations(profile.nameCapacity())
    result.nameBytes.padDeclarations(profile.nameBytes)
    result.imports.padDeclarations(profile.imports)
    result.tables.padDeclarations(profile.tables)
    result.memories.padDeclarations(profile.memories)
    result.globals.padDeclarations(profile.globals)
    result.exports.padDeclarations(profile.exports)
    result.elements.padDeclarations(profile.elements)
    result.elementItems.padDeclarations(profile.elementItems)
    result.datas.padDeclarations(profile.datas)

proc allocateModulePayload*(c: var Circuit, payload: ModulePayloadSource): ModulePayloadWires =
  for value in payload.names:
    result.names.add SourceNameWires(active: c.bit(value.active),size: c.allocate(scalar(value.text.len)),start: c.allocate(scalar(value.start)), finish: c.allocate(scalar(value.finish)))

proc contents(entries: openArray[ReadOnlyEntry]): Table[uint64, uint64] =
  for entry in entries:
    if entry.active: result[entry.address] = entry.value

proc pack(c: var Circuit, bits: openArray[Linear]): Linear =
  var value = constant(0)
  for i, bit in bits: value = value+bit.scale(scalar(1'u64 shl i))
  c.materialize(value)

proc constrainFlatNames(c: var Circuit, source: var BinarySource,
    names: NameEnvironmentWires, values: NameEnvironment,
    wires: ModulePayloadWires, payload: ModulePayloadSource): seq[ReadOnlyWires] =
  when defined(zkbuildNameFrameAudit):
    var nameFrame = NameFrameAudit(flat: true)
  when defined(zkbuildNameSourceAudit):
    var nameSource: NameSourceAudit
  var parents: seq[OwnedParentWires]
  var parentHints: seq[OwnedParent]
  var children: seq[OwnedChildWires]
  var childHints: seq[OwnedChild]
  var roots, queries, rootQueries: seq[ReadOnlyWires]
  var rootValues, reads, rootReads: seq[ReadOnlyEntry]
  let nodes = contents(values.nodes)
  for i, name in payload.names:
    let wire = wires.names[i]
    when defined(zkbuildNameFrameAudit):
      let headerGate = c.constraints.len
      let headerToken = c.tokenRecords.len
    let size = c.constrainBinaryRead(source,brU32,wire.active,wire.start,wire.size,name.length)
    let start = c.materialize(wire.start+size)
    when defined(zkbuildNameFrameAudit):
      nameFrame.headers.add NameFrameHeaderAudit(firstGate: headerGate,lastGate: c.constraints.len,
        token: headerToken,fields: copyAuditExpressions([wire.active,wire.size,wire.start,start,wire.finish]))
    parents.add OwnedParentWires(active: wire.active,count: wire.size,start: start,finish: wire.finish)
    parentHints.add OwnedParent(active: name.active,count: uint32(name.text.len),
      start: name.start+uint32(name.length.length),finish: name.finish)
    roots.add ReadOnlyWires(active: wire.active,address: wire.active.scale(scalar(i)),value: names.heads[i])
    rootValues.add(if name.active: ReadOnlyEntry(active: true,address: uint64(i),value: uint64(values.heads[i])) else: ReadOnlyEntry())
    when defined(zkbuildNameSourceAudit):
      var rootAudit = NameSourceHeaderAudit(firstGate: c.constraints.len,zeroStart: c.values.len,
        head: copyAuditExpressions([names.heads[i]])[0],finalHead: constant(0))
    c.constrain(constant(1)-wire.active,names.heads[i],constant(0))
    c.constrain(c.zeroIndicator(wire.size),names.heads[i],constant(0))
    when defined(zkbuildNameSourceAudit):
      rootAudit.lastGate = c.constraints.len
      nameSource.headers.add rootAudit
    result.add ReadOnlyWires(active: wire.active,address: wire.active.scale(scalar(i)),
      value: wire.start+wire.finish.scale(scalar(1'u64 shl 32)))
  var priorTail, priorOwner = constant(0)
  for i, item in payload.nameBytes:
    let row = item.row
    let active = c.bit(row.active)
    let owner = c.allocate(scalar(row.owner))
    let ordinal = c.allocate(scalar(row.ordinal))
    let start = c.allocate(scalar(row.start))
    let head = c.allocate(scalar(item.head))
    let raw = nodes.getOrDefault(uint64(item.head))
    let node = c.allocate(scalar(raw))
    queries.add ReadOnlyWires(active: active,address: head,value: node)
    reads.add(if row.active: ReadOnlyEntry(active: true,address: uint64(item.head),value: raw) else: ReadOnlyEntry())
    when defined(zkbuildNameSourceAudit):
      var byteAudit = NameSourceByteAudit(firstGate: c.constraints.len)
    let bits = c.constrainUnsigned(node,42)
    when defined(zkbuildNameSourceAudit): byteAudit.range = c.snapshotRangeUse()
    let value = c.pack(bits[0..7])
    let tail = c.pack(bits[8..39])
    let root = c.allocate(scalar(if row.active: values.heads[int(row.owner)] else: 0'u32))
    rootQueries.add ReadOnlyWires(active: active,address: owner,value: root)
    rootReads.add(if row.active: ReadOnlyEntry(active: true,address: uint64(row.owner),value: uint64(values.heads[int(row.owner)])) else: ReadOnlyEntry())
    when defined(zkbuildNameSourceAudit):
      if i > 0: byteAudit.zeroStart = c.values.len
    let same = if i == 0: constant(0) else: c.multiply(active,c.zeroIndicator(owner-priorOwner))
    c.constrain(active-same,head-root,constant(0))
    c.constrain(same,head-priorTail,constant(0))
    when defined(zkbuildNameSourceAudit):
      byteAudit.lastGate = c.constraints.len
      byteAudit.nodeQuery = copyAuditExpressions([active,head,node])
      byteAudit.rootQuery = copyAuditExpressions([active,owner,root])
      byteAudit.fields = copyAuditExpressions([value,tail,same])
      nameSource.bytes.add byteAudit
    let hint = if row.active: source.readToken(row.start,brByte) else: BinaryRead()
    when defined(zkbuildNameFrameAudit):
      let byteGate = c.constraints.len
      let byteToken = c.tokenRecords.len
    let size = c.constrainBinaryRead(source,brByte,active,start,value,hint)
    let finish = c.materialize(start+size)
    children.add OwnedChildWires(active: active,owner: owner,ordinal: ordinal,start: start,finish: finish)
    when defined(zkbuildNameFrameAudit):
      nameFrame.bytes.add NameFrameByteAudit(firstGate: byteGate,lastGate: c.constraints.len,
        token: byteToken,fields: copyAuditExpressions([active,owner,ordinal,start,finish]))
    childHints.add row
    priorTail = tail
    priorOwner = owner
  when defined(zkbuildNameFrameAudit): nameFrame.owned = c.ownedRecords.len
  c.constrainOwnedStream(parents,children,parentHints,childHints)
  # Enforce nil termination from child ordinal against the authenticated size.
  var counts, countQueries: seq[ReadOnlyWires]
  var countValues, countReads: seq[ReadOnlyEntry]
  for i, parent in parents:
    counts.add ReadOnlyWires(active: parent.active,address: parent.active.scale(scalar(i)),value: parent.count)
    countValues.add(if parentHints[i].active: ReadOnlyEntry(active: true,address: uint64(i),value: uint64(parentHints[i].count)) else: ReadOnlyEntry())
  for i, child in children:
    let row = childHints[i]
    let count = c.allocate(scalar(if row.active: parentHints[int(row.owner)].count else: 0'u32))
    countQueries.add ReadOnlyWires(active: child.active,address: child.owner,value: count)
    countReads.add(if row.active: ReadOnlyEntry(active: true,address: uint64(row.owner),value: uint64(parentHints[int(row.owner)].count)) else: ReadOnlyEntry())
    when defined(zkbuildNameSourceAudit):
      var endAudit = NameSourceEndAudit(firstGate: c.constraints.len,
        countQuery: copyAuditExpressions([child.active,child.owner,count]))
    let nodeBits = c.constrainUnsigned(queries[i].value,42)
    when defined(zkbuildNameSourceAudit): endAudit.range = c.snapshotRangeUse()
    let tail = c.pack(nodeBits[8..39])
    when defined(zkbuildNameSourceAudit): endAudit.zeroStart = c.values.len
    let selector = c.multiply(child.active,c.zeroIndicator(child.ordinal+constant(1)-count))
    c.constrain(selector,tail,constant(0))
    when defined(zkbuildNameSourceAudit):
      endAudit.tail = copyAuditExpressions([tail])[0]
      endAudit.selector = copyAuditExpressions([selector])[0]
      endAudit.lastGate = c.constraints.len
      nameSource.ends.add endAudit
  when defined(zkbuildNameSourceAudit): nameSource.tables.add c.readOnlyRecords.len
  c.constrainReadOnly(counts,countQueries,buildReadOnlyWitness(countValues,countReads),32,32)
  when defined(zkbuildNameSourceAudit): nameSource.tables.add c.readOnlyRecords.len
  c.constrainReadOnly(names.nodes,queries,buildReadOnlyWitness(values.nodes,reads),32,42)
  when defined(zkbuildNameSourceAudit): nameSource.tables.add c.readOnlyRecords.len
  c.constrainReadOnly(roots,rootQueries,buildReadOnlyWitness(rootValues,rootReads),32,32)
  when defined(zkbuildNameFrameAudit): c.nameFrameRecords.add nameFrame
  when defined(zkbuildNameSourceAudit): c.nameSourceRecords.add nameSource

proc constrainSourceNames(c: var Circuit, source: var BinarySource,
    names: NameEnvironmentWires, values: NameEnvironment,
    wires: ModulePayloadWires, payload: ModulePayloadSource): seq[ReadOnlyWires] =
  if wires.names.len != payload.names.len or names.heads.len != wires.names.len or values.heads.len != names.heads.len:
    raise newException(ValueError, "source name dimensions differ")
  if payload.flat: return c.constrainFlatNames(source,names,values,wires,payload)
  when defined(zkbuildNameFrameAudit):
    var nameFrame = NameFrameAudit(flat: false)
  when defined(zkbuildNameSourceAudit):
    var nameSource: NameSourceAudit
  let nodes = contents(values.nodes)
  var queries: seq[ReadOnlyWires]
  var queryValues: seq[ReadOnlyEntry]
  for i, name in payload.names:
    let wire = wires.names[i]
    when defined(zkbuildNameFrameAudit):
      var nameHeader = NameFrameHeaderAudit(firstGate: c.constraints.len,
        byteStart: nameFrame.bytes.len,byteCount: name.text.len)
    discard c.constrainUnsigned(wire.start, 32)
    when defined(zkbuildNameFrameAudit): nameHeader.ranges.add c.snapshotRangeUse()
    discard c.constrainUnsigned(wire.finish, 32)
    when defined(zkbuildNameFrameAudit):
      nameHeader.ranges.add c.snapshotRangeUse()
      nameHeader.token = c.tokenRecords.len
    let size = c.constrainBinaryRead(source, brU32, constant(1), wire.start, constant(name.text.len), name.length)
    var position = c.materialize(wire.start+size)
    when defined(zkbuildNameFrameAudit):
      nameHeader.lastGate = c.constraints.len
      nameHeader.fields = copyAuditExpressions([constant(1),constant(name.text.len),wire.start,position,wire.finish])
    when defined(zkbuildNameSourceAudit):
      var rootAudit = NameSourceHeaderAudit(head: copyAuditExpressions([names.heads[i]])[0])
    var head = names.heads[i]
    var hostHead = uint64(values.heads[i])
    for j in 0..<name.text.len:
      let raw = nodes.getOrDefault(hostHead)
      let node = c.allocate(scalar(raw))
      queries.add ReadOnlyWires(active: constant(1), address: head, value: node)
      queryValues.add ReadOnlyEntry(active: true, address: hostHead, value: raw)
      when defined(zkbuildNameSourceAudit):
        var byteAudit = NameSourceByteAudit(firstGate: c.constraints.len,nodeQuery: copyAuditExpressions([constant(1),head,node]),
          rootQuery: copyAuditExpressions([constant(0),constant(0),constant(0)]))
      let bits = c.constrainUnsigned(node, 42)
      when defined(zkbuildNameSourceAudit): byteAudit.range = c.snapshotRangeUse()
      let value = c.pack(bits[0..7])
      when defined(zkbuildNameSourceAudit): byteAudit.lastGate = c.constraints.len
      let hint = source.readToken(name.start+uint32(name.length.length)+uint32(j), brByte)
      when defined(zkbuildNameFrameAudit):
        let byteGate = c.constraints.len
        let byteToken = c.tokenRecords.len
        let byteStart = position
      discard c.constrainBinaryRead(source, brByte, constant(1), position, value, hint)
      position = c.materialize(position+constant(1))
      when defined(zkbuildNameFrameAudit):
        nameFrame.bytes.add NameFrameByteAudit(firstGate: byteGate,lastGate: c.constraints.len,
          token: byteToken,fields: copyAuditExpressions([constant(1),constant(i),constant(j),byteStart,position]))
      when defined(zkbuildNameSourceAudit): byteAudit.tailGate = c.constraints.len
      head = c.pack(bits[8..39])
      when defined(zkbuildNameSourceAudit):
        byteAudit.fields = copyAuditExpressions([value,head,constant(0)])
        nameSource.bytes.add byteAudit
      hostHead = (raw shr 8) and 0xffffffff'u64
    when defined(zkbuildNameSourceAudit):
      rootAudit.nilGate = c.constraints.len
      rootAudit.finalHead = copyAuditExpressions([head])[0]
      nameSource.headers.add rootAudit
    c.assertEqual(head, constant(0))
    when defined(zkbuildNameFrameAudit): nameHeader.closeGate = c.constraints.len
    c.assertEqual(wire.finish, position)
    when defined(zkbuildNameFrameAudit): nameFrame.headers.add nameHeader
    result.add ReadOnlyWires(active: constant(1), address: constant(i),
      value: wire.start+wire.finish.scale(scalar(1'u64 shl 32)))
  when defined(zkbuildNameSourceAudit): nameSource.tables.add c.readOnlyRecords.len
  c.constrainReadOnly(names.nodes, queries, buildReadOnlyWitness(values.nodes, queryValues), 32, 42)
  when defined(zkbuildNameFrameAudit): c.nameFrameRecords.add nameFrame
  when defined(zkbuildNameSourceAudit): c.nameSourceRecords.add nameSource

proc constrainSourceConstant(c: var Circuit, source: var BinarySource, cursor: var Linear,
    record: ConstantWires, hint: SourceConstant, active, useExpression: Linear) =
  when defined(zkbuildConstantSourceAudit):
    var audit = ConstantSourceAudit(firstGate: c.constraints.len,
      fields: copyAuditExpressions([active,useExpression,cursor,record.active,record.count,record.opcode,record.immediate,record.vectors]))
  template readConstant(kind: BinaryReadKind, enabled, position, expected: Linear, encoded: BinaryRead): Linear =
    block:
      when defined(zkbuildConstantSourceAudit):
        let readIndex = c.tokenRecords.len
      let size = c.constrainBinaryRead(source,kind,enabled,position,expected,encoded)
      when defined(zkbuildConstantSourceAudit): audit.reads.add ConstantReadAudit(token: readIndex)
      size
  template readVariant(mode, position, expected: Linear, encoded: BinaryRead): Linear =
    block:
      when defined(zkbuildConstantSourceAudit):
        let readIndex = c.tokenRecords.len
      let size = c.constrainVariantRead(source,mode,position,expected,encoded)
      when defined(zkbuildConstantSourceAudit): audit.reads.add ConstantReadAudit(token: readIndex)
      size
  template advance(length: Linear) =
    cursor = c.materialize(cursor+length)
    when defined(zkbuildConstantSourceAudit): audit.reads[^1].cursor = copyAuditExpressions([cursor])[0]
  let modern = c.multiply(active, useExpression)
  let legacy = active-modern
  c.assertEqual(record.active, active)
  c.constrain(active, record.count-constant(1), constant(0))
  const Opcodes = [0x41,0x42,0x43,0x44,0x302,0xd0,0xd2,0x23]
  var selects: array[8, Linear]
  var sum, mode = constant(0)
  const Modes = [3,5,6,7,7,1,2,2] # BinaryReadKind ordinal + 1.
  for i, opcode in Opcodes:
    when defined(zkbuildConstantSourceAudit): audit.zeroStarts.add c.values.len
    selects[i] = c.multiply(modern, c.zeroIndicator(record.opcode-constant(opcode)))
    sum = sum+selects[i]
    mode = mode+selects[i].scale(scalar(Modes[i]))
  c.assertEqual(sum, modern)
  let vector = selects[4]
  let opcodeProduct = c.multiply(modern, record.opcode)
  let prefix = opcodeProduct+vector.scale(scalar(0xfd-0x302))
  let opcodeLength = readConstant(brByte,modern,cursor,prefix,hint.opcode)
  advance(opcodeLength)
  let subLength = readConstant(brU32,vector,cursor,vector.scale(scalar(12)),hint.subopcode)
  advance(subLength)
  let firstValue = c.allocate(scalar(hint.firstValue))
  let first = c.multiply(modern,firstValue)
  let secondValue = c.allocate(scalar(hint.secondValue))
  let second = c.multiply(vector,secondValue)
  let firstLength = readVariant(mode,cursor,first,hint.first)
  advance(firstLength)
  let secondLength = readVariant(vector.scale(scalar(binaryReadMode(brLittle64))),cursor,second,hint.second)
  advance(secondLength)
  when defined(zkbuildConstantSourceAudit): audit.heads = c.packedRecords.len
  let split = c.splitSignatureHeads(first)
  let wide = selects[1]+selects[3]
  let wideImmediate = c.multiply(wide,split.params)
  let shortImmediate = c.multiply(modern-wide-vector,first)
  c.constrain(modern, record.immediate-wideImmediate-shortImmediate, constant(0))
  c.constrain(modern, record.vectors-vector, constant(0))
  let endLength = readConstant(brByte,modern,cursor,modern.scale(scalar(11)),hint.terminal)
  advance(endLength)
  c.constrain(legacy, record.opcode-constant(0xd2), constant(0))
  c.constrain(legacy, record.vectors, constant(0))
  let legacyImmediate = c.multiply(legacy,record.immediate)
  let indexLength = readConstant(brU32,legacy,cursor,legacyImmediate,hint.legacy)
  advance(indexLength)
  when defined(zkbuildConstantSourceAudit):
    audit.fields.add copyAuditExpressions([modern,legacy,opcodeProduct,firstValue,first,secondValue,second,wideImmediate,shortImmediate,legacyImmediate])
    audit.selectors = copyAuditExpressions(selects)
    audit.lastGate = c.constraints.len
    c.constantSourceRecords.add audit

proc constrainModulePayload*(c: var Circuit, source: var BinarySource,
    envelope: BinaryEnvelopeWires, wires: ModulePayloadWires, hint: ModulePayloadSource,
    module: ModuleEnvironmentWires, moduleValues: ModuleEnvironment,
    environment: TypeEnvironmentWires, environmentValues: TypeEnvironment,
    signatures: SignatureEnvironmentWires, signatureValues: SignatureEnvironment,
    bulk: BulkEnvironmentWires): void =
  if hint.exports.len != module.exports.len or hint.globals.len != module.globalInitializers.len or
      hint.elements.len != module.elements.len or hint.datas.len != module.datas.len:
    raise newException(ValueError, "module payload dimensions differ")
  let names = c.constrainSourceNames(source, module.names, moduleValues.names, wires, hint)
  when defined(zkbuildImportAudit):
    var importAudit = ImportAudit(importedFunctions: module.importedFunctions,
      importedTables: module.importedTables,importedMemories: module.importedMemories,
      importedGlobals: module.importedGlobals)
    var importRow: ImportRowAudit
    var auditingImport = false
  when defined(zkbuildScalarPayloadAudit):
    var scalarPayload: ScalarPayloadAudit
    var scalarRow: ScalarPayloadRowAudit
    var scalarKind = -1
  var nameValues: seq[ReadOnlyEntry]
  for i, value in hint.names:
    nameValues.add(if value.active: ReadOnlyEntry(active: true, address: uint64(i), value: uint64(value.start)+(uint64(value.finish) shl 32)) else: ReadOnlyEntry())
  let nameMap = contents(nameValues)
  let objects = contents(environmentValues.objects)
  var nameQueries, objectQueries, signatureQueries: seq[ReadOnlyWires]
  var nameReads, objectReads, signatureReads: seq[ReadOnlyEntry]
  var typeIndices, memoryLimits, memoryFlags, tableLimits, tableFlags: seq[ReadOnlyWires]
  var typeIndexValues, memoryLimitValues, memoryFlagValues, tableLimitValues, tableFlagValues: seq[ReadOnlyEntry]
  for i, row in signatures.signatures:
    typeIndices.add ReadOnlyWires(active: row.active, address: row.address, value: signatures.typeIndices[i])
    let value = signatureValues.signatures[i]
    typeIndexValues.add ReadOnlyEntry(active: value.active, address: value.address, value: uint64(signatureValues.typeIndices[i]))
  for i, row in module.memories:
    memoryLimits.add ReadOnlyWires(active: row.active, address: row.active.scale(scalar(i)),
      value: row.minimum+row.maximum.scale(scalar(1'u64 shl 32)))
    memoryFlags.add ReadOnlyWires(active: row.active, address: row.active.scale(scalar(i)), value: row.hasMax)
    let value = moduleValues.memories[i]
    memoryLimitValues.add ReadOnlyEntry(active: value.active, address: (if value.active: uint64(i) else: 0), value: uint64(value.minimum)+(uint64(value.maximum) shl 32))
    memoryFlagValues.add ReadOnlyEntry(active: value.active, address: (if value.active: uint64(i) else: 0), value: uint64(ord(value.hasMax)))
  for i, row in module.tableLimits:
    tableLimits.add ReadOnlyWires(active: row.active, address: row.active.scale(scalar(i)),
      value: row.minimum+row.maximum.scale(scalar(1'u64 shl 32)))
    tableFlags.add ReadOnlyWires(active: row.active, address: row.active.scale(scalar(i)), value: row.hasMax)
    let value = moduleValues.tableLimits[i]
    tableLimitValues.add ReadOnlyEntry(active: value.active, address: (if value.active: uint64(i) else: 0), value: uint64(value.minimum)+(uint64(value.maximum) shl 32))
    tableFlagValues.add ReadOnlyEntry(active: value.active, address: (if value.active: uint64(i) else: 0), value: uint64(ord(value.hasMax)))
  let functionTypes = contents(typeIndexValues)
  let memoryLimitMap = contents(memoryLimitValues)
  let memoryFlagMap = contents(memoryFlagValues)
  let tableLimitMap = contents(tableLimitValues)
  let tableFlagMap = contents(tableFlagValues)
  var memoryQueries, memoryFlagQueries, tableQueries, tableFlagQueries: seq[ReadOnlyWires]
  var memoryReads, memoryFlagReads, tableReads, tableFlagReads: seq[ReadOnlyEntry]
  template query(bank: untyped, values: untyped, lookup: untyped,
      enabled, key: Linear, hostActive: bool, hostKey: uint64): Linear =
    block:
      let actual = if hostActive: lookup.getOrDefault(hostKey) else: 0'u64
      let value = c.allocate(scalar(actual))
      bank.add ReadOnlyWires(active: enabled, address: c.multiply(enabled, key), value: value)
      values.add(if hostActive: ReadOnlyEntry(active: true, address: hostKey, value: actual) else: ReadOnlyEntry())
      value
  template name(cursor: var Linear, index: Linear, hostIndex: uint64, enabled = constant(1), hostEnabled = true) =
    block:
      let value = query(nameQueries, nameReads, nameMap, enabled, index, hostEnabled, hostIndex)
      when defined(zkbuildImportAudit):
        let nameHeads = c.packedRecords.len
      let span = c.splitSignatureHeads(value)
      c.constrain(enabled,cursor-span.params,constant(0))
      cursor = c.selectWire(enabled,span.results,cursor)
      when defined(zkbuildImportAudit):
        if auditingImport:
          let q = nameQueries[^1]
          importRow.names.add ImportNameAudit(heads: nameHeads,
            query: copyAuditExpressions([q.active,q.address,q.value]),
            cursor: copyAuditExpressions([cursor])[0])
      when defined(zkbuildScalarPayloadAudit):
        if scalarKind == 3:
          let q = nameQueries[^1]
          scalarRow.name = ImportNameAudit(heads: nameHeads,
            query: copyAuditExpressions([q.active,q.address,q.value]),cursor: copyAuditExpressions([cursor])[0])
  when defined(zkbuildSegmentPayloadAudit):
    var segmentAudit = SegmentPayloadAudit(flat: hint.flat,ownedIndex: -1,modeTable: -1)
    var segmentRow: SegmentPayloadRowAudit
    var segmentKind = -1
  template read(cursor: var Linear, kind: BinaryReadKind, enabled, expected: Linear, encoded: BinaryRead) =
    block:
      when defined(zkbuildImportAudit):
        let readIndex = c.tokenRecords.len
      let size = c.constrainBinaryRead(source, kind, enabled, cursor, c.multiply(enabled, expected), encoded)
      cursor = c.materialize(cursor+size)
      when defined(zkbuildImportAudit):
        if auditingImport:
          importRow.reads.add ImportReadAudit(token: readIndex,cursor: copyAuditExpressions([cursor])[0])
      when defined(zkbuildScalarPayloadAudit):
        if scalarKind >= 0:
          scalarRow.reads.add ImportReadAudit(token: readIndex,cursor: copyAuditExpressions([cursor])[0])
      when defined(zkbuildSegmentPayloadAudit):
        if segmentKind >= 0:
          segmentRow.reads.add ImportReadAudit(token: readIndex,cursor: copyAuditExpressions([cursor])[0])
  template typeByte(tag: Linear): Linear =
    constant(127)-tag-(c.zeroIndicator(tag-constant(5))+c.zeroIndicator(tag-constant(6))).scale(scalar(10))
  template limit(cursor: var Linear, enabled, mem, tab, memIndex, tabIndex: Linear,
      hostMemory, hostTable: bool, hostMemIndex, hostTabIndex: uint64, token: SourceLimit) =
    block:
      let memoryData = query(memoryQueries, memoryReads, memoryLimitMap, mem, memIndex, hostMemory, hostMemIndex)
      let memoryFlag = query(memoryFlagQueries, memoryFlagReads, memoryFlagMap, mem, memIndex, hostMemory, hostMemIndex)
      let tableData = query(tableQueries, tableReads, tableLimitMap, tab, tabIndex, hostTable, hostTabIndex)
      let tableFlag = query(tableFlagQueries, tableFlagReads, tableFlagMap, tab, tabIndex, hostTable, hostTabIndex)
      when defined(zkbuildImportAudit):
        if auditingImport:
          importRow.limitHeads = c.packedRecords.len
      when defined(zkbuildScalarPayloadAudit):
        if scalarKind in [0,1]: scalarRow.limitHeads = c.packedRecords.len
      let fields = c.splitSignatureHeads(memoryData+tableData)
      let hasMax = memoryFlag+tableFlag
      read(cursor, brByte, enabled, hasMax, token.flags)
      read(cursor, brU32, enabled, fields.params, token.minimum)
      read(cursor, brU32, hasMax, fields.results, token.maximum)
      when defined(zkbuildScalarPayloadAudit):
        if scalarKind in [0,1]:
          for q in [memoryQueries[^1],memoryFlagQueries[^1],tableQueries[^1],tableFlagQueries[^1]]:
            scalarRow.limitQueries.add copyAuditExpressions([q.active,q.address,q.value])
  var exportCount, importCount = constant(0)
  for row in module.exports: exportCount = exportCount+row.active
  var hostExportCount: int
  for row in moduleValues.exports:
    if row.active: inc hostExportCount
  when defined(zkbuildImportAudit): importAudit.exportCount = copyAuditExpressions([exportCount])[0]
  var cursor = envelope.payloadStarts[2]
  var functions, globals, tables, memories = constant(0)
  var hostFunctions, hostGlobals, hostTables, hostMemories: uint64
  var priorImport = constant(1)
  for i, item in hint.imports:
    when defined(zkbuildImportAudit):
      auditingImport = true
      importRow = ImportRowAudit(firstGate: c.constraints.len)
    let enabled = c.bit(item.active)
    when defined(zkbuildImportAudit): importRow.active = copyAuditExpressions([enabled])[0]
    c.constrain(enabled,constant(1)-priorImport,constant(0))
    priorImport = enabled
    name(cursor, exportCount+constant(2*i), uint64(hostExportCount+2*i),enabled,item.active)
    name(cursor, exportCount+constant(2*i+1), uint64(hostExportCount+2*i+1),enabled,item.active)
    importCount = importCount+enabled
    let kind = c.allocate(scalar(item.kind))
    when defined(zkbuildImportAudit): importRow.kind = copyAuditExpressions([kind])[0]
    discard c.constrainUnsigned(kind, 2)
    when defined(zkbuildImportAudit): importRow.kindRange = c.snapshotRangeUse()
    c.constrain(constant(1)-enabled,kind,constant(0))
    read(cursor, brByte, enabled, kind, item.kindRead)
    when defined(zkbuildImportAudit): importRow.zeroStarts.add c.values.len
    let function = c.multiply(enabled,c.zeroIndicator(kind))
    when defined(zkbuildImportAudit): importRow.zeroStarts.add c.values.len
    let table = c.multiply(enabled,c.zeroIndicator(kind-constant(1)))
    when defined(zkbuildImportAudit): importRow.zeroStarts.add c.values.len
    let memory = c.multiply(enabled,c.zeroIndicator(kind-constant(2)))
    when defined(zkbuildImportAudit): importRow.zeroStarts.add c.values.len
    let global = c.multiply(enabled,c.zeroIndicator(kind-constant(3)))
    when defined(zkbuildImportAudit): importRow.indicators = copyAuditExpressions([function,table,memory,global])
    let index = query(signatureQueries, signatureReads, functionTypes, function,
      functions.scale(scalar(2)), item.active and item.kind == 0, hostFunctions*2)
    when defined(zkbuildImportAudit):
      let q = signatureQueries[^1]
      importRow.typeQuery = copyAuditExpressions([q.active,q.address,q.value])
    read(cursor, brU32, function, index, item.functionType)
    let objectIndex = c.selectWire(global, globals, tables)
    when defined(zkbuildImportAudit): importRow.objectIndex = copyAuditExpressions([objectIndex])[0]
    let objectValue = query(objectQueries, objectReads, objects, global+table,
      objectIndex.scale(scalar(2))+table, item.active and item.kind in [1'u32,3],
      (if item.kind == 3: hostGlobals*2 else: hostTables*2+1))
    when defined(zkbuildImportAudit):
      let qObject = objectQueries[^1]
      importRow.objectQuery = copyAuditExpressions([qObject.active,qObject.address,qObject.value])
    let bits = c.constrainUnsigned(objectValue, 4)
    when defined(zkbuildImportAudit): importRow.objectRange = c.snapshotRangeUse()
    let tag = objectValue-bits[3].scale(scalar(8))
    when defined(zkbuildImportAudit): importRow.typeZeroStart = c.values.len
    read(cursor, brByte, global+table, typeByte(tag), item.valueType)
    read(cursor, brByte, global, bits[3], item.mutable)
    limit(cursor, memory+table, memory, table, memories, tables, item.active and item.kind == 2, item.active and item.kind == 1,
      hostMemories, hostTables, item.limits)
    functions = c.materialize(functions+function)
    tables = c.materialize(tables+table)
    memories = c.materialize(memories+memory)
    globals = c.materialize(globals+global)
    when defined(zkbuildImportAudit):
      for qLimit in [memoryQueries[^1],memoryFlagQueries[^1],tableQueries[^1],tableFlagQueries[^1]]:
        importRow.limitQueries.add copyAuditExpressions([qLimit.active,qLimit.address,qLimit.value])
      importRow.counts = copyAuditExpressions([functions,tables,memories,globals])
      importRow.lastGate = c.constraints.len
      importAudit.rows.add importRow
    if item.active:
      case item.kind
      of 0: inc hostFunctions
      of 1: inc hostTables
      of 2: inc hostMemories
      else: inc hostGlobals
  when defined(zkbuildImportAudit):
    auditingImport = false
    importAudit.closeStart = c.constraints.len
  c.assertEqual(cursor, envelope.ends[2])
  c.assertEqual(functions, module.importedFunctions)
  c.assertEqual(tables, module.importedTables)
  c.assertEqual(memories, module.importedMemories)
  c.assertEqual(globals, module.importedGlobals)
  c.assertEqual(importCount, envelope.firstWords[2])
  when defined(zkbuildImportAudit): importAudit.closeEnd = c.constraints.len
  cursor = envelope.payloadStarts[4]
  var definedTables, priorTable = constant(0)
  priorTable = constant(1)
  for i, item in hint.tables:
    when defined(zkbuildScalarPayloadAudit):
      scalarKind = 0
      scalarRow = ScalarPayloadRowAudit(firstGate: c.constraints.len)
    let enabled = c.bit(item.active)
    when defined(zkbuildScalarPayloadAudit): scalarRow.active = copyAuditExpressions([enabled])[0]
    c.constrain(enabled,constant(1)-priorTable,constant(0))
    priorTable = enabled
    definedTables = definedTables+enabled
    let index = module.importedTables+constant(i)
    let value = query(objectQueries, objectReads, objects, enabled, index.scale(scalar(2))+constant(1), item.active, 2*(hostTables+uint64(i))+1)
    when defined(zkbuildScalarPayloadAudit):
      let q = objectQueries[^1]
      scalarRow.objectQuery = copyAuditExpressions([q.active,q.address,q.value])
      scalarRow.typeZeroStart = c.values.len
    read(cursor, brByte, enabled, typeByte(value), item.valueType)
    limit(cursor, enabled, constant(0), enabled, constant(0), index, false, item.active, 0'u64, hostTables+uint64(i), item.limits)
    when defined(zkbuildScalarPayloadAudit):
      scalarRow.lastGate = c.constraints.len
      scalarPayload.rows[0].add scalarRow
  when defined(zkbuildScalarPayloadAudit): scalarPayload.closeStarts[0] = c.constraints.len
  c.assertEqual(cursor, envelope.ends[4])
  c.assertEqual(definedTables, envelope.firstWords[4])
  when defined(zkbuildScalarPayloadAudit): scalarPayload.closeEnds[0] = c.constraints.len
  cursor = envelope.payloadStarts[5]
  var definedMemories, priorMemory = constant(0)
  priorMemory = constant(1)
  for i, item in hint.memories:
    when defined(zkbuildScalarPayloadAudit):
      scalarKind = 1
      scalarRow = ScalarPayloadRowAudit(firstGate: c.constraints.len)
    let enabled = c.bit(item.active)
    when defined(zkbuildScalarPayloadAudit): scalarRow.active = copyAuditExpressions([enabled])[0]
    c.constrain(enabled,constant(1)-priorMemory,constant(0))
    priorMemory = enabled
    definedMemories = definedMemories+enabled
    limit(cursor, enabled, enabled, constant(0), module.importedMemories+constant(i), constant(0),
      item.active, false, hostMemories+uint64(i), 0'u64, item)
    when defined(zkbuildScalarPayloadAudit):
      scalarRow.lastGate = c.constraints.len
      scalarPayload.rows[1].add scalarRow
  when defined(zkbuildScalarPayloadAudit): scalarPayload.closeStarts[1] = c.constraints.len
  c.assertEqual(cursor, envelope.ends[5])
  c.assertEqual(definedMemories, envelope.firstWords[5])
  when defined(zkbuildScalarPayloadAudit): scalarPayload.closeEnds[1] = c.constraints.len
  cursor = envelope.payloadStarts[6]
  var definedGlobals = constant(0)
  for i, item in hint.globals:
    when defined(zkbuildScalarPayloadAudit):
      scalarKind = 2
      scalarRow = ScalarPayloadRowAudit(firstGate: c.constraints.len)
    let enabled = module.globalInitializers[i].active
    when defined(zkbuildScalarPayloadAudit): scalarRow.active = copyAuditExpressions([enabled])[0]
    let hostEnabled = moduleValues.globalInitializers[i].active
    definedGlobals = definedGlobals+enabled
    let index = module.importedGlobals+constant(i)
    let value = query(objectQueries, objectReads, objects, enabled, index.scale(scalar(2)), hostEnabled, 2*(hostGlobals+uint64(i)))
    when defined(zkbuildScalarPayloadAudit):
      let q = objectQueries[^1]
      scalarRow.objectQuery = copyAuditExpressions([q.active,q.address,q.value])
    let bits = c.constrainUnsigned(value, 4)
    when defined(zkbuildScalarPayloadAudit):
      scalarRow.objectRange = c.snapshotRangeUse()
      scalarRow.typeZeroStart = c.values.len
    read(cursor, brByte, enabled, typeByte(value-bits[3].scale(scalar(8))), item.valueType)
    read(cursor, brByte, enabled, bits[3], item.mutable)
    when defined(zkbuildScalarPayloadAudit): scalarRow.constantIndex = c.constantSourceRecords.len
    c.constrainSourceConstant(source, cursor, module.globalInitializers[i], item.value, enabled, constant(1))
    when defined(zkbuildScalarPayloadAudit):
      scalarRow.lastGate = c.constraints.len
      scalarPayload.rows[2].add scalarRow
  when defined(zkbuildScalarPayloadAudit): scalarPayload.closeStarts[2] = c.constraints.len
  c.assertEqual(cursor, envelope.ends[6])
  c.assertEqual(definedGlobals, envelope.firstWords[6])
  when defined(zkbuildScalarPayloadAudit): scalarPayload.closeEnds[2] = c.constraints.len
  cursor = envelope.payloadStarts[7]
  for i, item in hint.exports:
    when defined(zkbuildScalarPayloadAudit):
      scalarKind = 3
      scalarRow = ScalarPayloadRowAudit(firstGate: c.constraints.len)
    let enabled = module.exports[i].active
    when defined(zkbuildScalarPayloadAudit):
      scalarRow.active = copyAuditExpressions([enabled])[0]
      scalarRow.fields = copyAuditExpressions([module.exports[i].kind,module.exports[i].index])
    name(cursor, constant(i), uint64(i),enabled,moduleValues.exports[i].active)
    read(cursor, brByte, enabled, module.exports[i].kind, item.kind)
    read(cursor, brU32, enabled, module.exports[i].index, item.index)
    when defined(zkbuildScalarPayloadAudit):
      scalarRow.lastGate = c.constraints.len
      scalarPayload.rows[3].add scalarRow
  when defined(zkbuildScalarPayloadAudit): scalarPayload.closeStarts[3] = c.constraints.len
  c.assertEqual(cursor, envelope.ends[7])
  c.assertEqual(exportCount, envelope.firstWords[7])
  when defined(zkbuildScalarPayloadAudit):
    scalarPayload.closeEnds[3] = c.constraints.len
    scalarKind = -1
  cursor = envelope.payloadStarts[9]
  var elementCount = constant(0)
  var itemParents: seq[OwnedParentWires]
  var itemParentHints: seq[OwnedParent]
  var modes: seq[ReadOnlyWires]
  var modeValues: seq[ReadOnlyEntry]
  for i, item in hint.elements:
    when defined(zkbuildSegmentPayloadAudit):
      segmentKind = 0
      segmentRow = SegmentPayloadRowAudit(firstGate: c.constraints.len)
    let enabled = module.elements[i].active
    let hostEnabled = moduleValues.elements[i].active
    elementCount = elementCount+enabled
    if item.items.len != module.elements[i].items.len: raise newException(ValueError, "source element item dimensions differ")
    let flags = c.allocate(scalar(item.flags.value))
    let bits = c.constrainUnsigned(flags, 3)
    when defined(zkbuildSegmentPayloadAudit): segmentRow.ranges.add c.snapshotRangeUse()
    c.constrain(constant(1)-enabled,flags,constant(0))
    read(cursor, brU32, enabled, flags, item.flags)
    let active = enabled-bits[0]
    let explicitTable = c.multiply(active, bits[1])
    let firstBoth = c.multiply(bits[0], bits[1])
    c.assertEqual(module.elements[i].mode, active+firstBoth.scale(scalar(2)))
    c.constrain(constant(1)-explicitTable, module.elements[i].tableIndex, constant(0))
    read(cursor, brU32, explicitTable, module.elements[i].tableIndex, item.tableIndex)
    when defined(zkbuildSegmentPayloadAudit): segmentRow.constants.add c.constantSourceRecords.len
    c.constrainSourceConstant(source, cursor, module.elements[i].offset, item.offset, active, constant(1))
    let secondBoth = c.multiply(bits[0], bits[1])
    let hasType = bits[0]+bits[1]-secondBoth
    let typed = c.multiply(hasType, bits[2])
    let tag = bulk.elements[i].value
    c.constrain(enabled-typed, tag-constant(5), constant(0))
    when defined(zkbuildSegmentPayloadAudit): segmentRow.zeroStarts.add c.values.len
    let elementTypeByte = typeByte(tag)
    let typeProduct = c.multiply(bits[2], elementTypeByte)
    read(cursor, brByte, hasType, typeProduct, item.elementType)
    read(cursor, brU32, enabled, module.elements[i].itemCount, item.count)
    when defined(zkbuildSegmentPayloadAudit):
      segmentRow.fields = copyAuditExpressions([enabled,flags,explicitTable,module.elements[i].mode,
        module.elements[i].tableIndex,firstBoth,secondBoth,typed,tag,typeProduct,module.elements[i].itemCount])
    if hint.flat:
      let start = c.multiply(enabled,cursor)
      let finish = c.allocate(scalar(item.finish))
      itemParents.add OwnedParentWires(active: enabled,count: module.elements[i].itemCount,start: start,finish: finish)
      itemParentHints.add OwnedParent(active: hostEnabled,count: moduleValues.elements[i].itemCount,start: item.itemsStart,finish: item.finish)
      modes.add ReadOnlyWires(active: enabled,address: enabled.scale(scalar(i)),value: bits[2])
      modeValues.add(if hostEnabled: ReadOnlyEntry(active: true,address: uint64(i),value: (item.flags.value shr 2) and 1) else: ReadOnlyEntry())
      cursor = c.selectWire(enabled,finish,cursor)
      when defined(zkbuildSegmentPayloadAudit):
        segmentRow.fields.add copyAuditExpressions([start,finish,cursor])
    else:
      for j, expr in item.items:
        when defined(zkbuildSegmentPayloadAudit): segmentRow.constants.add c.constantSourceRecords.len
        c.constrainSourceConstant(source, cursor, module.elements[i].items[j], expr, constant(1), bits[2])
    when defined(zkbuildSegmentPayloadAudit):
      segmentRow.lastGate = c.constraints.len
      segmentAudit.elements.add segmentRow
  when defined(zkbuildSegmentPayloadAudit):
    segmentKind = -1
    segmentAudit.closeStarts[0] = c.constraints.len
  c.assertEqual(cursor, envelope.ends[9])
  c.assertEqual(elementCount, envelope.firstWords[9])
  when defined(zkbuildSegmentPayloadAudit): segmentAudit.closeEnds[0] = c.constraints.len
  if hint.flat:
    if hint.elementItems.len != module.elementItems.len: raise newException(ValueError,"flat source item dimensions differ")
    var children: seq[OwnedChildWires]
    var childHints: seq[OwnedChild]
    var queries: seq[ReadOnlyWires]
    var reads: seq[ReadOnlyEntry]
    let modeMap = contents(modeValues)
    for i, item in hint.elementItems:
      when defined(zkbuildSegmentPayloadAudit): segmentRow = SegmentPayloadRowAudit(firstGate: c.constraints.len)
      let row = module.elementItems[i]
      let enabled = row.value.active
      var position = c.allocate(scalar(item.row.start))
      let start = position
      let hostMode = if item.row.active: modeMap.getOrDefault(uint64(item.row.owner)) else: 0'u64
      let mode = c.allocate(scalar(hostMode))
      queries.add ReadOnlyWires(active: enabled,address: row.owner,value: mode)
      reads.add(if item.row.active: ReadOnlyEntry(active: true,address: uint64(item.row.owner),value: hostMode) else: ReadOnlyEntry())
      when defined(zkbuildSegmentPayloadAudit): segmentRow.constants.add c.constantSourceRecords.len
      c.constrainSourceConstant(source,position,row.value,item.expression,enabled,mode)
      when defined(zkbuildSegmentPayloadAudit):
        segmentRow.fields = copyAuditExpressions([enabled,row.owner,row.ordinal,start,position,mode])
        segmentRow.queries.add copyAuditExpressions([enabled,row.owner,mode])
        segmentRow.lastGate = c.constraints.len
        segmentAudit.items.add segmentRow
      children.add OwnedChildWires(active: enabled,owner: row.owner,ordinal: row.ordinal,start: start,finish: position)
      childHints.add item.row
    when defined(zkbuildSegmentPayloadAudit): segmentAudit.ownedIndex = c.ownedRecords.len
    c.constrainOwnedStream(itemParents,children,itemParentHints,childHints)
    when defined(zkbuildSegmentPayloadAudit): segmentAudit.modeTable = c.readOnlyRecords.len
    c.constrainReadOnly(modes,queries,buildReadOnlyWitness(modeValues,reads),32,1)
  cursor = envelope.payloadStarts[11]
  var dataCount = constant(0)
  for i, item in hint.datas:
    when defined(zkbuildSegmentPayloadAudit):
      segmentKind = 1
      segmentRow = SegmentPayloadRowAudit(firstGate: c.constraints.len)
    let enabled = module.datas[i].active
    dataCount = dataCount+enabled
    let flags = c.allocate(scalar(item.flags.value))
    discard c.constrainUnsigned(flags, 2)
    when defined(zkbuildSegmentPayloadAudit):
      segmentRow.ranges.add c.snapshotRangeUse()
      segmentRow.zeroStarts.add c.values.len
    c.assertEqual(c.zeroIndicator(flags-constant(3)), constant(0))
    c.constrain(constant(1)-enabled,flags,constant(0))
    read(cursor, brU32, enabled, flags, item.flags)
    when defined(zkbuildSegmentPayloadAudit): segmentRow.zeroStarts.add c.values.len
    let passive = c.multiply(enabled,c.zeroIndicator(flags-constant(1)))
    when defined(zkbuildSegmentPayloadAudit): segmentRow.zeroStarts.add c.values.len
    let explicitMemory = c.multiply(enabled,c.zeroIndicator(flags-constant(2)))
    c.assertEqual(module.datas[i].passive, passive)
    c.constrain(constant(1)-explicitMemory, module.datas[i].memoryIndex, constant(0))
    read(cursor, brU32, explicitMemory, module.datas[i].memoryIndex, item.memoryIndex)
    when defined(zkbuildSegmentPayloadAudit): segmentRow.constants.add c.constantSourceRecords.len
    c.constrainSourceConstant(source, cursor, module.datas[i].offset, item.offset, enabled-passive, constant(1))
    let size = c.allocate(scalar(item.length.value))
    c.constrain(constant(1)-enabled,size,constant(0))
    read(cursor, brU32, enabled, size, item.length)
    cursor = c.materialize(cursor+size)
    discard c.constrainUnsigned(envelope.ends[11]-cursor, 32)
    when defined(zkbuildSegmentPayloadAudit):
      segmentRow.ranges.add c.snapshotRangeUse()
      segmentRow.fields = copyAuditExpressions([enabled,flags,passive,explicitMemory,
        module.datas[i].passive,module.datas[i].memoryIndex,size,cursor])
      segmentRow.lastGate = c.constraints.len
      segmentAudit.datas.add segmentRow
  when defined(zkbuildSegmentPayloadAudit):
    segmentKind = -1
    segmentAudit.closeStarts[1] = c.constraints.len
  c.assertEqual(cursor, envelope.ends[11])
  c.assertEqual(dataCount, envelope.firstWords[11])
  when defined(zkbuildSegmentPayloadAudit):
    segmentAudit.closeEnds[1] = c.constraints.len
    segmentAudit.closeStarts[2] = c.constraints.len
  # Start and data-count sections contain exactly their one scalar header.
  c.assertEqual(envelope.payloadStarts[8], envelope.ends[8])
  c.assertEqual(envelope.payloadStarts[12], envelope.ends[12])
  when defined(zkbuildSegmentPayloadAudit): segmentAudit.closeEnds[2] = c.constraints.len
  var customCount = constant(0)
  var hostCustomCount: uint64
  for section in envelope.sections:
    when defined(zkbuildSegmentPayloadAudit):
      segmentRow = SegmentPayloadRowAudit(firstGate: c.constraints.len)
      segmentRow.zeroStarts.add c.values.len
    let custom = c.multiply(section.active, c.zeroIndicator(section.id))
    let hostId = uint64(hostExportCount)+2*(hostFunctions+hostGlobals+hostTables+hostMemories)+hostCustomCount
    let isCustom = section.id.evaluate(c.values).equals(scalar(0)) and section.active.evaluate(c.values).equals(scalar(1))
    let value = query(nameQueries, nameReads, nameMap, custom,
      exportCount+importCount.scale(scalar(2))+customCount, isCustom, hostId)
    when defined(zkbuildSegmentPayloadAudit): segmentRow.heads = c.packedRecords.len
    let span = c.splitSignatureHeads(value)
    c.constrain(custom, span.params-section.body, constant(0))
    let customMargin = c.multiply(custom, section.finish-span.results)
    discard c.constrainUnsigned(customMargin, 32)
    when defined(zkbuildSegmentPayloadAudit): segmentRow.ranges.add c.snapshotRangeUse()
    customCount = c.materialize(customCount+custom)
    when defined(zkbuildSegmentPayloadAudit):
      segmentRow.fields = copyAuditExpressions([custom,customMargin,customCount])
      let q = nameQueries[^1]
      segmentRow.queries.add copyAuditExpressions([q.active,q.address,q.value])
      segmentRow.lastGate = c.constraints.len
      segmentAudit.customs.add segmentRow
    if isCustom: inc hostCustomCount
  var nameCount = constant(0)
  for row in wires.names: nameCount = nameCount+row.active
  when defined(zkbuildSegmentPayloadAudit): segmentAudit.tail.firstGate = c.constraints.len
  if hint.flat:
    discard c.constrainUnsigned(constant(hint.customLimit)-customCount,32)
    when defined(zkbuildSegmentPayloadAudit):
      segmentAudit.tail.fields = @[constant(hint.customLimit)]
      segmentAudit.tail.ranges.add c.snapshotRangeUse()
    c.assertEqual(nameCount,exportCount+importCount.scale(scalar(2))+customCount)
  else:
    when defined(zkbuildSegmentPayloadAudit): segmentAudit.tail.fields = @[constant(hint.customCount)]
    c.assertEqual(customCount, constant(hint.customCount))
    c.assertEqual(constant(hint.names.len), constant(hint.exports.len+2*hint.imports.len+hint.customCount))
  when defined(zkbuildSegmentPayloadAudit): segmentAudit.tail.lastGate = c.constraints.len
  when defined(zkbuildImportAudit): importAudit.tables.add c.readOnlyRecords.len
  c.constrainReadOnly(names, nameQueries, buildReadOnlyWitness(nameValues, nameReads), 32, 64)
  when defined(zkbuildImportAudit): importAudit.tables.add c.readOnlyRecords.len
  c.constrainReadOnly(environment.objects, objectQueries, buildReadOnlyWitness(environmentValues.objects, objectReads), 33, 4)
  when defined(zkbuildImportAudit): importAudit.tables.add c.readOnlyRecords.len
  c.constrainReadOnly(typeIndices, signatureQueries, buildReadOnlyWitness(typeIndexValues, signatureReads), 33, 32)
  when defined(zkbuildImportAudit): importAudit.tables.add c.readOnlyRecords.len
  c.constrainReadOnly(memoryLimits, memoryQueries, buildReadOnlyWitness(memoryLimitValues, memoryReads), 32, 64)
  when defined(zkbuildImportAudit): importAudit.tables.add c.readOnlyRecords.len
  c.constrainReadOnly(memoryFlags, memoryFlagQueries, buildReadOnlyWitness(memoryFlagValues, memoryFlagReads), 32, 1)
  when defined(zkbuildImportAudit): importAudit.tables.add c.readOnlyRecords.len
  c.constrainReadOnly(tableLimits, tableQueries, buildReadOnlyWitness(tableLimitValues, tableReads), 32, 64)
  when defined(zkbuildImportAudit): importAudit.tables.add c.readOnlyRecords.len
  c.constrainReadOnly(tableFlags, tableFlagQueries, buildReadOnlyWitness(tableFlagValues, tableFlagReads), 32, 1)
  when defined(zkbuildImportAudit): c.importRecords.add importAudit
  when defined(zkbuildScalarPayloadAudit): c.scalarPayloadRecords.add scalarPayload
  when defined(zkbuildSegmentPayloadAudit): c.segmentPayloadRecords.add segmentAudit
