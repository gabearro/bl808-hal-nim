import std/[os, strutils]
import cps/wasm/component

proc load(path: string): ComponentInstance =
  instantiateComponent(decodeComponent(cast[seq[byte]](readFile(path))))

doAssert paramCount() == 2
let source = load(paramStr(1))
let bounce = load(paramStr(2))
let original = source.invoke("make", [])[0]
let lifted = bounce.invoke("bounce", [original])[0]
let tagged = componentTuple([lifted, componentValue(cpU32, 42)])
let returned = bounce.invoke("tagged-bounce", [tagged])[0]
doAssert returned.kind == cpTuple and returned.fields.len == 2 and returned.fields[1].bits == 42
try:
  discard bounce.invoke("bounce", [lifted])
  doAssert false, "a consumed stream handle was reused"
except ComponentError as error:
  doAssert "already consumed" in error.msg, error.msg
doAssert source.invoke("consume", [returned.fields[0]])[0].bits == 42
source.invoke("make", [])[0].dropComponentStream()
source.closeComponent()
bounce.closeComponent()
echo "WIT stream ownership PASS: transfer, tuple result, stale token, partial cancellation"
