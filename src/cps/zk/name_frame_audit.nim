## Name length headers, byte cursors, and their shared-stream/table links.
import std/strutils
import r1cs, owned_audit, import_audit, signature_audit, declaration_audit, indexed_audit
import envelope_audit, readonly_audit, packed_audit, token_audit

proc line(value: Linear): string =
  result = $value.len
  for term in value:
    result.add " " & $term.wire & ":"
    for b in encodeScalar(term.coefficient): result.add toHex(b,2).toLowerAscii()

proc writeNameFrameRecords*(f: File, c: Circuit) =
  when not defined(zkbuildNameFrameAudit):
    raise newException(ValueError,"name framing evidence requires -d:zkbuildNameFrameAudit")
  else:
    for record in c.nameFrameRecords:
      f.writeLine("N ",ord(record.flat)," ",record.owned," ",record.headers.len," ",record.bytes.len)
      for h in record.headers:
        if h.fields.len != 5 or h.ranges.len != (if record.flat: 0 else: 2):
          raise newException(ValueError,"invalid name header evidence")
        f.writeLine("H ",h.firstGate," ",h.lastGate," ",h.token," ",h.byteStart," ",h.byteCount," ",h.closeGate)
        for value in h.fields: f.writeLine(line(value))
        for range in h.ranges: f.writeUse(range)
      for b in record.bytes:
        if b.fields.len != 5: raise newException(ValueError,"invalid name byte evidence")
        f.writeLine("Y ",b.firstGate," ",b.lastGate," ",b.token)
        for value in b.fields: f.writeLine(line(value))

proc writeNameFrameAudit*(path: string, c: Circuit) =
  when not defined(zkbuildNameFrameAudit):
    raise newException(ValueError,"name framing evidence requires -d:zkbuildNameFrameAudit")
  else:
    requireEnvelopeAuditSource(c)
    if c.declarationRecords.len != 1 or c.indexedRecords.len != 1 or c.signatureRecords.len != 1 or
        c.signatureNamespaceRecords.len != 1 or c.importRecords.len != 1 or c.nameFrameRecords.len != 1:
      raise newException(ValueError,"name framing evidence requires exactly one complete module")
    let f = open(path,fmWrite)
    defer: f.close()
    f.writeLine("ZKNAMEFRAME1 ",c.values.len," ",c.publicCount," ",c.constraints.len,
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
    f.writeNameFrameRecords(c)
