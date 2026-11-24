## Exact byte source and fixed-shape primitive readers for binary binding.
## Public packed bytes are a transitional claim; a succinct digest relation
## can replace their packing without changing the authenticated read interface.
import r1cs, range_check, read_only_memory
import wasm_binary_claim

type
  BinaryReadKind* = enum
    brByte, brU32, brS32, brS33, brS64, brLittle32, brLittle64
  BinaryRead* = object
    position*: uint32
    length*: uint8
    value*: uint64
    bytes*: array[10, byte]
  BinarySourceClaim* = object
    length*: Linear
    limbs*: seq[Linear]
  BinarySource* = object
    length*: Linear
    entries*: seq[ReadOnlyWires]
    queries: seq[ReadOnlyWires]
    values: seq[ReadOnlyEntry]
    queryValues: seq[ReadOnlyEntry]
    data: seq[byte]
    when defined(zkbuildByteMemoryAudit):
      auditSourceIndex*: int

func readWidth*(kind: BinaryReadKind): int =
  case kind
  of brByte: 8
  of brU32, brS32, brLittle32: 32
  of brS33: 33
  of brS64, brLittle64: 64

func readCapacity*(kind: BinaryReadKind): int =
  case kind
  of brByte: 1
  of brU32, brS32, brS33: 5
  of brS64: 10
  of brLittle32: 4
  of brLittle64: 8

func signed(kind: BinaryReadKind): bool = kind in {brS32, brS33, brS64}
func leb(kind: BinaryReadKind): bool = kind in {brU32, brS32, brS33, brS64}

