## Actual name-node circuit, independent of WASM framing.
import std/[os,strutils]
import cps/zk/[r1cs,range_check,read_only_memory,wasm_names,gadget_audit]
when defined(zkbuildNameGraphAudit): import cps/zk/name_graph_audit

proc main() =
  if paramCount() != 3: quit("usage: zkbuild_audit_names MODE META AUDIT_OR_DASH",1)
  let mode = paramStr(1)
  var names = case mode
    of "empty": newSeq[string]()
    of "empty-name": @[""]
    of "unicode": @["\xc2\x80", "\xe0\xa0\x80", "\xed\x9f\xbf", "\xf0\x90\x80\x80", "\xf4\x8f\xbf\xbf"]
    of "shared": @["abc", "xbc", "abc", "bc", "c", ""]
    else: @["ascii\0", "plain"]
  var env = buildNameEnvironment(names, if mode == "padded": 32 else: 0)
  case mode
  of "bad-id": env.nodes[0].address = 0
  of "bad-cycle":
    env.nodes[0].value = (env.nodes[0].value and 255) or 256
    env.canonical[0].address = env.nodes[0].value
  of "bad-state": env.nodes[0].value = env.nodes[0].value or (1'u64 shl 40)
  of "bad-root":
    env = buildNameEnvironment(["\xc2\x80"])
    env.heads[0] = 1
  of "bad-canonical": env.canonical[0].value = uint64(env.nodes.len+1)
  of "bad-padding":
    env = buildNameEnvironment(["a"],4)
    env.nodes[3].value = 1
  else: discard
  let witness = buildNameWitness(env)
  var circuit = initCircuit(reuseRangeWitnesses = mode != "fresh")
  var wires: NameEnvironmentWires
  if mode == "literal":
    for row in env.nodes: wires.nodes.add ReadOnlyWires(active: constant(ord(row.active)),address: constant(int(row.address)),value: constant(int(row.value)))
    for row in env.canonical: wires.canonical.add ReadOnlyWires(active: constant(ord(row.active)),address: constant(int(row.address)),value: constant(int(row.value)))
    for head in env.heads: wires.heads.add constant(int(head))
  else: wires = circuit.allocateNames(env,publicInputs = true)
  circuit.constrainNames(wires,witness)
  doAssert circuit.satisfied(),"unsatisfied name graph: " & mode
  let hashes = circuit.fingerprints()
  writeFile(paramStr(2),$circuit.values.len & " " & $circuit.publicCount & " " & $circuit.constraints.len & "\n" & hashes.matrix & "\n" & hashes.witness & "\n")
  if paramStr(3) != "-":
    when defined(zkbuildNameGraphAudit): writeNameGraphFragmentAudit(paramStr(3),circuit)
    else: raise newException(ValueError,"audit flag not enabled")
  echo "name graph ",mode," constraints=",circuit.constraints.len
main()
