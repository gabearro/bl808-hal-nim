## Complete declaration-source relation metadata over the authenticated module.
import std/strutils
import r1cs, envelope_audit, readonly_audit, packed_audit, token_audit

proc line(value: Linear): string =
  result = $value.len
  for term in value:
    result.add " " & $term.wire & ":"
    for b in encodeScalar(term.coefficient): result.add toHex(b,2).toLowerAscii()

proc writeDeclarationRecord*(f: File, r: DeclarationAudit) =
  f.writeLine("C ",r.types.len," ",r.params.len," ",r.results.len," ",r.functions.len," ",r.tags.len)
  for value in [r.firstFunction,r.typeStart,r.typeEnd,r.typeCount,r.functionStart,r.functionEnd,r.functionCount,r.tagStart,r.tagEnd]: f.writeLine(line(value))
  f.writeLine("K ",r.typeCloseStart," ",r.typeCloseEnd," ",r.paramCloseStart," ",r.paramCloseEnd," ",
    r.resultCloseStart," ",r.resultCloseEnd," ",r.functionCloseStart," ",r.functionCloseEnd," ",r.tagCloseStart," ",r.tagCloseEnd)
  for value in [r.paramTotal,r.resultTotal]: f.writeLine(line(value))
  f.writeUse(r.paramTotalRange)
  f.writeUse(r.resultTotalRange)
  var indices = "B"
  for i in r.tables: indices.add " " & $i
  f.writeLine(indices)
  for row in r.types:
    f.writeLine("Y ",row.firstGate," ",row.lastGate," ",row.headerToken," ",row.paramToken," ",row.resultToken," ",row.heads)
    for value in row.fields & row.counts: f.writeLine(line(value))
    for range in row.ranges: f.writeUse(range)
    for value in [row.paramPosition,row.resultPosition,row.remaining]: f.writeLine(line(value))
    f.writeUse(row.remainingRange)
    for value in row.metadata & row.paramLength & row.resultLength: f.writeLine(line(value))
  for group in [r.params,r.results]:
    for row in group:
      f.writeLine("V ",row.firstGate," ",row.lastGate," ",row.tagZero," ",row.extendedZero," ",row.keySplit," ",row.spanSplit," ",row.heads," ",row.node," ",row.token," ",ord(row.hasOrder))
      for value in row.fields & row.location & row.metadata & row.member: f.writeLine(line(value))
      f.writeUse(row.addressRange)
      f.writeUse(row.valueRange)
      if row.hasOrder: f.writeUse(row.orderRange)
      f.writeUse(row.withinRange)
      for value in [row.orderDelta,row.within,row.code,row.position,row.memberKey,row.count]: f.writeLine(line(value))
  for row in r.functions:
    f.writeLine("F ",row.firstGate," ",row.lastGate," ",row.token)
    for value in @[row.active,row.cursor,row.count] & row.query: f.writeLine(line(value))
  for row in r.tags:
    f.writeLine("G ",row.firstGate," ",row.lastGate," ",row.attributeToken," ",row.indexToken)
    for value in [row.active,row.typeIndex,row.position,row.cursor]: f.writeLine(line(value))

proc writeDeclarationAudit*(path: string, c: Circuit) =
  when not defined(zkbuildDeclarationAudit):
    raise newException(ValueError,"declaration evidence requires -d:zkbuildDeclarationAudit")
  else:
    requireEnvelopeAuditSource(c)
    if c.declarationRecords.len != 1: raise newException(ValueError,"declaration evidence requires exactly one module")
    let f = open(path,fmWrite)
    defer: f.close()
    f.writeLine("ZKDECLARATIONS1 ",c.values.len," ",c.publicCount," ",c.constraints.len,
      " ",c.binaryReadMemoryRecords[0].queries.len div 3," ",c.tokenRecords.len," ",c.readOnlyRecords.len," ",c.packedRecords.len)
    for gate in c.constraints:
      for side in [gate.a,gate.b,gate.c]: f.writeLine(line(side))
    f.writeEnvelopeBody(c)
    f.writeReadOnlyRecords(c)
    f.writePackedRecords(c)
    f.writeDeclarationRecord(c.declarationRecords[0])
