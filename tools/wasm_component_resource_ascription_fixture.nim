import cps/wasm/component

proc checkResourceAscription*(instance: ComponentInstance): bool =
  for expected in [42'u64, 84'u64]:
    if instance.invoke("run", []).len != 0: return false
    let value = instance.invoke("status", [])
    if value.len != 1 or value[0].kind != cpU32 or value[0].bits != expected:
      return false
  true
