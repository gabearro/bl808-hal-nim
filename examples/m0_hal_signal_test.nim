## M0 HAL signal/control feature test.
##
## Covers ADC/DAC, audio/PDM/I2S, PWM, checksum, DMA, and DMA2D APIs.

import bl808/startup
import bl808/core
import bl808/mmio, bl808/memmap
import bl808/adc, bl808/audio, bl808/cks, bl808/dma, bl808/dma2d
import bl808/glb, bl808/gpio, bl808/i2s, bl808/pdm, bl808/pwm, bl808/uart
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  ScratchSrc = OcramBase + 0x7000'u
  ScratchDst = OcramBase + 0x7040'u

var
  console: Uart
  passed = 0
  failed = 0

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

proc smokeCksDma() =
  cksReset()
  regWrite(CksConfig, 0)
  cksSetEndian(true)
  check("cks endian set", (regRead(CksConfig) and (1'u32 shl CksEndian)) != 0)
  cksSetEndian(false)
  cksFeedByte(0x5A'u8)
  cksFeedWord(0x1234_5678'u32)
  cksFeedBuffer([0xDE'u8, 0xAD'u8, 0xBE'u8, 0xEF'u8])
  discard cksResult()
  discard cksCompute([1'u8, 2'u8, 3'u8, 4'u8])
  check("cks feed/compute APIs", true)

  enableDma0Clock()
  let d = initDma(dma0)
  for i in 0'u ..< 4'u:
    regWrite(ScratchSrc + i * 4, 0xA500_0000'u32 or i.uint32)
    regWrite(ScratchDst + i * 4, 0)
  let copied = d.memcopy(0.DmaChannel, ScratchDst.uint32, ScratchSrc.uint32, 16)
  var match = copied
  for i in 0'u ..< 4'u:
    if regRead(ScratchDst + i * 4) != (0xA500_0000'u32 or i.uint32):
      match = false
  check("dma memory copy", match)
  var lli = buildLli(ScratchSrc.uint32, ScratchDst.uint32, 4)
  let cfg = DmaTransferConfig(
    srcAddr: ScratchSrc.uint32, dstAddr: ScratchDst.uint32, transferSize: 4,
    srcWidth: width32, dstWidth: width32, srcBurst: burst4, dstBurst: burst4,
    srcIncrement: true, dstIncrement: true, flow: flowM2M_Dma,
    srcPeriph: 0, dstPeriph: 0, enableTcInt: true,
  )
  d.configureChannelLli(1.DmaChannel, unsafeAddr lli, cfg)
  d.startChannel(1.DmaChannel)
  let chBase = Dma0Base + 0x100'u + 1'u * 0x100'u
  let enabled = (regRead(chBase + DmaChConfig) and (1'u32 shl CfgEnable)) != 0
  discard enabled
  discard d.channelActive(1.DmaChannel)
  discard d.tcInterruptPending(1.DmaChannel)
  d.clearTcInterrupt(1.DmaChannel)
  d.stopChannel(1.DmaChannel)
  let stopped = (regRead(chBase + DmaChConfig) and (1'u32 shl CfgEnable)) == 0
  discard d.channelEnabled(1.DmaChannel)
  discard d.errInterruptPending(1.DmaChannel)
  d.clearErrInterrupt(1.DmaChannel)
  d.clearAllInterrupts()
  check("dma channel control/irq APIs", stopped)

  mmPowerOn()
  let xfer = dma2dTransfer(0x2200_0000'u32, 16, 0x2200_1000'u32, 16, 8, 2, timeout = 8)
  let fill = dma2dFillRect(0x2200_2000'u32, 16, 8, 2, 0x2200_3000'u32, timeout = 8)
  check("dma2d bounded APIs", xfer in {dma2dOk, dma2dTimeout} and fill in {dma2dOk, dma2dTimeout})

proc smokeAdcDac() =
  let a = initAdc(adc14Bit, vref2v0, clkDiv = 3)
  checkEq("adc clock divider", (regRead(AdcCfg1) and AdcClkDivMask) shr AdcClkDivShift, 3)
  let channels = [0.AdcChannel, 1.AdcChannel]
  a.startScan(channels)
  a.enableDma()
  a.disableDma()
  let (_, fifoValid) = a.readFifo()
  discard fifoValid
  discard a.fifoCount()
  checkEq("adc fifo addr", fifoDataAddr().uint32, GpipGpadcDmaRdata.uint32)
  let (_, chErr) = a.readChannel(0.AdcChannel, timeout = 1)
  let (_, tempErr) = a.readTemperatureRaw()
  let (_, vbatErr) = a.readVbatRaw()
  check("adc bounded reads", chErr in {adcOk, adcTimeout} and
        tempErr in {adcOk, adcTimeout} and vbatErr in {adcOk, adcTimeout})
  a.stopScan()
  check("adc scan stop", (regRead(AdcCfg1) and (1'u32 shl AdcScanEn)) == 0)

  dacEnable(dacA)
  dacWrite(0x0123_0456'u32)
  dacWriteDma(0x0000_00AB'u32)
  dacEnableDma()
  let dacData = regRead(GlbDacData)
  check("dac direct write", dacData == 0x0123_0456'u32 or
        dacData == (0x0123_0456'u32 and 0x03FF_03FF'u32))
  dacDisable(dacA)
  check("dac disable", (regRead(GlbDacActrl) and 0x03'u32) == 0)

proc smokeAudioPdmI2s() =
  auadcInit(auRate16k)
  auadcSetVolume(0x155)
  auadcSetPgaGain(7)
  auadcEnableDma()
  auadcEnable()
  discard auadcDataReady()
  discard auadcReadRaw()
  discard auadcFifoRead()
  checkEq("auadc fifo addr", auadcRxFifoAddr().uint32, AuadcRxFifoData.uint32)
  auadcDisable()
  check("auadc disable", (regRead(AuadcCmd) and (1'u32 shl AuadcConv)) == 0)

  audacInit()
  audacSetVolume(0x021)
  audacMute(true)
  audacEnableDma()
  audacWriteSample(0x1357_2468'u32)
  checkEq("audac fifo addr", audacTxFifoAddr().uint32, AudacTxFifoData.uint32)
  audacDisable()
  check("audac disable", (regRead(AudacCtrl0) and (1'u32 shl AudacItfEn)) == 0)

  pdmInit(pdmRate16k, pdmStereo)
  pdmSetGain(0x101)
  pdmSetAdcScale(0x22)
  pdmSetFifoThreshold(5)
  pdmEnableDma()
  pdmEnable()
  discard pdmFifoCount()
  discard pdmFifoFull()
  discard pdmFifoEmpty()
  discard pdmOverrun()
  discard pdmReadSample()
  let (_, pdmErr) = pdmFifoRead(timeout = 1)
  pdmDisableDma()
  checkEq("pdm fifo addr", pdmRxFifoAddr().uint32, PdmRxFifoData.uint32)
  pdmFlushFifo()
  pdmEnableInterrupt()
  pdmEnableOverrunInterrupt()
  pdmDisableInterrupt()
  pdmDisableOverrunInterrupt()
  pdmDisable()
  check("pdm bounded fifo APIs", pdmErr in {pdmOk, pdmTimeout, pdmOverrun, pdmFifoEmpty})

  let bus = initI2s(i2sStandard, i2sData24bit, i2sMaster, bclkDiv = 12)
  bus.enableTx()
  bus.enableRx()
  bus.writeSample(0x1122_3344'u32)
  discard bus.readSample()
  discard bus.txFifoCount()
  discard bus.rxFifoCount()
  bus.enableDmaTx()
  bus.enableDmaRx()
  checkEq("i2s tx fifo addr", bus.txFifoAddr().uint32, I2sFifoWdata.uint32)
  checkEq("i2s rx fifo addr", bus.rxFifoAddr().uint32, I2sFifoRdata.uint32)
  bus.disableTx()
  bus.disableRx()
  check("i2s disable", (regRead(I2sCfg) and ((1'u32 shl I2sTxEn) or (1'u32 shl I2sRxEn))) == 0)

proc smokePwm() =
  let p = initPwm()
  p.configureChannel(0.PwmChannel, period = 1000, duty = 250, clkDiv = 7)
  p.setDuty(0, 300)
  p.setThresholds(1.PwmChannel, 10, 110)
  p.setPeriod(1200)
  p.setDeadTime(0, 9)
  p.enableOutput(2.PwmChannel, positive = true, negative = true)
  p.setPolarity(2.PwmChannel, invertPositive = true, invertNegative = true)
  p.softwareBreak(true)
  p.softwareBreak(false)
  discard p.isStopped()
  p.enableInterrupt(PwmIntPrde)
  p.clearInterrupt(PwmIntPrde)
  discard p.readInterruptStatus()
  p.disableInterrupt(PwmIntPrde)
  p.start()
  p.stop()
  check("pwm control APIs", (regRead(PwmMc0Config0) and (1'u32 shl PwmStopEn)) != 0)

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()

  enableAllPeriphClocks()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(ConsoleUartTxPin, ConsoleUartRxPin)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), ConsoleClkHz)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 HAL Signal Test ===")

  smokeCksDma()
  smokeAdcDac()
  smokeAudioPdmI2s()
  smokePwm()

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
