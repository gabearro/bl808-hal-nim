## Complete table/memory/global/export source-loop evidence.
import std/strutils
import r1cs, constant_source_audit, name_source_audit, name_graph_audit, name_frame_audit
import owned_audit, import_audit, signature_audit, declaration_audit, indexed_audit
import envelope_audit, readonly_audit, packed_audit, token_audit

proc line(value: Linear): string =
  result = $value.len
  for term in value:
    result.add " " & $term.wire & ":"
    for b in encodeScalar(term.coefficient): result.add toHex(b,2).toLowerAscii()

proc writeScalarPayloadRecords*(f: File, c: Circuit) =
  when not defined(zkbuildScalarPayloadAudit):
    raise newException(ValueError,"scalar payload evidence requires -d:zkbuildScalarPayloadAudit")
  else:
    for r in c.scalarPayloadRecords:
      var header = "P"
      for rows in r.rows: header.add " " & $rows.len
      for i in 0..3: header.add " " & $r.closeStarts[i] & " " & $r.closeEnds[i]
      f.writeLine(header)
      for kind, rows in r.rows:
        for row in rows:
          f.writeLine("L ",row.firstGate," ",row.lastGate," ",row.typeZeroStart," ",row.constantIndex," ",row.limitHeads)
          f.writeLine(line(row.active))
          let query = if row.objectQuery.len == 0: @[constant(0),constant(0),constant(0)] else: row.objectQuery
          if query.len != 3: raise newException(ValueError,"invalid scalar payload query")
          for field in query: f.writeLine(line(field))
          if kind == 3:
            if row.fields.len != 2 or row.name.query.len != 3: raise newException(ValueError,"invalid export evidence")
            for field in row.fields: f.writeLine(line(field))
            f.writeLine("H ",row.name.heads)
            for field in row.name.query: f.writeLine(line(field))
            f.writeLine(line(row.name.cursor))
          if kind == 2: f.writeUse(row.objectRange)
          if kind in [0,1]:
            if row.limitQueries.len != 4: raise newException(ValueError,"invalid limit evidence")
            for q in row.limitQueries:
              if q.len != 3: raise newException(ValueError,"invalid limit query")
              for field in q: f.writeLine(line(field))
          let count = if kind == 0: 4 elif kind == 1: 3 else: 2
          if row.reads.len != count: raise newException(ValueError,"invalid scalar payload readers")
          for read in row.reads:
            f.writeLine("R ",read.token)
            f.writeLine(line(read.cursor))

proc writeScalarPayloadAudit*(path: string, c: Circuit) =
  when not defined(zkbuildScalarPayloadAudit):
    raise newException(ValueError,"scalar payload evidence requires -d:zkbuildScalarPayloadAudit")
  else:
    requireEnvelopeAuditSource(c)
    if c.declarationRecords.len != 1 or c.indexedRecords.len != 1 or c.signatureRecords.len != 1 or
        c.signatureNamespaceRecords.len != 1 or c.importRecords.len != 1 or c.nameFrameRecords.len != 1 or
        c.nameGraphRecords.len != 1 or c.nameSourceRecords.len != 1 or c.scalarPayloadRecords.len != 1:
      raise newException(ValueError,"scalar payload evidence requires exactly one complete module")
    let f = open(path,fmWrite)
    defer: f.close()
    f.writeLine("ZKSCALARPAYLOAD1 ",c.values.len," ",c.publicCount," ",c.constraints.len,
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
