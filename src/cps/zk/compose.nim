## Wire substitution for composing independently specified R1CS relations.
import r1cs
export r1cs

func remap*(expression: Linear, wires: openArray[Linear]): Linear =
  for term in expression:
    if term.wire < 0 or term.wire >= wires.len:
      raise newException(ValueError, "invalid source wire in circuit composition")
    result = result + wires[term.wire].scale(term.coefficient)

proc appendCircuit*(destination: var Circuit, source: Circuit,
                    publicWires: openArray[Linear]): seq[Linear] =
  ## Bind the source's public wires to caller-selected expressions. Remaining
  ## wires are fresh and private; source constraints retain their order.
  if source.values.len == 0 or not source.values[0].equals(scalar(1)) or
      publicWires.len != source.publicCount:
    raise newException(ValueError, "invalid source circuit interface")
  result.add constant(1)
  for value in publicWires: result.add value
  for i in source.publicCount+1 ..< source.values.len:
    result.add destination.allocate(source.values[i])
  for gate in source.constraints:
    destination.constrain(remap(gate.a, result), remap(gate.b, result), remap(gate.c, result))
