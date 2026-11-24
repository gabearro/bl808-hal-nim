## Full byte-envelope evidence layered on the authenticated token matrices.
import std/strutils
import r1cs, binary_read_audit, token_audit, lookup_audit

proc line(value: Linear): string =
  result = $value.len
  for term in value:
    result.add " " & $term.wire & ":"
    for b in encodeScalar(term.coefficient): result.add toHex(b,2).toLowerAscii()

proc requireEnvelopeAuditSource*(c: Circuit) =
  when not defined(zkbuildEnvelopeAudit):
    raise newException(ValueError,"envelope evidence requires -d:zkbuildEnvelopeAudit and its dependencies")
  else:
    if c.envelopeRecords.len != 1 or c.binaryReadMemoryRecords.len != 1:
      raise newException(ValueError,"envelope evidence requires one source and envelope")
    let r = c.envelopeRecords[0]
    if r.sourceIndex != c.binaryReadMemoryRecords[0].sourceIndex:
      raise newException(ValueError,"detached envelope source")

proc writeEnvelopeBody*(f: File, c: Circuit) =
  requireEnvelopeAuditSource(c)
  when defined(zkbuildEnvelopeAudit):
    let r = c.envelopeRecords[0]
    writeBinaryReadBody(f,c)
    writeTokenRecords(f,c)
    f.writeLine("E ",r.firstWire," ",r.lastWire," ",r.firstGate," ",r.lastGate," ",r.rows.len,
      " ",r.headerTokens.len," ",r.outputs.len)
    f.writeLine(line(r.sourceLength))
    var header = "H"
    for id in r.headerTokens: header.add " " & $id
    f.writeLine(header)
    for row in r.rows:
      f.writeLine("J ",row.idToken," ",row.sizeToken," ",row.wordToken," ",row.standardStart," ",row.aggregateStart)
      for value in row.fields: f.writeLine(line(value))
      for range in row.ranges: f.writeUse(range)
      for value in [row.sizePosition,row.remaining,row.standard,row.rankGap,row.nextRank,row.wordGap,row.cursor]: f.writeLine(line(value))
      for range in [row.remainingRange,row.rankGapRange,row.wordGapRange]: f.writeUse(range)
      f.writeLookupRecord(row.lookup)
    for value in r.outputs: f.writeLine(line(value))

proc writeEnvelopeAudit*(path: string, c: Circuit) =
  when not defined(zkbuildEnvelopeAudit):
    raise newException(ValueError,"envelope evidence requires -d:zkbuildEnvelopeAudit and its dependencies")
  else:
    requireEnvelopeAuditSource(c)
    let f = open(path,fmWrite)
    defer: f.close()
    f.writeLine("ZKENVELOPE1 ",c.values.len," ",c.publicCount," ",c.constraints.len,
      " ",c.binaryReadMemoryRecords[0].queries.len div 3," ",c.tokenRecords.len)
    for gate in c.constraints:
      for side in [gate.a,gate.b,gate.c]: f.writeLine(line(side))
    f.writeEnvelopeBody(c)
