## Fixed-capacity source instruction and auxiliary streams. Function PCs,
## instruction counts, branch arities and catch arities are witness values.
## Only the capacities and code-body table size determine the matrix shape.
import std/tables
import ../wasm/[types,validate]
import r1cs, range_check, read_only_memory, memory_consistency
import wasm_binary_source, wasm_binary_code, wasm_instruction_source
import wasm_signature_environment, wasm_branch_environment, wasm_catch_environment
import wasm_memory_metadata, wasm_instruction_events

type
  FlatSourceRow* = object
    active*, functionEnd*: bool
    functionIndex*, pc*: uint32
    instruction*: InstructionSourceRow
    head*, count*: uint32
    after*: uint32
  FlatAuxRow* = object
    active*: bool
    owner*, ordinal*, node*, position*: uint32
    label*: BinaryRead
    clause*: CatchSourceRead
  FlatFunctionEnd* = object
    active*: bool
    functionIndex*, pc*, branches*, catches*, vectors*: uint32
  FlatInstructionSource* = object
    rows*: seq[FlatSourceRow]
    labels*, catches*: seq[FlatAuxRow]
    functions*: seq[FlatFunctionEnd]
  FlatSourceWires = object
    active*, functionIndex*, pc*: Linear
    instruction*: SourceInstructionWires
  FlatAuxWires = object
    active*, owner*, ordinal*, node*, position*: Linear
  FlatInstructionWires* = object
    rows: seq[FlatSourceWires]
    labels, catches: seq[FlatAuxWires]
    ends, branches, catchCounts, vectors: seq[ReadOnlyWires]

proc contents(entries: openArray[ReadOnlyEntry]): Table[uint64,uint64] =
  for row in entries:
    if row.active: result[row.address] = row.value

proc buildFlatInstructionSource*(module: WasmModule, data: openArray[byte], code: CodeSource,
    instructionCapacity, labelCapacity, catchCapacity: int): FlatInstructionSource =
  if uint64(data.len) > uint64(high(uint32)):
    raise newException(ValueError,"flat source exceeds u32 byte namespace")
  for capacity in [instructionCapacity,labelCapacity,catchCapacity]:
    if capacity < 0 or uint64(capacity) > uint64(high(uint32)):
      raise newException(ValueError,"invalid flat instruction capacity")
  let source = buildInstructionSource(module,data,code)
  let branches = buildBranchEnvironment(module)
  let catches = buildCatchEnvironment(module)
  let branchBanks = contents(branches.banks)
  let branchNodes = contents(branches.nodes)
  let catchBanks = contents(catches.banks)
  let catchLinks = contents(catches.links)
  var first = 0'u32
  for item in module.imports:
    if item.kind == ikFunc: inc first
  for body, instructions in source.bodies:
    if uint64(first)+uint64(body) > uint64(high(uint32)):
      raise newException(ValueError,"flat function namespace overflow")
    let fn = first+uint32(body)
    var endRow = FlatFunctionEnd(active: true,functionIndex: fn,pc: uint32(instructions.high))
    for pc, instruction in instructions:
      if result.rows.len >= instructionCapacity:
        raise newException(ValueError,"flat instruction source profile overflow")
      let owner = uint32(result.rows.len)
      var row = FlatSourceRow(active: true,functionEnd: pc == instructions.high,
        functionIndex: fn,pc: uint32(pc),instruction: instruction,
        after: instruction.start+uint32(instruction.prefix.length)+uint32(instruction.subopcode.length)+
          uint32(instruction.first.length)+uint32(instruction.second.length))
      if instruction.opcode == uint16(ord(opBrTable)):
        let key = (uint64(fn) shl 32)+uint64(endRow.branches)
        var node = branchBanks.getOrDefault(key)
        row.head = uint32(node)
        row.count = uint32(instruction.labels.len)
        for ordinal, label in instruction.labels:
          if result.labels.len >= labelCapacity:
            raise newException(ValueError,"flat branch source profile overflow")
          result.labels.add FlatAuxRow(active: true,owner: owner,ordinal: uint32(ordinal),
            node: uint32(node),position: label.position,label: label)
          node = branchNodes.getOrDefault(node) shr 32
        inc endRow.branches
      elif instruction.opcode == uint16(ord(opTryTable)):
        let key = (uint64(fn) shl 32)+uint64(endRow.catches)
        var node = catchBanks.getOrDefault(key)
        row.head = uint32(node)
        row.count = uint32(instruction.catches.len)
        for ordinal, clause in instruction.catches:
          if result.catches.len >= catchCapacity:
            raise newException(ValueError,"flat catch source profile overflow")
          result.catches.add FlatAuxRow(active: true,owner: owner,ordinal: uint32(ordinal),
            node: uint32(node),position: clause.kind.position,clause: clause)
          node = catchLinks.getOrDefault(node) shr 2
        inc endRow.catches
      elif instruction.opcode == uint16(ord(opV128Const)):
        inc endRow.vectors
      row.instruction.labels = @[]
      row.instruction.catches = @[]
      result.rows.add row
    result.functions.add endRow
  if result.rows.len > instructionCapacity or result.labels.len > labelCapacity or
      result.catches.len > catchCapacity:
    raise newException(ValueError,"flat instruction source profile overflow")
  result.rows.setLen(instructionCapacity)
  result.labels.setLen(labelCapacity)
  result.catches.setLen(catchCapacity)
  if code.flat: result.functions.setLen(code.bodies.len)

