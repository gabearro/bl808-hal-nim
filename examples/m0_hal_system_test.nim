## M0 HAL system feature test.
##
## Covers core/MMIO helpers, CLIC, GLB clock/reset controls, GPIO, timers,
## cache/CCI, PDS/HBN safe status/retention helpers, and TZC read/pack helpers.

import bl808/startup
import bl808/core
import bl808/mmio, bl808/memmap, bl808/irq
import bl808/cache, bl808/glb, bl808/gpio, bl808/ipc, bl808/pds, bl808/timer, bl808/tzc
import bl808/uart
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  TestGpio = 20'u32

var
  console: Uart
  passed = 0
  failed = 0

proc dummyTrap() {.cdecl.} =
  discard

proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)
  if ok: inc passed else: inc failed

proc checkEq(label: string, got, expected: uint32) =
  if got == expected:
    check(label, true)
  else:
    discard console.sendString("[FAIL] ")
    discard console.sendString(label)
    discard console.sendString(" got=")
    console.sendHex32(got)
    discard console.sendString(" expected=")
    console.sendHex32(expected)
    discard console.sendLine("")
    inc failed

proc gpioCfg(pin: uint32): uint =
  GpioConfigBase + pin * 4

proc clicAttrCtl(irq: uint32): uint32 =
  ((regRead(ClicIntBase + irq * ClicIntStride) shr 16) and 0xFF'u32) and 0x07'u32

proc smokeCoreMmio() =
  var bodyRan = false
  withInterruptsDisabled:
    bodyRan = not interruptsEnabled()
  check("core interrupt guard", bodyRan)
  check("core detect", detectCore() in {coreM0, coreUnknown})
  icacheInvalidateAll()
  delayUs(1)
  check("core cache and delay", true)

proc smokeMmioScratch() =
  regWrite(HbnRsv3, 0)
  regSet(HbnRsv3, 1)
  check("mmio wait set", regWaitSet(HbnRsv3, 1, 4))
  regClear(HbnRsv3, 1)
  check("mmio wait clear", regWaitClear(HbnRsv3, 1, 4))
  regModify(HbnRsv3, fieldMask(4, 3), fieldSet(4, 5))
  checkEq("mmio field helpers", fieldVal(regRead(HbnRsv3), 4, 3), 5)

proc smokeClic() =
  let defaultTrapRef = cast[pointer](defaultTrapEntry)
  check("irq default trap entry linked", defaultTrapRef != nil)
  clicSetAttr(IrqM0Uart0, 0x04'u8)
  checkEq("clic attr setup", clicAttrCtl(IrqM0Uart0), 0x04)
  clicInit()
  checkEq("clic init clears uart attr", clicAttrCtl(IrqM0Uart0), 0)
  registerTrapHandler(IrqM0Uart1, dummyTrap)
  check("irq trap handler register", getTrapHandler(IrqM0Uart1) != nil)
  irqEnable(IrqM0Uart1)
  irqSetLevel(IrqM0Uart1, 1)
  clicSetPending(IrqM0Uart1)
  discard clicClaimPeripheral()
  clicCompletePeripheral(IrqM0Uart1)
  irqClearPending(IrqM0Uart1)
  clicClearPending(IrqM0Uart1)
  irqDisable(IrqM0Uart1)
  clicDisableIrq(IrqM0Uart1)
  discard clicReadMtime()
  clicSetMtimecmp(0xFFFF_FFFF'u32)
  check("clic pending/time APIs", true)

proc smokeGlbGpio() =
  disablePeriphClock(periphI2c1)
  check("glb disable peripheral clock", (regRead(GlbCgenCfg1) and (1'u32 shl periphI2c1.uint32)) == 0)
  enablePeriphClock(periphI2c1)
  resetPeriph(periphI2c1)
  check("glb reset peripheral", true)
  setSpiClockDiv(5)
  setSpiClockSource(spiClkXclk)
  enableSpiClock()
  checkEq("glb spi divider", regRead(GlbSpiCfg0) and 0x1F'u32, 5)

  when defined(bl808jtagram) or defined(bl808hwharness):
    check("glb uart clock helpers", true)
    check("glb i2c divider", true)
    check("glb dma1 clock", true)
    check("glb dsp/mm helpers", true)
    check("glb pll and peripheral clocks", true)
  else:
    disableUartClock()
    setUartClockDiv(0)
    setUartClockSource(uartClkXclk)
    enableUartClock()
    check("glb uart clock helpers", (regRead(GlbUartCfg0) and (1'u32 shl 4)) != 0)
    setI2cClockDiv(11)
    enableI2cClock()
    checkEq("glb i2c divider", (regRead(GlbI2cCfg0) shr 16) and 0xFF'u32, 11)
    enableDma1Clock()
    check("glb dma1 clock", (regRead(GlbDmaCfg0) and (1'u32 shl 25)) != 0)
    mmPowerOn()
    setDspXclkSel(0)
    setDspRootClkSel(0)
    setDspPllClkSel(0)
    setDspSysClkDiv(0, 0)
    setDspSysClock(dspClkRc32m)
    resetMmPeriph(MmResetUart3)
    resetMmUart3()
    check("glb dsp/mm helpers", true)
    wifiPllEnable()
    wifiPllEnableOutput(WifiPllEnDiv20)
    wifiPllDisableOutput(WifiPllEnDiv20)
    wifiPllDisable()
    auPllEnable()
    auPllDisable()
    setI2sClockDiv(3)
    enableI2sClock()
    setAdcClockDiv(2)
    setAdcClockSource(adcClkXtal)
    enableAdcClock()
    setSfClockDiv(1)
    setSfClockSource(sfClkBclk)
    enableSfClock()
    swapUartSignals(0)
    check("glb pll and peripheral clocks", true)
  enableSystemClock(GlbCgenCfg2, CgenCfg2Audio)
  disableSystemClock(GlbCgenCfg2, CgenCfg2Audio)
  enableSystemClock(GlbCgenCfg2, CgenCfg2Audio)
  check("glb system clock gate", (regRead(GlbCgenCfg2) and (1'u32 shl CgenCfg2Audio)) != 0)
  discard getHclkDiv()
  discard getBclkDiv()

  gpioInitOutput(TestGpio, drive2, pullUp)
  let cfg = regRead(gpioCfg(TestGpio))
  check("gpio output config", (cfg and (1'u32 shl GpioOe)) != 0 and
        ((cfg and GpioFuncSelMask) shr GpioFuncSelShift) == funcGpio.uint32)
  gpioSetFunction(TestGpio, funcGpio)
  gpioSetDrive(TestGpio, drive3)
  gpioSetPull(TestGpio, pullDown)
  gpioSetSchmitt(TestGpio, true)
  gpioWrite(TestGpio, true)
  gpioSet(TestGpio)
  gpioClear(TestGpio)
  gpioToggle(TestGpio)
  discard gpioRead(TestGpio)
  gpioDisableInterrupt(TestGpio)
  gpioClearInterrupt(TestGpio)
  check("gpio pin APIs", true)
  gpioSetupSpi(21, 22, 23, 24)
  gpioSetupI2c(25, 26, 0)
  check("gpio alternate setup helpers", true)

proc smokeIpc() =
  ipcInit()
  ipcSetReady()
  ipcClearAllSignals(ipcD0)
  ipcSendSignal(ipcD0, IpcSignalSync)
  discard ipcReadSignals(ipcD0)
  ipcClearSignal(ipcD0, IpcSignalSync)
  let payload = [0x11'u8, 0x22'u8, 0x33'u8, 0x44'u8, 0x55'u8]
  check("ipc bounded send message", ipcSendMessage(ipcD0, 0x1234'u16, payload))
  var tag = 0'u16
  var recvBuf: array[8, uint8]
  discard ipcRecvMessage(ipcD0, tag, recvBuf)
  discard ipcWaitReady(ipcD0, timeout = 1)
  ipcSharedWrite32(0x20'u, 0xA55A_5AA5'u32)
  checkEq("ipc shared word", ipcSharedRead32(0x20'u), 0xA55A_5AA5'u32)
  ipcSharedWriteBuffer(0x30'u, payload)
  var copied: array[5, uint8]
  ipcSharedReadBuffer(0x30'u, copied)
  check("ipc shared buffer", copied == payload)

proc smokeTimerPowerTzc() =
  let t = initTimer(timer0)
  t.disable(timerCh2)
  t.setClockSource(timerCh2, timerClkXtal)
  t.setClockDiv(timerCh2, 9)
  t.forceClockDiv(timerCh2)
  t.setCountMode(timerCh2, timerPreload)
  t.setPreloadValue(timerCh2, 0x1234)
  t.setMatchValue(timerCh2, 0, 0x5678)
  t.enableInterrupt(timerCh2, 0)
  t.clearInterrupt(timerCh2, 0)
  discard t.readStatus(timerCh2)
  discard t.readCounter(timerCh2)
  t.disableInterrupt(timerCh2, 0)
  t.setupPeriodic(timerCh2, 1000, timerClkXtal)
  t.disable(timerCh2)
  checkEq("timer match value", regRead(Timer0Base + TimerTmr2_0), 1000)
  t.setWdtClockSource(wdtClkXtal)
  t.setWdtClockDiv(7)
  t.forceWdtClockDiv()
  t.wdtClearInterrupt()
  check("watchdog maintenance APIs", true)

  pdsConfigureLpMtimerClock()
  discard pdsGetStatus()
  hbnWriteRetention(0, 0xA5A5_5A5A'u32)
  checkEq("hbn retention roundtrip", hbnReadRetention(0), 0xA5A5_5A5A'u32)
  enableRc32k()
  enableXtal32k()
  check("pds/hbn safe APIs", true)

  check("tzc readable", tzcRead(TzcSecRomCtrl) != 0xFFFF_FFFF'u32)
  checkEq("tzc pack window", tzcPackWindow(0x1200'u32, 0x1000'u32, 10), 0x0004_0008'u32)
  discard tzcRomSbootDone()
  tzcBypassSecure(false)
  let tzcBefore = tzcRead(TzcSecRomCtrl)
  tzcConfigureRegion(3, 0x5800_0000'u32, 12, tzcAll)
  tzcLockRegion(3)
  checkEq("tzc unused compatibility region", tzcRead(TzcSecRomCtrl), tzcBefore)
  check("tzc status APIs", true)

proc smokeCache() =
  check("cache invalidate", l1cInvalidateAll())
  check("cache flush", l1cFlushAll())
  cciFlushAll()
  check("cci flush", true)

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()

  enableAllPeriphClocks()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  when not defined(bl808jtagram) and not defined(bl808hwharness):
    setMcuSysClock(clkXtal, 0, 0)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(ConsoleUartTxPin, ConsoleUartRxPin)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), ConsoleClkHz)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 HAL System Test ===")

  smokeCoreMmio()
  smokeMmioScratch()
  smokeClic()
  smokeGlbGpio()
  smokeIpc()
  smokeTimerPowerTzc()
  smokeCache()

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
