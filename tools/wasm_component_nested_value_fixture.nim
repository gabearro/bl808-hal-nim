import cps/wasm/component

proc checkNestedValue*(instance: ComponentInstance): bool =
  const number = 0x1122_3344_5566_7788'u64
  let present = componentOptionSome(componentTuple([
    componentString("café"), componentValue(cpU64, number)]))
  block:
    let value = instance.invoke("echo",
      [componentRecord([present, componentValue(cpU8, 19)])])
    if value.len != 1 or value[0].kind != cpRecord or value[0].fields.len != 2:
      return false
    let fields = value[0].fields
    if fields[0].kind != cpOption or fields[0].caseIndex != 1 or
        fields[0].fields.len != 1 or fields[1].kind != cpU8 or fields[1].bits != 19:
      return false
    let payload = fields[0].fields[0]
    if payload.kind != cpTuple or payload.fields.len != 2 or
        payload.fields[0].kind != cpString or payload.fields[0].text != "café" or
        payload.fields[1].kind != cpU64 or payload.fields[1].bits != number:
      return false
  let value = instance.invoke("echo",
    [componentRecord([componentOptionNone(), componentValue(cpU8, 23)])])
  if value.len != 1 or value[0].kind != cpRecord or value[0].fields.len != 2:
    return false
  let fields = value[0].fields
  fields[0].kind == cpOption and fields[0].caseIndex == 0 and
    fields[0].fields.len == 0 and fields[1].kind == cpU8 and fields[1].bits == 23
