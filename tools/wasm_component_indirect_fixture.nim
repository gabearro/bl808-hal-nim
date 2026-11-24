import cps/wasm/component

const
  WideInteger = 0x1122_3344_5566_7788'u64
  FirstByte = 23'u64
  LastWord = 47'u64

proc indirectInput(): ComponentValue =
  result = ComponentValue(kind: cpTuple, fields: newSeqOfCap[ComponentValue](17))
  result.fields.add(componentValue(cpU8, FirstByte))
  result.fields.add(componentValue(cpU64, WideInteger))
  result.fields.add(componentValue(cpS16, cast[uint64](-7'i64)))
  for i in 3 .. 16:
    result.fields.add(componentValue(cpU32, if i == 16: LastWord else: i.uint64))

proc indirectArgumentsBinding*(plan: ComponentPlan,
                               calls: ptr int = nil): ComponentHostBinding =
  result.name = "verify"
  for exp in plan.exports:
    if exp.name == "evaluate":
      result.signature = exp.signature
      break
  result.callback = proc(args: openArray[ComponentValue]): seq[ComponentValue] =
    if calls != nil: inc calls[]
    let expected = indirectInput()
    if args.len != 1 or args[0].kind != cpTuple or
        args[0].fields.len != expected.fields.len:
      raise newException(ComponentError, "indirect argument tuple shape mismatch")
    for i, field in expected.fields:
      if args[0].fields[i].kind != field.kind or args[0].fields[i].bits != field.bits:
        raise newException(ComponentError, "indirect argument tuple value mismatch")
    @[componentTuple([componentValue(cpU64, WideInteger - 7),
      componentValue(cpU32, FirstByte + LastWord)])]

proc checkIndirectArguments*(instance: ComponentInstance): bool =
  let values = instance.invoke("evaluate", [indirectInput()])
  values.len == 1 and values[0].kind == cpTuple and values[0].fields.len == 2 and
    values[0].fields[0].kind == cpU64 and values[0].fields[0].bits == WideInteger - 7 and
    values[0].fields[1].kind == cpU32 and values[0].fields[1].bits == FirstByte + LastWord
