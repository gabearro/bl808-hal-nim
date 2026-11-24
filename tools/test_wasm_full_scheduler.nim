import bl808/[wasm_full_baseline, wasm_scheduler, wasm_store]

var image = newSeq[byte](WasmProgramHeaderLen.int + WasmFullBaselineModule.len)
doAssert initWasmProgramImage(
  cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
  WasmFullBaselineModule) == wasmProgramOk
let base = cast[ptr UncheckedArray[byte]](addr image[0])

resetWasmScheduler()
let started = startFullWasmImageTaskI32(base, image.len.uint32,
  "indirect", [20'i32, 22'i32], maxTotalFuel = 64)
doAssert started.status == wasmSchedOk and started.state == wasmTaskReady
var current = started
var slices = 0
while current.state in {wasmTaskReady, wasmTaskYielded}:
  current = resumeWasmTask(started.id, 2)
  inc slices
  doAssert slices < 32
doAssert slices > 1 and current.status == wasmSchedOk and
  current.state == wasmTaskExited and current.result == 42
doAssert current.fuelUsed > 2 and current.fuelUsed <= 64
doAssert current.yields > 0
var collected: array[WasmSchedulerMaxTasks, WasmSchedulerTaskInfo]
doAssert collectWasmTasks(collected) == 1
doAssert collected[0].id == started.id and collected[0].result == 42
doAssert killWasmTask(started.id).state == wasmTaskKilled
doAssert getWasmTask(started.id).status == wasmSchedNoTask

let limited = startFullWasmImageTaskI32(base, image.len.uint32,
  "indirect", [20'i32, 22'i32], maxTotalFuel = 2)
doAssert limited.status == wasmSchedOk
doAssert resumeWasmTask(limited.id, 1).state == wasmTaskYielded
let quota = resumeWasmTask(limited.id, 1)
doAssert quota.state == wasmTaskYielded
let exhausted = resumeWasmTask(limited.id, 1)
doAssert exhausted.status == wasmSchedQuotaExceeded and
  exhausted.state == wasmTaskTrapped
for _ in 0 .. WasmTaskTrapReapPolls:
  discard reapTrappedSlots()
doAssert getWasmTask(limited.id).status == wasmSchedNoTask

resetWasmScheduler()
echo "full WASM scheduler PASS: bounded slices, result, quota, teardown"
