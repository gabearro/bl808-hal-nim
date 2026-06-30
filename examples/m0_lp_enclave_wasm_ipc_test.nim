## M0 enclave server for LP WASM service access over IPC.

import bl808/startup
import bl808/core, bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/ipc
import bl808/enclave/enclave, bl808/enclave/partition, bl808/enclave/vault
import bl808/kernel/alloc
import bl808/panicoverride

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  LpStatusAddr = XramBase + 0x3EC4'u
  LpStageAddr = XramBase + 0x3EC8'u
  LpOk = 0x4549_4C00'u32
  WaitLimit = 900_000

var console: Uart

proc line(s: string) =
  discard console.sendLine(s)

proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)

proc spinDelay() =
  for _ in 0 ..< 100:
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
  heapInit()
  enableAllPeriphClocks()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone),
    ConsoleClkHz)

  line("")
  line("=== BL808 Enclave WASM LP IPC Test ===")

  ipcInit()
  regWrite(XramSyncLP, 0)
  regWrite(LpStatusAddr, 0)
  regWrite(LpStageAddr, 0)
  regWrite(XramBufM0toLP, 0)
  regWrite(XramBufM0toLP + 4'u, 0)
  regWrite(XramBufLPtoM0, 0)
  regWrite(XramBufLPtoM0 + 4'u, 0)
  dcacheFlushAll()
  fenceIo()

  mmPowerOn()
  line("[M0] Releasing LP enclave WASM IPC client")
  releaseLP()

  let initOk = enclaveInit(defaultPartition(lock = true), rkSoftDev)
  check("enclaveInit with LOCKED partition", initOk)
  if not initOk:
    line("=== Test Failed ===")
    while true: wfi()

  regWrite(XramSyncLP, IpcSyncFlag)
  dcacheFlushAll()
  fenceIo()

  var lpReady = false
  var sawSignal = false
  for _ in 0 ..< WaitLimit:
    let signals = ipcReadSignals(ipcLP)
    if signals != 0 and not sawSignal:
      printHex("[M0] ipc signals = ", signals)
      printHex("[M0] lp->m0 header0 = ", sharedRead32(XramBufLPtoM0))
      printHex("[M0] lp->m0 header1 = ", sharedRead32(XramBufLPtoM0 + 4'u))
      sawSignal = true
    enclaveIpcPoll()
    let status = sharedRead32(LpStatusAddr)
    if status == LpOk:
      lpReady = true
      break
    if status != 0:
      discard console.sendString("[DIAG] LP enclave WASM IPC status=")
      console.sendHex32(status)
      discard console.sendLine("")
      printHex("[DIAG] LP enclave WASM IPC stage=", sharedRead32(LpStageAddr))
      printHex("[M0] status m0->lp header0 = ", sharedRead32(XramBufM0toLP))
      printHex("[M0] status m0->lp header1 = ", sharedRead32(XramBufM0toLP + 4'u))
      check("LP managed WASM through enclave IPC", false)
      line("=== Test Failed ===")
      while true: wfi()
    spinDelay()

  if lpReady:
    check("LP managed WASM through enclave IPC", true)
    line("=== Test Complete ===")
  else:
    printHex("[DIAG] LP enclave WASM IPC timeout status=", sharedRead32(LpStatusAddr))
    printHex("[DIAG] LP enclave WASM IPC stage=", sharedRead32(LpStageAddr))
    printHex("[M0] final ipc signals = ", ipcReadSignals(ipcLP))
    printHex("[M0] final lp->m0 header0 = ", sharedRead32(XramBufLPtoM0))
    printHex("[M0] final lp->m0 header1 = ", sharedRead32(XramBufLPtoM0 + 4'u))
    printHex("[M0] final m0->lp header0 = ", sharedRead32(XramBufM0toLP))
    printHex("[M0] final m0->lp header1 = ", sharedRead32(XramBufM0toLP + 4'u))
    check("LP managed WASM through enclave IPC", false)
    line("=== Test Failed ===")
  while true:
    wfi()
