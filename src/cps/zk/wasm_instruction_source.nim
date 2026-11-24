## Source instruction decoding for every currently admitted binary layout.
## Variable payloads use the same authenticated byte source as declarations.
import std/tables
import ../wasm/[types, validate, block_types, opcode_encoding]
import r1cs, range_check, read_only_memory, memory_consistency, opcode_lookup
import wasm_binary_source, wasm_binary_code, wasm_signature_environment
import wasm_branch_environment, wasm_catch_environment, wasm_memory_metadata
import wasm_instruction_events

type
  CatchSourceRead* = object
    kind*, tag*, depth*: BinaryRead
  InstructionSourceRow* = object
    opcode*: uint16
    primary*, secondary*: uint32
    pad*: uint64
    start*, finish*: uint32
    prefix*, subopcode*, first*, second*: BinaryRead
    labels*: seq[BinaryRead]
    catches*: seq[CatchSourceRead]
  InstructionSource* = object
    bodies*: seq[seq[InstructionSourceRow]]
  SourceInstructionWires* = object
    opcode*, primary*, secondary*, pad*, start*, finish*: Linear

func operandModes*(form: ImmediateForm): tuple[first, second: int] =
  case form
  of efNone: discard
  of efU32, efBranchTable: result.first = binaryReadMode(brU32)
  of efPair: result = (binaryReadMode(brU32), binaryReadMode(brU32))
  of efBlock: result.first = binaryReadMode(brS33)
  of efTryTable: result = (binaryReadMode(brS33), binaryReadMode(brU32))
  of efTypedSelect: result = (binaryReadMode(brU32), binaryReadMode(brByte))
  of efS32: result.first = binaryReadMode(brS32)
  of efS64: result.first = binaryReadMode(brS64)
  of efLittle32: result.first = binaryReadMode(brLittle32)
  of efLittle64: result.first = binaryReadMode(brLittle64)
  of efReferenceType, efLane: result.first = binaryReadMode(brByte)
  of efVector16: result = (binaryReadMode(brLittle64), binaryReadMode(brLittle64))

proc encodingTable(): OpcodeLookup[8] =
  var values = newSeq[array[8, int]](65536)
  for code in 0..65535:
    let encoding = opcodeEncoding(uint16(code))
    let modes = operandModes(encoding.form)
    values[code] = [int(encoding.present), int(encoding.prefix), int(encoding.prefixed),
      int(encoding.subopcode), ord(encoding.form), int(encoding.swapPair), modes.first, modes.second]
  buildOpcodeLookup(values)

let encodings = encodingTable()

