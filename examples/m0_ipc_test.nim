## M0 side of the Phase 6 IPC bridge test.
##
## M0 sends numbers to D0 for squaring, awaits the results.
## Also runs a local heartbeat task to demonstrate concurrent operation.
##
## Build: nim c -d:bl808m0 -d:bl808kernel examples/m0_ipc_test.nim
## Run with D0:
##   timeout 60s qemu-system-riscv64 -M bl808 -nographic \
##     -serial mon:stdio -serial file:/tmp/d0.txt \
##     -device loader,file=examples/d0_ipc_test,cpu-num=1 \
##     -kernel examples/m0_ipc_test

import bl808/startup
import bl808/core
import bl808/ipc, bl808/memmap, bl808/mmio
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/cps
import bl808/kernel/ipcbridge

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  RpcTagSquare = 1'u16  ## Tag for "square this number" RPC
  D0ReadyWaitMs = 20_000
  D0ReadyPollMs = 100
  RpcTimeoutMs = 5_000'u64
  D0IpcDebugAddr = XramBase + 0x00C'u
  JtagD0StatusAddr = XramBase + 0x3E00'u
  JtagD0RunMagic = 0x4430_5255'u32 # "D0RU"
  JtagD0RunPollLimit = 8_000_000
  FaultRecordAddr = XramBase + 0x2E00'u

  FaultMagicOff = 0'u
  FaultReasonOff = 12'u
  FaultCauseLoOff = 16'u
  FaultCauseHiOff = 20'u
  FaultEpcLoOff = 24'u
  FaultEpcHiOff = 28'u
  FaultTvalLoOff = 32'u
  FaultTvalHiOff = 36'u
  FaultSpLoOff = 40'u
  FaultSpHiOff = 44'u

var console: Uart

