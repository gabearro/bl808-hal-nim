import cps/wasm/component

proc checkContext*(instance: ComponentInstance): bool {.noinline.} =
  let first = instance.invoke("run", [componentString("Ox64")])
  if first.len != 1 or first[0].kind != cpU32 or first[0].bits != 4: return false
  let second = instance.invoke("run", [componentString("again")])
  second.len == 1 and second[0].kind == cpU32 and second[0].bits == 5

proc checkContextPostReturn*(instance: ComponentInstance): bool {.noinline.} =
  let first = instance.invoke("f", [])
  if first.len != 1 or first[0].kind != cpU32 or first[0].bits != 7: return false
  let saved = instance.invoke("check", [])
  saved.len == 1 and saved[0].kind == cpU32 and saved[0].bits == 42

when isMainModule:
  import std/os

  doAssert paramCount() == 1
  let bytes = cast[seq[byte]](readFile(paramStr(1)))
  var rejected = false
  try:
    discard decodeComponent(bytes)
  except ComponentError as error:
    rejected = error.msg == "unsupported canonical definition"
  doAssert rejected
  echo "Canonical context opt-in gate PASS"
