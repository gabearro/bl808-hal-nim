## M0 launcher for the LP WebAssembly VM smoke image.

import bl808/startup
import bl808/core, bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/wasm_runtime
import bl808/wasm_smoke
import bl808/wasm_task_smoke

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  LpWasmStatusAddr = 0x40002E80'u
  LpWasmStageAddr = WasmSmokeStageAddr
  LpWasmCapsAddr = 0x40002E88'u
  LpWasmTaskStatusAddr = 0x40002E8C'u
  WaitLimit = 100_000
  ExpectedLpWasmCaps =
    (wasmCoreLP.ord.uint32 shl 24) or
    (1'u32 shl 0) or # compact runtime
    (1'u32 shl 1) or # flash-backed VM
    (1'u32 shl 2) or # software f32
    (1'u32 shl 3) or # i32
    (1'u32 shl 4)    # f32

var console: Uart

proc spinDelay() =
  for _ in 0 ..< 1_000:
    {.emit: """asm volatile("");""".}

proc sharedRead32(address: uint): uint32 =
  dcacheFlushAll()
  dcacheInvalidateAll()
  core.fence()
  regRead(address)

proc printHex(label: string, value: uint32) =
  discard console.sendString(label)
  console.sendHex32(value)
  discard console.sendLine("")

proc main() {.exportc, cdecl.} =
  systemInit()

  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), ConsoleClkHz)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 WASM LP Smoke Helper (M0) ===")
  discard console.sendLine("[M0] Releasing LP WASM smoke")

  regWrite(LpWasmStatusAddr, 0)
  regWrite(LpWasmStageAddr, 0)
  regWrite(LpWasmCapsAddr, 0)
  regWrite(LpWasmTaskStatusAddr, 0)
  dcacheFlushAll()
  fenceIo()

  mmPowerOn()
  releaseLP()

  var ok = false
  var lastStage = 0'u32
  var printedStatus = false
  var printedTaskStatus = false
  for _ in 0 ..< WaitLimit:
    let status = sharedRead32(LpWasmStatusAddr)
    let stage = sharedRead32(LpWasmStageAddr)
    if stage != 0 and stage != lastStage:
      printHex("  lp_wasm_stage=", stage)
      lastStage = stage
    if status != 0:
      let caps = sharedRead32(LpWasmCapsAddr)
      let taskStatus = sharedRead32(LpWasmTaskStatusAddr)
      if not printedStatus:
        printHex("  lp_wasm_status=", status)
        printHex("  lp_wasm_caps=", caps)
        printedStatus = true
      if taskStatus != 0 and not printedTaskStatus:
        printHex("  lp_wasm_task_status=", taskStatus)
        printedTaskStatus = true
      if status == WasmSmokeOk and caps == ExpectedLpWasmCaps and
          taskStatus == WasmTaskSmokeOk:
        ok = true
        break
    spinDelay()

  if ok:
    discard console.sendLine("[PASS] LP WASM runtime capabilities match LP compact profile")
    discard console.sendLine("[PASS] LP WASM i32/f32/memory smoke passed")
    discard console.sendLine("[PASS] LP WASM task context switching smoke passed")
  else:
    printHex("  lp_wasm_stage=", sharedRead32(LpWasmStageAddr))
    if not printedStatus:
      printHex("  lp_wasm_status=", sharedRead32(LpWasmStatusAddr))
      printHex("  lp_wasm_caps=", sharedRead32(LpWasmCapsAddr))
    if not printedTaskStatus:
      printHex("  lp_wasm_task_status=", sharedRead32(LpWasmTaskStatusAddr))
    discard console.sendLine("[FAIL] LP WASM smoke did not pass")

  while true:
    wfi()
