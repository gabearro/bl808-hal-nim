## Function/type origin and shared-list environment constraint evidence.
import std/strutils
import r1cs, declaration_audit, indexed_audit, envelope_audit, readonly_audit, packed_audit, token_audit

proc line(value: Linear): string =
  result = $value.len
  for term in value:
    result.add " " & $term.wire & ":"
    for b in encodeScalar(term.coefficient): result.add toHex(b,2).toLowerAscii()

proc reference(f: File, r: SignatureReferenceAudit) =
  f.writeLine("R ",r.zeroStart)
  for value in r.query: f.writeLine(line(value))

proc writeSignatureRecord*(f: File, r: SignatureAudit) =
  f.writeLine("S ",r.metadata.len," ",r.nodes.len," ",r.extraMetadata.len div 3," ",r.extraOperands.len div 3)
  var indices = "B"
  for i in r.tables: indices.add " " & $i
  f.writeLine(indices)
  for value in r.extraMetadata & r.extraOperands: f.writeLine(line(value))
  for row in r.metadata:
    f.writeLine("M ",row.firstGate," ",row.lastGate," ",row.heads)
    for value in row.entry & @[row.typeIndex]: f.writeLine(line(value))
    for item in row.references: f.reference(item)
    f.writeUse(row.addressRange)
    f.writeUse(row.typeIndexRange)
    f.writeLine(line(row.functionEntry))
    for value in row.origin: f.writeLine(line(value))
  for row in r.nodes:
    f.writeLine("N ",row.firstGate," ",row.lastGate," ",row.node," ",row.tagZero)
    for value in row.entry & @[row.delta]: f.writeLine(line(value))
    f.writeUse(row.deltaRange)
    f.reference(row.reference)

proc writeNamespaceRecord*(f: File, r: SignatureNamespaceAudit) =
  f.writeLine("D ",r.rows.len," ",r.firstAliasStart," ",r.firstAliasEnd," ",r.closeStart," ",r.closeEnd,
    " ",r.typeBindStart," ",r.typeBindEnd," ",r.functionBindStart," ",r.functionBindEnd)
  for value in [r.functions,r.types,r.importedFunctions,r.firstFunction]: f.writeLine(line(value))
  f.writeUse(r.importedRange)
  for row in r.rows:
    f.writeLine("Q ",row.firstGate," ",row.lastGate)
    for value in row.entry: f.writeLine(line(value))
    f.writeUse(row.addressRange)
    for value in [row.typeEntry,row.index,row.functions,row.types]: f.writeLine(line(value))

proc writeSignatureAudit*(path: string, c: Circuit) =
  when not defined(zkbuildSignatureAudit):
    raise newException(ValueError,"signature evidence requires -d:zkbuildSignatureAudit")
  else:
    requireEnvelopeAuditSource(c)
    if c.declarationRecords.len != 1 or c.indexedRecords.len != 1 or c.signatureRecords.len != 1 or c.signatureNamespaceRecords.len != 1:
      raise newException(ValueError,"signature evidence requires exactly one module")
    let f = open(path,fmWrite)
    defer: f.close()
    f.writeLine("ZKSIGNATURES2 ",c.values.len," ",c.publicCount," ",c.constraints.len,
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
