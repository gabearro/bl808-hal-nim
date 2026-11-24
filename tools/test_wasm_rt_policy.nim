import bl808/wasm_rt_policy

const M0 = 1'u32 shl 1

proc hard(offset: uint64): WasmRtSpec =
  WasmRtSpec(class: wrHard, releaseTick: 0, deadlineTick: 90,
    budgetTicks: 30, maxSliceTicks: 20, startJitterTicks: 5,
    affinityMask: M0, slotOffsetTicks: offset, slotLengthTicks: 40,
    residentWorkingSet: true, boundedImports: true,
    noPeerDependency: true, noFlashMutation: true)

var policy: WasmRtPolicy
doAssert policy.initWasmRtPolicy(M0, 0, 100) == wrOk
var unsafe = hard(10)
unsafe.noPeerDependency = false
doAssert policy.admitWasmRtJob(1, unsafe) == wrUnsafeHardSlot
doAssert policy.admitWasmRtJob(1, hard(10)) == wrOk
doAssert policy.admitWasmRtJob(2, hard(30)) == wrSlotOverlap
doAssert policy.admitWasmRtJob(2, hard(50)) == wrOk

let softLate = WasmRtSpec(class: wrSoft, releaseTick: 0,
  deadlineTick: 95, budgetTicks: 20, maxSliceTicks: 8,
  affinityMask: M0, overrun: wrDemote)
let softEarly = WasmRtSpec(class: wrSoft, releaseTick: 0,
  deadlineTick: 80, budgetTicks: 20, maxSliceTicks: 8,
  affinityMask: M0, overrun: wrStop)
doAssert policy.admitWasmRtJob(3, softLate) == wrOk
doAssert policy.admitWasmRtJob(4, softEarly) == wrOk
let runnable = [1'u32, 2, 3, 4, 5]
doAssert policy.dispatchCutoffTick(1, 10) == 50
doAssert policy.dispatchCutoffTick(4, 91) == 110
doAssert policy.chooseWasmRtJob(runnable, 10, 8) == 1
doAssert policy.chooseWasmRtJob([3'u32, 4], 10, 8) == 0
doAssert policy.chooseWasmRtJob(runnable, 45, 8) == 0
doAssert policy.chooseWasmRtJob(runnable, 91, 8) == 4
doAssert policy.chooseWasmRtJob(runnable, 103, 8) == 0
doAssert policy.chooseWasmRtJob([3'u32, 5], 91, 8) == 3
doAssert policy.chooseWasmRtJob([5'u32], 91, 8) == 5
doAssert policy.observeWasmRtRun(1, 16, 30) == wrStopJob
doAssert policy.wasmRtTelemetry().startJitterMisses == 1
doAssert policy.observeWasmRtRun(3, 91, 100) == wrDemoteJob
doAssert policy.wasmRtClass(3) == wrBestEffort
doAssert policy.observeWasmRtRun(2, 51, 80, memoryFault = true) == wrStopJob
let telemetry = policy.wasmRtTelemetry()
doAssert telemetry.hardFaults == 1 and telemetry.sliceOverruns == 2 and
  telemetry.deadlineMisses == 2 and telemetry.maxStartJitterTicks == 6
policy.removeWasmRtJob(1)
doAssert policy.admitWasmRtJob(6, hard(10)) == wrOk

var periodic: WasmRtPolicy
doAssert periodic.initWasmRtPolicy(M0, 1000, 100) == wrOk
var recurring = hard(10)
recurring.releaseTick = 1000
doAssert periodic.admitWasmRtJob(7, recurring) == wrOk
doAssert periodic.chooseWasmRtJob([7'u32], 1010, 0) == 7
doAssert periodic.observeWasmRtRun(7, 1010, 1025) == wrKeepRunning
doAssert periodic.chooseWasmRtJob([7'u32], 1110, 0) == 7
doAssert periodic.observeWasmRtRun(7, 1110, 1130) == wrKeepRunning
doAssert periodic.observeWasmRtRun(7, 1130, 1145) == wrStopJob
doAssert periodic.wasmRtTelemetry().budgetOverruns == 1
doAssert periodic.observeWasmRtRun(7, 1210, 1225) == wrKeepRunning
doAssert periodic.wasmRtTelemetry().starts == 3
doAssert periodic.wasmRtTelemetry().deadlineMisses == 0
periodic.pollWasmRtPolicy(1250)
doAssert periodic.wasmRtTelemetry().missedReservations == 0
periodic.pollWasmRtPolicy(1450)
doAssert periodic.wasmRtTelemetry().missedReservations == 2
periodic.pollWasmRtPolicy(1450)
doAssert periodic.wasmRtTelemetry().missedReservations == 2
var invalidDeadline = hard(10)
invalidDeadline.deadlineTick = 40
doAssert periodic.admitWasmRtJob(8, invalidDeadline) == wrUnsafeHardSlot

var wake: WasmRtPolicy
doAssert wake.initWasmRtPolicy(M0, 1000, 100) == wrOk
doAssert wake.nextWasmRtWakeTick([], 900, 0) == 0
var releasesInSlot = hard(10)
releasesInSlot.releaseTick = 1015
doAssert wake.admitWasmRtJob(1, releasesInSlot) == wrOk
doAssert wake.nextWasmRtWakeTick([3'u32], 900, 105) == 900
doAssert wake.nextWasmRtWakeTick([1'u32], 1000, 0) == 1010
doAssert wake.nextWasmRtWakeTick([1'u32], 1010, 0) == 1015
doAssert wake.nextWasmRtWakeTick([1'u32], 1015, 0) == 1015
doAssert wake.nextWasmRtWakeTick([], 1015, 0) == 1050
doAssert wake.nextWasmRtWakeTick([], 1080, 0) == 1080
wake.pollWasmRtPolicy(1080)
doAssert wake.wasmRtTelemetry().missedReservations == 1
doAssert wake.nextWasmRtWakeTick([], 1080, 0) == 1110
wake.removeWasmRtJob(1)
doAssert wake.nextWasmRtWakeTick([], 1080, 0) == 0
var late = softLate
late.releaseTick = 1120
late.deadlineTick = 1150
doAssert wake.admitWasmRtJob(2, late) == wrOk
doAssert wake.nextWasmRtWakeTick([2'u32], 1100, 0) == 1120
doAssert wake.nextWasmRtWakeTick([], 1100, 0) == 1151
wake.pollWasmRtPolicy(1151)
wake.pollWasmRtPolicy(1152)
doAssert wake.nextWasmRtWakeTick([], 1152, 0) == 0
doAssert wake.wasmRtTelemetry().deadlineMisses == 1
echo "WASM RT policy PASS: hard slots, admission, EDF, slack, overruns"