proc allocateFlatInstructionSource*(c: var Circuit, hint: FlatInstructionSource): FlatInstructionWires =
  for row in hint.rows:
    let value = row.instruction
    result.rows.add FlatSourceWires(active: c.allocate(scalar(ord(row.active))),
      functionIndex: c.allocate(scalar(row.functionIndex)),pc: c.allocate(scalar(row.pc)),
      instruction: SourceInstructionWires(opcode: c.allocate(scalar(value.opcode)),
        primary: c.allocate(scalar(value.primary)),secondary: c.allocate(scalar(value.secondary)),
        pad: c.allocate(scalar(value.pad)),start: c.allocate(scalar(value.start)),finish: c.allocate(scalar(value.finish))))
  template auxiliary(source: untyped, target: untyped) =
    for row in source:
      target.add FlatAuxWires(active: c.allocate(scalar(ord(row.active))),
        owner: c.allocate(scalar(row.owner)),ordinal: c.allocate(scalar(row.ordinal)),
        node: c.allocate(scalar(row.node)),position: c.allocate(scalar(row.position)))
  auxiliary(hint.labels,result.labels)
  auxiliary(hint.catches,result.catches)
  for row in hint.functions:
    let active = c.allocate(scalar(ord(row.active)))
    template entry(fieldValue: uint32): ReadOnlyWires =
      ReadOnlyWires(active: active,address: c.allocate(scalar(row.functionIndex)),value: c.allocate(scalar(fieldValue)))
    result.ends.add entry(row.pc)
    result.branches.add entry(row.branches)
    result.catchCounts.add entry(row.catches)
    result.vectors.add entry(row.vectors)

