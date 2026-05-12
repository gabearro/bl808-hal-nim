## M0 all-core integration test.
##
## Tests all three BL808 cores working together:
##   1. Wait for LP alive (XRAM heartbeat)
##   2. Send RPC to D0: square(3) → expect 9
##   3. Send RPC to LP: add(7, 8) → expect 15
##   4. Verify LP heartbeat advancing
##
## Build:
##   nim c -d:bl808m0 -d:bl808kernel examples/m0_allcore_test.nim
##   nim c -d:bl808d0 -d:bl808kernel examples/d0_allcore_test.nim
##   nim c -d:bl808lp -d:bl808kernel examples/lp_allcore_test.nim
##
## Run:
##   qemu-system-riscv64 -M bl808,lp-firmware=examples/lp_allcore_test \
##     -kernel examples/m0_allcore_test \
##     -device loader,file=examples/d0_allcore_test \
##     -nographic -serial mon:stdio -serial file:/tmp/d0.txt \
##     -serial null -serial null

import bl808/startup
import bl808/core
import bl808/mmio, bl808/memmap
import bl808/ipc
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/cps
import bl808/kernel/ipcbridge

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

  RpcTagSquare = 1'u16   ## D0: square a number
  RpcTagAdd    = 2'u16   ## LP: add two uint16s
  LpRpcTimeoutMs = 5_000'u64

  LpStatusAddr    = 0x40002F00'u
  LpHeartbeatAddr = 0x40002F04'u
  LpStageAddr     = 0x40002F08'u
  LpHandlerCountAddr = 0x40002F0C'u
  LpTickLoAddr    = 0x40002F10'u
  LpTickHiAddr    = 0x40002F14'u
  LpMtimecmpLoAddr = 0x40002F18'u
  LpMtimecmpHiAddr = 0x40002F1C'u
  LpSchedTicksAddr = 0x40002F20'u
  LpTimersFiredAddr = 0x40002F24'u
  LpTimerHeapLenAddr = 0x40002F28'u
  LpClicTimerAddr = 0x40002F2C'u
  LpMstatusAddr   = 0x40002F30'u
  LpMieAddr       = 0x40002F34'u
  LpAliveMarker   = 0xA11CE902'u32
  LpBootReg       = PdsBase + 0x144'u
  LpClockReg      = PdsBase + 0x110'u
  LpRtcClockReg   = PdsBase + 0x130'u
  LpResetReg      = GlbBase + 0x548'u
  SfOffsetReg     = SfCtrlBase + 0x0A0'u
  LpXipEntry      = FlashXipBase + Ox64LPBootOffset
  JtagD0StatusAddr = XramBase + 0x3E00'u
  JtagD0RunMagic   = 0x4430_5255'u32 # "D0RU"
  JtagD0RunPollLimit = 8_000_000

var console: Uart
var passed = 0
var failed = 0

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

proc printHex(label: string, value: uint32) =
  discard console.sendString(label)
  console.sendHex32(value)
  discard console.sendLine("")

proc check(name: string, got: uint32, expected: uint32) =
  discard console.sendString("  ")
  discard console.sendString(name)
  discard console.sendString(": got ")
  printInt(got.int)
  if got == expected:
    discard console.sendLine(" [OK]")
    passed += 1
  else:
    discard console.sendString(", expected ")
    printInt(expected.int)
    discard console.sendLine(" [FAIL]")
    failed += 1

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

proc clearLpDiagnostics() =
  const diagAddrs = [
    LpStatusAddr,
    LpHeartbeatAddr,
    LpStageAddr,
    LpHandlerCountAddr,
    LpTickLoAddr,
    LpTickHiAddr,
    LpMtimecmpLoAddr,
    LpMtimecmpHiAddr,
    LpSchedTicksAddr,
    LpTimersFiredAddr,
    LpTimerHeapLenAddr,
    LpClicTimerAddr,
    LpMstatusAddr,
    LpMieAddr,
  ]
  for address in diagAddrs:
    regWrite(address, 0)
  dcacheFlushAll()
  fenceIo()

