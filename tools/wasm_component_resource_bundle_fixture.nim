import cps/wasm/component

proc makeTicket*(instance: ComponentInstance, id: uint32): ComponentValue =
  let values = instance.invokeInterface("bundles", "[constructor]ticket",
    [componentValue(cpU32, id)])
  if values.len != 1 or values[0].kind != cpOwnedResource:
    raise newException(ComponentError, "ticket constructor returned the wrong shape")
  values[0]

proc bundleValue*(tickets: openArray[ComponentValue]): ComponentValue =
  componentRecord([componentValue(cpU32, 7), componentList(tickets)])

proc checkResourceBundle*(instance: ComponentInstance): bool =
  let first = makeTicket(instance, 19)
  let second = makeTicket(instance, 23)
  let peeked = instance.invokeInterface("bundles", "peek",
    [componentOptionSome(borrowComponentResource(first))])
  if peeked.len != 1 or peeked[0].bits != 19: return false
  let returned = instance.invokeInterface("bundles", "exchange",
    [bundleValue([first, second])])
  if returned.len != 1 or returned[0].kind != cpRecord or returned[0].fields.len != 2:
    return false
  let fields = returned[0].fields
  if fields[0].bits != 7 or fields[1].kind != cpList or fields[1].fields.len != 2:
    return false
  for i, value in fields[1].fields:
    let peek = instance.invokeInterface("bundles", "[method]ticket.get",
      [borrowComponentResource(value)])
    if peek.len != 1 or peek[0].bits != [19'u64, 23'u64][i]: return false
    dropComponentResource(value)
  let dropped = instance.invokeInterface("bundles", "last-dropped", [])
  dropped.len == 1 and dropped[0].bits == 23
