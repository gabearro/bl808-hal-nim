import cps/wasm/component

proc nestedListArguments*(malformed: uint8): array[2, ComponentValue] =
  [componentList([
    componentList([componentString("α"), componentString("")]),
    componentList([]),
    componentList([componentString("🍰")])]),
    componentValue(cpU8, malformed)]

proc checkNestedList*(instance: ComponentInstance): bool =
  let values = instance.invoke("echo", nestedListArguments(0))
  if values.len != 1 or values[0].kind != cpList: return false
  let groups = values[0].fields
  if groups.len != 3 or groups[0].kind != cpList or groups[1].kind != cpList or
      groups[2].kind != cpList or groups[0].fields.len != 2 or
      groups[1].fields.len != 0 or groups[2].fields.len != 1:
    return false
  groups[0].fields[0].kind == cpString and groups[0].fields[0].text == "α" and
    groups[0].fields[1].kind == cpString and groups[0].fields[1].text == "" and
    groups[2].fields[0].kind == cpString and groups[2].fields[0].text == "🍰"
