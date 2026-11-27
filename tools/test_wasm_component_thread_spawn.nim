import std/[os, strutils]
import cps/wasm/component
when defined(wasmComponentThreadSpawn):
  import wasm_component_callback_fixture

let directory = paramStr(1)

proc readFixture(name: string): string = readFile(directory / (name & ".wasm"))

proc reject(name, diagnostic: string) =
  try:
    discard decodeComponent(cast[seq[byte]](readFixture(name)))
    doAssert false, name & " validated unexpectedly"
  except ComponentError as error:
    doAssert error.msg.contains(diagnostic), error.msg

when defined(wasmComponentThreadSpawn):
  doAssert checkThreadSpawnFixtures(readFixture("probe"), readFixture("parallelism"))
  reject("shared", "shared canonical threads require preemptive core support")
  reject("parallelism-shared", "shared canonical threads require preemptive core support")
  reject("invalid-flag", "invalid canonical thread sharedness")
  reject("missing-type", "invalid canonical spawn function type")
  reject("erased-import", "canonical resource function type mismatch")
  reject("indirect", "canonical thread.spawn-indirect requires a shared core table")
  reject("legacy", "invalid canonical spawn function type")
  for (name, diagnostic) in [("null", "canonical thread.spawn-ref target is null"),
                             ("capacity", "canonical thread.spawn-ref capacity exceeded")]:
    let trapping = block:
      let plan = decodeComponent(cast[seq[byte]](readFixture(name)))
      instantiateComponent(plan)
    defer: trapping.closeComponent()
    let call = trapping.beginCallback("run", [])
    try:
      discard call.pollCallback()
      doAssert false, name & " did not trap"
    except ComponentError as error:
      doAssert error.msg.contains(diagnostic), error.msg
    doAssert call.pollCallback() == ccsTrapped
  echo "Component thread spawn PASS: pinned wire, callback scheduling, capacity and traps"
else:
  reject("probe", "canonical thread spawning is disabled")
  echo "Component thread spawn feature gate PASS"
