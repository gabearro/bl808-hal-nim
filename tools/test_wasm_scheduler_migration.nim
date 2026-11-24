import std/os
import bl808/[wasm_scheduler, wasm_store]

proc wrapped(path: string): seq[byte] =
  let moduleBytes = cast[seq[byte]](readFile(path))
  result = newSeq[byte](WasmProgramHeaderLen.int + moduleBytes.len)
  doAssert initWasmProgramImage(
    cast[ptr UncheckedArray[byte]](addr result[0]), result.len.uint32,
    moduleBytes) == wasmProgramOk

proc imageBase(image: var seq[byte]): ptr UncheckedArray[byte] =
  cast[ptr UncheckedArray[byte]](addr image[0])

proc main() =
  doAssert paramCount() == 2
  var image = wrapped(paramStr(1))
  var other = wrapped(paramStr(2))
  resetWasmScheduler()
  let source = startFullWasmImageTaskI32(image.imageBase(), image.len.uint32,
    "deep", [], maxTotalFuel = 256, slotLabel = 2)
  doAssert source.status == wasmSchedOk
  for _ in 0 ..< 8:
    doAssert resumeWasmTask(source.id, 5).state == wasmTaskYielded
  var migration = captureWasmTaskMigration(source.id)
  doAssert migration.status == wasmMigrationOk and migration.slot == 2 and
    migration.fuelUsed == 40 and migration.bytes.len > 64
  doAssert getWasmTask(source.id).state == wasmTaskMigrating
  doAssert resumeWasmTask(source.id, 1).status == wasmSchedBadState
  doAssert activateWasmTaskMigration(source.id) == wasmMigrationBadState
  doAssert cancelWasmTaskMigration(source.id) == wasmMigrationOk
  doAssert getWasmTask(source.id).state == wasmTaskYielded
  migration = captureWasmTaskMigration(source.id)
  doAssert migration.status == wasmMigrationOk

  let wrong = prepareFullWasmMigrationImage(other.imageBase(),
    other.len.uint32, migration)
  doAssert wrong.status == wasmSchedInitFailed
  var corrupt = migration
  corrupt.bytes = migration.bytes
  corrupt.bytes[^1] = corrupt.bytes[^1] xor 1
  doAssert prepareFullWasmMigrationImage(image.imageBase(), image.len.uint32,
    corrupt).status == wasmSchedInitFailed
  doAssert getWasmTask(source.id).state == wasmTaskMigrating

  let dest = prepareFullWasmMigrationImage(image.imageBase(),
    image.len.uint32, migration)
  doAssert dest.status == wasmSchedOk and dest.state == wasmTaskMigrating
  doAssert resumeWasmTask(dest.id, 1).status == wasmSchedBadState
  doAssert cancelWasmTaskMigration(dest.id) == wasmMigrationBadState
  doAssert retireWasmTaskMigration(source.id) == wasmMigrationOk
  doAssert getWasmTask(source.id).status == wasmSchedNoTask
  doAssert activateWasmTaskMigration(dest.id) == wasmMigrationOk
  var current = getWasmTask(dest.id)
  var slices = 0
  while current.state == wasmTaskYielded:
    current = resumeWasmTask(dest.id, 8)
    inc slices
    doAssert slices < 100
  doAssert current.status == wasmSchedOk and
    current.state == wasmTaskExited and current.result == 42 and
    current.fuelUsed > migration.fuelUsed
  discard killWasmTask(dest.id)

  let second = startFullWasmImageTaskI32(image.imageBase(), image.len.uint32,
    "deep", [], maxTotalFuel = 256, slotLabel = 2)
  doAssert resumeWasmTask(second.id, 2).state == wasmTaskYielded
  let pending = captureWasmTaskMigration(second.id)
  doAssert pending.status == wasmMigrationOk
  let abandoned = prepareFullWasmMigrationImage(image.imageBase(),
    image.len.uint32, pending)
  doAssert abandoned.status == wasmSchedOk
  doAssert discardPreparedWasmTaskMigration(abandoned.id) == wasmMigrationOk
  doAssert getWasmTask(abandoned.id).status == wasmSchedNoTask
  doAssert cancelWasmTaskMigration(second.id) == wasmMigrationOk
  doAssert getWasmTask(second.id).state == wasmTaskYielded
  discard killWasmTask(second.id)
  resetWasmScheduler()
  echo "full scheduler portable handoff PASS: freeze, verify, retire, activate"

main()
