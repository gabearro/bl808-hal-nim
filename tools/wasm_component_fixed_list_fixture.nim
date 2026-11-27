import cps/wasm/component

proc checkFixedListDirect*(instance: ComponentInstance): bool {.noinline.} =
  block:
    let item = componentValue(cpS64, cast[uint64](-42'i64))
    let values = instance.invoke("single", [componentFixedList([item])])
    if values.len != 1 or values[0].kind != cpFixedList or values[0].fields.len != 1 or
        values[0].fields[0].kind != cpS64 or values[0].fields[0].bits != item.bits:
      return false
  block:
    let items = [componentValue(cpU32, 7), componentValue(cpU32, 12), componentValue(cpU32, 30)]
    let values = instance.invoke("reverse", [componentFixedList(items)])
    if values.len != 1 or values[0].kind != cpFixedList or values[0].fields.len != items.len:
      return false
    for i, field in values[0].fields:
      if field.kind != cpU32 or field.bits != items[items.high - i].bits: return false
  try:
    discard instance.invoke("reverse", [componentFixedList([componentValue(cpU32, 1)])])
  except ComponentError as error:
    return error.msg == "component fixed-length list length mismatch"
  false

proc checkFixedListIndirect*(instance: ComponentInstance): bool {.noinline.} =
  var items = newSeqOfCap[ComponentValue](17)
  for i in 1 .. 17:
    items.add(componentValue(cpU32, i.uint64))
  let values = instance.invoke("sum-large", [componentFixedList(move items)])
  values.len == 1 and values[0].kind == cpU32 and values[0].bits == 153

when isMainModule:
  import std/os

  doAssert paramCount() == 2
  for i in 1 .. 2:
    let bytes = cast[seq[byte]](readFile(paramStr(i)))
    when defined(wasmComponentFixedLists):
      let instance = instantiateComponent(decodeComponent(bytes))
      defer: closeComponent(instance)
      doAssert if i == 1: checkFixedListDirect(instance) else: checkFixedListIndirect(instance)
    else:
      var rejected = false
      try:
        discard decodeComponent(bytes)
      except ComponentError as error:
        rejected = error.msg == "unsupported component type"
      doAssert rejected
  when defined(wasmComponentFixedLists):
    echo "WIT fixed-length list direct and indirect execution PASS"
  else:
    echo "WIT fixed-length list opt-in gate PASS"
