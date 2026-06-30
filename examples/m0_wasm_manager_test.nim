## M0 managed WASM program lifecycle smoke test.

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/alloc
import bl808/wasm_control
import bl808/wasm_http
import bl808/wasm_manager
import bl808/wasm_scheduler_smoke
import bl808/wasm_store

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

  ManagerSlot = 4'u32

  AddModule = [
    byte 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7F, 0x7F, 0x01,
    0x7F, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01,
    0x03, 0x61, 0x64, 0x64, 0x00, 0x00, 0x0A, 0x09,
    0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6A,
    0x0B
  ]

proc pass(console: Uart, msg: string) =
  discard console.sendString("[PASS] ")
  discard console.sendLine(msg)

proc fail(console: Uart, msg: string, code: uint32 = 0) =
  discard console.sendString("[FAIL] ")
  discard console.sendString(msg)
  if code != 0:
    discard console.sendString(" code=")
    console.sendHex32(code)
  discard console.sendLine("")

proc appendAscii(dst: var seq[byte], s: string) =
  for ch in s:
    dst.add(byte(ch))

proc wasmInstallRequest(path: string, wasm: openArray[byte]): seq[byte] =
  result = @[]
  result.appendAscii("POST " & path & " HTTP/1.1\r\n")
  result.appendAscii("Host: bl808\r\n")
  result.appendAscii("Content-Length: " & $wasm.len & "\r\n")
  result.appendAscii("\r\n")
  for b in wasm:
    result.add(b)

proc emptyRequest(httpMethod, path: string): seq[byte] =
  result = @[]
  result.appendAscii(httpMethod & " " & path & " HTTP/1.1\r\n")
  result.appendAscii("Host: bl808\r\n")
  result.appendAscii("Content-Length: 0\r\n")
  result.appendAscii("\r\n")