proc buildInstructionSource*(module: WasmModule, data: openArray[byte], code: CodeSource): InstructionSource =
  if code.bodies.len < module.codes.len: raise newException(ValueError, "source body count differs")
  for i in module.codes.len..<code.bodies.len:
    if code.bodies[i].active: raise newException(ValueError,"unexpected active source body")
  template read(position: var uint32, kind: BinaryReadKind): BinaryRead =
    block:
      let token = readBinaryToken(data, position, kind)
      if uint64(position)+uint64(token.length) > uint64(high(uint32)):
        raise newException(ValueError, "source instruction position overflow")
      position += uint32(token.length)
      token
  for body, function in module.codes:
    if uint64(function.code.code.len) >= uint64(high(uint32)):
      raise newException(ValueError, "source instruction count overflow")
    var position = code.bodies[body].instructions
    var rows: seq[InstructionSourceRow]
    for pc in 0..function.code.code.len:
      let instruction = if pc < function.code.code.len: function.code.code[pc] else: Instr(op: opEnd)
      let encoding = opcodeEncoding(uint16(ord(instruction.op)))
      if not encoding.present: raise newException(ValueError, "unencoded source opcode")
      var row = InstructionSourceRow(opcode: uint16(ord(instruction.op)), primary: instruction.imm1,
        secondary: instruction.imm2, pad: (if pc < function.code.code.len: function.code.normalizedBlockPad(pc) else: 0), start: position)
      row.prefix = read(position, brByte)
      if encoding.prefixed: row.subopcode = read(position, brU32)
      let modes = operandModes(encoding.form)
      if modes.first != 0: row.first = read(position, BinaryReadKind(modes.first-1))
      if modes.second != 0: row.second = read(position, BinaryReadKind(modes.second-1))
      if encoding.form == efVector16:
        if uint64(instruction.imm1) >= uint64(function.code.v128Consts.len):
          raise newException(ValueError, "missing source vector constant")
        # The reader bytes come from the source; its claimed words must come
        # from the decoded pool consumed by the compiler. Allocating both from
        # source bytes alone would leave a substituted pool unconstrained.
        let vector = function.code.v128Consts[int(instruction.imm1)]
        row.first.value = 0
        row.second.value = 0
        for i in 0..<8:
          row.first.value = row.first.value or (uint64(vector[i]) shl (8*i))
          row.second.value = row.second.value or (uint64(vector[8+i]) shl (8*i))
      if encoding.form == efBranchTable:
        if uint64(instruction.imm1) >= uint64(function.code.brTables.len): raise newException(ValueError, "missing source branch bank")
        for _ in 0..function.code.brTables[int(instruction.imm1)].labels.len:
          row.labels.add read(position, brU32)
      elif encoding.form == efTryTable:
        if uint64(instruction.imm2) >= uint64(function.code.catchTables.len): raise newException(ValueError, "missing source catch bank")
        for clause in function.code.catchTables[int(instruction.imm2)]:
          var item = CatchSourceRead(kind: read(position, brByte))
          if clause.kind in {ckCatch, ckCatchRef}: item.tag = read(position, brU32)
          item.depth = read(position, brU32)
          row.catches.add item
      row.finish = position
      rows.add row
    result.bodies.add rows

proc allocateInstructionSource*(c: var Circuit, source: InstructionSource): seq[seq[SourceInstructionWires]] =
  for body in source.bodies:
    var rows: seq[SourceInstructionWires]
    for row in body:
      rows.add SourceInstructionWires(opcode: c.allocate(scalar(row.opcode)),
        primary: c.allocate(scalar(row.primary)), secondary: c.allocate(scalar(row.secondary)),
        pad: c.allocate(scalar(row.pad)), start: c.allocate(scalar(row.start)), finish: c.allocate(scalar(row.finish)))
    result.add rows

type InstructionDecode* = object
  after*, branch*, catching*, vector*, blockLike*, conditional*: Linear
  count*: Linear

