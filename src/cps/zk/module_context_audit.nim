## Whole-module semantic-rule replay; no private assignment is exported.
import std/strutils
import r1cs, segment_payload_audit, scalar_payload_audit, constant_source_audit
import name_source_audit, name_graph_audit, name_frame_audit, owned_audit, import_audit
import signature_audit, declaration_audit, indexed_audit, envelope_audit, readonly_audit, packed_audit, token_audit
proc line(value: Linear): string =
  result = $value.len
  for term in value:
    result.add " " & $term.wire & ":"
    for b in encodeScalar(term.coefficient): result.add toHex(b,2).toLowerAscii()
proc arrayRows(f: File, rows: seq[seq[Linear]]) =
  f.writeLine("A ",rows.len)
  for row in rows:
    f.writeLine("D ",row.len)
    for field in row: f.writeLine(line(field))
proc writeModuleContextRecords*(f: File, c: Circuit) =
  when not defined(zkbuildModuleContextAudit):
    raise newException(ValueError,"module context evidence requires -d:zkbuildModuleContextAudit")
  else:
    for r in c.moduleContextRecords:
      f.writeLine("M ",ord(r.flat)," ",r.ownedIndex+1," ",r.elementBank+1," ",r.startBindFirst," ",r.startBindLast)
      if r.counts.len != 14: raise newException(ValueError,"invalid module counter interface")
      for value in r.counts: f.writeLine(line(value))
      f.arrayRows(r.memories)
      f.arrayRows(r.tables)
      f.arrayRows(r.globals)
      f.writeLine("E ",r.elements.len)
      for row in r.elements:
        f.arrayRows(@[row.fields,row.offset])
        f.arrayRows(row.items)
      for rows in [r.items,r.datas,r.exports,r.unique,r.bodies,r.bulk]: f.arrayRows(rows)
      f.writeLine("H ",r.heads.len)
      for head in r.heads: f.writeLine(line(head))
      var banks = "T " & $r.banks.len
      for index in r.banks: banks.add " " & $index
      f.writeLine(banks)
      f.writeLine("P ",r.programs.len)
      for program in r.programs:
        f.writeLine("K ",program.firstGate," ",program.lastGate," ",program.primitives.len)
        for primitive in program.primitives: f.writeUse(primitive)

proc writeModuleContextAudit*(path: string, c: Circuit, magic = "ZKMODULECONTEXT1") =
  when not defined(zkbuildModuleContextAudit):
    raise newException(ValueError,"module context evidence requires -d:zkbuildModuleContextAudit")
  else:
    requireEnvelopeAuditSource(c)
    if c.declarationRecords.len != 1 or c.indexedRecords.len != 1 or c.signatureRecords.len != 1 or
        c.signatureNamespaceRecords.len != 1 or c.importRecords.len != 1 or c.nameFrameRecords.len != 1 or
        c.nameGraphRecords.len != 1 or c.nameSourceRecords.len != 1 or c.scalarPayloadRecords.len != 1 or c.segmentPayloadRecords.len != 1 or c.moduleContextRecords.len != 1:
      raise newException(ValueError,"module context evidence requires exactly one complete module")
    let f = open(path,fmWrite)
    defer: f.close()
    f.writeLine(magic," ",c.values.len," ",c.publicCount," ",c.constraints.len,
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
    f.writeScalarPayloadRecords(c)
    f.writeSegmentPayloadRecords(c)
    f.writeModuleContextRecords(c)