proc textRequest(httpMethod, path, body: string): seq[byte] =
  result = @[]
  result.appendAscii(httpMethod & " " & path & " HTTP/1.1\r\n")
  result.appendAscii("Host: bl808\r\n")
  result.appendAscii("Content-Length: " & $body.len & "\r\n")
  result.appendAscii("\r\n")
  result.appendAscii(body)

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
  discard console.sendLine("=== BL808 WASM Program Manager Test ===")

  let caps = wasmRuntimeCapabilities()
  if caps.core != wasmCoreM0 or not caps.flashBacked or not caps.supportsI32:
    fail(console, "manager runtime capabilities", caps.core.ord.uint32)
    discard console.sendLine("=== Test Complete ===")
    while true: wfi()
  pass(console, "manager runtime capabilities exposed")

  let eraseResult = unloadWasmProgramSlot(ManagerSlot)
  if eraseResult.status != wasmManagerOk:
    fail(console, "manager slot pre-erase", eraseResult.storeError.ord.uint32)
    discard console.sendLine("=== Test Complete ===")
    while true: wfi()
  pass(console, "manager slot prepared")

  var installedSlot: uint32
  let installResult = installWasmProgramBytesAuto(
    AddModule,
    installedSlot,
    startIndex = ManagerSlot,
    generation = 2'u32,
  )
  if installResult.status != wasmControlOk:
    fail(console, "manager auto install", installResult.status.ord.uint32)
    discard console.sendLine("=== Test Complete ===")
    while true: wfi()
  if installedSlot != ManagerSlot:
    fail(console, "manager auto slot mismatch", installedSlot)
    discard console.sendLine("=== Test Complete ===")
    while true: wfi()
  pass(console, "manager auto-installed WASM slot")

  var slots: array[8, WasmControlSlot]
  let listed = listWasmPrograms(slots)
  if listed <= ManagerSlot:
    fail(console, "manager list too short", listed)
  elif slots[ManagerSlot.int].state != wasmSlotPresent:
    fail(console, "manager slot not present", slots[ManagerSlot.int].state.ord.uint32)
  elif slots[ManagerSlot.int].generation != 2'u32:
    fail(console, "manager generation mismatch", slots[ManagerSlot.int].generation)
  elif slots[ManagerSlot.int].checksum == 0:
    fail(console, "manager checksum missing")
  else:
    pass(console, "manager listed installed WASM slot")

  var handle: WasmProgramHandle
  let openResult = handle.openWasmProgramSlot(ManagerSlot)
  if openResult != wasmManagerOk:
    fail(console, "manager open slot", openResult.ord.uint32)
  else:
    pass(console, "manager opened WASM program")
    let runResult = handle.invokeI32("add", [11'i32, 31'i32])
    if runResult.status != wasmManagerOk:
      fail(console, "manager invoke", runResult.status.ord.uint32)
    elif runResult.value != 42'i32:
      fail(console, "manager result mismatch", cast[uint32](runResult.value))
    else:
      pass(console, "manager invoked WASM export")
    handle.close()
    if handle.loaded:
      fail(console, "manager close")
    else:
      pass(console, "manager closed WASM program")

  let controlRun = runWasmProgramI32(ManagerSlot, "add", [15'i32, 27'i32])
  if controlRun.status != wasmControlOk:
    fail(console, "manager control invoke", controlRun.status.ord.uint32)
  elif controlRun.value != 42'i32:
    fail(console, "manager control result mismatch", cast[uint32](controlRun.value))
  else:
    pass(console, "manager control invoked WASM export")

  let unloadResult = unloadWasmProgram(ManagerSlot)
  if unloadResult.status != wasmControlOk:
    fail(console, "manager unload slot", unloadResult.status.ord.uint32)
  elif queryWasmProgramSlot(ManagerSlot).state != wasmSlotEmpty:
    fail(console, "manager slot not empty after unload")
  else:
    pass(console, "manager unloaded WASM slot")

  let schedulerStatus = runWasmSchedulerSmoke(ManagerSlot)
  if schedulerStatus != WasmSchedulerSmokeOk:
    fail(console, "manager scheduler task lifecycle", schedulerStatus)
  else:
    pass(console, "manager scheduled WASM tasks cooperatively")

  let httpInstall = handleWasmHttpRequest(
    wasmHttpPost,
    "/wasm/programs/4",
    AddModule,
  )
  if httpInstall.statusCode != 201'u16 or httpInstall.control.status != wasmControlOk:
    fail(console, "http adapter install", httpInstall.statusCode.uint32)
  else:
    pass(console, "http adapter installed WASM slot")

  let httpStart = handleWasmHttpRequest(
    wasmHttpPost,
    "/wasm/programs/4/start/add",
    [byte('2'), byte('0'), byte(','), byte('2'), byte('2')],
  )
  if httpStart.statusCode != 201'u16:
    fail(console, "http adapter start task", httpStart.statusCode.uint32)
  else:
    pass(console, "http adapter started WASM task")

  let httpRunTasks = handleWasmHttpRequest(
    wasmHttpPost,
    "/wasm/tasks/run",
    [byte('f'), byte('u'), byte('e'), byte('l'), byte('='), byte('8')],
  )
  if httpRunTasks.statusCode != 200'u16:
    fail(console, "http adapter run scheduler", httpRunTasks.statusCode.uint32)
  else:
    pass(console, "http adapter ran WASM scheduler")

  let httpTasks = handleWasmHttpRequest(
    wasmHttpGet,
    "/wasm/tasks",
    [],
  )
  if httpTasks.statusCode != 200'u16 or httpTasks.body.len == 0 or httpTasks.body[0] != '{':
    fail(console, "http adapter list tasks", httpTasks.statusCode.uint32)
  else:
    pass(console, "http adapter listed WASM tasks")
  resetWasmScheduler()

  let httpInvoke = handleWasmHttpRequest(
    wasmHttpPost,
    "/wasm/programs/4/invoke/add",
    [byte('1'), byte('9'), byte(','), byte('2'), byte('3')],
  )
  if httpInvoke.statusCode != 200'u16 or httpInvoke.control.value != 42'i32:
    fail(console, "http adapter invoke", httpInvoke.statusCode.uint32)
  else:
    pass(console, "http adapter invoked WASM export")

  let httpDelete = handleWasmHttpRequest(
    wasmHttpDelete,
    "/wasm/programs/4",
    [],
  )
  if httpDelete.statusCode != 200'u16 or
      queryWasmProgramSlot(ManagerSlot).state != wasmSlotEmpty:
    fail(console, "http adapter delete", httpDelete.statusCode.uint32)
  else:
    pass(console, "http adapter unloaded WASM slot")

  var rawInstall = wasmInstallRequest("/wasm/programs/4", AddModule)
  let rawInstallResponse = handleWasmHttpBytes(rawInstall)
  if rawInstallResponse.statusCode != 201'u16 or
      rawInstallResponse.control.status != wasmControlOk:
    fail(console, "http parser install", rawInstallResponse.statusCode.uint32)
  else:
    pass(console, "http parser installed WASM slot")

  var rawInvoke = textRequest("POST", "/wasm/programs/4/invoke/add", "args=18,24")
  let rawInvokeResponse = handleWasmHttpBytes(rawInvoke)
  if rawInvokeResponse.statusCode != 200'u16 or rawInvokeResponse.control.value != 42'i32:
    fail(console, "http parser invoke", rawInvokeResponse.statusCode.uint32)
  else:
    pass(console, "http parser invoked WASM export")

  let formatted = formatWasmHttpResponse(rawInvokeResponse)
  if formatted.len == 0 or formatted[0] != 'H':
    fail(console, "http formatter")
  else:
    pass(console, "http formatter serialized response")

  var rawDelete = emptyRequest("DELETE", "/wasm/programs/4")
  let rawDeleteResponse = handleWasmHttpBytes(rawDelete)
  if rawDeleteResponse.statusCode != 200'u16 or
      queryWasmProgramSlot(ManagerSlot).state != wasmSlotEmpty:
    fail(console, "http parser delete", rawDeleteResponse.statusCode.uint32)
  else:
    pass(console, "http parser unloaded WASM slot")

  let httpCaps = handleWasmHttpRequest(
    wasmHttpGet,
    "/wasm/capabilities",
    [],
  )
  if httpCaps.statusCode != 200'u16 or httpCaps.body.len == 0 or httpCaps.body[0] != '{':
    fail(console, "http adapter capabilities", httpCaps.statusCode.uint32)
  else:
    pass(console, "http adapter exposed WASM capabilities")

  discard console.sendLine("=== Test Complete ===")

  while true:
    wfi()
