import bl808/[wasm_full_baseline, wasm_rt_policy, wasm_scheduler, wasm_store]
when defined(wasmRtKernelTest): import bl808/wasm_rt_kernel

var image = newSeq[byte](WasmProgramHeaderLen.int + WasmFullBaselineModule.len)
doAssert initWasmProgramImage(
  cast[ptr UncheckedArray[byte]](addr image[0]), image.len.uint32,
  WasmFullBaselineModule) == wasmProgramOk
let base = cast[ptr UncheckedArray[byte]](addr image[0])

var now = 0'u64
proc tick(): uint64 {.nimcall.} =
  result = now
  now += 1

resetWasmScheduler()
doAssert initWasmRtScheduler(2'u32, 0, 100) == wrOk
let started = startFullWasmImageTaskI32(base, image.len.uint32,
  "indirect", [20'i32, 22'i32], maxTotalFuel = 64)
doAssert started.status == wasmSchedOk
doAssert admitWasmTaskRt(started.id, WasmRtSpec(
  class: wrHard, releaseTick: 0, deadlineTick: 90,
  budgetTicks: 30, maxSliceTicks: 10, startJitterTicks: 5,
  affinityMask: 2, slotOffsetTicks: 0, slotLengthTicks: 60,
  residentWorkingSet: true, boundedImports: true,
  noPeerDependency: true, noFlashMutation: true)) == wrOk
doAssert runWasmSchedulerRt(tick, 10, fuelPerTask = 64) == 1
let completed = getWasmTask(started.id)
doAssert completed.status == wasmSchedOk and completed.state == wasmTaskExited and
  completed.result == 42
doAssert wasmSchedulerRtTelemetry().starts == 1 and
  wasmSchedulerRtTelemetry().deadlineMisses == 0

let soft = startFullWasmImageTaskI32(base, image.len.uint32,
  "add", [18'i32, 24'i32], maxTotalFuel = 64)
doAssert soft.status == wasmSchedOk
doAssert admitWasmTaskRt(soft.id, WasmRtSpec(
  class: wrSoft, releaseTick: 60, deadlineTick: 80,
  budgetTicks: 20, maxSliceTicks: 10, affinityMask: 2,
  overrun: wrStop)) == wrOk
doAssert runWasmSchedulerRt(tick, 10, fuelPerTask = 64) == 0
now = 60
doAssert runWasmSchedulerRt(tick, 10, fuelPerTask = 64) == 1
doAssert getWasmTask(soft.id).result == 42
doAssert wasmSchedulerRtTelemetry().starts == 2
resetWasmScheduler()
echo "WASM RT task dispatch PASS: full VM hard slot and soft deadline"

when defined(wasmRtKernelTest):
  var
    kernelNow = 1_000'u64
    armedTick: uint64
    installed: TestTimedHook
    noHookCapacity = true
    installs: int

  proc kernelTick(): uint64 {.nimcall.} = kernelNow

  proc install(hook: TestTimedHook, deadline: uint64): bool {.nimcall.} =
    if noHookCapacity or installed != nil: return false
    installed = hook
    inc installs
    armedTick = deadline
    true

  proc rearm(hook: TestTimedHook, deadline: uint64): bool {.nimcall.} =
    if installed != hook: return false
    armedTick = deadline
    true

  proc pollAt(tick: uint64) =
    kernelNow = tick
    if armedTick != 0 and armedTick <= tick:
      armedTick = installed(tick)

  wasmRtTestTick = kernelTick
  wasmRtTestInstall = install
  wasmRtTestRearm = rearm
  doAssert not attachWasmRtKernel()
  doAssert initWasmRtScheduler(2, 1_000, 100) == wrOk
  doAssert not attachWasmRtKernel() and armedTick == 0
  noHookCapacity = false
  doAssert attachWasmRtKernel(fuelPerSlice = 1) and armedTick == 0 and installs == 1

  let hard = startFullWasmImageTaskI32(base, image.len.uint32,
    "indirect", [20'i32, 22'i32], maxTotalFuel = 64)
  doAssert hard.status == wasmSchedOk and armedTick == 0
  doAssert admitWasmTaskRt(hard.id, WasmRtSpec(
    class: wrHard, releaseTick: 1_015, budgetTicks: 30, maxSliceTicks: 10,
    startJitterTicks: 5, affinityMask: 2, slotOffsetTicks: 10,
    slotLengthTicks: 40, residentWorkingSet: true, boundedImports: true,
    noPeerDependency: true, noFlashMutation: true)) == wrOk
  doAssert armedTick == 1_010
  doAssert resumeWasmTask(hard.id).status == wasmSchedBadState
  doAssert runWasmScheduler() == 0
  pollAt(1_010)
  doAssert armedTick == 1_015 and getWasmTask(hard.id).resumes == 0
  pollAt(1_015)
  doAssert getWasmTask(hard.id).resumes == 1 and armedTick == 1_015
  for _ in 0 ..< 16:
    if armedTick == 0: break
    pollAt(1_015)
  doAssert getWasmTask(hard.id).result == 42 and armedTick == 0

  let delayed = startFullWasmImageTaskI32(base, image.len.uint32,
    "add", [18'i32, 24'i32], maxTotalFuel = 64)
  doAssert admitWasmTaskRt(delayed.id, WasmRtSpec(class: wrSoft,
    releaseTick: 1_040, deadlineTick: 1_060, affinityMask: 2,
    maxSliceTicks: 10)) == wrOk and armedTick == 1_040
  doAssert blockWasmTask(delayed.id, wasmTaskBlockedIpc).status == wasmSchedOk
  doAssert armedTick == 1_061
  pollAt(1_061)
  doAssert armedTick == 0 and wasmSchedulerRtTelemetry().deadlineMisses == 1
  doAssert unblockWasmTask(delayed.id).status == wasmSchedOk
  doAssert armedTick == 1_061
  for _ in 0 ..< 8:
    if armedTick == 0: break
    pollAt(1_061)
  doAssert getWasmTask(delayed.id).result == 42 and armedTick == 0
  doAssert wasmSchedulerRtTelemetry().deadlineMisses == 1
  doAssert attachWasmRtKernel(fuelPerSlice = 1) and installs == 1
  resetWasmScheduler()
  doAssert armedTick == 0
  detachWasmRtKernel()
  echo "WASM tickless dispatch PASS: release, one slice per poll, IPC unblock, blocked deadline"
