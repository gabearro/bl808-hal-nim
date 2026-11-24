## Packed field boundaries and ranges; never contains witness assignments.
import std/strutils
import r1cs, token_audit

proc line(value: Linear): string =
  result = $value.len
  for term in value:
    result.add " " & $term.wire & ":"
    for b in encodeScalar(term.coefficient): result.add toHex(b,2).toLowerAscii()

proc writePackedRecords*(f: File, c: Circuit) =
  when not defined(zkbuildPackedAudit):
    raise newException(ValueError,"packed field evidence requires -d:zkbuildPackedAudit")
  else:
    for row in c.packedRecords:
      f.writeLine("F ",row.lowWidth," ",row.highWidth," ",row.firstGate," ",row.lastGate)
      for value in [row.input,row.low,row.high]: f.writeLine(line(value))
      f.writeUse(row.range)

proc writePackedAudit*(path: string, c: Circuit) =
  when not defined(zkbuildPackedAudit):
    raise newException(ValueError,"packed field evidence requires -d:zkbuildPackedAudit")
  else:
    let f = open(path,fmWrite)
    defer: f.close()
    f.writeLine("ZKPACKED1 ",c.values.len," ",c.publicCount," ",c.constraints.len," ",c.packedRecords.len)
    for gate in c.constraints:
      for side in [gate.a,gate.b,gate.c]: f.writeLine(line(side))
    f.writePackedRecords(c)