proc waitForJtagD0RunMagic() =
  for _ in 0 ..< JtagD0RunPollLimit:
    if sharedRead32(JtagD0StatusAddr) == JtagD0RunMagic:
      regWrite(JtagD0StatusAddr, 0)
      dcacheFlushAll()
      fenceIo()
      discard console.sendLine("[diag] D0 JTAG run magic observed")
      return
    spinDelay()
  discard console.sendLine("[FAIL] D0 JTAG load handshake timeout")

proc printLpSchedulerDiag() =
  printHex("  lp_tick_lo=", sharedRead32(LpTickLoAddr))
  printHex("  lp_tick_hi=", sharedRead32(LpTickHiAddr))
  printHex("  lp_cmp_lo=", sharedRead32(LpMtimecmpLoAddr))
  printHex("  lp_cmp_hi=", sharedRead32(LpMtimecmpHiAddr))
  printHex("  lp_sched_ticks=", sharedRead32(LpSchedTicksAddr))
  printHex("  lp_timers_fired=", sharedRead32(LpTimersFiredAddr))
  printHex("  lp_timer_heap=", sharedRead32(LpTimerHeapLenAddr))
  printHex("  lp_clic_timer=", sharedRead32(LpClicTimerAddr))
  printHex("  lp_mstatus=", sharedRead32(LpMstatusAddr))
  printHex("  lp_mie=", sharedRead32(LpMieAddr))

proc printLpRpcDiag() =
  printHex("  req0=", sharedRead32(XramM0toLPReq))
  printHex("  req4=", sharedRead32(XramM0toLPReq + 4))
  printHex("  req8=", sharedRead32(XramM0toLPReq + 8))
  printHex("  resp0=", sharedRead32(XramM0toLPResp))
  printHex("  resp4=", sharedRead32(XramM0toLPResp + 4))
  printHex("  status=", sharedRead32(LpStatusAddr))
  printHex("  heartbeat=", sharedRead32(LpHeartbeatAddr))
  printHex("  stage=", sharedRead32(LpStageAddr))
  printHex("  handlers=", sharedRead32(LpHandlerCountAddr))
  printHex("  ipc1_raw=", regRead(Ipc1Base + IpcCpu0Irsrr))
  printHex("  ipc1_masked=", regRead(Ipc1Base + IpcCpu0Isr))
  printLpSchedulerDiag()

# ---------------------------------------------------------------------------
# Test task
# ---------------------------------------------------------------------------

