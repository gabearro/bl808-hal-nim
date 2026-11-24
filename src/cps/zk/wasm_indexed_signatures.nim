## Verified indexed views of shared type lists. Only complete declaration
## heads are indexed, so storage is linear in the declared type vectors.
## Node reads bind every cell to the original immutable list representation.
import std/[tables, sets, algorithm]
import r1cs, range_check, read_only_memory, memory_consistency, wasm_signature_environment

type
  IndexedSignatureEnvironment* = object
    lengths*, members*, singletons*: seq[ReadOnlyEntry]
  IndexedSignatureWires* = object
    lengths*, members*, singletons*: seq[ReadOnlyWires]
  IndexedSignatureQueries* = object
    lengths*, members*, singletons*: seq[ReadOnlyEntry]
  IndexedSignatureQueryWires* = object
    lengths*, members*, singletons*: seq[ReadOnlyWires]
  IndexedSignatureWitness* = object
    memberNodes*, memberLengths*, metadataLengths*, firstMembers*, singletonNodes*: seq[ReadOnlyEntry]
    lengths*, members*, singletons*, nodes*: MemoryWitness

func signatureMemberAddress*(head, ordinal: uint32): uint64 = (uint64(head) shl 32) or uint64(ordinal)

proc contents(entries: openArray[ReadOnlyEntry]): Table[uint64, uint64] =
  for entry in entries:
    if entry.active: result[entry.address] = entry.value

proc query(enabled: bool, address: uint64, values: Table[uint64, uint64]): ReadOnlyEntry =
  if enabled: result = ReadOnlyEntry(active: true, address: address, value: values.getOrDefault(address))

