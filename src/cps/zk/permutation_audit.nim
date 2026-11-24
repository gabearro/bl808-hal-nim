## Full-matrix evidence for exact permutation calls; excludes witness values.
import std/strutils
import r1cs

proc hex(value: Scalar): string =
  for b in encodeScalar(value): result.add toHex(b,2).toLowerAscii()
proc line(value: Linear): string =
  result = $value.len
  for term in value: result.add " " & $term.wire & ":" & hex(term.coefficient)

proc writePermutationAudit*(path: string, c: Circuit) =
  when not defined(zkbuildPermutationAudit):
    raise newException(ValueError,"permutation audit requires -d:zkbuildPermutationAudit")
  else:
    let f = open(path,fmWrite)
    defer: f.close()
    f.writeLine("ZKPERMUTE1 ",c.values.len," ",c.publicCount," ",c.constraints.len," ",c.permutationRecords.len)
    for gate in c.constraints:
      for side in [gate.a,gate.b,gate.c]: f.writeLine(line(side))
    for row in c.permutationRecords:
      var depth = 0
      var n = row.capacity
      while n > 1: inc depth; n = n shr 1
      f.writeLine("P ",depth," ",row.firstWire," ",row.lastWire," ",row.firstGate," ",row.lastGate," ",row.capacity)
      for value in row.inputs: f.writeLine(line(value))
      for value in row.outputs: f.writeLine(line(value))
