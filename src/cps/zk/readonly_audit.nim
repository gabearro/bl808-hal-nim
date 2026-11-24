## Evidence for immutable table initialization, ordering and query membership.
import std/strutils
import r1cs, token_audit, memory_audit

proc line(value: Linear): string =
  result = $value.len
  for term in value:
    result.add " " & $term.wire & ":"
    for b in encodeScalar(term.coefficient): result.add toHex(b,2).toLowerAscii()

proc writeReadOnlyRecords*(f: File, c: Circuit) =
  when not defined(zkbuildReadOnlyAudit):
    raise newException(ValueError,"immutable-table evidence requires -d:zkbuildReadOnlyAudit")
  else:
    for row in c.readOnlyRecords:
      if row.entries.len mod 3 != 0 or row.queries.len mod 3 != 0 or
          row.memoryIndex < 0 or row.memoryIndex >= c.memoryRecords.len:
        raise newException(ValueError,"invalid immutable-table evidence")
      f.writeLine("I ",row.firstGate," ",row.preludeEnd," ",row.entries.len div 3,
        " ",row.queries.len div 3," ",row.order.len)
      for value in row.entries: f.writeLine(line(value))
      for value in row.queries: f.writeLine(line(value))
      for order in row.order:
        f.writeLine("D")
        f.writeLine(line(order.delta))
        f.writeUse(order.range)
      f.writeMemoryRecord(c.memoryRecords[row.memoryIndex])

proc writeReadOnlyAudit*(path: string, c: Circuit) =
  when not defined(zkbuildReadOnlyAudit):
    raise newException(ValueError,"immutable-table evidence requires -d:zkbuildReadOnlyAudit")
  else:
    let f = open(path,fmWrite)
    defer: f.close()
    f.writeLine("ZKREADONLY1 ",c.values.len," ",c.publicCount," ",c.constraints.len," ",c.readOnlyRecords.len)
    for gate in c.constraints:
      for side in [gate.a,gate.b,gate.c]: f.writeLine(line(side))
    f.writeReadOnlyRecords(c)
