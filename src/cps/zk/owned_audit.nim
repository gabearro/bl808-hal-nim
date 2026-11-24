## Shared parent/child stream constraint evidence, without witness values.
import std/strutils
import r1cs, import_audit, signature_audit, declaration_audit, indexed_audit
import envelope_audit, readonly_audit, packed_audit, token_audit

proc line(value: Linear): string =
  result = $value.len
  for term in value:
    result.add " " & $term.wire & ":"
    for b in encodeScalar(term.coefficient): result.add toHex(b,2).toLowerAscii()

proc writeOwnedRecords*(f: File, c: Circuit) =
  when not defined(zkbuildOwnedAudit):
    raise newException(ValueError,"owned stream evidence requires -d:zkbuildOwnedAudit")
  else:
    for record in c.ownedRecords:
      if record.tables.len != 2: raise newException(ValueError,"invalid owned stream table count")
      f.writeLine("O ",record.parents.len," ",record.children.len," ",record.closeStart," ",record.closeEnd)
      f.writeLine("B ",record.tables[0]," ",record.tables[1])
      for parent in record.parents:
        if parent.fields.len != 4 or parent.ranges.len != 3:
          raise newException(ValueError,"invalid owned parent evidence")
        f.writeLine("P ",parent.firstGate," ",parent.lastGate," ",parent.zeroStart)
        for value in parent.fields: f.writeLine(line(value))
        for range in parent.ranges: f.writeUse(range)
      for i, child in record.children:
        if child.fields.len != 5 or child.ranges.len != 4 or child.countQuery.len != 3 or child.spanQuery.len != 3:
          raise newException(ValueError,"invalid owned child evidence")
        f.writeLine("C ",child.firstGate," ",child.lastGate," ",child.heads," ",child.priorZero," ",child.nextZero)
        for value in child.fields: f.writeLine(line(value))
        for range in child.ranges: f.writeUse(range)
        for value in child.countQuery & child.spanQuery & @[child.within,child.order,child.same,child.continues]: f.writeLine(line(value))
        f.writeUse(child.withinRange)
        if i > 0: f.writeUse(child.orderRange)

proc writeOwnedFragmentAudit*(path: string, c: Circuit) =
  when not defined(zkbuildOwnedAudit):
    raise newException(ValueError,"owned stream evidence requires -d:zkbuildOwnedAudit")
  else:
    let f = open(path,fmWrite)
    defer: f.close()
    f.writeLine("ZKOWNEDFRAG1 ",c.values.len," ",c.publicCount," ",c.constraints.len," ",c.readOnlyRecords.len," ",c.packedRecords.len," ",c.ownedRecords.len)
    for gate in c.constraints:
      for side in [gate.a,gate.b,gate.c]: f.writeLine(line(side))
    f.writeReadOnlyRecords(c)
    f.writePackedRecords(c)
    f.writeOwnedRecords(c)

proc writeOwnedAudit*(path: string, c: Circuit) =
  when not defined(zkbuildOwnedAudit) or not defined(zkbuildImportAudit):
    raise newException(ValueError,"module owned evidence requires owned and import audit dependencies")
  else:
    requireEnvelopeAuditSource(c)
    if c.declarationRecords.len != 1 or c.indexedRecords.len != 1 or c.signatureRecords.len != 1 or
        c.signatureNamespaceRecords.len != 1 or c.importRecords.len != 1:
      raise newException(ValueError,"owned evidence requires exactly one complete module")
    let f = open(path,fmWrite)
    defer: f.close()
    f.writeLine("ZKOWNED1 ",c.values.len," ",c.publicCount," ",c.constraints.len,
      " ",c.binaryReadMemoryRecords[0].queries.len div 3," ",c.tokenRecords.len," ",c.readOnlyRecords.len," ",c.packedRecords.len," ",c.ownedRecords.len)
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
    f.writeOwnedRecords(c)
