## M0 WASM task driven by the HAL CPS scheduler.

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/alloc
import bl808/kernel/cps
import bl808/wasm_cps
import bl808/wasm_store
import bl808/wasm_task_smoke

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  CpsWasmSlot = 5'u32

var
  console: Uart
  heartbeatTicks = 0'u32

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

proc heartbeatTask(): CpsVoidFuture {.cps.} =
  while heartbeatTicks < 64'u32:
    inc heartbeatTicks
    await yieldNow()

proc wasmCpsTask(): CpsVoidFuture {.cps.} =
  initWasmProgramStore()
  discard unloadWasmProgram(CpsWasmSlot)
  let install = installWasmProgramBytes(CpsWasmSlot, SumModule, generation = 4'u32)
  if install.status != wasmControlOk:
    fail("CPS WASM install", install.status.ord.uint32)
    return
  pass("CPS WASM program installed")

  discard heartbeatTask()
  let run = await startAndRunWasmProgramTaskCps(
    CpsWasmSlot,
    "sum",
    [32'i32],
    sliceFuel = 2'u32,
    maxSlices = 256'u32,
    maxTotalFuel = 2048'u32,
  )
  if run.status != wasmControlOk or run.taskState != wasmTaskExited:
    fail("CPS WASM task run", run.schedulerStatus.ord.uint32)
  elif run.value != 496'i32:
    fail("CPS WASM result", cast[uint32](run.value))
  elif heartbeatTicks < 4'u32:
    fail("CPS runtime starved by WASM", heartbeatTicks)
  elif run.yields < 4'u32:
    fail("CPS WASM did not yield", run.yields)
  else:
    pass("CPS drove WASM task without starving scheduler")
  discard killWasmProgramTask(run.taskId)

  let quota = await startAndRunWasmProgramTaskCps(
    CpsWasmSlot,
    "sum",
    [100'i32],
    sliceFuel = 4'u32,
    maxSlices = 256'u32,
    maxTotalFuel = 8'u32,
  )
  if quota.status == wasmControlRunError and
      quota.schedulerStatus == wasmSchedQuotaExceeded and
      quota.taskState == wasmTaskTrapped and
      quota.trapCode == wasmSchedQuotaExceeded.ord.uint32:
    pass("CPS WASM quota trap surfaced")
  else:
    fail("CPS WASM quota trap", quota.trapCode)
  discard killWasmProgramTask(quota.taskId)

  discard unloadWasmProgram(CpsWasmSlot)
  discard console.sendLine("=== Test Complete ===")

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
  discard console.sendLine("=== BL808 WASM CPS Scheduler Test ===")
  discard wasmCpsTask()
  runScheduler()