proc readBinaryToken*(data: openArray[byte], position: uint32, kind: BinaryReadKind): BinaryRead =
  result.position = position
  let capacity = readCapacity(kind)
  let width = readWidth(kind)
  for i in 0..<capacity:
    if uint64(position)+uint64(i) >= uint64(data.len):
      raise newException(ValueError, "binary read exceeds source")
    let value = data[int(position)+i]
    result.bytes[i] = value
    result.length = uint8(i+1)
    if not leb(kind):
      result.value = result.value or (uint64(value) shl (8*i))
      if i+1 == capacity: return
      continue
    let payload = value and 127
    let shift = 7*i
    result.value = result.value or (uint64(payload) shl shift)
    if (value and 128) == 0:
      let consumed = shift+7
      if consumed < width and signed(kind) and (payload and 64) != 0:
        result.value = result.value or (not 0'u64 shl consumed)
      if consumed > width:
        let kept = width-shift
        let high = int(payload) shr kept
        let expected = if signed(kind) and (int(payload) and (1 shl (kept-1))) != 0:
            (1 shl (7-kept))-1 else: 0
        if high != expected: raise newException(ValueError, "binary LEB overflow")
      if width < 64: result.value = result.value and ((1'u64 shl width)-1)
      return
  raise newException(ValueError, "unterminated binary LEB")

proc allocateBinarySourceClaim*(c: var Circuit, data: openArray[byte], capacity: int,
    publicInputs = true): BinarySourceClaim =
  let values = binarySourceInputs(data, capacity)
  template input(value: Scalar): Linear =
    if publicInputs: c.publicInput(value) else: c.allocate(value)
  result.length = input(values[0])
  for i in 1..<values.len: result.limbs.add input(values[i])

proc constrainBinarySource*(c: var Circuit, data: openArray[byte], capacity: int,
    claim: BinarySourceClaim): BinarySource =
  if capacity < data.len or capacity < 0 or claim.limbs.len != binarySourceLimbCount(capacity):
    raise newException(ValueError, "binary source dimensions differ")
  result.length = claim.length
  result.data = @data
  discard c.constrainUnsigned(claim.length, 32)
  when defined(zkbuildSourceAudit):
    let sourceFirstWire = c.values.len
    let sourceFirstGate = c.constraints.len
    let sourceLengthRange = c.auditRangeSource(claim.length,32)
  var previous = constant(1)
  var count, packed = constant(0)
  var weight = scalar(1)
  var limb = 0
  for i in 0..<capacity:
    let active = c.bit(i < data.len)
    let value = c.allocate(scalar(if i < data.len: data[i] else: 0'u8))
    discard c.constrainUnsigned(value, 8)
    c.constrain(active, constant(1)-previous, constant(0))
    c.constrain(constant(1)-active, value, constant(0))
    count = c.materialize(count+active)
    previous = active
    result.entries.add ReadOnlyWires(active: active, address: active.scale(scalar(i)), value: value)
    result.values.add(if i < data.len: ReadOnlyEntry(active: true, address: uint64(i), value: uint64(data[i])) else: ReadOnlyEntry())
    packed = packed+value.scale(weight)
    weight = weight*scalar(256)
    if i mod 31 == 30 or i+1 == capacity:
      c.assertEqual(packed, claim.limbs[limb])
      inc limb
      packed = constant(0)
      weight = scalar(1)
  c.assertEqual(count, claim.length)
  when defined(zkbuildSourceAudit):
    var outputs: seq[Linear]
    for row in result.entries:
      outputs.add row.active
      outputs.add row.address
      outputs.add row.value
    c.recordBinarySource(sourceFirstWire,sourceFirstGate,capacity,claim.length,
      claim.limbs,outputs,sourceLengthRange)
  when defined(zkbuildByteMemoryAudit):
    result.auditSourceIndex = c.binarySourceRecords.high

proc readToken*(source: BinarySource, position: uint32, kind: BinaryReadKind): BinaryRead =
  readBinaryToken(source.data, position, kind)

proc constrainBinaryRead*(c: var Circuit, source: var BinarySource,
    kind: BinaryReadKind, active, position, expected: Linear, hint: BinaryRead): Linear =
  ## Returns the authenticated encoded length. `kind` is a profile constant;
  ## callers select alternative layouts with constrained Boolean activations.
  when defined(zkbuildBodySourceAudit):
    let sourceBlockFirst = c.gadgets.len
    let sourceBlockGate = c.constraints.len
  when defined(zkbuildTokenAudit):
    var token = TokenAudit(kind: ord(kind),sourceIndex: source.auditSourceIndex,queryStart: source.queries.len,
      firstWire: c.values.len,firstGate: c.constraints.len,activeMode: active,position: position,
      expected: expected,sourceLength: source.length)
  c.constrainBoolean(active)
  discard c.constrainUnsigned(position, 32)
  when defined(zkbuildTokenAudit): token.positionRange = c.snapshotRangeUse()
  let width = readWidth(kind)
  let capacity = readCapacity(kind)
  let length = c.allocate(scalar(hint.length))
  discard c.constrainUnsigned(length, 4)
  when defined(zkbuildTokenAudit):
    token.length = length
    token.lengthRange = c.snapshotRangeUse()
    token.choiceStart = c.values.len
  var choices: seq[Linear]
  var total = constant(0)
  for i in 1..capacity:
    let selected = c.zeroIndicator(length-constant(i))
    choices.add selected
    total = total+selected
  c.assertEqual(total, active)
  c.constrain(constant(1)-active, length, constant(0))
  let bits = c.constrainUnsigned(expected, width)
  when defined(zkbuildTokenAudit): token.valueRange = c.snapshotRangeUse()
  c.constrain(constant(1)-active, expected, constant(0))
  let sign = if signed(kind): bits[width-1] else: constant(0)
  var present = active
  for i in 0..<capacity:
    let value = c.allocate(scalar(hint.bytes[i]))
    let byteBits = c.constrainUnsigned(value, 8)
    when defined(zkbuildTokenAudit):
      var row = TokenRowAudit(value: value,byteRange: c.snapshotRangeUse())
    let address = c.multiply(present, position+constant(i))
    source.queries.add ReadOnlyWires(active: present, address: address, value: value)
    source.queryValues.add(if hint.length > uint8(i): ReadOnlyEntry(active: true,
      address: uint64(hint.position)+uint64(i), value: uint64(hint.bytes[i])) else: ReadOnlyEntry())
    let remaining = c.multiply(present, source.length-position-constant(i+1))
    discard c.constrainUnsigned(remaining, 32)
    when defined(zkbuildTokenAudit): row.remainingRange = c.snapshotRangeUse()
    let next = c.materialize(present-choices[i])
    when defined(zkbuildTokenAudit):
      row.address = address
      row.remaining = remaining
      row.next = next
      row.extrasStart = c.values.len
      token.rows.add row
    if leb(kind):
      c.assertEqual(byteBits[7], next)
      for j in 0..6:
        let index = 7*i+j
        if index < width:
          c.constrain(present, byteBits[j]-bits[index], constant(0))
          c.constrain(constant(1)-present, bits[index]-sign, constant(0))
        else: c.constrain(present, byteBits[j]-sign, constant(0))
      if signed(kind): c.constrain(choices[i], byteBits[6]-sign, constant(0))
    else:
      for j in 0..7: c.assertEqual(byteBits[j], bits[8*i+j])
    present = next
  if not leb(kind): c.assertEqual(length, active.scale(scalar(capacity)))
  c.assertEqual(present, constant(0))
  when defined(zkbuildTokenAudit): c.recordToken(token)
  when defined(zkbuildBodySourceAudit):
    if c.sourceProgramActive:
      c.sourceProgramBlocks.add SourceBlockAudit(kind: 0,index: c.tokenRecords.high,
        firstPrimitive: sourceBlockFirst,lastPrimitive: c.gadgets.len,
        firstGate: sourceBlockGate,lastGate: c.constraints.len)
  length

proc finishBinaryReads*(c: var Circuit, source: BinarySource) =
  let witness = buildReadOnlyWitness(source.values, source.queryValues)
  c.constrainReadOnly(source.entries, source.queries, witness, 32, 8)
  when defined(zkbuildByteMemoryAudit):
    var queries: seq[Linear]
    for q in source.queries:
      queries.add q.active
      queries.add q.address
      queries.add q.value
    c.recordBinaryReadMemory(source.auditSourceIndex,c.memoryRecords.high,queries)

func binaryReadMode*(kind: BinaryReadKind): int = ord(kind)+1

proc constrainVariantRead*(c: var Circuit, source: var BinarySource,
    mode, position, expected: Linear, hint: BinaryRead): Linear =
  ## Mode zero is absent; modes 1..7 select the primitive readers above.
  ## A single byte-query stream and matrix serve every opcode layout.
  when defined(zkbuildBodySourceAudit):
    let sourceBlockFirst = c.gadgets.len
    let sourceBlockGate = c.constraints.len
  when defined(zkbuildTokenAudit):
    var token = TokenAudit(kind: 7,sourceIndex: source.auditSourceIndex,queryStart: source.queries.len,
      firstWire: c.values.len,firstGate: c.constraints.len,selectorStart: c.values.len,
      activeMode: mode,position: position,expected: expected,sourceLength: source.length)
  var selected: array[BinaryReadKind, Linear]
  let absent = c.zeroIndicator(mode)
  var active = constant(0)
  for kind in BinaryReadKind:
    selected[kind] = c.zeroIndicator(mode-constant(binaryReadMode(kind)))
    active = active+selected[kind]
  c.assertEqual(absent+active, constant(1))
  discard c.constrainUnsigned(position, 32)
  when defined(zkbuildTokenAudit): token.positionRange = c.snapshotRangeUse()
  let bits = c.constrainUnsigned(expected, 64)
  when defined(zkbuildTokenAudit): token.valueRange = c.snapshotRangeUse()
  let length = c.allocate(scalar(hint.length))
  discard c.constrainUnsigned(length, 4)
  when defined(zkbuildTokenAudit):
    token.length = length
    token.lengthRange = c.snapshotRangeUse()
    token.choiceStart = c.values.len
  var choices: array[10, Linear]
  var total = constant(0)
  for i in 0..9:
    choices[i] = c.zeroIndicator(length-constant(i+1))
    total = total+choices[i]
  c.assertEqual(total, active)
  c.constrain(absent, length, constant(0))
  c.constrain(selected[brByte], length-constant(1), constant(0))
  c.constrain(selected[brLittle32], length-constant(4), constant(0))
  c.constrain(selected[brLittle64], length-constant(8), constant(0))
  var long = constant(0)
  for i in 5..9: long = long+choices[i]
  c.constrain(selected[brU32]+selected[brS32]+selected[brS33], long, constant(0))
  let raw = selected[brByte]+selected[brLittle32]+selected[brLittle64]
  let leb = active-raw
  let signed = selected[brS32]+selected[brS33]+selected[brS64]
  when defined(zkbuildTokenAudit): token.signStart = c.values.len
  let sign = c.multiply(selected[brS32], bits[31])+c.multiply(selected[brS33], bits[32])+
    c.multiply(selected[brS64], bits[63])
  for i in 0..63:
    let available = if i < 8: active
      elif i < 32: active-selected[brByte]
      elif i == 32: selected[brS33]+selected[brS64]+selected[brLittle64]
      else: selected[brS64]+selected[brLittle64]
    c.constrain(constant(1)-available, bits[i], constant(0))
  var present = active
  for i in 0..9:
    let value = c.allocate(scalar(hint.bytes[i]))
    let byteBits = c.constrainUnsigned(value, 8)
    when defined(zkbuildTokenAudit):
      var row = TokenRowAudit(value: value,byteRange: c.snapshotRangeUse())
    let address = c.multiply(present, position+constant(i))
    source.queries.add ReadOnlyWires(active: present,address: address,value: value)
    source.queryValues.add(if int(hint.length) > i: ReadOnlyEntry(active: true,
      address: uint64(hint.position)+uint64(i), value: uint64(hint.bytes[i])) else: ReadOnlyEntry())
    let remaining = c.multiply(present, source.length-position-constant(i+1))
    discard c.constrainUnsigned(remaining, 32)
    when defined(zkbuildTokenAudit): row.remainingRange = c.snapshotRangeUse()
    let next = c.materialize(present-choices[i])
    when defined(zkbuildTokenAudit):
      row.address = address
      row.remaining = remaining
      row.next = next
      row.extrasStart = c.values.len
      token.rows.add row
    c.constrain(leb, byteBits[7]-next, constant(0))
    let lebPresent = c.multiply(leb, present)
    let rawPresent = c.multiply(raw, present)
    for j in 0..6:
      let index = 7*i+j
      let inWidth = if index < 32: leb
        elif index == 32: selected[brS33]+selected[brS64]
        elif index < 64: selected[brS64]
        else: constant(0)
      let data = if index < 64: c.multiply(inWidth, bits[index]) else: constant(0)
      let target = data+c.multiply(leb-inWidth, sign)
      c.constrain(lebPresent, byteBits[j]-target, constant(0))
      c.constrain(leb-lebPresent, target-sign, constant(0))
    c.constrain(c.multiply(signed, choices[i]), byteBits[6]-sign, constant(0))
    if i < 8:
      for j in 0..7:
        c.constrain(rawPresent, byteBits[j]-bits[8*i+j], constant(0))
        c.constrain(raw-rawPresent, bits[8*i+j], constant(0))
    present = next
  c.assertEqual(present, constant(0))
  when defined(zkbuildTokenAudit): c.recordToken(token)
  when defined(zkbuildBodySourceAudit):
    if c.sourceProgramActive:
      c.sourceProgramBlocks.add SourceBlockAudit(kind: 0,index: c.tokenRecords.high,
        firstPrimitive: sourceBlockFirst,lastPrimitive: c.gadgets.len,
        firstGate: sourceBlockGate,lastGate: c.constraints.len)
  length