proc buildIndexedSignatures*(environment: SignatureEnvironment, lengthCapacity = 0,
    memberCapacity = 0, maxMembers = 1_048_576): IndexedSignatureEnvironment =
  if lengthCapacity < 0 or memberCapacity < 0 or maxMembers < 0:
    raise newException(ValueError, "invalid indexed-signature dimensions")
  let nodes = contents(environment.nodes)
  var heads = initHashSet[uint32]()
  heads.incl 0
  for entry in environment.signatures:
    if entry.active:
      heads.incl uint32(entry.value and 0xffffffff'u64)
      heads.incl uint32(entry.value shr 32)
  for entry in environment.reversals:
    if entry.active:
      heads.incl uint32(entry.address)
      heads.incl uint32(entry.value)
  for tag, head in environment.singletons:
    if head == 0: raise newException(ValueError, "indexed signatures require singleton nodes")
    heads.incl head
    result.singletons.add ReadOnlyEntry(active: true, address: uint64(tag), value: uint64(head))
  var ordered: seq[uint32]
  for head in heads: ordered.add head
  ordered.sort()
  for head in ordered:
    var cursor = uint64(head)
    var ordinal = 0'u64
    while cursor != 0:
      if result.members.len >= maxMembers or ordinal >= uint64(high(uint32)) or
          cursor > uint64(high(uint32)) or not nodes.hasKey(cursor):
        raise newException(ValueError, "invalid or oversized signature list")
      let node = nodes[cursor]
      let tag = node and 7
      let next = node shr 3
      if tag > 6 or next >= cursor:
        raise newException(ValueError, "invalid signature-list cell")
      result.members.add ReadOnlyEntry(active: true, address: signatureMemberAddress(head, uint32(ordinal)),
        value: (cursor shl 3)+tag)
      inc ordinal
      cursor = next
    result.lengths.add ReadOnlyEntry(active: true, address: uint64(head), value: ordinal)
  if lengthCapacity != 0:
    if result.lengths.len > lengthCapacity: raise newException(ValueError, "signature length profile overflow")
    result.lengths.setLen(lengthCapacity)
  if memberCapacity != 0:
    if result.members.len > memberCapacity: raise newException(ValueError, "signature member profile overflow")
    result.members.setLen(memberCapacity)

proc buildIndexedSignatureWitness*(environment: IndexedSignatureEnvironment,
    signatures: SignatureEnvironment, extra = IndexedSignatureQueries()): IndexedSignatureWitness =
  let nodes = contents(signatures.nodes)
  let lengths = contents(environment.lengths)
  let members = contents(environment.members)
  for entry in environment.members:
    result.memberNodes.add query(entry.active, entry.value shr 3, nodes)
    result.memberLengths.add query(entry.active, entry.address shr 32, lengths)
  for entry in signatures.signatures:
    result.metadataLengths.add query(entry.active, entry.value and 0xffffffff'u64, lengths)
    result.metadataLengths.add query(entry.active, entry.value shr 32, lengths)
  for entry in environment.lengths:
    result.firstMembers.add query(entry.active and entry.address != 0, entry.address shl 32, members)
  var singletonLengths: seq[ReadOnlyEntry]
  for entry in environment.singletons:
    result.singletonNodes.add query(true, entry.value, nodes)
    singletonLengths.add ReadOnlyEntry(active: true, address: entry.value, value: 1)
  result.lengths = buildReadOnlyWitness(environment.lengths,
    result.memberLengths & result.metadataLengths & singletonLengths & extra.lengths)
  result.members = buildReadOnlyWitness(environment.members, result.firstMembers & extra.members)
  result.singletons = buildReadOnlyWitness(environment.singletons, extra.singletons)
  result.nodes = buildReadOnlyWitness(signatures.nodes, result.memberNodes & result.singletonNodes)

proc read(c: var Circuit, active, address: Linear, value: uint64): ReadOnlyWires =
  ReadOnlyWires(active: active, address: c.multiply(active, address), value: c.allocate(scalar(value)))

proc constrainSignatureMemberQuery*(c: var Circuit, active, head, ordinal: Linear,
    value: uint64): ReadOnlyWires =
  ## Range-check both components before packing. Otherwise an ordinal of
  ## 2^32 could alias ordinal zero of the following head.
  let selectedHead = c.multiply(active, head)
  let selectedOrdinal = c.multiply(active, ordinal)
  discard c.constrainUnsigned(selectedHead, 32)
  discard c.constrainUnsigned(selectedOrdinal, 32)
  ReadOnlyWires(active: active, address: selectedHead.scale(scalar(1'u64 shl 32))+selectedOrdinal,
    value: c.allocate(scalar(value)))

proc constrainIndexedSignatures*(c: var Circuit, environment: IndexedSignatureWires,
    signatures: SignatureEnvironmentWires, witness: IndexedSignatureWitness,
    extra = IndexedSignatureQueryWires()) =
  ## Complete member groups start at ordinal zero and their own head. Adjacent
  ## cells increment the ordinal and follow the authenticated next-node ID;
  ## a group's last cell reaches nil and closes at its declared length.
  if environment.lengths.len == 0 or environment.singletons.len != 7 or
      witness.memberNodes.len != environment.members.len or
      witness.memberLengths.len != environment.members.len or
      witness.firstMembers.len != environment.lengths.len or
      witness.metadataLengths.len != 2*signatures.signatures.len or witness.singletonNodes.len != 7:
    raise newException(ValueError, "indexed-signature circuit dimensions differ")
  when defined(zkbuildIndexedAudit):
    var audit = IndexedAudit(nilStart: c.constraints.len)
  c.assertEqual(environment.lengths[0].active, constant(1))
  c.assertEqual(environment.lengths[0].address, constant(0))
  c.assertEqual(environment.lengths[0].value, constant(0))
  when defined(zkbuildIndexedAudit): audit.nilEnd = c.constraints.len
  var lengthQueries, memberQueries, nodeQueries: seq[ReadOnlyWires]
  for i, entry in environment.lengths:
    when defined(zkbuildIndexedAudit):
      var item = IndexedLengthAudit(firstGate: c.constraints.len,headZero: c.values.len,
        fields: copyAuditExpressions([entry.active,entry.address,entry.value]))
    let zeroHead = c.zeroIndicator(entry.address)
    when defined(zkbuildIndexedAudit): item.lengthZero = c.values.len
    let zeroLength = c.zeroIndicator(entry.value)
    c.constrain(entry.active, zeroHead-zeroLength, constant(0))
    let nonempty = c.multiply(entry.active, constant(1)-zeroHead)
    memberQueries.add c.read(nonempty, entry.address.scale(scalar(1'u64 shl 32)), witness.firstMembers[i].value)
    when defined(zkbuildIndexedAudit):
      item.nonempty = copyAuditExpressions([nonempty])[0]
      let q = memberQueries[^1]
      item.firstMember = copyAuditExpressions([q.active,q.address,q.value])
      item.lastGate = c.constraints.len
      audit.lengths.add item

  var heads, ordinals, nexts, lengths, continuing: seq[Linear]
  for i, entry in environment.members:
    when defined(zkbuildIndexedAudit):
      var item = IndexedMemberAudit(firstGate: c.constraints.len,addressSplit: c.packedRecords.len,
        fields: copyAuditExpressions([entry.active,entry.address,entry.value]))
    let address = c.splitSignatureHeads(entry.address)
    when defined(zkbuildIndexedAudit): item.cellSplit = c.packedRecords.len
    let cell = c.splitSignatureNode(entry.value)
    let head = address.results
    let ordinal = address.params
    let cursor = cell.next
    when defined(zkbuildIndexedAudit): item.headZero = c.values.len
    let zeroHead = c.zeroIndicator(head)
    c.constrain(entry.active, zeroHead, constant(0))
    when defined(zkbuildIndexedAudit): item.cursorZero = c.values.len
    let zeroCursor = c.zeroIndicator(cursor)
    c.constrain(entry.active, zeroCursor, constant(0))
    when defined(zkbuildIndexedAudit): item.tagZero = c.values.len
    let invalidTag = c.zeroIndicator(cell.tag-constant(7))
    c.assertEqual(invalidTag, constant(0))
    let nodeQuery = c.read(entry.active, cursor, witness.memberNodes[i].value)
    nodeQueries.add nodeQuery
    when defined(zkbuildIndexedAudit): item.nodeSplit = c.packedRecords.len
    let node = c.splitSignatureNode(nodeQuery.value)
    c.constrain(entry.active, cell.tag-node.tag, constant(0))
    let lengthQuery = c.read(entry.active, head, witness.memberLengths[i].value)
    lengthQueries.add lengthQuery
    when defined(zkbuildIndexedAudit):
      if i != 0: item.continuationZero = c.values.len
    let continuation = if i == 0: constant(0) else: c.multiply(entry.active, c.zeroIndicator(head-heads[i-1]))
    let start = entry.active-continuation
    c.constrain(start, ordinal, constant(0))
    c.constrain(start, cursor-head, constant(0))
    if i != 0:
      c.constrain(continuation, ordinal-ordinals[i-1]-constant(1), constant(0))
      c.constrain(continuation, cursor-nexts[i-1], constant(0))
    heads.add head
    ordinals.add ordinal
    nexts.add node.next
    lengths.add lengthQuery.value
    continuing.add continuation
    when defined(zkbuildIndexedAudit):
      item.nodeQuery = copyAuditExpressions([nodeQuery.active,nodeQuery.address,nodeQuery.value])
      item.lengthQuery = copyAuditExpressions([lengthQuery.active,lengthQuery.address,lengthQuery.value])
      item.continuing = copyAuditExpressions([continuation])[0]
      item.lastGate = c.constraints.len
      audit.members.add item
  for i, entry in environment.members:
    when defined(zkbuildIndexedAudit):
      var item = IndexedCloseAudit(firstGate: c.constraints.len)
    let finish = entry.active-(if i == environment.members.high: constant(0) else: continuing[i+1])
    c.constrain(finish, nexts[i], constant(0))
    c.constrain(finish, ordinals[i]+constant(1)-lengths[i], constant(0))
    when defined(zkbuildIndexedAudit):
      item.lastGate = c.constraints.len
      audit.closing.add item
  for i, entry in signatures.signatures:
    when defined(zkbuildIndexedAudit):
      var item = IndexedMetadataAudit(firstGate: c.constraints.len,heads: c.packedRecords.len,
        fields: copyAuditExpressions([entry.active,entry.address,entry.value]))
    let heads = c.splitSignatureHeads(entry.value)
    lengthQueries.add c.read(entry.active, heads.params, witness.metadataLengths[2*i].value)
    lengthQueries.add c.read(entry.active, heads.results, witness.metadataLengths[2*i+1].value)
    when defined(zkbuildIndexedAudit):
      let p = lengthQueries[^2]
      let r = lengthQueries[^1]
      item.params = copyAuditExpressions([p.active,p.address,p.value])
      item.results = copyAuditExpressions([r.active,r.address,r.value])
      item.lastGate = c.constraints.len
      audit.metadata.add item
  for i, entry in environment.singletons:
    when defined(zkbuildIndexedAudit):
      var item = IndexedSingletonAudit(firstGate: c.constraints.len,
        fields: copyAuditExpressions([entry.active,entry.address,entry.value]))
    c.assertEqual(entry.active, constant(1))
    c.assertEqual(entry.address, constant(i))
    let nodeQuery = c.read(constant(1), entry.value, witness.singletonNodes[i].value)
    c.assertEqual(nodeQuery.value, constant(i))
    nodeQueries.add nodeQuery
    lengthQueries.add ReadOnlyWires(active: constant(1), address: entry.value, value: constant(1))
    when defined(zkbuildIndexedAudit):
      item.nodeQuery = copyAuditExpressions([nodeQuery.active,nodeQuery.address,nodeQuery.value])
      item.lastGate = c.constraints.len
      audit.singletons.add item
  lengthQueries.add extra.lengths
  memberQueries.add extra.members
  when defined(zkbuildIndexedAudit):
    for q in extra.lengths: audit.extraLengths.add copyAuditExpressions([q.active,q.address,q.value])
    for q in extra.members: audit.extraMembers.add copyAuditExpressions([q.active,q.address,q.value])
    for q in extra.singletons: audit.extraSingletons.add copyAuditExpressions([q.active,q.address,q.value])
    audit.tables.add c.readOnlyRecords.len
  c.constrainReadOnly(environment.lengths, lengthQueries, witness.lengths, 32, 32)
  when defined(zkbuildIndexedAudit): audit.tables.add c.readOnlyRecords.len
  c.constrainReadOnly(environment.members, memberQueries, witness.members, 64, 35)
  when defined(zkbuildIndexedAudit): audit.tables.add c.readOnlyRecords.len
  c.constrainReadOnly(environment.singletons, extra.singletons, witness.singletons, 3, 32)
  when defined(zkbuildIndexedAudit): audit.tables.add c.readOnlyRecords.len
  c.constrainReadOnly(signatures.nodes, nodeQueries, witness.nodes, 32, 35)
  when defined(zkbuildIndexedAudit): c.indexedRecords.add audit
