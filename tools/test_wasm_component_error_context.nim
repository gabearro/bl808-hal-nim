import std/[os, strutils]
import cps/wasm/component

let bytes = cast[seq[byte]](readFile(paramStr(1)))
when not defined(wasmComponentErrorContext):
  try:
    discard decodeComponent(bytes)
    doAssert false, "error-context was accepted without the feature"
  except ComponentError as error:
    doAssert error.msg.contains("error-context is disabled")
else:
  let plan = decodeComponent(bytes)

  proc expectTrap(instance: ComponentInstance, name, message: string,
                  args: openArray[ComponentValue] = []) =
    try:
      discard instance.invoke(name, args)
      doAssert false, "expected a trap from " & name
    except ComponentError as error:
      doAssert error.msg.contains(message), error.msg
    instance.closeComponent()

  let origin = instantiateComponent(plan)
  let created = origin.invoke("new", [])[0]
  const expected = when defined(wasmComponentErrorContextMessages): "éd" else: ""
  doAssert created.componentErrorContextMessage() == expected
  let moved = origin.invoke("transfer", [created])[0]
  doAssert moved.componentErrorContextMessage() == expected
  # The host value keeps its immutable message after all guest handles are closed.
  origin.closeComponent()
  let other = instantiateComponent(plan)
  doAssert other.invoke("describe", [moved])[0].text == expected
  let supplied = componentErrorContext("host diagnostic 🍎")
  let detail = other.invoke("detail", [componentRecord([
    supplied, componentValue(cpU32, 42)])])[0]
  doAssert detail.fields[1].bits == 42
  doAssert detail.fields[0].componentErrorContextMessage() == supplied.componentErrorContextMessage()
  doAssert other.invoke("describe", [detail.fields[0]])[0].text == "host diagnostic 🍎"
  discard other.invoke("drop", [detail.fields[0]])
  doAssert detail.fields[0].componentErrorContextMessage() == "host diagnostic 🍎"
  other.closeComponent()

  let generated = instantiateComponent(decodeComponent(cast[seq[byte]](readFile(paramStr(2)))))
  doAssert generated.invoke("pass", [supplied])[0].componentErrorContextMessage() ==
    supplied.componentErrorContextMessage()
  generated.closeComponent()

  when defined(wasmComponentErrorContextMessages):
    instantiateComponent(plan).expectTrap("new-oob", "out of bounds")
    instantiateComponent(plan).expectTrap("new-invalid", "UTF-16")
  else:
    let discardMessages = instantiateComponent(plan)
    doAssert discardMessages.invoke("new-oob", [])[0].componentErrorContextMessage() == ""
    doAssert discardMessages.invoke("new-invalid", [])[0].componentErrorContextMessage() == ""
    discardMessages.closeComponent()

  for name in ["invalid-drop", "resource-as-context", "invalid-lift"]:
    instantiateComponent(plan).expectTrap(name, "invalid canonical error-context handle")
  instantiateComponent(plan).expectTrap("context-as-resource", "crInvalidHandle")
  instantiateComponent(plan).expectTrap("debug-unaligned", "unaligned canonical error-context return area", [supplied])
  instantiateComponent(plan).expectTrap("debug-oob", "out of bounds", [supplied])

  let bounded = instantiateComponent(plan)
  for _ in 0 ..< 300: discard bounded.invoke("drop", [supplied])
  for _ in 0 ..< 256: discard bounded.invoke("new", [])
  bounded.expectTrap("new", "component error-context handle capacity exceeded")

  when defined(wasmComponentHostEndpoints) and defined(wasmComponentFutures):
    let futurePlan = decodeComponent(cast[seq[byte]](readFile(paramStr(3))))
    let futureGuest = instantiateComponent(futurePlan)
    let pair = newComponentEndpointPair(cpFuture, cpErrorContext)
    doAssert pair.writable.writeComponentEndpoint([supplied]).status == cesPending
    let value = futureGuest.invoke("read", [pair.readable])[0]
    doAssert value.componentErrorContextMessage() == "host diagnostic 🍎"
    doAssert pair.writable.pollComponentEndpoint().status == cesCompleted
    pair.writable.closeComponentEndpoint()
    futureGuest.closeComponent()
  echo "WASM Component Model error-context PASS"
