## Connect the WASM task table to one rearmable timed kernel poll hook.

when not defined(bl808WasmRtPolicy):
  {.error: "enable the WASM real-time policy".}

import ./wasm_scheduler

when defined(wasmRtKernelTest):
  type TestTimedHook* = proc(now: uint64): uint64 {.closure.}
  var
    wasmRtTestTick*: WasmSchedulerClock
    wasmRtTestInstall*: proc(hook: TestTimedHook, deadline: uint64): bool {.nimcall.}
    wasmRtTestRearm*: proc(hook: TestTimedHook, deadline: uint64): bool {.nimcall.}
  template readTick(): uint64 = wasmRtTestTick()
  template addSchedulerTimedPollHook(hook, deadline: untyped): bool =
    wasmRtTestInstall(hook, deadline)
  template rescheduleSchedulerTimedPollHook(hook, deadline: untyped): bool =
    wasmRtTestRearm(hook, deadline)
elif defined(bl808kernel):
  import ./kernel/[clock, sched]
else:
  {.error: "the timed WASM driver requires the BL808 kernel".}

var
  attached: bool
  fallbackSliceTicks: uint64
  sliceFuel: uint32

proc localTick(): uint64 {.nimcall.} = readTick()

when FullSchedulerAtomicWait:
  proc localAtomicNanoseconds(): uint64 {.nimcall.} =
    when defined(wasmRtKernelTest): localTick() * 1000
    else: ticksToUs(localTick()) * 1000

  proc atomicDurationTicks(ns: uint64): uint64 {.nimcall.} =
    let us = ns div 1000 + (if ns mod 1000 == 0: 0'u64 else: 1'u64)
    when defined(wasmRtKernelTest): us
    else:
      let rate = max(clockGetTickRate(), 1'u64)
      min(us, uint64.high div rate) * rate

proc pollWasmRtKernel(now: uint64): uint64 =
  discard now
  if not attached: return 0
  # One slice per poll. Ready CPS work and other timed hooks get the next
  # scheduler iteration even when the WASM task can continue immediately.
  discard runWasmSchedulerRt(localTick, fallbackSliceTicks, sliceFuel, maxResumes = 1)
  nextWasmSchedulerRtWakeTick(localTick(), fallbackSliceTicks)

proc rearmWasmRtKernel() {.nimcall.} =
  let deadline = nextWasmSchedulerRtWakeTick(localTick(), fallbackSliceTicks)
  discard rescheduleSchedulerTimedPollHook(pollWasmRtKernel, deadline)

proc attachWasmRtKernel*(bestEffortMaxSliceTicks = 0'u64,
                         fuelPerSlice = WasmSchedulerDefaultFuel): bool =
  ## Call from task context after kernel and per-core RT policy setup.
  ## A zero fallback allows only explicitly admitted tasks to run.
  if not wasmRtSchedulerReady() or fuelPerSlice == 0: return false
  when defined(wasmRtKernelTest):
    if wasmRtTestTick == nil or wasmRtTestInstall == nil or wasmRtTestRearm == nil:
      return false
  if not rescheduleSchedulerTimedPollHook(pollWasmRtKernel, 0) and
      not addSchedulerTimedPollHook(pollWasmRtKernel, 0):
    attached = false
    setWasmRtKernelWakeHook(nil)
    return false
  fallbackSliceTicks = bestEffortMaxSliceTicks
  sliceFuel = fuelPerSlice
  attached = true
  when FullSchedulerAtomicWait:
    setWasmSchedulerAtomicClock(localAtomicNanoseconds, atomicDurationTicks)
  setWasmRtKernelWakeHook(rearmWasmRtKernel)
  true

proc detachWasmRtKernel*() =
  if not attached: return
  attached = false
  setWasmRtKernelWakeHook(nil)
  discard rescheduleSchedulerTimedPollHook(pollWasmRtKernel, 0)
