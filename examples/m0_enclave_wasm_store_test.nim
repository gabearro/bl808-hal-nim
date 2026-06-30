## Enclave + flash-backed WebAssembly program store smoke test.
##
## Installs a tiny `.wasm` program into the managed flash store, executes it
## through the compact flash-backed VM inside an enclave-enabled image, then
## seals the execution status through the enclave service dispatcher.

import bl808/startup, bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/enclave/abi, bl808/enclave/enclave, bl808/enclave/partition
import bl808/enclave/services, bl808/enclave/vault
import bl808/kernel/alloc
import bl808/panicoverride
import bl808/wasm_control
import bl808/wasm_slot_smoke

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  EnclaveManagedSlot = 3'u32

var
  console: Uart
  passed = 0
  failed = 0
  scratch {.align: 16.}: array[128, uint8]

proc buf(): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](addr scratch[0])

proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)
  if ok: inc passed else: inc failed

proc putPayload(status: uint32): int =
  wrU32(buf(), 0, status)
  let msg = "wasm-slot-ok"
  for i in 0 ..< msg.len:
    buf()[4 + i] = msg[i].uint8
  4 + msg.len

proc putWasmInvokeReq(slot: uint32, a, b: int32): int =
  let name = "add"
  wrU32(buf(), 0, slot)
  wrU32(buf(), 4, name.len.uint32)
  wrU32(buf(), 8, 2)
  wrU32(buf(), 12, cast[uint32](a))
  wrU32(buf(), 16, cast[uint32](b))
  for i in 0 ..< name.len:
    buf()[20 + i] = name[i].uint8
  20 + name.len

