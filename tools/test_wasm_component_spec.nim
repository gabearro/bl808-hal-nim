import std/[json, os, strutils]
import cps/wasm/[component, utf8_names]

proc concatCaseIndex(exportName, label: string): uint32 =
  let labels = case exportName
    of "variant": @["s", "n"]
    of "flat-mix": @["a", "b", "c", "d"]
    of "flat-pad": @["p", "q"]
    of "list-variant": @["n", "s"]
    of "list-variant2": @["b", "w"]
    else: raise newException(ValueError, "WAST variant needs a harness case mapping")
  let index = labels.find(label)
  doAssert index >= 0
  index.uint32

proc toComponent(node: JsonNode, exportName = ""): ComponentValue =
  case node["type"].getStr()
  of "bool": componentValue(cpBool, node["value"].getBool().uint64)
  of "u8": componentValue(cpU8, parseBiggestUInt(node["value"].getStr()))
  of "u16": componentValue(cpU16, parseBiggestUInt(node["value"].getStr()))
  of "u32": componentValue(cpU32, parseBiggestUInt(node["value"].getStr()))
  of "u64": componentValue(cpU64, parseBiggestUInt(node["value"].getStr()))
  of "s8": componentValue(cpS8, cast[uint64](parseBiggestInt(node["value"].getStr())))
  of "s16": componentValue(cpS16, cast[uint64](parseBiggestInt(node["value"].getStr())))
  of "s32": componentValue(cpS32, cast[uint64](parseBiggestInt(node["value"].getStr())))
  of "s64": componentValue(cpS64, cast[uint64](parseBiggestInt(node["value"].getStr())))
  of "f32": componentValue(cpF32, parseBiggestUInt(node["value"].getStr()))
  of "f64": componentValue(cpF64, parseBiggestUInt(node["value"].getStr()))
  of "string": componentString(node["value"].getStr())
  of "char":
    let value = node["value"].getStr()
    doAssert validWasmName(value)
    var scalars: seq[uint32]
    for scalar in utf8Scalars(value):
      scalars.add(scalar)
    doAssert scalars.len == 1
    componentValue(cpChar, scalars[0].uint64)
  of "list":
    let items = node["value"]
    # The pinned cases use the specialized numeric ABI only for u32 lists.
    if (items.len > 0 and items[0]["type"].getStr() == "u32") or
        exportName in ["concat-u32s", "scores", "f"]:
      var words: seq[uint32]
      for item in items:
        doAssert item["type"].getStr() == "u32"
        words.add(parseBiggestUInt(item["value"].getStr()).uint32)
      return componentU32List(words)
    var values: seq[ComponentValue]
    for item in items:
      values.add(toComponent(item, exportName))
    componentList(values)
  of "tuple":
    var fields: seq[ComponentValue]
    for item in node["value"]:
      fields.add(toComponent(item, exportName))
    componentTuple(fields)
  of "record":
    var fields: seq[ComponentValue]
    for item in node["value"]:
      let context = if item[0].getStr() == "scores": "scores" else: exportName
      fields.add(toComponent(item[1], context))
    componentRecord(fields)
  of "variant":
    let value = node["value"]
    let index = concatCaseIndex(exportName, value["case"].getStr())
    let payload = value["payload"]
    if payload.kind == JNull: componentVariant(index, [])
    else: componentVariant(index, [toComponent(payload, exportName)])
  of "option":
    let value = node["value"]
    if value.kind == JNull: componentOptionNone()
    else: componentOptionSome(toComponent(value, exportName))
  of "result":
    let value = node["value"]
    if value.hasKey("Ok"):
      componentResult(0, [toComponent(value["Ok"], exportName)])
    else:
      componentResult(1, [toComponent(value["Err"], exportName)])
  of "enum":
    let index = ["red", "green", "blue"].find(node["value"].getStr())
    doAssert index >= 0
    componentEnum(index.uint32)
  of "flags":
    var bits = 0'u32
    for item in node["value"]:
      let index = ["a", "b", "c"].find(item.getStr())
      doAssert index >= 0
      bits = bits or (1'u32 shl index)
    componentFlags(bits)
  else:
    raise newException(ValueError, "WAST value type needs a harness adapter")

proc loadComponent(filename: string): ComponentPlan =
  decodeComponent(cast[seq[byte]](readFile(filename)))

proc matches(actual, expected: ComponentValue): bool =
  actual.kind == expected.kind and actual.bits == expected.bits and
    actual.text == expected.text

proc main() =
  doAssert paramCount() == 1
  let manifest = parseFile(paramStr(1))
  doAssert manifest["revision"].getStr() == ComponentSpecRevision
  var instance: ComponentInstance
  var instanceKey = -1
  var instanceFile: string
  var counts: array[5, int]
  for item in manifest["cases"]:
    let file = item["filename"].getStr()
    let location = item["location"].getStr()
    try:
      case item["kind"].getStr()
      of "validate":
        discard loadComponent(file)
        inc counts[4]
      of "instantiate":
        discard instantiateComponent(loadComponent(file))
        inc counts[0]
      of "reject":
        let detail = item["detail"].getStr()
        var rejected = false
        try:
          discard loadComponent(file)
        except ComponentError as error:
          doAssert detail.len == 0 or detail in error.msg, error.msg
          rejected = true
        doAssert rejected, "accepted invalid component"
        inc counts[1]
      of "assert_return", "assert_trap":
        let key = item["instance"].getInt()
        if instanceKey != key or instanceFile != file:
          instance = instantiateComponent(loadComponent(file))
          instanceKey = key
          instanceFile = file
        let action = item["action"]
        doAssert action["type"].getStr() == "invoke"
        let exportName = action["field"].getStr()
        var args: seq[ComponentValue]
        for value in action["args"]:
          args.add(value.toComponent(exportName))
        if item["kind"].getStr() == "assert_return":
          let actual = instance.invoke(exportName, args)
          let expected = item["expected"]
          doAssert actual.len == expected.len
          for i, resultValue in actual:
            doAssert matches(resultValue, expected[i].toComponent())
          inc counts[2]
        else:
          var trapped = false
          try:
            discard instance.invoke(exportName, args)
          except ComponentError as error:
            doAssert item["detail"].getStr() in error.msg, error.msg
            trapped = true
          doAssert trapped, "invocation did not trap"
          var locked = false
          try:
            discard instance.invoke(exportName, args)
          except ComponentError as error:
            locked = error.msg == "component store locked after trap"
          doAssert locked, "trapped component store could still be invoked"
          inc counts[3]
      else:
        raise newException(ValueError, "unrecognized harness command")
    except Exception:
      stderr.writeLine(location, " failed")
      raise
  echo "upstream Component Model PASS: ", counts[0], " instantiated, ",
    counts[4], " validated, ", counts[1], " rejected, ", counts[2], " return checks, ",
    counts[3], " trap checks"

main()
