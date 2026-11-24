## Offline evidence linking the binary-source table to its public SHA digest.
import std/strutils
import r1cs
when defined(zkbuildSourceAudit) and defined(zkbuildShaAudit):
  import sha256_audit

proc hex(value: Scalar): string =
  for b in encodeScalar(value): result.add toHex(b,2).toLowerAscii()
proc line(value: Linear): string =
  result = $value.len
  for term in value: result.add " " & $term.wire & ":" & hex(term.coefficient)

proc writeSourceRecord*(f: File, row: BinarySourceRecord) =
  f.writeLine("B ",row.firstWire," ",row.lastWire," ",row.firstGate," ",row.lastGate,
    " ",row.capacity," ",row.limbs.len," ",row.outputs.len)
  f.writeLine(line(row.length))
  for value in row.limbs: f.writeLine(line(value))
  for value in row.outputs: f.writeLine(line(value))
  let r = row.lengthRange
  f.writeLine("R ",ord(r.kind)," ",r.width," ",r.firstWire," ",r.lastWire,
    " ",r.firstGate," ",r.lastGate," ",r.reference+1," ",r.inputs.len," ",r.outputs.len)
  for value in r.inputs: f.writeLine(line(value))
  for value in r.outputs: f.writeLine(line(value))

proc writeSourceHashAudit*(path: string, c: Circuit) =
  when not (defined(zkbuildSourceAudit) and defined(zkbuildShaAudit)):
    raise newException(ValueError,"source/hash audit requires source, SHA, and gadget audit defines")
  else:
    let f = open(path,fmWrite)
    defer: f.close()
    f.writeLine("ZKSOURCEHASH1 ",c.values.len," ",c.publicCount," ",c.constraints.len,
      " ",c.binarySourceRecords.len," ",c.sha256Records.len)
    for gate in c.constraints:
      for side in [gate.a,gate.b,gate.c]: f.writeLine(line(side))
    for row in c.binarySourceRecords: writeSourceRecord(f,row)
    writeSha256Records(f,c)
