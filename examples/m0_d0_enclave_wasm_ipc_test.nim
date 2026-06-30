## M0 enclave server for D0 WASM service access over IPC.

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
  D0StatusAddr = XramBase + 0x3EC0'u
  D0Ok = 0x4549_5700'u32
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
  line("=== BL808 Enclave WASM IPC Test ===")

  ipcInit()
  regWrite(XramSyncD0, 0)
  regWrite(D0StatusAddr, 0)
  dcacheFlushAll()
  fenceIo()

  let initOk = enclaveInit(defaultPartition(lock = true), rkSoftDev)
  check("enclaveInit with LOCKED partition", initOk)
  if not initOk:
    line("=== Test Failed ===")
    while true: wfi()

  mmPowerOn()
  line("[M0] Releasing D0 enclave WASM IPC client")
  releaseD0()

  var d0Ready = false
  var sawSignal = false
  for _ in 0 ..< WaitLimit:
    let signals = ipcReadSignals(ipcD0)
    if signals != 0 and not sawSignal:
      printHex("[M0] ipc signals = ", signals)
      printHex("[M0] d0->m0 header0 = ", sharedRead32(XramBufD0toM0))
      printHex("[M0] d0->m0 header1 = ", sharedRead32(XramBufD0toM0 + 4'u))
      sawSignal = true
    enclaveIpcPoll()
    let status = sharedRead32(D0StatusAddr)
    if status == D0Ok:
      d0Ready = true
      break
    if status != 0:
      discard console.sendString("[DIAG] D0 enclave WASM IPC status=")
      console.sendHex32(status)
      discard console.sendLine("")
      check("D0 managed WASM through enclave IPC", false)
      line("=== Test Failed ===")
      while true: wfi()
    spinDelay()

  if d0Ready:
    check("D0 managed WASM through enclave IPC", true)
    line("=== Test Complete ===")
  else:
    printHex("[DIAG] D0 enclave WASM IPC timeout status=", sharedRead32(D0StatusAddr))
    printHex("[M0] final ipc signals = ", ipcReadSignals(ipcD0))
    printHex("[M0] final d0->m0 header0 = ", sharedRead32(XramBufD0toM0))
    printHex("[M0] final d0->m0 header1 = ", sharedRead32(XramBufD0toM0 + 4'u))
    printHex("[M0] final m0->d0 header0 = ", sharedRead32(XramBufM0toD0))
    printHex("[M0] final m0->d0 header1 = ", sharedRead32(XramBufM0toD0 + 4'u))
    check("D0 managed WASM through enclave IPC", false)
    line("=== Test Failed ===")
  while true:
    wfi()
