import std/[os,strutils]
import cps/wasm/binary_order
import cps/zk/[r1cs,range_check,opcode_lookup,lookup_audit,gadget_audit]

proc main() =
  if paramCount() != 3: quit("usage: audit_lookup MODE META AUDIT",1)
  let mode = paramStr(1)
  let parts = mode.split('-')
  let code = parseInt(parts[^1])
  var table = newSeq[array[2,int]](65536)
  for i in 0..255:
    let rank = binarySectionOrder(i)
    if rank >= 0: table[i] = [1,rank]
  let lookup = buildOpcodeLookup(table)
  var c = initCircuit(reuseRangeWitnesses = true)
  let input = if parts[0] == "literal": constant(code) else: c.publicInput(scalar(code))
  if parts[0] == "cached": discard c.constrainUnsigned(input,16)
  let outputs = c.constrainLookup(lookup,input)
  doAssert c.satisfied()
  let expected = lookup.lookupValue(uint16(code))
  for i in 0..1: doAssert outputs[i].evaluate(c.values).equals(scalar(expected[i]))
  let hashes = c.fingerprints()
  writeFile(paramStr(2),$c.values.len & " " & $c.publicCount & " " & $c.constraints.len & "\n" & hashes.matrix & "\n" & hashes.witness & "\n")
  if paramStr(3) != "-": writeLookupAudit(paramStr(3),c)
  echo "lookup ",mode," branches=",lookup.lookupBranches," gates=",c.constraints.len
main()