proc putWasmInstallReq(slot: uint32): int =
  wrU32(buf(), 0, slot)
  wrU32(buf(), 4, 7'u32) # generation
  wrU32(buf(), 8, 0'u32) # flags
  wrU32(buf(), 12, WasmSlotAddModule.len.uint32)
  for i in 0 ..< WasmSlotAddModule.len:
    buf()[16 + i] = WasmSlotAddModule[i]
  16 + WasmSlotAddModule.len

proc testEnclaveWasmCapabilities() =
  let (st, respLen) =
    enclaveDispatch(callerUmodeAppCtx(), svcWasmCapabilities, 0, buf(), scratch.len)
  let ok =
    st == svcOk and respLen == 32 and
    rdU32(buf(), 0) == wasmCoreM0.ord.uint32 and
    rdU32(buf(), 4) == 1'u32 and
    rdU32(buf(), 8) == 1'u32 and
    rdU32(buf(), 12) == 1'u32 and
    rdU32(buf(), 16) == 1'u32 and
    rdU32(buf(), 20) == 1'u32 and
    rdU32(buf(), 24) == 0'u32 and
    rdU32(buf(), 28) == 0'u32
  check("report WASM runtime capabilities through enclave service", ok)

proc testEnclaveWasmInstallInvokeUnload() =
  let installLen = putWasmInstallReq(EnclaveManagedSlot)
  let (installStatus, installRespLen) =
    enclaveDispatch(callerUmodeAppCtx(), svcWasmInstallBytes,
                    installLen, buf(), scratch.len)
  let installOk =
    installStatus == svcOk and installRespLen == 16 and
    rdU32(buf(), 0) == wasmControlOk.ord.uint32 and
    cast[int32](rdU32(buf(), 12)) == EnclaveManagedSlot.int32
  check("install WASM bytes through enclave service", installOk)

  let reqLen = putWasmInvokeReq(EnclaveManagedSlot, 21'i32, 21'i32)
  let (invokeStatus, invokeRespLen) =
    enclaveDispatch(callerUmodeAppCtx(), svcWasmInvokeI32,
                    reqLen, buf(), scratch.len)
  let invokeOk =
    invokeStatus == svcOk and invokeRespLen == 16 and
    rdU32(buf(), 0) == wasmControlOk.ord.uint32 and
    cast[int32](rdU32(buf(), 12)) == 42'i32
  check("invoke enclave-installed WASM slot", invokeOk)

  wrU32(buf(), 0, EnclaveManagedSlot)
  let (unloadStatus, unloadRespLen) =
    enclaveDispatch(callerUmodeAppCtx(), svcWasmUnloadSlot, 4, buf(), scratch.len)
  let unloadOk =
    unloadStatus == svcOk and unloadRespLen == 16 and
    rdU32(buf(), 0) == wasmControlOk.ord.uint32 and
    cast[int32](rdU32(buf(), 12)) == EnclaveManagedSlot.int32
  check("unload WASM slot through enclave service", unloadOk)

proc testEnclaveWasmInvoke(): uint32 =
  let reqLen = putWasmInvokeReq(WasmSlotSmokeSlot, 18'i32, 24'i32)
  let (st, respLen) =
    enclaveDispatch(callerUmodeAppCtx(), svcWasmInvokeI32, reqLen, buf(), scratch.len)
  let ok =
    st == svcOk and respLen == 16 and
    rdU32(buf(), 0) == 0'u32 and
    rdU32(buf(), 4) == 0'u32 and
    rdU32(buf(), 8) == 0'u32 and
    cast[int32](rdU32(buf(), 12)) == 42'i32
  check("invoke flash-backed WASM slot through enclave service", ok)
  if ok: WasmSlotSmokeOk else: WasmSlotInvokeFailed

proc testEnclaveWasmTaskLifecycle() =
  let reqLen = putWasmInvokeReq(WasmSlotSmokeSlot, 20'i32, 22'i32)
  let (startStatus, startRespLen) =
    enclaveDispatch(callerUmodeAppCtx(), svcWasmTaskStartI32, reqLen, buf(), scratch.len)
  let taskId = rdU32(buf(), 8)
  let startOk =
    startStatus == svcOk and startRespLen == 44 and
    rdU32(buf(), 0) == wasmControlOk.ord.uint32 and taskId != 0
  check("start WASM task through enclave service", startOk)
  if not startOk:
    return

  wrU32(buf(), 0, taskId)
  wrU32(buf(), 4, 8'u32)
  let (resumeStatus, resumeRespLen) =
    enclaveDispatch(callerUmodeAppCtx(), svcWasmTaskResume, 8, buf(), scratch.len)
  let resumeOk =
    resumeStatus == svcOk and resumeRespLen == 44 and
    rdU32(buf(), 0) == wasmControlOk.ord.uint32 and
    rdU32(buf(), 16) == wasmTaskExited.ord.uint32 and
    cast[int32](rdU32(buf(), 20)) == 42'i32 and
    rdU32(buf(), 36) != 0'u32 and
    rdU32(buf(), 40) != 0'u32
  check("resume WASM task through enclave service", resumeOk)

  wrU32(buf(), 0, taskId)
  let (statusStatus, statusRespLen) =
    enclaveDispatch(callerUmodeAppCtx(), svcWasmTaskStatus, 4, buf(), scratch.len)
  let statusOk =
    statusStatus == svcOk and statusRespLen == 44 and
    rdU32(buf(), 0) == wasmControlOk.ord.uint32 and
    rdU32(buf(), 16) == wasmTaskExited.ord.uint32
  check("report WASM task status through enclave service", statusOk)

  wrU32(buf(), 0, taskId)
  let (killStatus, killRespLen) =
    enclaveDispatch(callerUmodeAppCtx(), svcWasmTaskKill, 4, buf(), scratch.len)
  let killOk =
    killStatus == svcOk and killRespLen == 44 and
    rdU32(buf(), 0) == wasmControlOk.ord.uint32
  check("reap WASM task through enclave service", killOk)

proc testEnclaveWasmInvokeBadRequest() =
  let name = "add"
  wrU32(buf(), 0, WasmSlotSmokeSlot)
  wrU32(buf(), 4, name.len.uint32)
  wrU32(buf(), 8, 9) # one more than the service's fixed arg budget
  let (st, respLen) =
    enclaveDispatch(callerUmodeAppCtx(), svcWasmInvokeI32, 12, buf(), scratch.len)
  check("reject malformed WASM enclave invoke request",
    st == svcBadRequest and respLen == 0)

proc testEnclaveWasmInvokeBadSlot() =
  let reqLen = putWasmInvokeReq(0xFFFF_FFFF'u32, 18'i32, 24'i32)
  let (st, respLen) =
    enclaveDispatch(callerUmodeAppCtx(), svcWasmInvokeI32, reqLen, buf(), scratch.len)
  let ok =
    st == svcOk and respLen == 16 and
    rdU32(buf(), 0) == wasmControlBadSlot.ord.uint32 and
    cast[int32](rdU32(buf(), 12)) == 0'i32
  check("report bad WASM slot through enclave service", ok)

proc testSealSlotResult(status: uint32) =
  let payloadLen = putPayload(status)
  let (sealStatus, sealedLen) =
    enclaveDispatch(callerUmodeAppCtx(), svcSealBlob, payloadLen, buf(), scratch.len)
  check("seal flash-backed WASM result status",
    sealStatus == svcOk and sealedLen == 16 + payloadLen + 32)

  var sealed: array[96, uint8]
  for i in 0 ..< sealedLen:
    sealed[i] = buf()[i]

  for i in 0 ..< sealedLen:
    buf()[i] = sealed[i]
  let (openStatus, plainLen) =
    enclaveDispatch(callerUmodeAppCtx(), svcUnsealBlob, sealedLen, buf(), scratch.len)

  var ok = openStatus == svcOk and plainLen == payloadLen and rdU32(buf(), 0) == status
  let msg = "wasm-slot-ok"
  for i in 0 ..< msg.len:
    if buf()[4 + i] != msg[i].uint8:
      ok = false
  check("unseal flash-backed WASM result round-trip", ok)

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  enableAllPeriphClocks()
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
  discard console.sendLine("=== BL808 Enclave WASM Store Test ===")

  let initOk = enclaveInit(defaultPartition(lock = false), rkSoftDev)
  check("enclaveInit", initOk)

  let installStatus = installWasmSlotSmoke()
  check("install flash-backed WASM slot", installStatus == WasmSlotSmokeOk)

  if installStatus == WasmSlotSmokeOk:
    let runStatus = runWasmSlotSmoke()
    check("invoke flash-backed WASM slot in enclave image", runStatus == WasmSlotSmokeOk)
    testEnclaveWasmCapabilities()
    testEnclaveWasmInstallInvokeUnload()
    let svcRunStatus = testEnclaveWasmInvoke()
    testEnclaveWasmTaskLifecycle()
    testEnclaveWasmInvokeBadRequest()
    testEnclaveWasmInvokeBadSlot()
    if runStatus == WasmSlotSmokeOk and svcRunStatus == WasmSlotSmokeOk:
      testSealSlotResult(svcRunStatus)

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0:
    discard console.sendLine("=== Test Complete ===")
  else:
    discard console.sendLine("=== Test Failed ===")

  while true:
    wfi()
