## Complete constant-expression reader evidence, without private assignments.
import std/strutils
import r1cs, name_source_audit, name_graph_audit, name_frame_audit, owned_audit
import import_audit, signature_audit, declaration_audit, indexed_audit
import envelope_audit, readonly_audit, packed_audit

proc line(value: Linear): string =
  result = $value.len
  for term in value:
    result.add " " & $term.wire & ":"
    for b in encodeScalar(term.coefficient): result.add toHex(b,2).toLowerAscii()

proc writeConstantSourceRecords*(f: File, c: Circuit) =
  when not defined(zkbuildConstantSourceAudit):
    raise newException(ValueError,"constant source evidence requires -d:zkbuildConstantSourceAudit")
  else:
    f.writeLine("C ",c.constantSourceRecords.len)
    for r in c.constantSourceRecords:
      if r.fields.len != 18 or r.selectors.len != 8 or r.zeroStarts.len != 8 or r.reads.len != 6:
        raise newException(ValueError,"invalid constant source record")
      var header = "K " & $r.firstGate & " " & $r.lastGate & " " & $r.heads
      for start in r.zeroStarts: header.add " " & $start
      f.writeLine(header)
      for field in r.fields & r.selectors: f.writeLine(line(field))
      for read in r.reads:
        f.writeLine("R ",read.token)
        f.writeLine(line(read.cursor))

proc writeConstantSourceAudit*(path: string, c: Circuit) =
  when not defined(zkbuildConstantSourceAudit):
    raise newException(ValueError,"constant source evidence requires -d:zkbuildConstantSourceAudit")
  else:
    requireEnvelopeAuditSource(c)
    if c.declarationRecords.len != 1 or c.indexedRecords.len != 1 or c.signatureRecords.len != 1 or
        c.signatureNamespaceRecords.len != 1 or c.importRecords.len != 1 or c.nameFrameRecords.len != 1 or
        c.nameGraphRecords.len != 1 or c.nameSourceRecords.len != 1:
      raise newException(ValueError,"constant source evidence requires exactly one complete module")
    let f = open(path,fmWrite)
    defer: f.close()
    f.writeLine("ZKCONSTANTSOURCE1 ",c.values.len," ",c.publicCount," ",c.constraints.len,
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
    f.writeNameGraphRecords(c)
    f.writeNameSourceRecords(c)
    f.writeConstantSourceRecords(c)
