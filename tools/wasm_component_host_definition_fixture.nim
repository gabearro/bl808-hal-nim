import cps/wasm/component

proc hostDefinitionFunctions*(started: ComponentHostFunc): array[3, ComponentHostBinding] =
  let offset: ComponentHostFunc = proc(args: openArray[ComponentValue]): seq[ComponentValue] =
    @[componentValue(cpU32, 4)]
  let scale: ComponentHostFunc = proc(args: openArray[ComponentValue]): seq[ComponentValue] =
    @[componentValue(cpU32, 2 * args[0].bits)]
  [
    ComponentHostBinding(name: "offset",
      signature: ComponentFuncType(hasResult: true, resultType: cpU32), callback: offset),
    ComponentHostBinding(name: "scale",
      signature: ComponentFuncType(params: @[cpU32], hasResult: true, resultType: cpU32),
      callback: scale),
    ComponentHostBinding(name: "started", callback: started)
  ]

proc checkHostDefinition*(instance: ComponentInstance): bool =
  let value = instance.invoke("apply", [componentValue(cpU32, 19)])
  value.len == 1 and value[0].kind == cpU32 and value[0].bits == 42