proc switchJtagMuxToD0() =
  const
    jtagD0Gpio = (27'u32 shl 8) or (1'u32 shl 22) or (1'u32 shl 1) or 1'u32
  regWrite(GpioConfigBase + 6'u * 4'u, jtagD0Gpio)
  regWrite(GpioConfigBase + 7'u * 4'u, jtagD0Gpio)
  regWrite(GpioConfigBase + 12'u * 4'u, jtagD0Gpio)
  regWrite(GpioConfigBase + 13'u * 4'u, jtagD0Gpio)
  fenceIo()

proc spinDelay() =
  for _ in 0 ..< 100:
    {.emit: """asm volatile("");""".}

proc sharedRead32(address: uint): uint32 =
  dcacheFlushAll()
  dcacheInvalidateAll()
  core.fence()
  regRead(address)

proc waitForJtagD0RunMagic() =
  for _ in 0 ..< JtagD0RunPollLimit:
    if sharedRead32(JtagD0StatusAddr) == JtagD0RunMagic:
      regWrite(JtagD0StatusAddr, 0)
      dcacheFlushAll()
      fenceIo()
      discard console.sendLine("[M0] D0 JTAG run magic observed")
      return
    spinDelay()
  discard console.sendLine("[FAIL] D0 JTAG load handshake timeout")

proc printInt(n: int) =
  if n == 0:
    discard console.sendByte(ord('0').uint8)
    return
  var buf: array[12, uint8]
  var i = 0
  var v = if n < 0: -n else: n
  if n < 0: discard console.sendByte(ord('-').uint8)
  while v > 0 and i < 12:
    buf[i] = (v mod 10).uint8 + ord('0').uint8
    v = v div 10
    inc i
  for j in countdown(i - 1, 0):
    discard console.sendByte(buf[j])

proc printHex32(v: uint32) =
  console.sendHex32(v)

proc printFaultField(label: string, loOff, hiOff: uint) =
  discard console.sendString(label)
  printHex32(regRead(FaultRecordAddr + hiOff))
  discard console.sendString("_")
  printHex32(regRead(FaultRecordAddr + loOff))

proc printFaultRecord() =
  discard console.sendString("[M0] fault magic=")
  printHex32(regRead(FaultRecordAddr + FaultMagicOff))
  discard console.sendString(" reason=")
  printHex32(regRead(FaultRecordAddr + FaultReasonOff))
  discard console.sendString(" ")
  printFaultField("cause=", FaultCauseLoOff, FaultCauseHiOff)
  discard console.sendString(" ")
  printFaultField("epc=", FaultEpcLoOff, FaultEpcHiOff)
  discard console.sendString(" ")
  printFaultField("tval=", FaultTvalLoOff, FaultTvalHiOff)
  discard console.sendString(" ")
  printFaultField("sp=", FaultSpLoOff, FaultSpHiOff)
  discard console.sendLine("")

# ---------------------------------------------------------------------------
# CPS task: send numbers to D0 for squaring
# ---------------------------------------------------------------------------

proc rpcTask(): CpsVoidFuture {.cps.} =
  # Wait for D0 to be ready
  discard console.sendLine("[M0] Waiting for D0...")
  var waited = 0
  while waited < D0ReadyWaitMs and not ipcIsReady(ipcD0):
    await sleepMs(D0ReadyPollMs)
    waited += D0ReadyPollMs

  if not ipcIsReady(ipcD0):
    discard console.sendString("[M0] D0 ready timeout [FAIL] debug=")
    printHex32(regRead(D0IpcDebugAddr))
    discard console.sendLine("")
    printFaultRecord()
    return

  discard console.sendString("[M0] D0 ready [OK] debug=")
  printHex32(regRead(D0IpcDebugAddr))
  discard console.sendLine("")

  var allPass = true
  var stopLoop = false
  var i = 1
  while i <= 5 and not stopLoop:
    discard console.sendString("[M0] Sending ")
    printInt(i)
    discard console.sendString(" to D0... ")

    var squared: uint32
    try:
      squared = await ipcCallU32(RpcTagSquare, i.uint32, timeoutMs = RpcTimeoutMs)
    except CatchableError:
      discard console.sendString("[FAIL] RPC failed debug=")
      printHex32(regRead(D0IpcDebugAddr))
      discard console.sendLine("")
      allPass = false
      stopLoop = true

    printInt(squared.int)
    let expected = (i * i).uint32
    if squared == expected:
      discard console.sendLine(" [OK]")
    else:
      discard console.sendString(" [FAIL] expected ")
      printInt(expected.int)
      discard console.sendLine("")
      allPass = false
    i += 1

  if allPass:
    var req = [6'u8, 0, 0, 0]
    var resp: array[4, uint8]
    var respLen = 0
    try:
      discard await ipcCall(RpcTagSquare, req, addr resp[0], resp.len,
                            addr respLen, timeoutMs = RpcTimeoutMs)
      let rawSquared = resp[0].uint32 or
                       (resp[1].uint32 shl 8) or
                       (resp[2].uint32 shl 16) or
                       (resp[3].uint32 shl 24)
      if respLen == 4 and rawSquared == 36'u32:
        discard console.sendLine("[M0] Raw IPC call correct [PASS]")
      else:
        discard console.sendLine("[M0] Raw IPC call wrong [FAIL]")
        allPass = false
    except CatchableError:
      discard console.sendString("[M0] Raw IPC call failed [FAIL] debug=")
      printHex32(regRead(D0IpcDebugAddr))
      discard console.sendLine("")
      allPass = false

  if allPass:
    discard console.sendLine("[M0] All IPC calls correct! [PASS]")
  else:
    discard console.sendLine("[M0] Some IPC calls failed [FAIL]")

# ---------------------------------------------------------------------------
# Heartbeat to show scheduler is alive
# ---------------------------------------------------------------------------

proc heartbeat(): CpsVoidFuture {.cps.} =
  var count = 0
  while count < 3:
    await sleepMs(1000)
    discard console.sendLine("[M0] heartbeat")
    count += 1

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

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
  discard console.sendLine("=== BL808 Phase 6: Cross-Core IPC Test (M0) ===")

  heapInit()
  schedulerInit()

  # Clear stale D0 readiness/debug from a previous reset before releasing D0.
  regWrite(XramSyncD0, 0)
  regWrite(D0IpcDebugAddr, 0)
  for off in countup(0'u, 60'u, 4'u):
    regWrite(FaultRecordAddr + off, 0)
  dcacheFlushAll()
  core.fence()

  # Real BL808 hardware keeps D0 held until M0 powers the MM domain and
  # releases the C906 clock/reset path.
  mmPowerOn()
  when defined(bl808jtagram):
    releaseD0(forceLoad = false)
    discard console.sendLine("[M0] Switching JTAG mux to D0")
    switchJtagMuxToD0()
    discard console.sendLine("[M0] JTAG mux switched to D0")
    waitForJtagD0RunMagic()
  else:
    releaseD0()

  ipcBridgeInit()

  discard console.sendLine("[M0] IPC bridge initialized")
  discard rpcTask()
  discard heartbeat()

  discard console.sendLine("[M0] Entering scheduler")
  discard console.sendLine("")

  runScheduler()