proc pack(c: var Circuit, bits: openArray[Linear]): Linear =
  var value = constant(0)
  for i, bit in bits: value = value+bit.scale(scalar(1'u64 shl i))
  c.materialize(value)

proc constrainFlatInstructionSource*(c: var Circuit, source: var BinarySource,
    bodySpans: CodeSpans, wires: FlatInstructionWires, hint: FlatInstructionSource,
    firstFunction: Linear, branches: BranchEnvironmentWires, branchValues: BranchEnvironment,
    catches: CatchEnvironmentWires, catchValues: CatchEnvironment,
    memory: MemoryEnvironmentWires, memoryValues: MemoryEnvironment,
    events: openArray[InstructionEventWires], eventValues: openArray[InstructionEventRow],
    primary,secondary,pads: openArray[Linear]) =
  if wires.rows.len != hint.rows.len or wires.labels.len != hint.labels.len or
      wires.catches.len != hint.catches.len or wires.ends.len != hint.functions.len or
      bodySpans.instructions.len != hint.functions.len or events.len != eventValues.len or
      events.len != primary.len or events.len != secondary.len or events.len != pads.len:
    raise newException(ValueError,"flat source dimensions differ")
  when defined(zkbuildInstructionSourceAudit):
    let sourceMarker = c.beginSourceProgram()
    var sourceAudit = InstructionSourceAudit(flat: true,firstFunction: copyAuditExpressions([firstFunction])[0])
    for row in bodySpans.instructions: sourceAudit.spans.add copyAuditExpressions([row.active,row.address,row.value])
    for i in 0..<wires.ends.len:
      var fields: seq[Linear]
      for row in [wires.ends[i],wires.branches[i],wires.catchCounts[i],wires.vectors[i]]:
        fields.add copyAuditExpressions([row.active,row.address,row.value])
      sourceAudit.functions.add fields
    for row in wires.labels: sourceAudit.labels.add copyAuditExpressions([row.active,row.owner,row.ordinal,row.node,row.position])
    for row in wires.catches: sourceAudit.catches.add copyAuditExpressions([row.active,row.owner,row.ordinal,row.node,row.position])
    for i, row in events:
      sourceAudit.events.add copyAuditExpressions([row.control.operand.kind,row.control.operand.functionIndex,row.pc,row.opcode,primary[i],secondary[i],pads[i]])
  discard c.constrainUnsigned(firstFunction,32)
  let branchBanks = contents(branchValues.banks)
  let branchNodes = contents(branchValues.nodes)
  let catchBanks = contents(catchValues.banks)
  let catchLinks = contents(catchValues.links)
  let catchClauses = contents(catchValues.clauses)
  var spanValues, endValues, branchCountValues, catchCountValues, vectorCountValues: seq[ReadOnlyEntry]
  var functionCount = constant(0)
  for i, row in hint.functions:
    let body = bodySpans.instructions[i]
    for entry in [wires.ends[i],wires.branches[i],wires.catchCounts[i],wires.vectors[i]]:
      c.assertEqual(entry.active,body.active)
      c.constrain(entry.active,entry.address-firstFunction-constant(i),constant(0))
    c.constrain(body.active,body.address-firstFunction-constant(i),constant(0))
    let encoded = encodeScalar(body.value.evaluate(c.values))
    var value: uint64
    for j in 24..31: value = (value shl 8)+uint64(encoded[j])
    spanValues.add ReadOnlyEntry(active: row.active,address: uint64(row.functionIndex),value: value)
    endValues.add ReadOnlyEntry(active: row.active,address: uint64(row.functionIndex),value: uint64(row.pc))
    branchCountValues.add ReadOnlyEntry(active: row.active,address: uint64(row.functionIndex),value: uint64(row.branches))
    catchCountValues.add ReadOnlyEntry(active: row.active,address: uint64(row.functionIndex),value: uint64(row.catches))
    vectorCountValues.add ReadOnlyEntry(active: row.active,address: uint64(row.functionIndex),value: uint64(row.vectors))
    functionCount = c.materialize(functionCount+body.active)
  let spans = contents(spanValues)
  let ends = contents(endValues)
  let branchCounts = contents(branchCountValues)
  let catchCounts = contents(catchCountValues)
  let vectorCounts = contents(vectorCountValues)
  let memoryVectors = contents(memoryValues.vectorCounts)
  var immediateLookup: Table[uint64,uint64]
  for row in hint.rows:
    if row.active:
      immediateLookup[(uint64(row.functionIndex) shl 32)+uint64(row.pc)] =
        uint64(row.instruction.primary)+(uint64(row.instruction.secondary) shl 32)
  var spanQueries,endQueries,branchCountQueries,catchCountQueries,vectorCountQueries,memoryVectorQueries: seq[ReadOnlyWires]
  var spanReads,endReads,branchCountReads,catchCountReads,vectorCountReads,memoryVectorReads: seq[ReadOnlyEntry]
  var branchQueries,catchQueries: seq[ReadOnlyWires]
  var branchReads,catchReads: seq[ReadOnlyEntry]
  var immediateQueries: seq[ReadOnlyWires]
  var immediateReads: seq[ReadOnlyEntry]
  var infoEntries,immediateEntries,positionEntries,auxEntries,headEntries: seq[ReadOnlyWires]
  var infoValues,immediateValues,positionValues,auxValues,headValues: seq[ReadOnlyEntry]
  var frameWires: seq[MemoryAccessWires]
  var frameValues: seq[MemoryAccess]
  template query(bank: untyped, values: untyped, lookup: untyped,
      enabled,key: Linear, hostActive: bool, hostKey: uint64): Linear =
    block:
      let actual = if hostActive: lookup.getOrDefault(hostKey) else: 0'u64
      let value = c.allocate(scalar(actual))
      bank.add ReadOnlyWires(active: enabled,address: c.multiply(enabled,key),value: value)
      values.add(if hostActive: ReadOnlyEntry(active: true,address: hostKey,value: actual) else: ReadOnlyEntry())
      value
  var fn = firstFunction
  var pc,previousFinish,depth,branchIndex,catchIndex,vectorIndex = constant(0)
  var previousActive = constant(1)
  var expectedLabels,expectedCatches = constant(0)
  var hostBranches,hostCatches,hostVectors: uint64
  var stack: seq[tuple[pc: uint32,conditional,seen: bool]]
  for index, row in wires.rows:
    let raw = hint.rows[index]
    let instruction = row.instruction
    c.constrainBoolean(row.active)
    c.constrain(row.active,constant(1)-previousActive,constant(0))
    for value in [row.functionIndex,row.pc,instruction.opcode,instruction.primary,instruction.secondary,
        instruction.pad,instruction.start,instruction.finish]:
      c.constrain(constant(1)-row.active,value,constant(0))
    discard c.constrainUnsigned(row.functionIndex,32)
    discard c.constrainUnsigned(row.pc,32)
    c.constrain(row.active,row.functionIndex-fn,constant(0))
    c.constrain(row.active,row.pc-pc,constant(0))
    let spanWord = query(spanQueries,spanReads,spans,row.active,row.functionIndex,raw.active,uint64(raw.functionIndex))
    let span = c.splitSignatureHeads(spanWord)
    let start = c.multiply(row.active,c.zeroIndicator(row.pc))
    let afterPrevious = c.selectWire(start,span.params,previousFinish)
    c.constrain(row.active,instruction.start-afterPrevious,constant(0))
    when defined(zkbuildInstructionSourceAudit):
      var rowAudit = InstructionRowAudit(fields: copyAuditExpressions([row.active,row.functionIndex,row.pc,instruction.opcode,
        instruction.primary,instruction.secondary,instruction.pad,instruction.start,instruction.finish]),decode: c.instructionDecodeRecords.len)
    let decoded = c.constrainInstructionDecode(source,instruction,raw.instruction,branchIndex,catchIndex,vectorIndex,row.active)
    let list = decoded.branch+decoded.catching
    let count = c.multiply(list,decoded.count)+decoded.branch
    let headB = query(branchQueries,branchReads,branchBanks,decoded.branch,
      row.functionIndex.scale(scalar(1'u64 shl 32))+branchIndex,
      raw.active and raw.instruction.opcode == uint16(ord(opBrTable)),(uint64(raw.functionIndex) shl 32)+hostBranches)
    let headC = query(catchQueries,catchReads,catchBanks,decoded.catching,
      row.functionIndex.scale(scalar(1'u64 shl 32))+catchIndex,
      raw.active and raw.instruction.opcode == uint16(ord(opTryTable)),(uint64(raw.functionIndex) shl 32)+hostCatches)
    let head = headB+headC
    c.constrain(row.active-list,instruction.finish-decoded.after,constant(0))
    c.constrain(c.multiply(list,c.zeroIndicator(count)),instruction.finish-decoded.after,constant(0))
    discard c.constrainUnsigned(c.multiply(row.active,instruction.finish-decoded.after),32)
    let key = row.functionIndex.scale(scalar(1'u64 shl 32))+row.pc
    infoEntries.add ReadOnlyWires(active: row.active,address: key,value: instruction.opcode+instruction.pad.scale(scalar(65536)))
    immediateEntries.add ReadOnlyWires(active: row.active,address: key,value: instruction.primary+instruction.secondary.scale(scalar(1'u64 shl 32)))
    positionEntries.add ReadOnlyWires(active: row.active,address: row.active.scale(scalar(index)),value: decoded.after+instruction.finish.scale(scalar(1'u64 shl 32)))
    auxEntries.add ReadOnlyWires(active: row.active,address: row.active.scale(scalar(index)),value: decoded.branch+decoded.catching.scale(scalar(2))+count.scale(scalar(4)))
    headEntries.add ReadOnlyWires(active: row.active,address: row.active.scale(scalar(index)),value: head)
    let hostKey = (uint64(raw.functionIndex) shl 32)+uint64(raw.pc)
    let isBranch = raw.active and raw.instruction.opcode == uint16(ord(opBrTable))
    let isCatch = raw.active and raw.instruction.opcode == uint16(ord(opTryTable))
    template addValue(target: untyped, recordAddress,recordValue: uint64) =
      target.add(if raw.active: ReadOnlyEntry(active: true,address: recordAddress,value: recordValue) else: ReadOnlyEntry())
    addValue(infoValues,hostKey,uint64(raw.instruction.opcode)+(raw.instruction.pad shl 16))
    addValue(immediateValues,hostKey,uint64(raw.instruction.primary)+(uint64(raw.instruction.secondary) shl 32))
    addValue(positionValues,uint64(index),uint64(raw.after)+(uint64(raw.instruction.finish) shl 32))
    addValue(auxValues,uint64(index),uint64(ord(isBranch))+2*uint64(ord(isCatch))+4*uint64(raw.count))
    addValue(headValues,uint64(index),uint64(raw.head))
    expectedLabels = c.materialize(expectedLabels+c.multiply(decoded.branch,count))
    expectedCatches = c.materialize(expectedCatches+c.multiply(decoded.catching,count))
    branchIndex = c.materialize(branchIndex+decoded.branch)
    catchIndex = c.materialize(catchIndex+decoded.catching)
    vectorIndex = c.materialize(vectorIndex+decoded.vector)
    if isBranch: inc hostBranches
    if isCatch: inc hostCatches
    if raw.active and raw.instruction.opcode == uint16(ord(opV128Const)): inc hostVectors
    let ending = c.multiply(row.active,c.zeroIndicator(instruction.opcode-constant(ord(opEnd))))
    let otherwise = c.multiply(row.active,c.zeroIndicator(instruction.opcode-constant(ord(opElse))))
    let empty = c.zeroIndicator(depth)
    let innerEnd = c.multiply(ending,constant(1)-empty)
    let rootEnd = c.multiply(ending,empty)
    c.constrain(otherwise,empty,constant(0))
    let readActive = innerEnd+otherwise
    let hostRead = raw.active and raw.instruction.opcode in [uint16(ord(opEnd)),uint16(ord(opElse))] and stack.len != 0
    let frame = if hostRead: stack[^1] else: (0'u32,false,false)
    let frameValue = uint64(frame.pc)+(uint64(ord(frame.conditional)) shl 32)+(uint64(ord(frame.seen)) shl 33)
    let frameWire = c.allocate(scalar(frameValue))
    when defined(zkbuildInstructionSourceAudit): rowAudit.frame = copyAuditExpressions([frameWire])[0]
    let bits = c.constrainUnsigned(frameWire,34)
    let framePc = c.pack(bits.toOpenArray(0,31))
    frameWires.add MemoryAccessWires(active: readActive,write: constant(0),
      address: c.multiply(readActive,row.functionIndex.scale(scalar(1'u64 shl 32))+depth-constant(1)),value: frameWire)
    frameValues.add(if hostRead: MemoryAccess(active: true,address: (uint64(raw.functionIndex) shl 32)+uint64(stack.len-1),value: frameValue) else: MemoryAccess())
    # The opener's immediate table is authenticated after all rows are built.
    # Keep the query key/value in a separate stream for the same table.
    let openKey = row.functionIndex.scale(scalar(1'u64 shl 32))+framePc
    let hostOpenKey = (uint64(raw.functionIndex) shl 32)+uint64(frame.pc)
    let opener = query(immediateQueries,immediateReads,immediateLookup,readActive,openKey,hostRead,hostOpenKey)
    let offsets = c.splitSignatureHeads(opener)
    c.constrain(innerEnd,offsets.params-row.pc,constant(0))
    c.constrain(otherwise,bits[32]-constant(1),constant(0))
    c.constrain(otherwise,bits[33],constant(0))
    c.constrain(otherwise,offsets.results-row.pc,constant(0))
    c.constrain(c.multiply(c.multiply(innerEnd,bits[32]),constant(1)-bits[33]),offsets.results-row.pc,constant(0))
    let writeActive = decoded.blockLike+otherwise
    let writeValue = c.multiply(decoded.blockLike,row.pc+decoded.conditional.scale(scalar(1'u64 shl 32)))+
      c.multiply(otherwise,frameWire+constant(1'u64 shl 33))
    frameWires.add MemoryAccessWires(active: writeActive,write: writeActive,
      address: c.multiply(writeActive,row.functionIndex.scale(scalar(1'u64 shl 32))+depth-otherwise),value: writeValue)
    var hostWrite: MemoryAccess
    if raw.active and raw.instruction.opcode in [uint16(ord(opBlock)),uint16(ord(opLoop)),uint16(ord(opIf)),uint16(ord(opTryTable))]:
      hostWrite = MemoryAccess(active: true,write: true,address: (uint64(raw.functionIndex) shl 32)+uint64(stack.len),
        value: uint64(raw.pc)+(uint64(ord(raw.instruction.opcode == uint16(ord(opIf)))) shl 32))
      stack.add (raw.pc,raw.instruction.opcode == uint16(ord(opIf)),false)
    elif raw.active and raw.instruction.opcode == uint16(ord(opElse)) and stack.len != 0:
      hostWrite = MemoryAccess(active: true,write: true,address: (uint64(raw.functionIndex) shl 32)+uint64(stack.len-1),value: frameValue+(1'u64 shl 33))
      stack[^1].seen = true
    elif raw.active and raw.instruction.opcode == uint16(ord(opEnd)) and stack.len != 0:
      stack.setLen(stack.len-1)
    frameValues.add hostWrite
    depth = c.materialize(depth+decoded.blockLike-innerEnd)
    discard c.constrainUnsigned(depth,32)
    let lastPc = query(endQueries,endReads,ends,rootEnd,row.functionIndex,raw.functionEnd,uint64(raw.functionIndex))
    c.constrain(rootEnd,row.pc-lastPc,constant(0))
    c.constrain(rootEnd,instruction.finish-span.results,constant(0))
    let bCount = query(branchCountQueries,branchCountReads,branchCounts,rootEnd,row.functionIndex,raw.functionEnd,uint64(raw.functionIndex))
    let cCount = query(catchCountQueries,catchCountReads,catchCounts,rootEnd,row.functionIndex,raw.functionEnd,uint64(raw.functionIndex))
    let vCount = query(vectorCountQueries,vectorCountReads,vectorCounts,rootEnd,row.functionIndex,raw.functionEnd,uint64(raw.functionIndex))
    let pool = query(memoryVectorQueries,memoryVectorReads,memoryVectors,rootEnd,row.functionIndex,raw.functionEnd,uint64(raw.functionIndex))
    c.constrain(rootEnd,branchIndex-bCount,constant(0))
    c.constrain(rootEnd,catchIndex-cCount,constant(0))
    c.constrain(rootEnd,vectorIndex-vCount,constant(0))
    c.constrain(rootEnd,vectorIndex-pool,constant(0))
    branchIndex = c.multiply(constant(1)-rootEnd,branchIndex)
    catchIndex = c.multiply(constant(1)-rootEnd,catchIndex)
    vectorIndex = c.multiply(constant(1)-rootEnd,vectorIndex)
    fn = c.materialize(fn+rootEnd)
    pc = c.multiply(constant(1)-rootEnd,pc+row.active)
    previousFinish = instruction.finish
    previousActive = row.active
    if raw.functionEnd: hostBranches = 0; hostCatches = 0; hostVectors = 0
    when defined(zkbuildInstructionSourceAudit): sourceAudit.rows.add rowAudit
  c.assertEqual(fn,firstFunction+functionCount)
  c.assertEqual(pc,constant(0))
  c.assertEqual(depth,constant(0))
  let positions = contents(positionValues)
  let metadata = contents(auxValues)
  let heads = contents(headValues)
  var positionQueries,metadataQueries,headQueries: seq[ReadOnlyWires]
  var positionReads,metadataReads,headReads: seq[ReadOnlyEntry]
  var branchNodeQueries,catchLinkQueries,catchClauseQueries: seq[ReadOnlyWires]
  var branchNodeReads,catchLinkReads,catchClauseReads: seq[ReadOnlyEntry]
  template auxiliary(rows: untyped,values: untyped,isCatch: static bool,expected: Linear) =
    block:
      var previousActive = constant(1)
      var previousKey,previousOwner,previousOrdinal,previousNext,previousAfter,countRows = constant(0)
      for i, row in rows:
        let raw = values[i]
        c.constrainBoolean(row.active)
        c.constrain(row.active,constant(1)-previousActive,constant(0))
        for field in [row.owner,row.ordinal,row.node,row.position]:
          discard c.constrainUnsigned(field,32)
          c.constrain(constant(1)-row.active,field,constant(0))
        let key = row.owner.scale(scalar(1'u64 shl 32))+row.ordinal
        if i != 0: discard c.constrainUnsigned(c.multiply(row.active,key-previousKey-constant(1)),64)
        let spanWord = query(positionQueries,positionReads,positions,row.active,row.owner,raw.active,uint64(raw.owner))
        let span = c.splitSignatureHeads(spanWord)
        let kindWord = query(metadataQueries,metadataReads,metadata,row.active,row.owner,raw.active,uint64(raw.owner))
        let kindBits = c.constrainUnsigned(kindWord,35)
        let kind = c.pack(kindBits.toOpenArray(0,1))
        let count = c.pack(kindBits.toOpenArray(2,34))
        c.constrain(row.active,kind-constant(when isCatch: 2 else: 1),constant(0))
        discard c.constrainUnsigned(c.multiply(row.active,count-row.ordinal-constant(1)),33)
        let head = query(headQueries,headReads,heads,row.active,row.owner,raw.active,uint64(raw.owner))
        let same = if i == 0: constant(0)
          else: c.multiply(c.multiply(row.active,previousActive),c.zeroIndicator(row.owner-previousOwner))
        let first = row.active-same
        c.constrain(first,row.ordinal,constant(0))
        c.constrain(first,row.node-head,constant(0))
        c.constrain(first,row.position-span.params,constant(0))
        c.constrain(same,row.ordinal-previousOrdinal-constant(1),constant(0))
        c.constrain(same,row.node-previousNext,constant(0))
        c.constrain(same,row.position-previousAfter,constant(0))
        var after = row.position
        var next: Linear
        when isCatch:
          let link = query(catchLinkQueries,catchLinkReads,catchLinks,row.active,row.node,raw.active,uint64(raw.node))
          let clause = query(catchClauseQueries,catchClauseReads,catchClauses,row.active,row.node,raw.active,uint64(raw.node))
          let linkBits = c.constrainUnsigned(link,34)
          let clauseKind = c.pack(linkBits.toOpenArray(0,1))
          next = c.pack(linkBits.toOpenArray(2,33))
          let parts = c.splitSignatureHeads(clause)
          let tagged = c.multiply(row.active,constant(1)-linkBits[1])
          let kindLength = c.constrainBinaryRead(source,brByte,row.active,after,clauseKind,raw.clause.kind)
          after = c.materialize(after+kindLength)
          c.constrain(c.multiply(row.active,linkBits[1]),parts.params,constant(0))
          let tagLength = c.constrainBinaryRead(source,brU32,tagged,c.multiply(tagged,after),
            c.multiply(tagged,parts.params),raw.clause.tag)
          after = c.materialize(after+tagLength)
          let depthLength = c.constrainBinaryRead(source,brU32,row.active,c.multiply(row.active,after),parts.results,raw.clause.depth)
          after = c.materialize(after+depthLength)
        else:
          let node = query(branchNodeQueries,branchNodeReads,branchNodes,row.active,row.node,raw.active,uint64(raw.node))
          let parts = c.splitSignatureHeads(node)
          next = parts.results
          let size = c.constrainBinaryRead(source,brU32,row.active,after,parts.params,raw.label)
          after = c.materialize(after+size)
        let continues = if i+1 == rows.len: constant(0)
          else: c.multiply(c.multiply(row.active,rows[i+1].active),c.zeroIndicator(row.owner-rows[i+1].owner))
        let last = row.active-continues
        c.constrain(last,next,constant(0))
        c.constrain(last,after-span.results,constant(0))
        c.constrain(last,row.ordinal+constant(1)-count,constant(0))
        countRows = c.materialize(countRows+row.active)
        previousActive = row.active
        previousKey = key
        previousOwner = row.owner
        previousOrdinal = row.ordinal
        previousNext = next
        previousAfter = after
      discard c.constrainUnsigned(expected,64)
      c.assertEqual(countRows,expected)
  auxiliary(wires.labels,hint.labels,false,expectedLabels)
  auxiliary(wires.catches,hint.catches,true,expectedCatches)
  let instructions = contents(infoValues)
  var infoQueries: seq[ReadOnlyWires]
  var infoReads: seq[ReadOnlyEntry]
  for i, bank in branches.banks:
    let parts = c.splitSignatureHeads(bank.address)
    let raw = branchValues.banks[i]
    let count = query(branchCountQueries,branchCountReads,branchCounts,bank.active,parts.results,raw.active,raw.address shr 32)
    discard c.constrainUnsigned(c.multiply(bank.active,count-parts.params-constant(1)),32)
  for i, bank in catches.banks:
    let parts = c.splitSignatureHeads(bank.address)
    let raw = catchValues.banks[i]
    let count = query(catchCountQueries,catchCountReads,catchCounts,bank.active,parts.results,raw.active,raw.address shr 32)
    discard c.constrainUnsigned(c.multiply(bank.active,count-parts.params-constant(1)),32)
  for i, event in events:
    let raw = eventValues[i]
    discard c.constrainUnsigned(event.control.operand.functionIndex,32)
    discard c.constrainUnsigned(event.pc,32)
    discard c.constrainUnsigned(event.opcode,16)
    discard c.constrainUnsigned(primary[i],32)
    discard c.constrainUnsigned(secondary[i],32)
    discard c.constrainUnsigned(pads[i],33)
    let begin = c.zeroIndicator(event.control.operand.kind-constant(ord(veInstructionBegin)))
    let ending = c.zeroIndicator(event.control.operand.kind-constant(ord(veFunctionEnd)))
    let key = event.control.operand.functionIndex.scale(scalar(1'u64 shl 32))+event.pc
    let hostKey = (uint64(raw.control.operand.functionIndex) shl 32)+uint64(raw.pc)
    let info = query(infoQueries,infoReads,instructions,begin,key,raw.control.operand.kind == uint8(ord(veInstructionBegin)),hostKey)
    let immediate = query(immediateQueries,immediateReads,immediateLookup,begin,key,raw.control.operand.kind == uint8(ord(veInstructionBegin)),hostKey)
    c.constrain(begin,info-event.opcode-pads[i].scale(scalar(65536)),constant(0))
    c.constrain(begin,immediate-primary[i]-secondary[i].scale(scalar(1'u64 shl 32)),constant(0))
    let last = query(endQueries,endReads,ends,ending,event.control.operand.functionIndex,
      raw.control.operand.kind == uint8(ord(veFunctionEnd)),uint64(raw.control.operand.functionIndex))
    c.constrain(ending,last-event.pc,constant(0))
  when defined(zkbuildInstructionSourceAudit): sourceAudit.program = c.endSourceProgram(sourceMarker)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(bodySpans.instructions,spanQueries,buildReadOnlyWitness(spanValues,spanReads),32,64)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(wires.ends,endQueries,buildReadOnlyWitness(endValues,endReads),32,32)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(wires.branches,branchCountQueries,buildReadOnlyWitness(branchCountValues,branchCountReads),32,32)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(wires.catchCounts,catchCountQueries,buildReadOnlyWitness(catchCountValues,catchCountReads),32,32)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(wires.vectors,vectorCountQueries,buildReadOnlyWitness(vectorCountValues,vectorCountReads),32,32)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(memory.vectorCounts,memoryVectorQueries,buildReadOnlyWitness(memoryValues.vectorCounts,memoryVectorReads),32,32)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(branches.banks,branchQueries,buildReadOnlyWitness(branchValues.banks,branchReads),64,32)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(catches.banks,catchQueries,buildReadOnlyWitness(catchValues.banks,catchReads),64,32)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(branches.nodes,branchNodeQueries,buildReadOnlyWitness(branchValues.nodes,branchNodeReads),32,64)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(catches.links,catchLinkQueries,buildReadOnlyWitness(catchValues.links,catchLinkReads),32,34)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(catches.clauses,catchClauseQueries,buildReadOnlyWitness(catchValues.clauses,catchClauseReads),32,64)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(infoEntries,infoQueries,buildReadOnlyWitness(infoValues,infoReads),64,49)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(immediateEntries,immediateQueries,buildReadOnlyWitness(immediateValues,immediateReads),64,64)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(positionEntries,positionQueries,buildReadOnlyWitness(positionValues,positionReads),32,64)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(auxEntries,metadataQueries,buildReadOnlyWitness(auxValues,metadataReads),32,35)
  when defined(zkbuildInstructionSourceAudit): sourceAudit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(headEntries,headQueries,buildReadOnlyWitness(headValues,headReads),32,32)
  while frameValues.len < readOnlyCapacity(frameWires.len,0): frameValues.add MemoryAccess()
  while frameWires.len < frameValues.len:
    frameWires.add MemoryAccessWires(active: constant(0),write: constant(0),address: constant(0),value: constant(0))
  when defined(zkbuildInstructionSourceAudit): sourceAudit.frameMemoryIndex = c.memoryRecords.len
  discard c.constrainMemory(frameWires,buildMemoryWitness(frameValues),64,34)
  when defined(zkbuildInstructionSourceAudit): c.instructionSourceRecords.add sourceAudit
