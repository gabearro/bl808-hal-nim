## Source-bound code-body and local-declaration programs. No assignment data.
import std/strutils
import r1cs, module_context_audit, token_audit
proc line(value: Linear): string =
  result = $value.len
  for term in value:
    result.add " " & $term.wire & ":"
    for b in encodeScalar(term.coefficient): result.add toHex(b,2).toLowerAscii()
proc rows*(f: File, values: seq[seq[Linear]]) =
  f.writeLine("A ",values.len)
  for row in values:
    f.writeLine("D ",row.len)
    for field in row: f.writeLine(line(field))
proc banks*(f: File, values: seq[int]) =
  var text = "T " & $values.len
  for value in values: text.add " " & $value
  f.writeLine(text)
proc program*(f: File, value: SourceProgramAudit) =
  let p = value.program
  f.writeLine("P ",p.firstGate," ",p.lastGate," ",p.primitives.len," ",value.blocks.len)
  for primitive in p.primitives: f.writeUse(primitive)
  for b in value.blocks:
    f.writeLine("X ",b.kind," ",b.index," ",b.firstPrimitive," ",b.lastPrimitive," ",b.firstGate," ",b.lastGate)
proc writeBodySourceAudit*(path: string, c: Circuit, magic = "ZKBODYSOURCE1") =
  when not defined(zkbuildBodySourceAudit):
    raise newException(ValueError,"body source evidence requires -d:zkbuildBodySourceAudit")
  else:
    if c.sourceProgramActive or c.codeSourceRecords.len != 1 or c.localDeclarationRecords.len != 1 or c.localRangeRecords.len != 1:
      raise newException(ValueError,"body source evidence requires complete code and locals programs")
    writeModuleContextAudit(path,c,magic)
    let f = open(path,fmAppend)
    defer: f.close()
    let code = c.codeSourceRecords[0]
    f.writeLine("Y ",ord(code.flat)," ",code.bodies.len)
    f.writeLine(line(code.firstFunction))
    for row in code.bodies:
      f.rows(@[row.fields])
      f.rows(row.locals)
    f.rows(code.locals)
    f.rows(code.spans)
    f.banks(code.banks)
    f.program(code.program)
    let local = c.localDeclarationRecords[0]
    f.writeLine("L")
    f.writeLine(line(local.firstFunction))
    f.writeLine(line(local.functionCount))
    f.rows(local.ranges)
    f.rows(local.tags)
    f.rows(local.totals)
    f.banks(local.banks)
    f.program(local.program)
    let ranges = c.localRangeRecords[0]
    f.writeLine("Z")
    f.rows(ranges.locals)
    f.rows(ranges.ranges)
    f.rows(ranges.tags)
    f.rows(@[ranges.selected])
    f.banks(ranges.banks)
    f.program(ranges.program)
