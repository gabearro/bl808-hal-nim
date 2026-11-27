import cps/wasm/[component, linear_memory, types]

proc errorContextMemory(context: pointer, mt: MemType): ref LinearMemory =
  if mt.limits.min != 1: return nil
  new(result)
  if result[].initLinearMemory(LinearMemoryConfig(initialPages: 1, maxPages: 1,
      admissionPages: 1, maxCommittedChunks: 1, residentChunks: 1)) != lmOk:
    return nil

proc checkErrorContextFixture*(fixture: string): bool =
  let instance = block:
    let plan = decodeComponent(cast[seq[byte]](fixture))
    instantiateComponent(plan, [], errorContextMemory, nil)
  let zero = componentValue(cpU32, 0)
  let context = instance.invoke("new", [componentValue(cpU32, uint32.high.uint64),
    componentValue(cpU32, 1)])[0]
  if context.componentErrorContextMessage() != "": return false
  discard instance.invoke("debug", [context, zero])
  let length = instance.invoke("length", [])[0]
  discard instance.invoke("drop", [context])
  result = length.bits == 0
  instance.closeComponent()
