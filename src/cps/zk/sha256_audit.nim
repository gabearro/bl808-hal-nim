## Offline matrix evidence for SHA calls embedded in larger validation circuits.
## Contains constraints and wire references, never witness values or key material.
import std/strutils
import r1cs

proc hex(value: Scalar): string =
  for b in encodeScalar(value): result.add toHex(b,2).toLowerAscii()

proc line(value: Linear): string =
  result = $value.len
  for term in value: result.add " " & $term.wire & ":" & hex(term.coefficient)

proc writeSha256Record*(f: File, row: Sha256Record) =
  f.writeLine("S ",row.firstWire," ",row.lastWire," ",row.firstGate," ",row.lastGate," ",row.source.len)
  f.writeLine(line(row.length))
  for value in row.digest: f.writeLine(line(value))
  for value in row.source: f.writeLine(line(value))
  let r = row.lengthRange
  f.writeLine("R ",ord(r.kind)," ",r.width," ",r.firstWire," ",r.lastWire,
    " ",r.firstGate," ",r.lastGate," ",r.reference+1," ",r.inputs.len," ",r.outputs.len)
  for value in r.inputs: f.writeLine(line(value))
  for value in r.outputs: f.writeLine(line(value))

proc writeSha256Records*(f: File, c: Circuit) =
  when not defined(zkbuildShaAudit):
    raise newException(ValueError,"SHA records require -d:zkbuildShaAudit")
  else:
    for row in c.sha256Records: writeSha256Record(f,row)

proc writeSha256Audit*(path: string, c: Circuit) =
  when not defined(zkbuildShaAudit):
    raise newException(ValueError,"SHA audit requires -d:zkbuildShaAudit -d:zkbuildGadgetAudit")
  else:
    let f = open(path,fmWrite)
    defer: f.close()
    f.writeLine("ZKSHAEMBED1 ",c.values.len," ",c.publicCount," ",c.constraints.len," ",c.sha256Records.len)
    for gate in c.constraints:
      for side in [gate.a,gate.b,gate.c]: f.writeLine(line(side))
    writeSha256Records(f,c)
