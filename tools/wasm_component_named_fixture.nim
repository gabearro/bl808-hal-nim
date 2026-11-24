import cps/wasm/component

const
  BiasInterface* = "ox64:demo/bias@0.2.0"
  ArithmeticInterface* = "ox64:demo/arithmetic@0.2.0"

proc biasBinding*(): ComponentHostInterface =
  let offset: ComponentHostFunc =
    proc(args: openArray[ComponentValue]): seq[ComponentValue] =
      @[componentValue(cpS32, args[0].bits + 1)]
  ComponentHostInterface(name: BiasInterface, functions: @[
    ComponentHostBinding(name: "offset", signature: ComponentFuncType(
      params: @[cpS32], hasResult: true, resultType: cpS32), callback: offset)])

proc checkNamedArithmetic*(instance: ComponentInstance): bool =
  let values = instance.invokeInterface(ArithmeticInterface, "add",
    [componentValue(cpS32, 19), componentValue(cpS32, 22)])
  values.len == 1 and values[0].kind == cpS32 and values[0].bits == 42
