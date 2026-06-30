## M0 flash-resident WASM program store smoke test.

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/alloc
import bl808/wasm_store
import cps/wasm/runtime_int

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

  StoreSlot = 0'u32

  AddModule = [
    byte 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7F, 0x7F, 0x01,
    0x7F, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01,
    0x03, 0x61, 0x64, 0x64, 0x00, 0x00, 0x0A, 0x09,
    0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6A,
    0x0B
  ]

proc printStatus(console: Uart, err: WasmProgramError) =
  discard console.sendString("[FAIL] WASM program store error=")
  console.sendHex32(err.ord.uint32)
  discard console.sendLine("")

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  initWasmProgramStore()

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
  discard console.sendLine("=== BL808 WASM Program Store Test ===")

  let writeErr = writeWasmProgramSlot(StoreSlot, AddModule, generation = 1'u32)
  if writeErr != wasmProgramOk:
    printStatus(console, writeErr)
    discard console.sendLine("=== Test Complete ===")
    while true:
      wfi()
  discard console.sendLine("[PASS] WASM program written to flash slot")

  var program: LoadedWasmProgram
  let loadErr = loadWasmProgramSlot(StoreSlot, program)
  if loadErr != wasmProgramOk:
    printStatus(console, loadErr)
  elif not program.loaded:
    discard console.sendLine("[FAIL] WASM program did not load")
  elif program.header.imageLen != 41'u32:
    discard console.sendLine("[FAIL] WASM program header length mismatch")
  else:
    var vm = initIntWasmVM()
    var moduleIdx: int
    var value: int32
    var ok = true
    try:
      moduleIdx = vm.instantiateFlashIntOnly(program.module)
      value = vm.invokeI32(moduleIdx, "add", [17'i32, 25'i32])
    except CatchableError:
      ok = false

    if not ok:
      discard console.sendLine("[FAIL] WASM program invoke trapped")
    elif value != 42'i32:
      discard console.sendLine("[FAIL] WASM program result mismatch")
    else:
      program.unload()
      if program.loaded:
        discard console.sendLine("[FAIL] WASM program unload failed")
      else:
        discard console.sendLine("[PASS] WASM program loaded from flash-backed store")
        discard console.sendLine("[PASS] WASM program invoked through compact VM")
        discard console.sendLine("[PASS] WASM program unloaded")

  discard console.sendLine("=== Test Complete ===")

  while true:
    wfi()
