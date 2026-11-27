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

proc checkNameAttributes*(bytes: openArray[byte]): bool =
  let plan = decodeComponent(bytes)
  let incoming = plan.componentNameAttributes("configured", importing = true)
  let answer = plan.componentNameAttributes("answer", importing = false)
  let iface = plan.componentNameAttributes("ox64:demo/bias@0.2", importing = false)
  if incoming.implements != "ox64:demo/bias@0.2" or incoming.versionSuffix != ".6+board" or
      not incoming.hasExternalId or incoming.externalId != "" or
      not answer.hasExternalId or answer.externalId != "雪" or iface.versionSuffix != ".5":
    return false
  var supplied = biasBinding()
  supplied.name = "configured"
  let instance = instantiateComponent(plan, [], interfaces = [supplied])
  let values = instance.invoke("answer", [])
  if values.len != 1 or values[0].kind != cpS32 or values[0].bits != 42: return false
  let forwarded = instance.invokeInterface("ox64:demo/bias@0.2", "offset",
    [componentValue(cpS32, 41)])
  forwarded.len == 1 and forwarded[0].kind == cpS32 and forwarded[0].bits == 42
