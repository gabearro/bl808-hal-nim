import cps/wasm/component

proc checkGeneratedResource*(instance: ComponentInstance,
                             generatedInterface: static bool = true): bool =
  template call(name, args: untyped): untyped =
    when generatedInterface: instance.invokeInterface("counters", name, args)
    else: instance.invoke(name, args)
  let values = call("[constructor]counter",
    [componentValue(cpU32, 42)])
  if values.len != 1 or values[0].kind != cpOwnedResource: return false
  let owned = values[0]
  let borrowed = borrowComponentResource(owned)
  let read = call("[method]counter.get", [borrowed])
  if read.len != 1 or read[0].bits != 42: return false
  when generatedInterface:
    let before = call("last-dropped", [])
    if before.len != 1 or before[0].bits != 0: return false
  dropComponentResource(owned)
  when generatedInterface:
    let after = call("last-dropped", [])
    return after.len == 1 and after[0].bits == 42
  else:
    try:
      discard call("[method]counter.get", [borrowed])
    except ComponentError:
      return true
