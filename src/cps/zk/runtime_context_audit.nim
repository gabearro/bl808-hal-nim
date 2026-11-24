## Source-bound memory/SIMD, bulk-operation and reference context certificate.
import std/sets
import r1cs, structured_control_audit, body_source_audit, lookup_audit
proc writeRuntimeContextAudit*(path: string,c: Circuit,suffixOnly = false) =
  when not defined(zkbuildRuntimeContextAudit):
    raise newException(ValueError,"runtime context requires -d:zkbuildRuntimeContextAudit")
  else:
    if c.runtimeContextRecords.len != 3 or c.runtimeContextBindingLast-c.runtimeContextBindingFirst != 2:
      raise newException(ValueError,"incomplete runtime context composition")
    if not suffixOnly: writeStructuredControlAudit(path,c,magic = "ZKRUNTIMECONTEXT1")
    let file = open(path,if suffixOnly: fmWrite else: fmAppend)
    defer: file.close()
    var catalog: seq[int]
    var seen: HashSet[int]
    for stage in c.runtimeContextRecords:
      for helper in stage.program.blocks:
        if helper.kind == 2 and helper.index notin seen:
          seen.incl helper.index
          catalog.add helper.index
    file.writeLine("K ",catalog.len)
    for index in catalog:
      file.writeLine("J ",index)
      file.writeLookupRecord(c.lookupRecords[index])
    file.writeLine("C ",c.runtimeContextRecords.len)
    for stage in c.runtimeContextRecords:
      file.writeLine("Q ",stage.kind)
      for rows in [stage.rows,stage.flags,stage.selectors,stage.inputs,stage.outputs,stage.auxiliary]: file.rows(rows)
      file.banks(stage.banks)
      file.program(stage.program)
    file.writeLine("B ",c.runtimeContextBindingFirst," ",c.runtimeContextBindingLast)
