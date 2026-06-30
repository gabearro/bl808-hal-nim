## Enclave + WebAssembly VM smoke test.
##
## Runs the compact WASM VM inside an enclave-enabled M0 image, then binds the
## WASM result through enclave seal/unseal services. This is the first bridge
## between "programs are WASM" and the enclave service boundary.

import bl808/startup, bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/enclave/abi, bl808/enclave/enclave, bl808/enclave/partition
import bl808/enclave/services, bl808/enclave/vault
import bl808/kernel/alloc
import bl808/panicoverride
import bl808/wasm_smoke
when defined(bl808WasmCompact):
  import bl808/wasm_task_smoke

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

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
  let msg = "wasm-ok"
  for i in 0 ..< msg.len:
    buf()[4 + i] = msg[i].uint8
  4 + msg.len

proc testSealWasmResult(status: uint32) =
  let payloadLen = putPayload(status)
  let (sealStatus, sealedLen) =
    enclaveDispatch(callerUmodeAppCtx(), svcSealBlob, payloadLen, buf(), scratch.len)
  check("seal WASM result status", sealStatus == svcOk and sealedLen == 16 + payloadLen + 32)

  var sealed: array[80, uint8]
  for i in 0 ..< sealedLen:
    sealed[i] = buf()[i]

  for i in 0 ..< sealedLen:
    buf()[i] = sealed[i]
  let (openStatus, plainLen) =
    enclaveDispatch(callerUmodeAppCtx(), svcUnsealBlob, sealedLen, buf(), scratch.len)

  var ok = openStatus == svcOk and plainLen == payloadLen and rdU32(buf(), 0) == status
  let msg = "wasm-ok"
  for i in 0 ..< msg.len:
    if buf()[4 + i] != msg[i].uint8:
      ok = false
  check("unseal WASM result round-trip", ok)

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
  discard console.sendLine("=== BL808 Enclave WASM Smoke Test ===")

  let initOk = enclaveInit(defaultPartition(lock = false), rkSoftDev)
  check("enclaveInit", initOk)

  let wasmStatus = runWasmSmoke()
  when defined(bl808WasmCompact):
    check("compact WASM i32/f32/memory smoke passed", wasmStatus == WasmSmokeOk)
  else:
    check("full WASM i32/f32/memory smoke passed", wasmStatus == WasmSmokeOk)
  if wasmStatus == WasmSmokeOk:
    testSealWasmResult(wasmStatus)

  when defined(bl808WasmCompact):
    let taskStatus = runWasmTaskSmoke()
    check("enclave WASM task context switching smoke passed", taskStatus == WasmTaskSmokeOk)

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
