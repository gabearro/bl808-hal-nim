## Catch type equality against authenticated OUTER frame signatures. Parameter
## lists run in pop order; result lists use the independently checked reversal
## cache. Opaque exception references follow the runtime's current externref.
import std/tables
import r1cs, range_check, read_only_memory, memory_consistency
import wasm_instruction_events, wasm_signature_environment, wasm_signature_frames
import wasm_throw_events, wasm_indexed_signatures, wasm_catch_environment

type CatchTypingWitness* = object
  metadataQueries*, singletonQueries*, tagQueries*, reverseQueries*, nodeQueries*: seq[ReadOnlyEntry]
  metadata*, singletons*, tags*, reversals*, nodes*: MemoryWitness

proc contents(entries: openArray[ReadOnlyEntry]): Table[uint64, uint64] =
  for entry in entries:
    if entry.active: result[entry.address] = entry.value

proc query(active: bool, address: uint64, values: Table[uint64, uint64]): ReadOnlyEntry =
  if active: ReadOnlyEntry(active: true, address: address, value: values.getOrDefault(address)) else: ReadOnlyEntry()

proc buildCatchTypingWitness*(signatures: SignatureEnvironment, indexed: IndexedSignatureEnvironment,
    tags: TagEnvironment, rows: openArray[InstructionEventRow], frames: SignatureFrameWitness,
    catches: CatchEnvironmentWitness): CatchTypingWitness =
  if rows.len != frames.sources.len or rows.len != catches.linkQueries.len or rows.len != catches.clauseQueries.len:
    raise newException(ValueError, "catch typing witness dimensions differ")
  let metadata = contents(signatures.signatures)
  let singles = contents(indexed.singletons)
  let tagMap = contents(tags.tags)
  let reverse = contents(signatures.reversals)
  let nodes = contents(signatures.nodes)
  for i in 0..<rows.len:
    let mark = catches.linkQueries[i].active
    let token = frames.sources[i]
    let family = (token shr 2) and 3
    let index = token shr 4
    let loopFrame = (token and 3) == 1
    let meta = query(mark and family <= 1, 2*index+uint64(ord(family == 0)), metadata)
    let single = query(mark and family == 3, index, singles)
    let head = if loopFrame: (if family == 0: meta.value and 0xffffffff'u64 else: 0'u64)
      else: (meta.value shr 32)+single.value
    let reversed = query(mark and not loopFrame, head, reverse)
    let normalized = if loopFrame: head else: reversed.value
    let tagged = (catches.linkQueries[i].value and 2) == 0
    let reference = (catches.linkQueries[i].value and 1) != 0
    result.metadataQueries.add meta
    result.singletonQueries.add single
    result.tagQueries.add query(mark and tagged, catches.clauseQueries[i].value and 0xffffffff'u64, tagMap)
    result.reverseQueries.add reversed
    result.nodeQueries.add query(mark and reference, normalized, nodes)
  result.metadata = buildReadOnlyWitness(signatures.signatures, result.metadataQueries)
  result.singletons = buildReadOnlyWitness(indexed.singletons, result.singletonQueries)
  result.tags = buildReadOnlyWitness(tags.tags, result.tagQueries)
  result.reversals = buildReadOnlyWitness(signatures.reversals, result.reverseQueries)
  result.nodes = buildReadOnlyWitness(signatures.nodes, result.nodeQueries)

proc read(c: var Circuit, active, address: Linear, value: uint64): ReadOnlyWires =
  ReadOnlyWires(active: active, address: c.multiply(active, address), value: c.allocate(scalar(value)))

proc constrainCatchTyping*(c: var Circuit, catches: CatchProjection, frames: SignatureFrameProjection,
    signatures: SignatureEnvironmentWires, indexed: IndexedSignatureWires,
    tags: TagEnvironmentWires, reversals: openArray[ReadOnlyWires], witness: CatchTypingWitness) =
  let count = catches.marks.len
  if count == 0 or frames.source.len != count or catches.tags.len != count or
      catches.tagged.len != count or catches.references.len != count or
      witness.metadataQueries.len != count or witness.singletonQueries.len != count or
      witness.tagQueries.len != count or witness.reverseQueries.len != count or witness.nodeQueries.len != count:
    raise newException(ValueError, "catch typing circuit dimensions differ")
  when defined(zkbuildStructuredControlAudit):
    let marker = c.beginSourceProgram()
  var metadata, singles, tagQueries, reverseQueries, nodes: seq[ReadOnlyWires]
  for i, mark in catches.marks:
    let frame = frames.source[i]
    let meta = c.read(c.multiply(mark, frame.isType+frame.isFunction),
      frame.index.scale(scalar(2))+frame.isType, witness.metadataQueries[i].value)
    metadata.add meta
    let heads = c.splitSignatureHeads(meta.value)
    let single = c.read(c.multiply(mark, frame.isValue), frame.index, witness.singletonQueries[i].value)
    singles.add single
    c.constrain(c.multiply(mark, frame.isEmpty), frame.index, constant(0))
    let loopFrame = c.zeroIndicator(frame.kind-constant(1))
    let head = c.selectWire(loopFrame, c.multiply(frame.isType, heads.params), heads.results+single.value)
    let reversed = c.read(c.multiply(mark, constant(1)-loopFrame), head, witness.reverseQueries[i].value)
    reverseQueries.add reversed
    let normalized = c.multiply(loopFrame, head)+reversed.value
    let tag = c.read(catches.tagged[i], catches.tags[i], witness.tagQueries[i].value)
    tagQueries.add tag
    let payload = c.splitSignatureHeads(tag.value)
    c.constrain(catches.tagged[i], payload.results, constant(0))
    c.constrain(mark-catches.references[i], normalized-payload.params, constant(0))
    let nodeQuery = c.read(catches.references[i], normalized, witness.nodeQueries[i].value)
    nodes.add nodeQuery
    let node = c.splitSignatureNode(nodeQuery.value)
    c.constrain(catches.references[i], node.tag-constant(6), constant(0))
    c.constrain(catches.references[i], node.next-payload.params, constant(0))
  when defined(zkbuildStructuredControlAudit):
    var audit = DynamicTypingStageAudit(kind: 7,selectors: captureFrames(frames),program: c.endSourceProgram(marker))
    for i in 0..<count: audit.inputs.add copyAuditExpressions([catches.marks[i],catches.depths[i],catches.tags[i],
      catches.tagged[i],catches.references[i]])
    audit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(signatures.signatures, metadata, witness.metadata, 33, 64)
  when defined(zkbuildStructuredControlAudit): audit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(indexed.singletons, singles, witness.singletons, 3, 32)
  when defined(zkbuildStructuredControlAudit): audit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(tags.tags, tagQueries, witness.tags, 32, 64)
  when defined(zkbuildStructuredControlAudit): audit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(reversals, reverseQueries, witness.reversals, 32, 32)
  when defined(zkbuildStructuredControlAudit): audit.banks.add c.readOnlyRecords.len
  c.constrainReadOnly(signatures.nodes, nodes, witness.nodes, 32, 35)
  when defined(zkbuildStructuredControlAudit): c.structuredControlRecords.add audit
