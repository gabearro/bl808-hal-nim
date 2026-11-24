## Source traversal evidence for elements, data, singleton and custom sections.
import std/strutils
import r1cs, scalar_payload_audit, constant_source_audit, name_source_audit, name_graph_audit, name_frame_audit
import owned_audit, import_audit, signature_audit, declaration_audit, indexed_audit
import envelope_audit, readonly_audit, packed_audit, token_audit
proc line(value: Linear): string =
  result = $value.len
  for term in value:
    result.add " " & $term.wire & ":"
    for b in encodeScalar(term.coefficient): result.add toHex(b,2).toLowerAscii()
proc writeRow(f: File, r: SegmentPayloadRowAudit) =
  f.writeLine("B ",r.firstGate," ",r.lastGate," ",r.heads," ",r.fields.len," ",r.zeroStarts.len,
    " ",r.ranges.len," ",r.constants.len," ",r.queries.len," ",r.reads.len)
  for field in r.fields: f.writeLine(line(field))
  var zeros = "Z"
  for index in r.zeroStarts: zeros.add " " & $index
  f.writeLine(zeros)
  var constants = "I"
  for index in r.constants: constants.add " " & $index
  f.writeLine(constants)
  for range in r.ranges: f.writeUse(range)
  for query in r.queries:
    if query.len != 3: raise newException(ValueError,"invalid segment query")
    for field in query: f.writeLine(line(field))
  for read in r.reads:
    f.writeLine("R ",read.token)
    f.writeLine(line(read.cursor))
proc writeSegmentPayloadRecords*(f: File, c: Circuit) =
  when not defined(zkbuildSegmentPayloadAudit):
    raise newException(ValueError,"segment payload evidence requires -d:zkbuildSegmentPayloadAudit")
  else:
    for r in c.segmentPayloadRecords:
      var header = "V " & $ord(r.flat) & " " & $(r.ownedIndex+1) & " " & $(r.modeTable+1) &
        " " & $r.elements.len & " " & $r.items.len & " " & $r.datas.len & " " & $r.customs.len
      for i in 0..2: header.add " " & $r.closeStarts[i] & " " & $r.closeEnds[i]
      f.writeLine(header)
      for rows in [r.elements,r.items,r.datas,r.customs]:
        for row in rows: f.writeRow(row)
      f.writeRow(r.tail)

proc writeSegmentPayloadAudit*(path: string, c: Circuit) =
  when not defined(zkbuildSegmentPayloadAudit):
    raise newException(ValueError,"segment payload evidence requires -d:zkbuildSegmentPayloadAudit")
  else:
    requireEnvelopeAuditSource(c)
    if c.declarationRecords.len != 1 or c.indexedRecords.len != 1 or c.signatureRecords.len != 1 or
        c.signatureNamespaceRecords.len != 1 or c.importRecords.len != 1 or c.nameFrameRecords.len != 1 or
        c.nameGraphRecords.len != 1 or c.nameSourceRecords.len != 1 or c.scalarPayloadRecords.len != 1 or c.segmentPayloadRecords.len != 1:
      raise newException(ValueError,"segment payload evidence requires exactly one complete module")
    let f = open(path,fmWrite)
    defer: f.close()
    f.writeLine("ZKSEGMENTPAYLOAD1 ",c.values.len," ",c.publicCount," ",c.constraints.len,
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