proc testAll(): CpsVoidFuture {.cps.} =
  # ---- Phase 1: Wait for LP ----
  discard console.sendLine("[1/4] Waiting for LP...")
  var lpAlive = false
  var attempts = 0
  while attempts < 40:
    await sleepMs(500)
    attempts += 1
    let status = sharedRead32(LpStatusAddr)
    if (attempts mod 10) == 0:
      printHex("  LP status=", status)
      printHex("  LP heartbeat=", sharedRead32(LpHeartbeatAddr))
    if status == LpAliveMarker:
      lpAlive = true
      break
  if lpAlive:
    discard console.sendLine("  LP alive [OK]")
    passed += 1
  else:
    discard console.sendLine("  LP not detected [FAIL]")
    failed += 1
    # Continue anyway to test D0

  # ---- Phase 2: RPC to D0 (square) ----
  discard console.sendLine("[2/4] RPC to D0: square(3)...")
  await sleepMs(2000)  # give D0 time to initialize
  let sq: uint32 = await ipcCallU32(RpcTagSquare, 3'u32)
  check("square(3)", sq, 9)

  # ---- Phase 3: RPC to LP (add) ----
  discard console.sendLine("[3/4] RPC to LP: add(7, 8)...")
  let hbBeforeRpc = sharedRead32(LpHeartbeatAddr)
  await sleepMs(1500)
  let hbAfterRpc = sharedRead32(LpHeartbeatAddr)
  printHex("  LP hb before=", hbBeforeRpc)
  printHex("  LP hb after=", hbAfterRpc)
  printHex("  LP stage=", sharedRead32(LpStageAddr))
  printHex("  LP handlers=", sharedRead32(LpHandlerCountAddr))
  printLpSchedulerDiag()

  # Pack two uint16s into one uint32: low=7, high=8
  let addArg = 7'u32 or (8'u32 shl 16)
  try:
    let sum: uint32 = await ipcCallU32LP(
      RpcTagAdd, addArg, timeoutMs = LpRpcTimeoutMs)
    check("add(7,8)", sum, 15)

    var req = [4'u8, 0, 5, 0]
    var resp: array[4, uint8]
    var respLen = 0
    discard await ipcCallLP(RpcTagAdd, req, addr resp[0], resp.len,
                            addr respLen, timeoutMs = LpRpcTimeoutMs)
    let rawSum = resp[0].uint32 or
                 (resp[1].uint32 shl 8) or
                 (resp[2].uint32 shl 16) or
                 (resp[3].uint32 shl 24)
    check("raw add(4,5)", rawSum, 9)
  except CatchableError:
    discard console.sendLine("  LP RPC failed [FAIL]")
    printLpRpcDiag()
    failed += 1

  # ---- Phase 4: Verify LP heartbeat advances ----
  discard console.sendLine("[4/4] Checking LP heartbeat...")
  let hb1 = sharedRead32(LpHeartbeatAddr)
  await sleepMs(3000)
  let hb2 = sharedRead32(LpHeartbeatAddr)
  if hb2 > hb1:
    discard console.sendString("  heartbeat ")
    printInt(hb1.int)
    discard console.sendString(" -> ")
    printInt(hb2.int)
    discard console.sendLine(" [OK]")
    passed += 1
  else:
    discard console.sendLine("  heartbeat not advancing [FAIL]")
    printLpSchedulerDiag()
    failed += 1

  # ---- Summary ----
  discard console.sendLine("")
  discard console.sendString("Result: ")
  printInt(passed)
  discard console.sendString(" passed, ")
  printInt(failed)
  discard console.sendLine(" failed")
  if failed == 0:
    discard console.sendLine("=== ALL TESTS PASSED ===")
  else:
    discard console.sendLine("=== SOME TESTS FAILED ===")

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
  discard console.sendLine("=== BL808 All-Core Integration Test (M0) ===")
  discard console.sendLine("")

  # Power on MM subsystem and release D0/LP cores
  mmPowerOn()
  clearLpDiagnostics()
  when defined(bl808jtagram):
    releaseLP()
    releaseD0(forceLoad = false)
    discard console.sendLine("[diag] Switching JTAG mux to D0")
    switchJtagMuxToD0()
    discard console.sendLine("[diag] JTAG mux switched to D0")
    waitForJtagD0RunMagic()
  else:
    releaseD0()
    releaseLP()
  discard console.sendLine("[diag] LP release registers")
  printHex("  boot=", regRead(LpBootReg))
  printHex("  clock=", regRead(LpClockReg))
  printHex("  rtc_clock=", regRead(LpRtcClockReg))
  printHex("  reset=", regRead(LpResetReg))
  printHex("  sf_offset=", regRead(SfOffsetReg))
  printHex("  xip0=", regRead(LpXipEntry))
  printHex("  status0=", sharedRead32(LpStatusAddr))
  printHex("  heartbeat0=", sharedRead32(LpHeartbeatAddr))
  printHex("  stage0=", sharedRead32(LpStageAddr))

  heapInit()
  schedulerInit()
  ipcBridgeInit()

  discard testAll()

  runScheduler()
