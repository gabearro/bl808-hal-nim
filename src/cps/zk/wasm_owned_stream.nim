## A shared row budget for variable-length, ordered child lists. The sum of
## parent counts and unique bounded child ordinals force complete coverage.
import r1cs, range_check, read_only_memory, wasm_signature_environment

type
  OwnedParent* = object
    active*: bool
    count*, start*, finish*: uint32
  OwnedParentWires* = object
    active*, count*, start*, finish*: Linear
  OwnedChild* = object
    active*: bool
    owner*, ordinal*, start*, finish*: uint32
  OwnedChildWires* = object
    active*, owner*, ordinal*, start*, finish*: Linear

proc constrainOwnedStream*(c: var Circuit, parents: openArray[OwnedParentWires],
    children: openArray[OwnedChildWires], hints: openArray[OwnedParent],
    rows: openArray[OwnedChild]) =
  if parents.len != hints.len or children.len != rows.len:
    raise newException(ValueError,"owned stream dimensions differ")
  when defined(zkbuildOwnedAudit):
    var audit: OwnedAudit
  var counts, spans, queries, spanQueries: seq[ReadOnlyWires]
  var countValues, spanValues, reads, spanReads: seq[ReadOnlyEntry]
  var total, seen = constant(0)
  var previous = constant(1)
  for i, parent in parents:
    when defined(zkbuildOwnedAudit):
      var parentAudit = OwnedParentAudit(firstGate: c.constraints.len,
        fields: copyAuditExpressions([parent.active,parent.count,parent.start,parent.finish]))
    c.constrainBoolean(parent.active)
    c.constrain(parent.active,constant(1)-previous,constant(0))
    for value in [parent.count,parent.start,parent.finish]:
      discard c.constrainUnsigned(value,32)
      when defined(zkbuildOwnedAudit): parentAudit.ranges.add c.snapshotRangeUse()
      c.constrain(constant(1)-parent.active,value,constant(0))
    when defined(zkbuildOwnedAudit): parentAudit.zeroStart = c.values.len
    c.constrain(c.zeroIndicator(parent.count),parent.finish-parent.start,constant(0))
    counts.add ReadOnlyWires(active: parent.active,address: parent.active.scale(scalar(i)),value: parent.count)
    spans.add ReadOnlyWires(active: parent.active,address: parent.active.scale(scalar(i)),
      value: parent.start+parent.finish.scale(scalar(1'u64 shl 32)))
    let hint = hints[i]
    countValues.add(if hint.active: ReadOnlyEntry(active: true,address: uint64(i),value: uint64(hint.count)) else: ReadOnlyEntry())
    spanValues.add(if hint.active: ReadOnlyEntry(active: true,address: uint64(i),value: uint64(hint.start)+(uint64(hint.finish) shl 32)) else: ReadOnlyEntry())
    total = total+parent.count
    previous = parent.active
    when defined(zkbuildOwnedAudit):
      parentAudit.lastGate = c.constraints.len
      audit.parents.add parentAudit
  previous = constant(1)
  for i, child in children:
    when defined(zkbuildOwnedAudit):
      var childAudit = OwnedChildAudit(firstGate: c.constraints.len,
        fields: copyAuditExpressions([child.active,child.owner,child.ordinal,child.start,child.finish]))
    c.constrainBoolean(child.active)
    c.constrain(child.active,constant(1)-previous,constant(0))
    for value in [child.owner,child.ordinal,child.start,child.finish]:
      discard c.constrainUnsigned(value,32)
      when defined(zkbuildOwnedAudit): childAudit.ranges.add c.snapshotRangeUse()
      c.constrain(constant(1)-child.active,value,constant(0))
    let row = rows[i]
    let hint = if row.active and uint64(row.owner) < uint64(hints.len): hints[int(row.owner)] else: OwnedParent()
    let count = c.allocate(scalar(hint.count))
    let span = c.allocate(scalar(uint64(hint.start)+(uint64(hint.finish) shl 32)))
    queries.add ReadOnlyWires(active: child.active,address: child.owner,value: count)
    spanQueries.add ReadOnlyWires(active: child.active,address: child.owner,value: span)
    reads.add(if row.active: ReadOnlyEntry(active: true,address: uint64(row.owner),value: uint64(hint.count)) else: ReadOnlyEntry())
    spanReads.add(if row.active: ReadOnlyEntry(active: true,address: uint64(row.owner),value: uint64(hint.start)+(uint64(hint.finish) shl 32)) else: ReadOnlyEntry())
    when defined(zkbuildOwnedAudit):
      childAudit.heads = c.packedRecords.len
      childAudit.countQuery = copyAuditExpressions([child.active,child.owner,count])
      childAudit.spanQuery = copyAuditExpressions([child.active,child.owner,span])
    let bounds = c.splitSignatureHeads(span)
    let within = c.multiply(child.active,count-child.ordinal-constant(1))
    discard c.constrainUnsigned(within,32)
    when defined(zkbuildOwnedAudit):
      childAudit.within = copyAuditExpressions([within])[0]
      childAudit.withinRange = c.snapshotRangeUse()
    var same = constant(0)
    if i > 0:
      let prior = children[i-1]
      when defined(zkbuildOwnedAudit): childAudit.priorZero = c.values.len
      same = c.multiply(child.active,c.zeroIndicator(child.owner-prior.owner))
      let key = child.owner.scale(scalar(1'u64 shl 32))+child.ordinal
      let priorKey = prior.owner.scale(scalar(1'u64 shl 32))+prior.ordinal
      let order = c.multiply(child.active,key-priorKey-constant(1))
      discard c.constrainUnsigned(order,64)
      when defined(zkbuildOwnedAudit):
        childAudit.order = copyAuditExpressions([order])[0]
        childAudit.orderRange = c.snapshotRangeUse()
      c.constrain(same,child.ordinal-prior.ordinal-constant(1),constant(0))
      c.constrain(same,child.start-prior.finish,constant(0))
    let first = child.active-same
    c.constrain(first,child.ordinal,constant(0))
    c.constrain(first,child.start-bounds.params,constant(0))
    var continues = constant(0)
    if i+1 < children.len:
      when defined(zkbuildOwnedAudit): childAudit.nextZero = c.values.len
      continues = c.multiply(children[i+1].active,c.zeroIndicator(children[i+1].owner-child.owner))
    let last = child.active-continues
    c.constrain(last,child.ordinal+constant(1)-count,constant(0))
    c.constrain(last,child.finish-bounds.results,constant(0))
    seen = seen+child.active
    previous = child.active
    when defined(zkbuildOwnedAudit):
      childAudit.same = copyAuditExpressions([same])[0]
      childAudit.continues = copyAuditExpressions([continues])[0]
      childAudit.lastGate = c.constraints.len
      audit.children.add childAudit
  when defined(zkbuildOwnedAudit): audit.closeStart = c.constraints.len
  c.assertEqual(total,seen)
  when defined(zkbuildOwnedAudit):
    audit.closeEnd = c.constraints.len
    audit.tables.add c.readOnlyRecords.len
  c.constrainReadOnly(counts,queries,buildReadOnlyWitness(countValues,reads),32,32)
  when defined(zkbuildOwnedAudit): audit.tables.add c.readOnlyRecords.len
  c.constrainReadOnly(spans,spanQueries,buildReadOnlyWitness(spanValues,spanReads),32,64)
  when defined(zkbuildOwnedAudit): c.ownedRecords.add audit
