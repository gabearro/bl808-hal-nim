## Structured validation programs and their frame/scratch memory arguments.
import r1cs, dynamic_typing_audit, body_source_audit, memory_audit
proc writeStructuredControlAudit*(path: string,c: Circuit,suffixOnly = false,magic = "ZKSTRUCTURED1") =
  when not defined(zkbuildStructuredControlAudit):
    raise newException(ValueError,"structured control requires -d:zkbuildStructuredControlAudit")
  else:
    if c.structuredControlRecords.len != 10 or c.structuredControlMemories.len != 2:
      raise newException(ValueError,"incomplete structured control composition")
    if not suffixOnly: writeDynamicTypingAudit(path,c,magic = magic)
    let file = open(path,if suffixOnly: fmWrite else: fmAppend)
    defer: file.close()
    file.writeLine("C ",c.structuredControlRecords.len)
    for stage in c.structuredControlRecords:
      file.writeLine("Q ",stage.kind)
      for rows in [stage.rows,stage.flags,stage.selectors,stage.inputs,stage.outputs,stage.auxiliary]: file.rows(rows)
      file.banks(stage.banks)
      file.program(stage.program)
    for index in c.structuredControlMemories: file.writeMemoryRecord(c.memoryRecords[index])
