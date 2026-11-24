## Name-node and UTF-8 constraints, without field assignments.
import std/strutils
import r1cs, name_frame_audit, owned_audit, import_audit, signature_audit
import declaration_audit, indexed_audit, envelope_audit, readonly_audit, packed_audit, token_audit, lookup_audit

proc line(value: Linear): string =
  result = $value.len
  for term in value:
    result.add " " & $term.wire & ":"
    for b in encodeScalar(term.coefficient): result.add toHex(b,2).toLowerAscii()

proc writeNameGraphRecords*(f: File, c: Circuit) =
  when not defined(zkbuildNameGraphAudit):
    raise newException(ValueError,"name graph evidence requires -d:zkbuildNameGraphAudit")
  else:
    for graph in c.nameGraphRecords:
      if graph.tables.len != 2: raise newException(ValueError,"invalid name graph tables")
      f.writeLine("G ",graph.nodes.len," ",graph.roots.len," ",graph.tables[0]," ",graph.tables[1])
      for node in graph.nodes:
        if node.fields.len != 7 or node.ranges.len != 3 or node.entry.len != 3 or node.query.len != 3 or node.canonical.len != 3:
          raise newException(ValueError,"invalid name node evidence")
        f.writeLine("J ",node.firstGate," ",node.lastGate," ",node.zeroStart)
        for field in node.entry & node.query & node.canonical & node.fields: f.writeLine(line(field))
        for range in node.ranges: f.writeUse(range)
        f.writeLookupRecord(node.lookup)
      for root in graph.roots:
        if root.ranges.len != 2 or root.query.len != 3: raise newException(ValueError,"invalid name root evidence")
        f.writeLine("R ",root.firstGate," ",root.lastGate," ",root.zeroStart)
        for field in @[root.head,root.state] & root.query: f.writeLine(line(field))
        for range in root.ranges: f.writeUse(range)

proc writeNameGraphFragmentAudit*(path: string, c: Circuit) =
  when not defined(zkbuildNameGraphAudit):
    raise newException(ValueError,"name graph evidence requires -d:zkbuildNameGraphAudit")
  else:
    let f = open(path,fmWrite)
    defer: f.close()
    f.writeLine("ZKNAMEGRAPHFRAG1 ",c.values.len," ",c.publicCount," ",c.constraints.len," ",c.readOnlyRecords.len," ",c.nameGraphRecords.len)
    for gate in c.constraints:
      for side in [gate.a,gate.b,gate.c]: f.writeLine(line(side))
    f.writeReadOnlyRecords(c)
    f.writeNameGraphRecords(c)

proc writeNameGraphAudit*(path: string, c: Circuit) =
  when not defined(zkbuildNameGraphAudit):
    raise newException(ValueError,"name graph evidence requires -d:zkbuildNameGraphAudit")
  else:
    requireEnvelopeAuditSource(c)
    if c.declarationRecords.len != 1 or c.indexedRecords.len != 1 or c.signatureRecords.len != 1 or
        c.signatureNamespaceRecords.len != 1 or c.importRecords.len != 1 or c.nameFrameRecords.len != 1 or c.nameGraphRecords.len != 1:
      raise newException(ValueError,"name graph evidence requires exactly one complete module")
    let f = open(path,fmWrite)
    defer: f.close()
    f.writeLine("ZKNAMEGRAPH1 ",c.values.len," ",c.publicCount," ",c.constraints.len,
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
