import cps/zk/[r1cs,wasm_owned_stream]

proc build(parents: seq[OwnedParent], rows: seq[OwnedChild]): Circuit =
  result = initCircuit()
  var ps: seq[OwnedParentWires]
  var cs: seq[OwnedChildWires]
  for p in parents:
    ps.add OwnedParentWires(active: result.bit(p.active),count: result.allocate(scalar(p.count)),
      start: result.allocate(scalar(p.start)),finish: result.allocate(scalar(p.finish)))
  for row in rows:
    cs.add OwnedChildWires(active: result.bit(row.active),owner: result.allocate(scalar(row.owner)),
      ordinal: result.allocate(scalar(row.ordinal)),start: result.allocate(scalar(row.start)),
      finish: result.allocate(scalar(row.finish)))
  result.constrainOwnedStream(ps,cs,parents,rows)

let parents = @[
  OwnedParent(active: true,count: 2,start: 10,finish: 14),
  OwnedParent(active: true,count: 0,start: 19,finish: 19),
  OwnedParent(active: true,count: 1,start: 21,finish: 22),OwnedParent()]
let rows = @[
  OwnedChild(active: true,owner: 0,ordinal: 0,start: 10,finish: 12),
  OwnedChild(active: true,owner: 0,ordinal: 1,start: 12,finish: 14),
  OwnedChild(active: true,owner: 2,ordinal: 0,start: 21,finish: 22),OwnedChild()]
doAssert build(parents,rows).satisfied()
var failures: int
template badRow(change: untyped) =
  block:
    var r {.inject.} = rows
    change
    var rejected = false
    try: rejected = not build(parents,r).satisfied()
    except ValueError: rejected = true
    doAssert rejected,astToStr(change)
    inc failures
badRow: r[0].owner = 1
badRow: r[0].ordinal = 1
badRow: r[0].start = 11
badRow: r[0].finish = 13
badRow: r[1].start = 13
badRow: r[1].finish = 15
badRow: r[1].ordinal = 0
badRow: r[1] = OwnedChild()
badRow: r[2].owner = 3
badRow: r[2].owner = high(uint32)
badRow: r[2].ordinal = high(uint32)
badRow: r[2].finish = 23
badRow: r[3] = r[2]
badRow: r[3].owner = 1
var p = parents
p[1].finish = 20
doAssert not build(p,rows).satisfied()
echo "owned stream PASS: zero-count parents and ",failures+1," forgeries"
