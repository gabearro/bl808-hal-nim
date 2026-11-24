## A single matrix certificate for source bytes, SHA-256, and every byte RAM query.
## This is offline circuit evidence, not a proof or an input to the kernel.
import std/strutils
import r1cs, binary_source_audit, sha256_audit, memory_audit

proc hex(value: Scalar): string =
  for b in encodeScalar(value): result.add toHex(b,2).toLowerAscii()
proc line(value: Linear): string =
  result = $value.len
  for term in value: result.add " " & $term.wire & ":" & hex(term.coefficient)

proc same(a,b: Linear): bool =
  if a.len != b.len: return false
  for i in 0..<a.len:
    if a[i].wire != b[i].wire or not a[i].coefficient.equals(b[i].coefficient): return false
  true
proc same(a,b: seq[Linear]): bool =
  if a.len != b.len: return false
  for i in 0..<a.len:
    if not same(a[i],b[i]): return false
  true

proc writeBinaryReadBody*(f: File, c: Circuit) =
  when not defined(zkbuildByteMemoryAudit):
    raise newException(ValueError,"byte memory evidence requires its audit defines")
  else:
    if c.binaryReadMemoryRecords.len != 1:
      raise newException(ValueError,"byte memory evidence requires exactly one source read interface")
    let record = c.binaryReadMemoryRecords[0]
    let source = c.binarySourceRecords[record.sourceIndex]
    var bytes: seq[Linear]
    for i in 0..<source.capacity: bytes.add source.outputs[3*i+2]
    var hashIndex = -1
    for i, hash in c.sha256Records:
      if same(hash.source,bytes) and same(hash.length,source.length):
        if hashIndex >= 0: raise newException(ValueError,"ambiguous source digest")
        hashIndex = i
    if hashIndex < 0: raise newException(ValueError,"source has no matching digest")
    if record.queries.len mod 3 != 0: raise newException(ValueError,"invalid query interface")
    writeSourceRecord(f,source)
    writeSha256Record(f,c.sha256Records[hashIndex])
    writeMemoryRecord(f,c.memoryRecords[record.memoryIndex])
    for value in record.queries: f.writeLine(line(value))

proc writeBinaryReadAudit*(path: string, c: Circuit) =
  when not defined(zkbuildByteMemoryAudit):
    raise newException(ValueError,"byte memory evidence requires -d:zkbuildByteMemoryAudit and its dependencies")
  else:
    if c.binaryReadMemoryRecords.len != 1:
      raise newException(ValueError,"byte memory evidence requires exactly one source read interface")
    let f = open(path,fmWrite)
    defer: f.close()
    f.writeLine("ZKBYTEMEM1 ",c.values.len," ",c.publicCount," ",c.constraints.len," ",c.binaryReadMemoryRecords[0].queries.len div 3)
    for gate in c.constraints:
      for side in [gate.a,gate.b,gate.c]: f.writeLine(line(side))
    writeBinaryReadBody(f,c)
