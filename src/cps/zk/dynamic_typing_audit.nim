## Source-linked variable and call typing evidence, without private assignments.
import r1cs, validation_event_audit, body_source_audit

proc writeDynamicTypingAudit*(path: string,c: Circuit,suffixOnly = false,magic = "ZKDYNAMICTYPING1") =
  when not defined(zkbuildDynamicTypingAudit):
    raise newException(ValueError,"dynamic typing evidence requires -d:zkbuildDynamicTypingAudit")
  else:
    if c.dynamicTypingRecords.len != 4:
      raise newException(ValueError,"dynamic typing evidence requires selectors, environment, variables and calls")
    if not suffixOnly: writeValidationEventAudit(path,c,magic)
    let file = open(path,if suffixOnly: fmWrite else: fmAppend)
    defer: file.close()
    file.writeLine("H ",c.dynamicTypingRecords.len)
    for stage in c.dynamicTypingRecords:
      file.writeLine("Q ",stage.kind)
      for rows in [stage.rows,stage.flags,stage.selectors,stage.inputs,stage.outputs,stage.auxiliary]: file.rows(rows)
      file.banks(stage.banks)
      file.program(stage.program)
