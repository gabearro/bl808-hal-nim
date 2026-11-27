import cps/wasm/component

proc checkMapRoundtrip*(instance: ComponentInstance): bool {.noinline.} =
  let empty = instance.invoke("roundtrip", [componentMap([])])
  if empty.len != 1 or empty[0].kind != cpMap or empty[0].fields.len != 0: return false
  let keys = [2'u64, 255, 2]
  let values = [1'u64, high(uint64), 42]
  var entries: seq[ComponentValue]
  for i, key in keys:
    entries.add(componentTuple([componentValue(cpU8, key), componentValue(cpU64, values[i])]))
  let returned = instance.invoke("roundtrip", [componentMap(entries)])
  if returned.len != 1 or returned[0].kind != cpMap or returned[0].fields.len != keys.len:
    return false
  for i, entry in returned[0].fields:
    if entry.kind != cpTuple or entry.fields.len != 2 or
        entry.fields[0].kind != cpU8 or entry.fields[0].bits != keys[i] or
        entry.fields[1].kind != cpU64 or entry.fields[1].bits != values[i]:
      return false
  true
