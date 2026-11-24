## Concrete packed-field circuits, including exact 64-bit boundaries.
import std/[os,strutils]
import cps/zk/[r1cs,range_check,packed_fields,packed_audit,gadget_audit]

proc main() =
  if paramCount() != 3: quit("usage: audit_packed MODE META AUDIT",1)
  let mode = paramStr(1)
  let low = if mode.endsWith("node"): 3 elif mode.endsWith("tiny"): 1 else: 32
  let highWidth = if low == 1: 1 else: 32
  let mask = if low+highWidth == 64: high(uint64) else: (1'u64 shl (low+highWidth))-1
  let inputs = @[0'u64,1,mask,mask-1,(0x12345678abcdef01'u64 and mask)]
  var circuit = initCircuit(reuseRangeWitnesses = true)
  var wires: seq[Linear]
  for value in inputs:
    wires.add(if mode.startsWith("literal"): constant(value) else: circuit.publicInput(scalar(value)))
  for i,value in inputs:
    let input = wires[i]
    if mode.startsWith("cached"): discard circuit.constrainUnsigned(input,low+highWidth)
    let parts = circuit.splitPackedFields(input,low,highWidth)
    doAssert parts.low.evaluate(circuit.values).equals(scalar(value and ((1'u64 shl low)-1)))
    doAssert parts.high.evaluate(circuit.values).equals(scalar(value shr low))
  doAssert circuit.satisfied()
  let hashes = circuit.fingerprints()
  writeFile(paramStr(2),$circuit.values.len & " " & $circuit.publicCount & " " & $circuit.constraints.len & "\n" & hashes.matrix & "\n" & hashes.witness & "\n")
  if paramStr(3) != "-": writePackedAudit(paramStr(3),circuit)
  echo "packed fields ",mode," constraints=",circuit.constraints.len
main()
