import std/[os,strutils]
import cps/zk/[r1cs,wasm_owned_stream,gadget_audit,owned_audit]

proc fixtures(mode: string): tuple[parents: seq[OwnedParent], children: seq[OwnedChild]] =
  if mode == "empty": return
  if mode == "empty-parent":
    result.parents = @[OwnedParent(active: true,start: 10,finish: 10)]
    return
  if mode == "one":
    result.parents = @[OwnedParent(active: true,count: 1,start: 10,finish: 11)]
    result.children = @[OwnedChild(active: true,start: 10,finish: 11)]
    return
  if mode == "wide":
    result.parents = @[OwnedParent(active: true,count: 2,start: high(uint32)-2,finish: high(uint32))]
    result.children = @[OwnedChild(active: true,start: high(uint32)-2,finish: high(uint32)-1),
      OwnedChild(active: true,ordinal: 1,start: high(uint32)-1,finish: high(uint32))]
    return
  result.parents = @[
    OwnedParent(active: true,count: 2,start: 10,finish: 15),
    OwnedParent(active: true,start: 20,finish: 20),
    OwnedParent(active: true,count: 3,start: 30,finish: 36)]
  result.children = @[
    OwnedChild(active: true,owner: 0,ordinal: 0,start: 10,finish: 12),
    OwnedChild(active: true,owner: 0,ordinal: 1,start: 12,finish: 15),
    OwnedChild(active: true,owner: 2,ordinal: 0,start: 30,finish: 31),
    OwnedChild(active: true,owner: 2,ordinal: 1,start: 31,finish: 35),
    OwnedChild(active: true,owner: 2,ordinal: 2,start: 35,finish: 36)]
  case mode
  of "multi","fresh","reuse","literal": discard
  of "padded":
    result.parents.setLen(5)
    result.children.setLen(8)
  of "bad-missing": result.children.setLen(4)
  of "bad-duplicate": result.children[1].ordinal = 0
  of "bad-ordinal": result.children[1].ordinal = 2
  of "bad-owner": result.children[2].owner = 3
  of "bad-first": result.children[0].start = 11
  of "bad-gap": result.children[1].start = 13
  of "bad-last": result.children[4].finish = 35
  of "bad-parent-hole": result.parents[1].active = false
  of "bad-child-hole": result.children[1] = OwnedChild()
  of "bad-empty": result.parents[1].finish = 21
  else: raise newException(ValueError,"unknown owned fixture")

proc main() =
  if paramCount() != 3: quit("usage: zkbuild_audit_owned MODE META AUDIT_OR_DASH",1)
  let mode = paramStr(1)
  let fixture = fixtures(mode)
  var c = initCircuit(reuseRangeWitnesses = mode != "fresh")
  template input(value: untyped): Linear =
    (if mode == "literal": constant(value) else: c.allocate(scalar(value)))
  var parents: seq[OwnedParentWires]
  var children: seq[OwnedChildWires]
  for p in fixture.parents:
    parents.add OwnedParentWires(active: input(ord(p.active)),count: input(p.count),start: input(p.start),finish: input(p.finish))
  for child in fixture.children:
    children.add OwnedChildWires(active: input(ord(child.active)),owner: input(child.owner),ordinal: input(child.ordinal),start: input(child.start),finish: input(child.finish))
  if mode == "reuse":
    children[0].start = parents[0].start
    children[1].finish = parents[0].finish
    children[2].start = parents[2].start
    children[4].finish = parents[2].finish
  c.constrainOwnedStream(parents,children,fixture.parents,fixture.children)
  if not c.satisfied(): raise newException(ValueError,"owned stream constraints rejected witness")
  let hashes = c.fingerprints()
  writeFile(paramStr(2),$c.values.len & " " & $c.publicCount & " " & $c.constraints.len & "\n" & hashes.matrix & "\n" & hashes.witness & "\n")
  if paramStr(3) != "-": writeOwnedFragmentAudit(paramStr(3),c)
  echo "owned fixture ",mode," constraints=",c.constraints.len
main()
