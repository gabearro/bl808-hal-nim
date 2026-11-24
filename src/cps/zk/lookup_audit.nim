## Audit-only reduced decision-DAG records. No witness data is serialized.
import std/strutils
import r1cs, token_audit

proc line(value: Linear): string =
  result = $value.len
  for term in value:
    result.add " " & $term.wire & ":"
    for b in encodeScalar(term.coefficient): result.add toHex(b,2).toLowerAscii()

proc writeLookupRecord*(f: File, r: LookupAudit) =
  f.writeLine("L ",r.firstWire," ",r.lastWire," ",r.firstGate," ",r.lastGate,
    " ",r.root," ",r.columns," ",r.nodes.len)
  f.writeLine(line(r.input))
  for value in r.outputs: f.writeLine(line(value))
  f.writeUse(r.range)
  for node in r.nodes:
    var header = "N " & $(node.bit+1) & " " & $node.zero & " " & $node.one
    for value in node.payload: header.add " " & $value
    f.writeLine(header)

proc writeLookupAudit*(path: string, c: Circuit) =
  when not defined(zkbuildLookupAudit):
    raise newException(ValueError,"lookup evidence requires -d:zkbuildLookupAudit and its dependencies")
  else:
    let f = open(path,fmWrite)
    defer: f.close()
    f.writeLine("ZKLOOKUP1 ",c.values.len," ",c.publicCount," ",c.constraints.len," ",c.lookupRecords.len)
    for gate in c.constraints:
      for side in [gate.a,gate.b,gate.c]: f.writeLine(line(side))
    for record in c.lookupRecords: f.writeLookupRecord(record)
