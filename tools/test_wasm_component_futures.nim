import std/[os, strutils]
import cps/wasm/component

proc load(path: string): ComponentInstance =
  instantiateComponent(decodeComponent(cast[seq[byte]](readFile(path))))

proc expectConsumed(instance: ComponentInstance, value: ComponentValue) =
  try:
    discard instance.invoke("bounce", [value])
    doAssert false, "the previous reader ticket was reused"
  except ComponentError as error:
    doAssert "already consumed" in error.msg, error.msg

doAssert paramCount() == 2
let source = load(paramStr(1))
let bounce = load(paramStr(2))
let original = source.invoke("make", [])[0]
let relifted = bounce.invoke("bounce", [original])[0]
expectConsumed(bounce, original)
let current = bounce.invoke("bounce", [relifted])[0]
expectConsumed(bounce, relifted)
let tagged = ComponentValue(kind: cpTuple, fields: @[current, componentValue(cpU32, 42)])
let returned = bounce.invoke("tagged-bounce", [tagged])[0]
doAssert returned.kind == cpTuple and returned.fields.len == 2 and returned.fields[1].bits == 42
returned.fields[0].dropComponentFuture()
expectConsumed(bounce, current)
doAssert source.invoke("observe-drop", [])[0].bits == 42

block:
  let abandoned = source.invoke("make", [])[0]
  let latest = bounce.invoke("bounce", [abandoned])[0]
  doAssert latest.kind == cpFuture
doAssert source.invoke("observe-drop", [])[0].bits == 42

# A reader in another store sees the writer's closure, even after a trap.
let reader = load(paramStr(1))
for trapped in [false, true]:
  let writer = load(paramStr(1))
  let detached = writer.invoke("make", [])[0]
  if trapped:
    try:
      discard writer.invoke("trap", [])
      doAssert false, "the writer did not trap"
    except ComponentError as error:
      doAssert "unreachable" in error.msg
  writer.closeComponent()
  doAssert reader.invoke("read-after-drop", [detached])[0].bits == 1
reader.closeComponent()
source.closeComponent()
bounce.closeComponent()
echo "WIT future ownership PASS: transfer, stale tokens, peer close and reader drop"
