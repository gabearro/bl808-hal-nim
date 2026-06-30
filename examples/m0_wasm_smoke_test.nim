## M0 WebAssembly VM smoke test.

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/alloc
import bl808/wasm_runtime
import bl808/wasm_smoke
import bl808/wasm_task_smoke

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  ExpectedM0WasmCaps =
    (wasmCoreM0.ord.uint32 shl 24) or
    (1'u32 shl 1) or # flash-backed VM is available
    (1'u32 shl 3) or # i32
    (1'u32 shl 4) or # f32
    (1'u32 shl 5) or # f64
    (1'u32 shl 6)    # imports/full runtime

proc printHex(console: Uart, label: string, value: uint32) =
  discard console.sendString(label)
  console.sendHex32(value)
  discard console.sendLine("")

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()

  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(ConsoleUartTxPin, ConsoleUartRxPin)
  let console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud,
    dataBits: data8,
    stopBits: stop1,
    parity: parityNone,
  ), ConsoleClkHz)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 WASM M0 Smoke Test ===")
  let caps = wasmRuntimeCapabilityWord()
  printHex(console, "  m0_wasm_caps=", caps)
  if caps == ExpectedM0WasmCaps:
    discard console.sendLine("[PASS] M0 WASM runtime capabilities match M0 profile")
  else:
    discard console.sendLine("[FAIL] M0 WASM runtime capability mismatch")
  let status = runWasmSmoke()
  if status == WasmSmokeOk and caps == ExpectedM0WasmCaps:
    discard console.sendLine("[PASS] WASM i32/f32/memory smoke passed")
  else:
    discard console.sendString("[FAIL] WASM smoke status=")
    console.sendHex32(status)
    discard console.sendLine("")
  let taskStatus = runWasmTaskSmoke()
  if taskStatus == WasmTaskSmokeOk:
    discard console.sendLine("[PASS] M0 WASM task context switching smoke passed")
  else:
    discard console.sendString("[FAIL] M0 WASM task smoke status=")
    console.sendHex32(taskStatus)
    discard console.sendLine("")
  discard console.sendLine("=== Test Complete ===")

  while true:
    wfi()
