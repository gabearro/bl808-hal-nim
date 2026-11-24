## M0 WASM task lifecycle: trapped-slot reaping + immediate teardown.
##
## Validates the M1 fix for the verified "trapped task leaks the 8-slot table
## forever" defect (wasm_scheduler.nim resumeWasmTask set wasmTaskTrapped with
## no reclaim path). A task is driven into a quota trap, asserted to still be
## observable (wasmTaskTrapped), then reapTrappedSlots() is shown to reclaim
## the slot. killWasmTask is shown to free a slot immediately. reapStuckTasks
## (soft watchdog) is exercised for call-safety.
##
## Run on hardware via tools/hw_validate.py (tier=manual):
##   make m0 FILE=examples/m0_wasm_lifecycle_test.nim
## Markers: [PASS] / [FAIL].

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/alloc
import bl808/kernel/cps
import bl808/wasm_control
import bl808/wasm_store
import bl808/wasm_task_smoke

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  LifecycleSlot = 6'u32
  TaskInfoCap = WasmSchedulerMaxTasks.uint32

var
  console: Uart

proc pass(msg: string) =
  discard console.sendString("[PASS] ")
  discard console.sendLine(msg)

proc fail(msg: string, code: uint32 = 0) =
  discard console.sendString("[FAIL] ")
  discard console.sendString(msg)
  if code != 0:
    discard console.sendString(" code=")
    console.sendHex32(code)
  discard console.sendLine("")

proc taskTableCount(): uint32 =
  var info: array[WasmSchedulerMaxTasks, WasmSchedulerTaskInfo]
  collectWasmTasks(info)

proc runLifecycleChecks() =
  initWasmProgramStore()
  discard unloadWasmProgram(LifecycleSlot)
  let install = installWasmProgramBytes(LifecycleSlot, SumModule, generation = 1'u32)
  if install.status != wasmControlOk:
    fail("lifecycle install", install.status.ord.uint32)
    return
  pass("lifecycle program installed")

  let baseline = taskTableCount()

  # 1) Drive a task into a quota trap, then assert the slot is STILL present
  #    (this is the exact condition that previously leaked). The slot must be
  #    observable as wasmTaskTrapped before reaping.
  var start = startWasmTaskI32(LifecycleSlot, "sum", [100'i32],
                               maxTotalFuel = 8'u32)
  if start.status != wasmSchedOk:
    fail("lifecycle start", start.status.ord.uint32)
    discard unloadWasmProgram(LifecycleSlot)
    return
  let taskId = start.id
  var seenTrapped = false
  for _ in 0 ..< 8:
    let r = resumeWasmTask(taskId, 4'u32)
    if r.state == wasmTaskTrapped:
      seenTrapped = true
      break
    if r.state == wasmTaskExited:
      break
  if not seenTrapped:
    fail("lifecycle did not reach trapped state", 0)
    discard killWasmTask(taskId)
    discard unloadWasmProgram(LifecycleSlot)
    return
  let trapped = getWasmTask(taskId)
  if trapped.status == wasmSchedOk and trapped.state == wasmTaskTrapped and
      taskTableCount() == baseline + 1'u32:
    pass("trapped slot retained for observation (pre-reap)")
  else:
    fail("trapped slot not observable", trapped.state.ord.uint32)

  # 2) Reap trapped slots. After WasmTaskTrapReapPolls+1 passes the slot must be
  #    reclaimed (the leak fix). The task id is then wasmSchedNoTask.
  for _ in 0 ..< WasmTaskTrapReapPolls.int + 1:
    discard reapTrappedSlots()
  let afterReap = getWasmTask(taskId)
  if afterReap.status == wasmSchedNoTask and taskTableCount() == baseline:
    pass("trapped slot reaped (leak fixed)")
  else:
    fail("trapped slot not reaped", afterReap.status.ord.uint32)

  # 3) killWasmTask frees a live slot immediately (clearSlotTeardown path).
  var start2 = startWasmTaskI32(LifecycleSlot, "sum", [4'i32],
                                maxTotalFuel = 4096'u32)
  if start2.status == wasmSchedOk:
    discard killWasmTask(start2.id)
    if getWasmTask(start2.id).status == wasmSchedNoTask:
      pass("kill freed slot immediately")
    else:
      fail("kill did not free slot", 0)
  else:
    fail("lifecycle start2", start2.status.ord.uint32)

  # 4) Soft watchdog reaper is callable and does not disturb live tasks.
  var start3 = startWasmTaskI32(LifecycleSlot, "sum", [4'i32])
  if start3.status == wasmSchedOk:
    let watchdogStopped = reapStuckTasks()
    # A fresh, progressing task must not be watchdog-killed; a count of 0 here
    # is the expected healthy result (it has not stalled).
    if getWasmTask(start3.id).status == wasmSchedOk and watchdogStopped == 0:
      pass("soft watchdog call-safe, no false stop")
    else:
      fail("soft watchdog false stop", watchdogStopped)
    discard killWasmTask(start3.id)
  else:
    fail("lifecycle start3", start3.status.ord.uint32)

  discard unloadWasmProgram(LifecycleSlot)
  discard console.sendLine("=== Lifecycle Test Complete ===")

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  schedulerInit()

  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(ConsoleUartTxPin, ConsoleUartRxPin)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud,
    dataBits: data8,
    stopBits: stop1,
    parity: parityNone,
  ), ConsoleClkHz)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 WASM Lifecycle Test ===")
  runLifecycleChecks()
  runScheduler()
