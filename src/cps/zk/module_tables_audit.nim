## Source-bound envelope and immutable-table evidence for the same full matrix.
import std/strutils
import r1cs, envelope_audit, readonly_audit, packed_audit

proc line(value: Linear): string =
  result = $value.len
  for term in value:
    result.add " " & $term.wire & ":"
    for b in encodeScalar(term.coefficient): result.add toHex(b,2).toLowerAscii()

proc writeModuleTablesAudit*(path: string, c: Circuit) =
  when not (defined(zkbuildEnvelopeAudit) and defined(zkbuildReadOnlyAudit) and defined(zkbuildPackedAudit)):
    raise newException(ValueError,"module table evidence requires envelope, read-only and packed-field audit flags")
  else:
    requireEnvelopeAuditSource(c)
    let f = open(path,fmWrite)
    defer: f.close()
    f.writeLine("ZKMODULETABLES2 ",c.values.len," ",c.publicCount," ",c.constraints.len,
      " ",c.binaryReadMemoryRecords[0].queries.len div 3," ",c.tokenRecords.len," ",c.readOnlyRecords.len," ",c.packedRecords.len)
    for gate in c.constraints:
      for side in [gate.a,gate.b,gate.c]: f.writeLine(line(side))
    f.writeEnvelopeBody(c)
    f.writeReadOnlyRecords(c)
    f.writePackedRecords(c)
