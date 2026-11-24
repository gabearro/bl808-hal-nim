import cps/wasm/component

proc flatArgumentsBinding*(plan: ComponentPlan,
                           calls: ptr int = nil,
                           memoryBacked: static bool = true): ComponentHostBinding =
  result.name = "verify"
  for exp in plan.exports:
    if exp.name == "signature":
      result.signature = exp.signature
      break
  result.callback = proc(args: openArray[ComponentValue]): seq[ComponentValue] =
    if calls != nil: inc calls[]
    let count = when memoryBacked: 4 else: 2
    if args.len != count or args[0].kind != cpTuple or args[0].fields.len != 2 or
        args[0].fields[0].kind != cpU8 or args[0].fields[0].bits != 42 or
        args[0].fields[1].kind != cpF64 or args[0].fields[1].bits != cast[uint64](2.5'f64) or
        args[1].kind != cpResult or args[1].fields.len != 1:
      raise newException(ComponentError, "flat aggregate parameter mismatch")
    when memoryBacked:
      if args[2].kind != cpOption or args[3].kind != cpU32List or
          args[3].fields.len != 2 or args[3].fields[0].bits != 0x01020304 or
          args[3].fields[1].bits != 0x05060708:
        raise newException(ComponentError, "flat list parameter mismatch")
    if args[1].caseIndex == 0:
      if args[1].fields[0].kind != cpF32 or args[1].fields[0].bits != 0x3f800000:
        raise newException(ComponentError, "flat result payload mismatch")
      when memoryBacked:
        if args[2].caseIndex != 1 or args[2].fields.len != 1 or args[2].fields[0].text != "Ox64":
          raise newException(ComponentError, "flat option payload mismatch")
      return @[componentValue(cpU32, 19)]
    if args[1].caseIndex != 1 or args[1].fields[0].kind != cpU64 or
        args[1].fields[0].bits != 0xfedcba9876543210'u64:
      raise newException(ComponentError, "flat result payload mismatch")
    when memoryBacked:
      if args[2].caseIndex != 0 or args[2].fields.len != 0:
        raise newException(ComponentError, "flat absent option mismatch")
    @[componentValue(cpU32, 23)]

proc checkFlatArguments*(instance: ComponentInstance): bool =
  let values = instance.invoke("run", [])
  values.len == 1 and values[0].kind == cpU32 and values[0].bits == 42
