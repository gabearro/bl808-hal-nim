## Concrete primitive and variant reader layouts, without private assignments.
import std/strutils
import r1cs, binary_read_audit

proc hex(value: Scalar): string =
  for b in encodeScalar(value): result.add toHex(b,2).toLowerAscii()
proc line(value: Linear): string =
  result = $value.len
  for term in value: result.add " " & $term.wire & ":" & hex(term.coefficient)
proc writeRange(f: File, r: GadgetRecord) =
  f.writeLine("R ",ord(r.kind)," ",r.width," ",r.firstWire," ",r.lastWire," ",r.firstGate," ",r.lastGate,
    " ",r.reference+1," ",r.inputs.len," ",r.outputs.len)
  for value in r.inputs: f.writeLine(line(value))
  for value in r.outputs: f.writeLine(line(value))
proc writeUse*(f: File, r: RangeUseAudit) =
  f.writeLine("U ",ord(r.hasSource))
  f.writeRange(r.call)
  if r.hasSource: f.writeRange(r.source)

proc writeTokenRecords*(f: File, c: Circuit) =
  when not defined(zkbuildTokenAudit):
    raise newException(ValueError,"token evidence requires its audit dependencies")
  else:
    let memory = c.binaryReadMemoryRecords[0]
    var queryStart = 0
    for r in c.tokenRecords:
      if r.sourceIndex != memory.sourceIndex or r.queryStart != queryStart:
        raise newException(ValueError,"token records do not cover the complete source read stream")
      queryStart += r.rows.len
      f.writeLine("T ",r.kind," ",r.firstWire," ",r.lastWire," ",r.firstGate," ",r.lastGate,
        " ",r.selectorStart," ",r.choiceStart," ",r.signStart," ",r.rows.len)
      for value in [r.activeMode,r.position,r.expected,r.length,r.sourceLength]: f.writeLine(line(value))
      for use in [r.positionRange,r.valueRange,r.lengthRange]: f.writeUse(use)
      for row in r.rows:
        f.writeLine("D ",row.extrasStart)
        for value in [row.value,row.address,row.remaining,row.next]: f.writeLine(line(value))
        f.writeUse(row.byteRange)
        f.writeUse(row.remainingRange)
    if 3*queryStart != memory.queries.len:
      raise newException(ValueError,"missing token records")

proc writeTokenAudit*(path: string, c: Circuit) =
  when not defined(zkbuildTokenAudit):
    raise newException(ValueError,"token evidence requires -d:zkbuildTokenAudit and byte memory audit dependencies")
  else:
    if c.binaryReadMemoryRecords.len != 1:
      raise newException(ValueError,"token evidence requires exactly one source read interface")
    let f = open(path,fmWrite)
    defer: f.close()
    let memory = c.binaryReadMemoryRecords[0]
    f.writeLine("ZKTOKEN1 ",c.values.len," ",c.publicCount," ",c.constraints.len," ",memory.queries.len div 3," ",c.tokenRecords.len)
    for gate in c.constraints:
      for side in [gate.a,gate.b,gate.c]: f.writeLine(line(side))
    writeBinaryReadBody(f,c)
    writeTokenRecords(f,c)
