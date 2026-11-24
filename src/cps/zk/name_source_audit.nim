## Source-byte/name-graph linkage evidence, without field assignments.
import std/strutils
import r1cs, name_graph_audit, name_frame_audit, owned_audit, import_audit, signature_audit
import declaration_audit, indexed_audit, envelope_audit, readonly_audit, packed_audit, token_audit

proc line(value: Linear): string =
  result = $value.len
  for term in value:
    result.add " " & $term.wire & ":"
    for b in encodeScalar(term.coefficient): result.add toHex(b,2).toLowerAscii()

proc writeNameSourceRecords*(f: File, c: Circuit) =
  when not defined(zkbuildNameSourceAudit):
    raise newException(ValueError,"name source evidence requires -d:zkbuildNameSourceAudit")
  else:
    for source in c.nameSourceRecords:
      f.writeLine("S ",source.headers.len," ",source.bytes.len," ",source.ends.len," ",source.tables.len)
      var tables = "B"
      for index in source.tables: tables.add " " & $index
      f.writeLine(tables)
      for h in source.headers:
        f.writeLine("H ",h.firstGate," ",h.lastGate," ",h.zeroStart," ",h.nilGate)
        for field in [h.head,h.finalHead]: f.writeLine(line(field))
      for b in source.bytes:
        if b.nodeQuery.len != 3 or b.rootQuery.len != 3 or b.fields.len != 3:
          raise newException(ValueError,"invalid source-name byte evidence")
        f.writeLine("J ",b.firstGate," ",b.lastGate," ",b.zeroStart," ",b.tailGate)
        for field in b.nodeQuery & b.rootQuery & b.fields: f.writeLine(line(field))
        f.writeUse(b.range)
      for e in source.ends:
        if e.countQuery.len != 3: raise newException(ValueError,"invalid source-name ending evidence")
        f.writeLine("E ",e.firstGate," ",e.lastGate," ",e.zeroStart)
        for field in @[e.tail,e.selector] & e.countQuery: f.writeLine(line(field))
        f.writeUse(e.range)

proc writeNameSourceAudit*(path: string, c: Circuit) =
  when not defined(zkbuildNameSourceAudit):
    raise newException(ValueError,"name source evidence requires -d:zkbuildNameSourceAudit")
  else:
    requireEnvelopeAuditSource(c)
    if c.declarationRecords.len != 1 or c.indexedRecords.len != 1 or c.signatureRecords.len != 1 or
        c.signatureNamespaceRecords.len != 1 or c.importRecords.len != 1 or c.nameFrameRecords.len != 1 or
        c.nameGraphRecords.len != 1 or c.nameSourceRecords.len != 1:
      raise newException(ValueError,"name source evidence requires exactly one complete module")
    let f = open(path,fmWrite)
    defer: f.close()
    f.writeLine("ZKNAMESOURCE1 ",c.values.len," ",c.publicCount," ",c.constraints.len,
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
