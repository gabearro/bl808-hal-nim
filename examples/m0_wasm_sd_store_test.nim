## M0 SD/exFAT to flash-backed WASM store smoke test.
##
## Place a small WASM module at 0:/programs/add.wasm to exercise the full path:
## SD/exFAT -> RAM scratch validation -> flash program slot -> compact VM.

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/alloc
import bl808/os_storage
import bl808/wasm_control
import bl808/wasm_http
import bl808/wasm_sd_store
import bl808/wasm_slot_smoke

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

  StoreSlot = 1'u32
  WasmName = "add.wasm"
  HttpWasmName = "http_add.wasm"

var wasmScratch: array[4096, byte]

proc printInstallStatus(console: Uart, r: WasmSdInstallResult) =
  discard console.sendString("[FAIL] WASM SD install status=")
  console.sendHex32(r.status.ord.uint32)
  discard console.sendString(" fs=")
  console.sendHex32(r.fsError.ord.uint32)
  discard console.sendString(" store=")
  console.sendHex32(r.storeError.ord.uint32)
  discard console.sendLine("")

proc printListStatus(console: Uart, r: WasmSdListResult) =
  discard console.sendString("[FAIL] WASM SD list status=")
  console.sendHex32(r.status.ord.uint32)
  discard console.sendString(" fs=")
  console.sendHex32(r.fsError.ord.uint32)
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
  discard console.sendLine("=== BL808 WASM SD Store Test ===")

  let storageStatus = osStorageInit(requireHighSpeed = true)
  if storageStatus != osStorageOk or not osStorageMounted():
    discard console.sendLine("[SKIP] SD filesystem not mounted")
    discard console.sendLine("=== Test Complete ===")
    while true:
      wfi()
  var fs = addr osStorageFs()

  let saved = fs[].saveWasmProgramToSd(WasmName, WasmSlotAddModule)
  if saved.status == wasmSdInstallOk:
    discard console.sendLine("[PASS] WASM program saved to SD")
  else:
    printInstallStatus(console, saved)
    discard console.sendLine("=== Test Complete ===")
    while true:
      wfi()

  var names: array[8, string]
  let listed = fs[].listWasmProgramsOnSd(names)
  var found = false
  for i in 0 ..< min(listed.count.int, names.len):
    if names[i] == WasmName:
      found = true
  if listed.status == wasmSdInstallOk and found:
    discard console.sendLine("[PASS] WASM program listed on SD")
  else:
    printListStatus(console, listed)
    discard console.sendLine("=== Test Complete ===")
    while true:
      wfi()

  let install = installWasmProgramFromSd(
    fs[],
    wasmSdProgramPath(WasmName),
    StoreSlot,
    wasmScratch,
    generation = 1'u32,
  )
  if install.status != wasmSdInstallOk:
    if install.status == wasmSdOpenError:
      discard console.sendLine("[SKIP] WASM file not found on SD")
    else:
      printInstallStatus(console, install)
    discard console.sendLine("=== Test Complete ===")
    while true:
      wfi()
  discard console.sendLine("[PASS] WASM program installed from SD")

  let run = runWasmProgramI32(StoreSlot, "add", [20'i32, 22'i32])
  if run.status != wasmControlOk:
    discard console.sendLine("[FAIL] WASM program run failed")
  elif run.value == 42'i32:
    discard console.sendLine("[PASS] WASM program invoked from SD-installed slot")
  else:
    discard console.sendLine("[FAIL] WASM program result mismatch")

  let httpSave = handleWasmHttpRequest(
    wasmHttpPost,
    "/wasm/repository/" & HttpWasmName,
    WasmSlotAddModule,
  )
  if httpSave.statusCode == 201'u16:
    discard console.sendLine("[PASS] HTTP saved WASM program to SD repository")
  else:
    discard console.sendString("[FAIL] HTTP SD save status=")
    console.sendHex32(httpSave.statusCode.uint32)
    discard console.sendLine("")
    discard console.sendLine("=== Test Complete ===")
    while true:
      wfi()

  let httpList = handleWasmHttpRequest(wasmHttpGet, "/wasm/repository", [])
  if httpList.statusCode == 200'u16 and httpList.body.len > 0 and
      httpList.body[0] == '{':
    discard console.sendLine("[PASS] HTTP listed SD WASM repository")
  else:
    discard console.sendString("[FAIL] HTTP SD list status=")
    console.sendHex32(httpList.statusCode.uint32)
    discard console.sendLine("")
    discard console.sendLine("=== Test Complete ===")
    while true:
      wfi()

  let httpInstall = handleWasmHttpRequest(
    wasmHttpPost,
    "/wasm/repository/" & HttpWasmName & "/install/2",
    [],
  )
  if httpInstall.statusCode == 201'u16:
    discard console.sendLine("[PASS] HTTP installed SD WASM program into flash slot")
  else:
    discard console.sendString("[FAIL] HTTP SD install status=")
    console.sendHex32(httpInstall.statusCode.uint32)
    discard console.sendString(" body=")
    discard console.sendString(httpInstall.body)
    discard console.sendLine("")
    discard console.sendLine("=== Test Complete ===")
    while true:
      wfi()

  let httpInvoke = handleWasmHttpRequest(
    wasmHttpPost,
    "/wasm/programs/2/invoke/add",
    [byte('1'), byte('9'), byte(','), byte('2'), byte('3')],
  )
  if httpInvoke.statusCode == 200'u16 and httpInvoke.control.value == 42'i32:
    discard console.sendLine("[PASS] HTTP invoked SD-installed WASM program")
  else:
    discard console.sendString("[FAIL] HTTP SD invoke status=")
    console.sendHex32(httpInvoke.statusCode.uint32)
    discard console.sendLine("")
    discard console.sendLine("=== Test Complete ===")
    while true:
      wfi()

  let httpDelete = handleWasmHttpRequest(
    wasmHttpDelete,
    "/wasm/repository/" & HttpWasmName,
    [],
  )
  if httpDelete.statusCode == 200'u16:
    discard console.sendLine("[PASS] HTTP deleted WASM program from SD repository")
  else:
    discard console.sendString("[FAIL] HTTP SD delete status=")
    console.sendHex32(httpDelete.statusCode.uint32)
    discard console.sendLine("")

  discard console.sendLine("=== Test Complete ===")

  while true:
    wfi()
