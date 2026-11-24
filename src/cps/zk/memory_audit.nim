## Offline evidence for complete RAM constraints. Contains no witness values.
import std/strutils
import r1cs

proc hex(value: Scalar): string =
  for b in encodeScalar(value): result.add toHex(b,2).toLowerAscii()
proc line(value: Linear): string =
  result = $value.len
  for term in value: result.add " " & $term.wire & ":" & hex(term.coefficient)
proc writeRange(f: File, r: MemoryRangeAudit) =
  f.writeLine("R ",r.kind," ",r.firstWire," ",r.lastWire," ",r.firstGate," ",r.lastGate)
proc writeAccess(f: File, r: MemoryAccessAudit) =
  f.writeLine("A ",r.firstGate," ",r.lastGate)
  for value in r.fields: f.writeLine(line(value))
  f.writeRange(r.address)
  f.writeRange(r.value)

proc writeMemoryRecord*(f: File, r: MemoryAudit) =
  f.writeLine("M ",r.addressBits," ",r.timeBits," ",r.valueBits," ",r.inputs.len," ",r.rows.len)
  for input in r.inputs: f.writeAccess(input)
  for row in r.rows:
    f.writeLine("S ",row.firstWire," ",row.lastWire," ",row.firstGate," ",row.lastGate)
    f.writeAccess(row.access)
    f.writeLine(line(row.clock))
    f.writeRange(row.clockRange)
  let p = r.network
  var depth = 0
  var n = p.capacity
  while n > 1: inc depth; n = n shr 1
  f.writeLine("P ",depth," ",p.firstWire," ",p.lastWire," ",p.firstGate," ",p.lastGate," ",p.capacity)
  for value in p.inputs: f.writeLine(line(value))
  for value in p.outputs: f.writeLine(line(value))

proc writeMemoryAudit*(path: string, c: Circuit) =
  when not defined(zkbuildMemoryAudit):
    raise newException(ValueError,"RAM evidence requires -d:zkbuildMemoryAudit with gadget and permutation audits")
  else:
    let f = open(path,fmWrite)
    defer: f.close()
    f.writeLine("ZKMEMORY1 ",c.values.len," ",c.publicCount," ",c.constraints.len," ",c.memoryRecords.len)
    for gate in c.constraints:
      for side in [gate.a,gate.b,gate.c]: f.writeLine(line(side))
    for r in c.memoryRecords: writeMemoryRecord(f,r)
