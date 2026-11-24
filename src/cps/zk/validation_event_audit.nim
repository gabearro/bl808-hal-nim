## Validation-event circuit evidence, containing expressions but no assignment.
import std/[sets,strutils]
import r1cs, instruction_source_audit, body_source_audit, lookup_audit, memory_audit, token_audit
proc line(value: Linear): string =
  result = $value.len
  for term in value:
    result.add " " & $term.wire & ":"
    for b in encodeScalar(term.coefficient): result.add toHex(b,2).toLowerAscii()
proc writeValidationEventAudit*(path: string,c: Circuit,magic = "ZKVALIDATIONEVENT1") =
  when not defined(zkbuildValidationEventAudit):
    raise newException(ValueError,"validation events require -d:zkbuildValidationEventAudit")
  else:
    if c.validationTraceRecords.len != 1 or c.validationStageRecords.len != 5 or c.validationTraceRecords[0].memories.len != 2:
      raise newException(ValueError,"validation evidence requires a complete module/event composition")
    writeInstructionSourceAudit(path,c,magic)
    let f = open(path,fmAppend)
    defer: f.close()
    var staticIds,admissionIds: seq[int]
    var seenStatic,seenAdmission: HashSet[int]
    for stage in c.validationStageRecords:
      for helper in stage.program.blocks:
        if helper.kind == 4 and helper.index notin seenStatic:
          seenStatic.incl helper.index
          staticIds.add helper.index
        elif helper.kind == 2 and helper.index notin seenAdmission:
          seenAdmission.incl helper.index
          admissionIds.add helper.index
    f.writeLine("V ",staticIds.len," ",admissionIds.len)
    for index in staticIds:
      let r = c.staticRuleRecords[index]
      f.writeLine("J ",index)
      f.writeLine("S ",r.firstGate," ",r.firstWire," ",r.lastWire," ",r.lastGate," ",r.root," ",r.nodes.len)
      f.rows(@[r.inputs,r.lowBits,r.outputs])
      f.writeUse(r.opcodeRange)
      f.writeUse(r.typeRange)
      for node in r.nodes:
        var row = "N " & $node.kind & " " & $node.bit & " " & $node.zero & " " & $node.one
        for v in node.payload: row.add " " & $v
        f.writeLine(row)
    for index in admissionIds:
      f.writeLine("J ",index)
      f.writeLookupRecord(c.lookupRecords[index])
    let trace = c.validationTraceRecords[0]
    f.writeLine("E ",c.validationStageRecords.len)
    f.writeLine(line(trace.firstFunction))
    f.rows(trace.rows)
    for stage in c.validationStageRecords:
      f.writeLine("G ",stage.kind)
      f.writeLine(line(stage.firstFunction))
      f.rows(stage.rows)
      f.rows(stage.flags)
      f.rows(stage.inputs)
      f.rows(stage.outputs)
      f.program(stage.program)
    for index in trace.memories: f.writeMemoryRecord(c.memoryRecords[index])