proc constrainInstructionDecode*(c: var Circuit, source: var BinarySource,
    row: SourceInstructionWires, hint: InstructionSourceRow,
    branchIndex, catchIndex, vectorIndex: Linear, active = constant(1)): InstructionDecode =
  ## One instruction's fixed fields. Variable lists and control destinations
  ## must also pass constrainInstructionSource before this is a full binding.
  when defined(zkbuildInstructionSourceAudit):
    let decodeMarker = c.beginSourceProgram()
    var decodeAudit = InstructionDecodeAudit(inputs: copyAuditExpressions([active,branchIndex,catchIndex,vectorIndex,
      row.opcode,row.primary,row.secondary,row.pad,row.start,row.finish]))
  let encoding = c.constrainLookup(encodings, row.opcode)
  c.constrainBoolean(active)
  c.assertEqual(encoding[0], constant(1))
  discard c.constrainUnsigned(row.primary, 32)
  discard c.constrainUnsigned(row.secondary, 32)
  discard c.constrainUnsigned(row.pad, 33)
  discard c.constrainUnsigned(row.start, 32)
  discard c.constrainUnsigned(row.finish, 32)
  discard c.constrainBinaryRead(source, brByte, active, row.start, c.multiply(active,encoding[1]), hint.prefix)
  let prefixed = c.multiply(active,encoding[2])
  let subSize = c.constrainBinaryRead(source, brU32, prefixed,
    c.multiply(prefixed, row.start+constant(1)), c.multiply(prefixed, encoding[3]), hint.subopcode)
  var cursor = c.materialize(row.start+active+subSize)
  let first = c.allocate(scalar(hint.first.value))
  let second = c.allocate(scalar(hint.second.value))
  when defined(zkbuildInstructionSourceAudit): decodeAudit.auxiliary = copyAuditExpressions([first,second])
  let firstSize = c.constrainVariantRead(source, c.multiply(active,encoding[6]), cursor, first, hint.first)
  cursor = c.materialize(cursor+firstSize)
  let secondSize = c.constrainVariantRead(source, c.multiply(active,encoding[7]), cursor, second, hint.second)
  cursor = c.materialize(cursor+secondSize)
  var form: array[ImmediateForm, Linear]
  for kind in ImmediateForm: form[kind] = c.multiply(active,c.zeroIndicator(encoding[4]-constant(ord(kind))))
  result.branch = form[efBranchTable]
  result.catching = form[efTryTable]
  result.vector = form[efVector16]
  result.blockLike = form[efBlock]+form[efTryTable]
  result.conditional = c.multiply(active,c.zeroIndicator(row.opcode-constant(ord(opIf))))
  result.count = c.selectWire(result.branch, first, second)
  let words = c.splitSignatureHeads(first)
  let ordinary = form[efU32]+form[efS32]+form[efLittle32]+form[efReferenceType]+form[efLane]
  let wide = form[efS64]+form[efLittle64]
  let pairFirst = c.selectWire(encoding[5], second, first)
  let pairSecond = c.selectWire(encoding[5], first, second)
  c.assertEqual(row.primary, c.multiply(ordinary, first)+c.multiply(wide, words.params)+
    c.multiply(form[efPair], pairFirst)+c.multiply(form[efTypedSelect], second)+
    c.multiply(result.branch, branchIndex)+c.multiply(result.vector, vectorIndex)+c.multiply(result.blockLike, row.primary))
  c.assertEqual(row.secondary, c.multiply(wide, words.results)+c.multiply(form[efPair], pairSecond)+
    c.multiply(result.catching, catchIndex)+c.multiply(result.conditional, row.secondary))
  c.constrain(form[efTypedSelect], first-constant(1), constant(0))
  let bits = c.constrainUnsigned(first, 64)
  let positive = constant(1)-bits[32]
  var allowed = positive
  var blockPad = c.multiply(positive, first+constant(256))
  for (value, pad) in [(64, 0), (1, 1), (2, 2), (3, 3), (4, 4), (5, 5), (16, 6), (17, 7)]:
    let matches = c.zeroIndicator(first-constant((1'u64 shl 33)-uint64(value)))
    allowed = allowed+matches
    blockPad = blockPad+matches.scale(scalar(pad))
  c.constrain(result.blockLike, allowed-constant(1), constant(0))
  c.constrain(c.multiply(result.blockLike, bits[32]), firstSize-constant(1), constant(0))
  c.assertEqual(row.pad, c.multiply(result.blockLike, blockPad))
  result.after = cursor
  when defined(zkbuildInstructionSourceAudit):
    decodeAudit.outputs = copyAuditExpressions([result.after,result.branch,result.catching,result.vector,
      result.blockLike,result.conditional,result.count])
    decodeAudit.program = c.endSourceProgram(decodeMarker)
    let decodeIndex = c.instructionDecodeRecords.len
    c.instructionDecodeRecords.add decodeAudit
    if decodeMarker.parentActive:
      c.sourceProgramBlocks.add SourceBlockAudit(kind: 3,index: decodeIndex,
        firstPrimitive: decodeMarker.firstPrimitive,lastPrimitive: c.gadgets.len,
        firstGate: decodeMarker.firstGate,lastGate: c.constraints.len)

proc contents(entries: openArray[ReadOnlyEntry]): Table[uint64, uint64] =
  for entry in entries:
    if entry.active: result[entry.address] = entry.value

proc pack(c: var Circuit, bits: openArray[Linear]): Linear =
  var value = constant(0)
  for i, bit in bits: value = value+bit.scale(scalar(1'u64 shl i))
  c.materialize(value)

proc constrainInstructionSource*(c: var Circuit, source: var BinarySource,
    bodySpans: CodeSpans, rows: seq[seq[SourceInstructionWires]], hint: InstructionSource,
    firstFunction: Linear, branches: BranchEnvironmentWires, branchValues: BranchEnvironment,
    catches: CatchEnvironmentWires, catchValues: CatchEnvironment,
    memory: MemoryEnvironmentWires, memoryValues: MemoryEnvironment,
    events: openArray[InstructionEventWires], eventValues: openArray[InstructionEventRow],
    primary, secondary, pads: openArray[Linear]): void =
  ## bodySpans must come from constrainCodeSource. The caller additionally
  ## constrains the validation schedule and total completed-function count.
  if rows.len != hint.bodies.len or rows.len != bodySpans.instructions.len or
      events.len != eventValues.len or events.len != primary.len or events.len != secondary.len or events.len != pads.len:
    raise newException(ValueError, "source instruction dimensions differ")
  when defined(zkbuildInstructionSourceAudit):
    let sourceMarker = c.beginSourceProgram()
    var sourceAudit = InstructionSourceAudit(flat: false,firstFunction: copyAuditExpressions([firstFunction])[0])
    for row in bodySpans.instructions: sourceAudit.spans.add copyAuditExpressions([row.active,row.address,row.value])
    for instructions in rows: sourceAudit.bodySizes.add instructions.len
    for i, row in events:
      sourceAudit.events.add copyAuditExpressions([row.control.operand.kind,row.control.operand.functionIndex,row.pc,row.opcode,primary[i],secondary[i],pads[i]])
  discard c.constrainUnsigned(firstFunction, 32)
  let firstBytes = encodeScalar(firstFunction.evaluate(c.values))
  var first: uint64
  for i in 24..31: first = (first shl 8) or uint64(firstBytes[i])
  let branchBanks = contents(branchValues.banks)
  let branchNodes = contents(branchValues.nodes)
  let catchBanks = contents(catchValues.banks)
  let catchLinks = contents(catchValues.links)
  let catchClauses = contents(catchValues.clauses)
  let vectors = contents(memoryValues.vectorCounts)
  var infoEntries, immediateEntries, lastEntries, branchCountEntries, catchCountEntries: seq[ReadOnlyWires]
  var infoValues, immediateValues, lastValues, branchCountValues, catchCountValues: seq[ReadOnlyEntry]
  for body, instructions in rows:
    if instructions.len != hint.bodies[body].len or instructions.len == 0:
      raise newException(ValueError, "missing source instruction or root end")
    let function = firstFunction+constant(body)
    let hostFunction = first+uint64(body)
    discard c.constrainUnsigned(function, 32)
    for pc, row in instructions:
      let raw = hint.bodies[body][pc]
      let key = function.scale(scalar(1'u64 shl 32))+constant(pc)
      infoEntries.add ReadOnlyWires(active: constant(1), address: key, value: row.opcode+row.pad.scale(scalar(65536)))
      immediateEntries.add ReadOnlyWires(active: constant(1), address: key, value: row.primary+row.secondary.scale(scalar(1'u64 shl 32)))
      infoValues.add ReadOnlyEntry(active: true, address: (hostFunction shl 32)+uint64(pc), value: uint64(raw.opcode)+(raw.pad shl 16))
      immediateValues.add ReadOnlyEntry(active: true, address: (hostFunction shl 32)+uint64(pc), value: uint64(raw.primary)+(uint64(raw.secondary) shl 32))
    lastEntries.add ReadOnlyWires(active: constant(1), address: function, value: constant(instructions.len-1))
    lastValues.add ReadOnlyEntry(active: true, address: hostFunction, value: uint64(instructions.len-1))
  let infoMap = contents(infoValues)
  let immediateMap = contents(immediateValues)
  let lastMap = contents(lastValues)
  var branchBankQueries, branchNodeQueries, catchBankQueries, catchLinkQueries, catchClauseQueries, vectorQueries: seq[ReadOnlyWires]
  var branchBankReads, branchNodeReads, catchBankReads, catchLinkReads, catchClauseReads, vectorReads: seq[ReadOnlyEntry]
  var infoQueries, immediateQueries, lastQueries: seq[ReadOnlyWires]
  var infoReads, immediateReads, lastReads: seq[ReadOnlyEntry]
  var frameAccesses: seq[MemoryAccessWires]
  var frameValues: seq[MemoryAccess]
  template query(bank: untyped, values: untyped, lookup: untyped,
      enabled, key: Linear, hostActive: bool, hostKey: uint64): Linear =
    block:
      let actual = if hostActive: lookup.getOrDefault(hostKey) else: 0'u64
      let value = c.allocate(scalar(actual))
      bank.add ReadOnlyWires(active: enabled, address: c.multiply(enabled, key), value: value)
      values.add(if hostActive: ReadOnlyEntry(active: true, address: hostKey, value: actual) else: ReadOnlyEntry())
      value
  for body, instructions in rows:
    let function = firstFunction+constant(body)
    let hostFunction = first+uint64(body)
    c.assertEqual(bodySpans.instructions[body].active, constant(1))
    c.assertEqual(bodySpans.instructions[body].address, function)
    let span = c.splitSignatureHeads(bodySpans.instructions[body].value)
    var position = span.params
    var branchIndex, catchIndex, vectorIndex, depth = constant(0)
    var hostBranches, hostCatches, hostVectors: uint64
    var stack: seq[tuple[pc: uint32, conditional, seen: bool]]
    for pc, row in instructions:
      let raw = hint.bodies[body][pc]
      c.assertEqual(row.start, position)
      when defined(zkbuildInstructionSourceAudit):
        var rowAudit = InstructionRowAudit(fields: copyAuditExpressions([constant(1),function,constant(pc),row.opcode,
          row.primary,row.secondary,row.pad,row.start,row.finish]),decode: c.instructionDecodeRecords.len,
          labelCount: raw.labels.len,catchCount: raw.catches.len)
      let decoded = c.constrainInstructionDecode(source, row, raw, branchIndex, catchIndex, vectorIndex)
      var after = decoded.after
      let isBranch = raw.opcode == uint16(ord(opBrTable))
      let isCatch = raw.opcode == uint16(ord(opTryTable))
      let branchHead = query(branchBankQueries, branchBankReads, branchBanks, decoded.branch,
        function.scale(scalar(1'u64 shl 32))+branchIndex, isBranch, (hostFunction shl 32)+hostBranches)
      var branchCursor = branchHead
      var hostBranchCursor = if isBranch: branchBanks.getOrDefault((hostFunction shl 32)+hostBranches) else: 0'u64
      c.constrain(decoded.branch, decoded.count+constant(1)-constant(raw.labels.len), constant(0))
      for label in raw.labels:
        let node = query(branchNodeQueries, branchNodeReads, branchNodes, decoded.branch, branchCursor, isBranch, hostBranchCursor)
        let parts = c.splitSignatureHeads(node)
        let length = c.constrainBinaryRead(source, brU32, decoded.branch,
          c.multiply(decoded.branch, after), parts.params, label)
        after = c.materialize(after+length)
        branchCursor = parts.results
        hostBranchCursor = branchNodes.getOrDefault(hostBranchCursor) shr 32
      c.assertEqual(branchCursor, constant(0))
      let catchHead = query(catchBankQueries, catchBankReads, catchBanks, decoded.catching,
        function.scale(scalar(1'u64 shl 32))+catchIndex, isCatch, (hostFunction shl 32)+hostCatches)
      var catchCursor = catchHead
      var hostCatchCursor = if isCatch: catchBanks.getOrDefault((hostFunction shl 32)+hostCatches) else: 0'u64
      c.constrain(decoded.catching, decoded.count-constant(raw.catches.len), constant(0))
      for clause in raw.catches:
        let link = query(catchLinkQueries, catchLinkReads, catchLinks, decoded.catching, catchCursor, isCatch, hostCatchCursor)
        let value = query(catchClauseQueries, catchClauseReads, catchClauses, decoded.catching, catchCursor, isCatch, hostCatchCursor)
        let linkBits = c.constrainUnsigned(link, 34)
        let kind = c.pack(linkBits[0..1])
        let next = c.pack(linkBits[2..33])
        let parts = c.splitSignatureHeads(value)
        let tagged = c.multiply(decoded.catching, constant(1)-linkBits[1])
        let kindLength = c.constrainBinaryRead(source, brByte, decoded.catching,
          c.multiply(decoded.catching, after), kind, clause.kind)
        after = c.materialize(after+kindLength)
        c.constrain(c.multiply(decoded.catching, linkBits[1]), parts.params, constant(0))
        let tagLength = c.constrainBinaryRead(source, brU32, tagged,
          c.multiply(tagged, after), c.multiply(tagged, parts.params), clause.tag)
        after = c.materialize(after+tagLength)
        let depthLength = c.constrainBinaryRead(source, brU32, decoded.catching,
          c.multiply(decoded.catching, after), parts.results, clause.depth)
        after = c.materialize(after+depthLength)
        catchCursor = next
        hostCatchCursor = catchLinks.getOrDefault(hostCatchCursor) shr 2
      c.assertEqual(catchCursor, constant(0))
      c.assertEqual(row.finish, after)
      position = row.finish
      branchIndex = c.materialize(branchIndex+decoded.branch)
      catchIndex = c.materialize(catchIndex+decoded.catching)
      vectorIndex = c.materialize(vectorIndex+decoded.vector)
      if isBranch: inc hostBranches
      if isCatch: inc hostCatches
      if raw.opcode == uint16(ord(opV128Const)): inc hostVectors
      # Authenticate source-control matching independently of the typed stack.
      let ending = c.zeroIndicator(row.opcode-constant(ord(opEnd)))
      let otherwise = c.zeroIndicator(row.opcode-constant(ord(opElse)))
      let empty = c.zeroIndicator(depth)
      let innerEnd = c.multiply(ending, constant(1)-empty)
      let rootEnd = c.multiply(ending, empty)
      c.assertEqual(rootEnd, constant(ord(pc == instructions.high)))
      c.constrain(otherwise, empty, constant(0))
      let readActive = innerEnd+otherwise
      let hostRead = raw.opcode in [uint16(ord(opEnd)), uint16(ord(opElse))] and stack.len != 0
      let frame = if hostRead: stack[^1] else: (0'u32, false, false)
      let hostFrame = uint64(frame.pc)+(uint64(ord(frame.conditional)) shl 32)+(uint64(ord(frame.seen)) shl 33)
      let frameValue = c.allocate(scalar(hostFrame))
      when defined(zkbuildInstructionSourceAudit): rowAudit.frame = copyAuditExpressions([frameValue])[0]
      let frameBits = c.constrainUnsigned(frameValue, 34)
      let framePc = c.pack(frameBits[0..31])
      let frameIf = frameBits[32]
      let frameSeen = frameBits[33]
      frameAccesses.add MemoryAccessWires(active: readActive, write: constant(0),
        address: c.multiply(readActive, function.scale(scalar(1'u64 shl 32))+depth-constant(1)), value: frameValue)
      frameValues.add(if hostRead: MemoryAccess(active: true, address: (hostFunction shl 32)+uint64(stack.len-1), value: hostFrame) else: MemoryAccess())
      let original = query(immediateQueries, immediateReads, immediateMap, readActive,
        function.scale(scalar(1'u64 shl 32))+framePc, hostRead, (hostFunction shl 32)+uint64(frame.pc))
      let offsets = c.splitSignatureHeads(original)
      c.constrain(innerEnd, offsets.params-constant(pc), constant(0))
      c.constrain(otherwise, frameIf-constant(1), constant(0))
      c.constrain(otherwise, frameSeen, constant(0))
      c.constrain(otherwise, offsets.results-constant(pc), constant(0))
      c.constrain(c.multiply(c.multiply(innerEnd, frameIf), constant(1)-frameSeen), offsets.results-constant(pc), constant(0))
      let writeActive = decoded.blockLike+otherwise
      let value = c.multiply(decoded.blockLike, constant(pc)+decoded.conditional.scale(scalar(1'u64 shl 32)))+
        c.multiply(otherwise, frameValue+constant(1'u64 shl 33))
      frameAccesses.add MemoryAccessWires(active: writeActive, write: writeActive,
        address: c.multiply(writeActive, function.scale(scalar(1'u64 shl 32))+depth-otherwise), value: value)
      var hostWrite: MemoryAccess
      if raw.opcode in [uint16(ord(opBlock)), uint16(ord(opLoop)), uint16(ord(opIf)), uint16(ord(opTryTable))]:
        hostWrite = MemoryAccess(active: true, write: true, address: (hostFunction shl 32)+uint64(stack.len),
          value: uint64(pc)+(uint64(ord(raw.opcode == uint16(ord(opIf)))) shl 32))
        stack.add (uint32(pc), raw.opcode == uint16(ord(opIf)), false)
      elif raw.opcode == uint16(ord(opElse)) and stack.len != 0:
        hostWrite = MemoryAccess(active: true, write: true, address: (hostFunction shl 32)+uint64(stack.len-1), value: hostFrame+(1'u64 shl 33))
        stack[^1].seen = true
      elif raw.opcode == uint16(ord(opEnd)) and stack.len != 0:
        stack.setLen(stack.len-1)
      frameValues.add hostWrite
      depth = c.materialize(depth+decoded.blockLike-innerEnd)
      discard c.constrainUnsigned(depth, 32)
      when defined(zkbuildInstructionSourceAudit): sourceAudit.rows.add rowAudit
    c.assertEqual(depth, constant(0))
    c.assertEqual(position, span.results)
    let poolCount = query(vectorQueries, vectorReads, vectors, constant(1), function, true, hostFunction)
    c.assertEqual(vectorIndex, poolCount)
    branchCountEntries.add ReadOnlyWires(active: constant(1), address: function, value: branchIndex)
    catchCountEntries.add ReadOnlyWires(active: constant(1), address: function, value: catchIndex)
    branchCountValues.add ReadOnlyEntry(active: true, address: hostFunction, value: hostBranches)
    catchCountValues.add ReadOnlyEntry(active: true, address: hostFunction, value: hostCatches)
  let branchCounts = contents(branchCountValues)
  let catchCounts = contents(catchCountValues)
  var branchCountQueries, catchCountQueries: seq[ReadOnlyWires]
  var branchCountReads, catchCountReads: seq[ReadOnlyEntry]
  for i, bank in branches.banks:
    let key = c.splitSignatureHeads(bank.address)
    let raw = branchValues.banks[i]
    let count = query(branchCountQueries, branchCountReads, branchCounts, bank.active, key.results, raw.active, raw.address shr 32)
    discard c.constrainUnsigned(c.multiply(bank.active, count-key.params-constant(1)), 32)
  for i, bank in catches.banks:
    let key = c.splitSignatureHeads(bank.address)
    let raw = catchValues.banks[i]
    let count = query(catchCountQueries, catchCountReads, catchCounts, bank.active, key.results, raw.active, raw.address shr 32)
    discard c.constrainUnsigned(c.multiply(bank.active, count-key.params-constant(1)), 32)
  for i, event in events:
    let raw = eventValues[i]
    discard c.constrainUnsigned(event.control.operand.functionIndex, 32)
    discard c.constrainUnsigned(event.pc, 32)
    discard c.constrainUnsigned(event.opcode, 16)
    discard c.constrainUnsigned(primary[i], 32)
    discard c.constrainUnsigned(secondary[i], 32)
    discard c.constrainUnsigned(pads[i], 33)
    let begin = c.zeroIndicator(event.control.operand.kind-constant(ord(veInstructionBegin)))
    let ending = c.zeroIndicator(event.control.operand.kind-constant(ord(veFunctionEnd)))
    let activeBegin = raw.control.operand.kind == uint8(ord(veInstructionBegin))
    let activeEnd = raw.control.operand.kind == uint8(ord(veFunctionEnd))
    let key = event.control.operand.functionIndex.scale(scalar(1'u64 shl 32))+event.pc
    let hostKey = (uint64(raw.control.operand.functionIndex) shl 32)+uint64(raw.pc)
    let info = query(infoQueries, infoReads, infoMap, begin, key, activeBegin, hostKey)
    let immediate = query(immediateQueries, immediateReads, immediateMap, begin, key, activeBegin, hostKey)
    c.constrain(begin, info-event.opcode-pads[i].scale(scalar(65536)), constant(0))
    c.constrain(begin, immediate-primary[i]-secondary[i].scale(scalar(1'u64 shl 32)), constant(0))
    let last = query(lastQueries, lastReads, lastMap, ending, event.control.operand.functionIndex, activeEnd, uint64(raw.control.operand.functionIndex))
    c.constrain(ending, last-event.pc, constant(0))
  when defined(zkbuildInstructionSourceAudit): sourceAudit.program = c.endSourceProgram(sourceMarker)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(branches.banks, branchBankQueries, buildReadOnlyWitness(branchValues.banks, branchBankReads), 64, 32)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(branches.nodes, branchNodeQueries, buildReadOnlyWitness(branchValues.nodes, branchNodeReads), 32, 64)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(catches.banks, catchBankQueries, buildReadOnlyWitness(catchValues.banks, catchBankReads), 64, 32)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(catches.links, catchLinkQueries, buildReadOnlyWitness(catchValues.links, catchLinkReads), 32, 34)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(catches.clauses, catchClauseQueries, buildReadOnlyWitness(catchValues.clauses, catchClauseReads), 32, 64)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(memory.vectorCounts, vectorQueries, buildReadOnlyWitness(memoryValues.vectorCounts, vectorReads), 32, 32)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(infoEntries, infoQueries, buildReadOnlyWitness(infoValues, infoReads), 64, 49)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(immediateEntries, immediateQueries, buildReadOnlyWitness(immediateValues, immediateReads), 64, 64)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(lastEntries, lastQueries, buildReadOnlyWitness(lastValues, lastReads), 32, 32)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(branchCountEntries, branchCountQueries, buildReadOnlyWitness(branchCountValues, branchCountReads), 32, 32)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(catchCountEntries, catchCountQueries, buildReadOnlyWitness(catchCountValues, catchCountReads), 32, 32)
  while frameValues.len < readOnlyCapacity(frameAccesses.len, 0): frameValues.add MemoryAccess()
  while frameAccesses.len < frameValues.len:
    frameAccesses.add MemoryAccessWires(active: constant(0), write: constant(0), address: constant(0), value: constant(0))
  when defined(zkbuildInstructionSourceAudit): sourceAudit.frameMemoryIndex = c.memoryRecords.len
  discard c.constrainMemory(frameAccesses, buildMemoryWitness(frameValues), 64, 34)
  when defined(zkbuildInstructionSourceAudit): c.instructionSourceRecords.add sourceAudit
