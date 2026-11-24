## Complete source instruction decoding/control evidence; no private assignment.
import std/[strutils,sets]
import r1cs, body_source_audit, lookup_audit, memory_audit
proc line(value: Linear): string =
  result = $value.len
  for term in value:
    result.add " " & $term.wire & ":"
    for b in encodeScalar(term.coefficient): result.add toHex(b,2).toLowerAscii()
proc writeInstructionSourceAudit*(path: string,c: Circuit,magic = "ZKINSTRUCTIONS1") =
  when not defined(zkbuildInstructionSourceAudit):
    raise newException(ValueError,"instruction source evidence requires -d:zkbuildInstructionSourceAudit")
  else:
    if c.instructionSourceRecords.len != 1: raise newException(ValueError,"instruction source audit requires one module")
    writeBodySourceAudit(path,c,magic)
    let f = open(path,fmAppend)
    defer: f.close()
    var selected: seq[int]
    var seen: HashSet[int]
    for decoder in c.instructionDecodeRecords:
      for helper in decoder.program.blocks:
        if helper.kind == 2 and helper.index notin seen:
          seen.incl helper.index
          selected.add helper.index
    f.writeLine("K ",selected.len)
    for index in selected:
      f.writeLine("J ",index)
      f.writeLookupRecord(c.lookupRecords[index])
    f.writeLine("D ",c.instructionDecodeRecords.len)
    for decoder in c.instructionDecodeRecords:
      f.rows(@[decoder.inputs,decoder.auxiliary,decoder.outputs])
      f.program(decoder.program)
    let source = c.instructionSourceRecords[0]
    f.writeLine("I ",ord(source.flat)," ",source.rows.len)
    f.writeLine(line(source.firstFunction))
    var bodySizes = "B " & $source.bodySizes.len
    for count in source.bodySizes: bodySizes.add " " & $count
    f.writeLine(bodySizes)
    for row in source.rows:
      f.writeLine("R ",row.decode," ",row.labelCount," ",row.catchCount)
      f.rows(@[row.fields,@[row.frame]])
    for values in [source.spans,source.functions,source.labels,source.catches,source.events]: f.rows(values)
    f.banks(source.banks)
    f.program(source.program)
    f.writeMemoryRecord(c.memoryRecords[source.frameMemoryIndex])
