## Exact indexed signature-list constraints, linked to source declarations.
import std/strutils
import r1cs, declaration_audit, envelope_audit, readonly_audit, packed_audit

proc line(value: Linear): string =
  result = $value.len
  for term in value:
    result.add " " & $term.wire & ":"
    for b in encodeScalar(term.coefficient): result.add toHex(b,2).toLowerAscii()

proc writeIndexedRecord*(f: File, r: IndexedAudit) =
  f.writeLine("X ",r.lengths.len," ",r.members.len," ",r.metadata.len," ",r.singletons.len)
  f.writeLine("N ",r.nilStart," ",r.nilEnd)
  var indices = "B"
  for i in r.tables: indices.add " " & $i
  f.writeLine(indices)
  f.writeLine("E ",r.extraLengths.len div 3," ",r.extraMembers.len div 3," ",r.extraSingletons.len div 3)
  for value in r.extraLengths & r.extraMembers & r.extraSingletons: f.writeLine(line(value))
  for row in r.lengths:
    f.writeLine("L ",row.firstGate," ",row.lastGate," ",row.headZero," ",row.lengthZero)
    for value in row.fields & @[row.nonempty] & row.firstMember: f.writeLine(line(value))
  for row in r.members:
    f.writeLine("M ",row.firstGate," ",row.lastGate," ",row.addressSplit," ",row.cellSplit," ",row.nodeSplit,
      " ",row.headZero," ",row.cursorZero," ",row.tagZero," ",row.continuationZero)
    for value in row.fields & row.nodeQuery & row.lengthQuery & @[row.continuing]: f.writeLine(line(value))
  for row in r.closing: f.writeLine("J ",row.firstGate," ",row.lastGate)
  for row in r.metadata:
    f.writeLine("H ",row.firstGate," ",row.lastGate," ",row.heads)
    for value in row.fields & row.params & row.results: f.writeLine(line(value))
  for row in r.singletons:
    f.writeLine("S ",row.firstGate," ",row.lastGate)
    for value in row.fields & row.nodeQuery: f.writeLine(line(value))

proc writeIndexedAudit*(path: string, c: Circuit) =
  when not defined(zkbuildIndexedAudit):
    raise newException(ValueError,"indexed evidence requires -d:zkbuildIndexedAudit")
  else:
    requireEnvelopeAuditSource(c)
    if c.declarationRecords.len != 1 or c.indexedRecords.len != 1:
      raise newException(ValueError,"indexed evidence requires exactly one module")
    let f = open(path,fmWrite)
    defer: f.close()
    f.writeLine("ZKINDEXED1 ",c.values.len," ",c.publicCount," ",c.constraints.len,
      " ",c.binaryReadMemoryRecords[0].queries.len div 3," ",c.tokenRecords.len," ",c.readOnlyRecords.len," ",c.packedRecords.len)
    for gate in c.constraints:
      for side in [gate.a,gate.b,gate.c]: f.writeLine(line(side))
    f.writeEnvelopeBody(c)
    f.writeReadOnlyRecords(c)
    f.writePackedRecords(c)
    f.writeDeclarationRecord(c.declarationRecords[0])
    f.writeIndexedRecord(c.indexedRecords[0])
