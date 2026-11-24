## Complete source import-loop evidence. This contains no witness assignment.
import std/strutils
import r1cs, signature_audit, declaration_audit, indexed_audit, envelope_audit
import readonly_audit, packed_audit, token_audit

proc line(value: Linear): string =
  result = $value.len
  for term in value:
    result.add " " & $term.wire & ":"
    for b in encodeScalar(term.coefficient): result.add toHex(b,2).toLowerAscii()

proc writeImportRecord*(f: File, r: ImportAudit) =
  f.writeLine("I ",r.rows.len," ",r.closeStart," ",r.closeEnd)
  var indices = "B"
  for i in r.tables: indices.add " " & $i
  f.writeLine(indices)
  for value in [r.exportCount,r.importedFunctions,r.importedTables,r.importedMemories,r.importedGlobals]:
    f.writeLine(line(value))
  for row in r.rows:
    if row.names.len != 2 or row.reads.len != 7 or row.zeroStarts.len != 4 or
        row.indicators.len != 4 or row.counts.len != 4 or row.typeQuery.len != 3 or
        row.objectQuery.len != 3 or row.limitQueries.len != 12:
      raise newException(ValueError,"invalid source import evidence dimensions")
    var header = "J " & $row.firstGate & " " & $row.lastGate & " " & $row.typeZeroStart & " " & $row.limitHeads
    for start in row.zeroStarts: header.add " " & $start
    f.writeLine(header)
    for value in [row.active,row.kind,row.objectIndex]: f.writeLine(line(value))
    f.writeUse(row.kindRange)
    f.writeUse(row.objectRange)
    for value in row.indicators & row.counts & row.typeQuery & row.objectQuery & row.limitQueries: f.writeLine(line(value))
    for name in row.names:
      f.writeLine("H ",name.heads)
      for value in name.query: f.writeLine(line(value))
      f.writeLine(line(name.cursor))
    for read in row.reads:
      f.writeLine("E ",read.token)
      f.writeLine(line(read.cursor))

proc writeImportAudit*(path: string, c: Circuit) =
  when not defined(zkbuildImportAudit):
    raise newException(ValueError,"import evidence requires -d:zkbuildImportAudit")
  else:
    requireEnvelopeAuditSource(c)
    if c.declarationRecords.len != 1 or c.indexedRecords.len != 1 or c.signatureRecords.len != 1 or
        c.signatureNamespaceRecords.len != 1 or c.importRecords.len != 1:
      raise newException(ValueError,"import evidence requires exactly one complete module")
    let f = open(path,fmWrite)
    defer: f.close()
    f.writeLine("ZKIMPORTS1 ",c.values.len," ",c.publicCount," ",c.constraints.len,
      " ",c.binaryReadMemoryRecords[0].queries.len div 3," ",c.tokenRecords.len," ",c.readOnlyRecords.len," ",c.packedRecords.len)
    for gate in c.constraints:
      for side in [gate.a,gate.b,gate.c]: f.writeLine(line(side))
    f.writeEnvelopeBody(c)
    f.writeReadOnlyRecords(c)
    f.writePackedRecords(c)
    f.writeDeclarationRecord(c.declarationRecords[0])
    f.writeIndexedRecord(c.indexedRecords[0])
    f.writeSignatureRecord(c.signatureRecords[0])
    f.writeNamespaceRecord(c.signatureNamespaceRecords[0])
    f.writeImportRecord(c.importRecords[0])
