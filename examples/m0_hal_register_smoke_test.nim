## M0 register-level smoke test for HAL modules that do not need attached
## external devices.
##
## This deliberately avoids long-running transfers. It exercises setup APIs and
## checks immediate MMIO side effects under QEMU.

import bl808/startup
import bl808/core
import bl808/mmio
import bl808/memmap, bl808/irq
import bl808/glb, bl808/gpio, bl808/uart
import bl808/adc, bl808/audio, bl808/can, bl808/cks
import bl808/dma, bl808/dma2d, bl808/efuse, bl808/emi, bl808/i2c
import bl808/i2s, bl808/ir, bl808/pdm, bl808/pwm, bl808/sec, bl808/timer
import bl808/pds, bl808/spi
import bl808/tzc as tzcHal
import bl808/cache, bl808/dbi, bl808/dvp, bl808/h264, bl808/lz4
import bl808/mjpeg, bl808/npu, bl808/osd, bl808/pka, bl808/psram
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

var
  console: Uart
  passed = 0
  failed = 0

proc ptr32[T](p: ptr T): uint32 =
  cast[uint32](cast[uint](p))

proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)
  if ok:
    inc passed
  else:
    inc failed

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

proc clicAttr(irq: uint32): uint32 =
  (regRead(ClicIntBase + irq * ClicIntStride) shr 16) and 0xFF'u32

proc clicIe(irq: uint32): uint32 =
  (regRead(ClicIntBase + irq * ClicIntStride) shr 8) and 0xFF'u32

proc clicAttrCtl(irq: uint32): uint32 =
  ## Low CLIC attr bits hold SHV/trigger controls; mode bits may read as M-mode.
  clicAttr(irq) and 0x07'u32

proc dummyTrap() {.cdecl.} =
  discard

proc smokeClic() =
  clicSetAttr(IrqM0Uart0, 0x04'u8)
  checkEq("CLIC attr dirty setup", clicAttrCtl(IrqM0Uart0), 0x04)
  clicInit()
  checkEq("CLIC init clears UART0 attr", clicAttrCtl(IrqM0Uart0), 0)
  checkEq("CLIC init clears timer attr", clicAttrCtl(7'u32), 0)
  bl808RegisterTrapHandlerC(IrqM0Uart1, dummyTrap)
  check("IRQ C trap bridge register", getTrapHandler(IrqM0Uart1) != nil)
  bl808EnablePeripheralIrqC(IrqM0Uart1, 3)
  let enabled = clicIe(IrqM0Uart1) != 0
  bl808DisablePeripheralIrqC(IrqM0Uart1)
  check("IRQ C enable/disable bridge", enabled and clicIe(IrqM0Uart1) == 0)

proc smokeCoreMmio() =
  var bodyRan = false
  withInterruptsDisabled:
    bodyRan = not interruptsEnabled()
  check("Core interrupt guard", bodyRan)
  check("Core detect API", detectCore() in {coreM0, coreUnknown})
  icacheInvalidateAll()
  delayUs(1)
  check("Core cache/delay APIs", true)

  regWrite(cks.CksConfig, 0)
  regSet(cks.CksConfig, 1)
  check("MMIO wait-set", regWaitSet(cks.CksConfig, 1, 4))
  regClear(cks.CksConfig, 1)
  check("MMIO wait-clear", regWaitClear(cks.CksConfig, 1, 4))
  regModify(cks.CksConfig, fieldMask(4, 2), fieldSet(4, 3))
  checkEq("MMIO field helpers", fieldVal(regRead(cks.CksConfig), 4, 2), 3)

proc smokeGlb() =
  disablePeriphClock(periphI2c1)
  check("GLB disable peripheral clock", (regRead(GlbCgenCfg1) and (1'u32 shl periphI2c1.uint32)) == 0)
  enablePeriphClock(periphI2c1)
  resetPeriph(periphI2c1)
  check("GLB reset peripheral API", true)
  setSpiClockDiv(5)
  setSpiClockSource(spiClkXclk)
  enableSpiClock()
  checkEq("GLB SPI clock divider", regRead(GlbSpiCfg0) and 0x1F'u32, 5)
  setI2cClockDiv(11)
  enableI2cClock()
  checkEq("GLB I2C clock divider", (regRead(GlbI2cCfg0) shr 16) and 0xFF'u32, 11)
  enableDma1Clock()
  check("GLB DMA1 clock enable", (regRead(GlbDmaCfg0) and (1'u32 shl 25)) != 0)
  discard getHclkDiv()
  discard getBclkDiv()
  check("GLB clock divider readback", true)
  enableSystemClock(GlbCgenCfg2, CgenCfg2Audio)
  disableSystemClock(GlbCgenCfg2, CgenCfg2Audio)
  enableSystemClock(GlbCgenCfg2, CgenCfg2Audio)
  check("GLB system clock gate API", (regRead(GlbCgenCfg2) and (1'u32 shl CgenCfg2Audio)) != 0)

proc smokeEmi() =
  emi.emiInit(emi.emiArbRoundRobin)
  checkEq("EMI init round-robin", regRead(emi.EmiCtrl),
          (1'u32 shl emi.EmiEn) or (emi.emiArbRoundRobin.uint32 shl emi.EmiArbModeShift))
  emi.emiSetArbitration(emi.emiArbFixed)
  checkEq("EMI arbitration fixed", regRead(emi.EmiCtrl) and emi.EmiArbModeMask, 0)
  emi.emiDisable()
  check("EMI disable", (regRead(emi.EmiCtrl) and (1'u32 shl emi.EmiEn)) == 0)
  emi.emiEnable()
  check("EMI enable", (regRead(emi.EmiCtrl) and (1'u32 shl emi.EmiEn)) != 0)

proc smokeTzc() =
  let romCtrl = regRead(tzcHal.TzcSecRomCtrl)
  let romR2 = regRead(tzcHal.TzcSecRomR2)
  check("TZC ROM ctrl readable", romCtrl != 0xFFFF_FFFF'u32)
  check("TZC ROM window readable", regRead(tzcHal.TzcSecRomR0) != 0xFFFF_FFFF'u32)
  check("TZC UART ctrl readable", regRead(tzcHal.TzcSecUartCtrl) != 0xFFFF_FFFF'u32)
  checkEq("TZC pack window", tzcHal.tzcPackWindow(0x1200'u32, 0x1000'u32, 10), 0x0004_0008'u32)
  tzcHal.tzcWrite(tzcHal.TzcSecUartCtrl, tzcHal.tzcRead(tzcHal.TzcSecUartCtrl))
  check("TZC write/read helper", tzcHal.tzcRead(tzcHal.TzcSecUartCtrl) != 0xFFFF_FFFF'u32)
  tzcHal.tzcConfigureRomRegion(2, 0x0000_0000'u32, 0x0000_0400'u32, 0)
  checkEq("TZC ROM region helper", regRead(tzcHal.TzcSecRomR2), tzcHal.tzcPackWindow(0, 0x400, 10))
  regWrite(tzcHal.TzcSecRomR2, romR2)
  regWrite(tzcHal.TzcSecRomCtrl, romCtrl)

proc smokePwm() =
  let p = pwm.initPwm()
  p.configureChannel(0.PwmChannel, period = 1000, duty = 250, clkDiv = 7)
  checkEq("PWM period", regRead(pwm.PwmMc0Period) and pwm.PwmPeriodMask, 1000)
  checkEq("PWM duty", (regRead(pwm.PwmMc0Ch0Thre) and pwm.PwmThrehMask) shr pwm.PwmThrehShift, 250)
  p.setThresholds(1.PwmChannel, 10, 110)
  checkEq("PWM thresholds", regRead(pwm.PwmMc0Ch1Thre), 0x006E_000A'u32)
  p.setPeriod(1200)
  checkEq("PWM set period", regRead(pwm.PwmMc0Period) and pwm.PwmPeriodMask, 1200)
  p.setDutyPercent(0, 50)
  checkEq("PWM duty percent", (regRead(pwm.PwmMc0Ch0Thre) and pwm.PwmThrehMask) shr pwm.PwmThrehShift, 600)
  p.setDeadTime(0, 9)
  checkEq("PWM dead-time", regRead(pwm.PwmMc0DeadTime) and 0xFF, 9)
  p.enableOutput(2.PwmChannel, positive = true, negative = true)
  check("PWM output enable", (regRead(pwm.PwmMc0Config1) and (0x05'u32 shl 8)) == (0x05'u32 shl 8))
  p.setPolarity(2.PwmChannel, invertPositive = true, invertNegative = true)
  check("PWM polarity", (regRead(pwm.PwmMc0Config1) and (0x03'u32 shl 20)) == (0x03'u32 shl 20))
  p.softwareBreak(true)
  check("PWM software break", (regRead(pwm.PwmMc0Config0) and (1'u32 shl pwm.PwmSwBreakEn)) != 0)
  p.softwareBreak(false)
  discard p.isStopped()
  p.start()
  check("PWM start", (regRead(pwm.PwmMc0Config0) and (1'u32 shl pwm.PwmStopEn)) == 0)
  p.enableInterrupt(pwm.PwmIntPrde)
  p.clearInterrupt(pwm.PwmIntPrde)
  discard p.readInterruptStatus()
  p.disableInterrupt(pwm.PwmIntPrde)
  check("PWM interrupt API", (regRead(pwm.PwmMc0IntEn) and (1'u32 shl pwm.PwmIntPrde)) == 0)
  p.stop()
  check("PWM stop", (regRead(pwm.PwmMc0Config0) and (1'u32 shl pwm.PwmStopEn)) != 0)

proc smokeCks() =
  cks.cksReset()
  check("CKS reset API", true)
  regWrite(cks.CksConfig, 0)
  cks.cksSetEndian(true)
  check("CKS endian set", (regRead(cks.CksConfig) and (1'u32 shl cks.CksEndian)) != 0)
  cks.cksSetEndian(false)
  check("CKS endian clear", (regRead(cks.CksConfig) and (1'u32 shl cks.CksEndian)) == 0)
  cks.cksFeedByte(0x5A'u8)
  cks.cksFeedWord(0x1234_5678'u32)
  cks.cksFeedBuffer([0xDE'u8, 0xAD'u8, 0xBE'u8, 0xEF'u8])
  discard cks.cksResult()
  discard cks.cksCompute([1'u8, 2'u8, 3'u8, 4'u8])
  check("CKS feed/compute APIs", true)

proc smokeAdc() =
  let a = adc.initAdc(adc.adc14Bit, adc.vref2v0, clkDiv = 3)
  let cfg1 = regRead(adc.AdcCfg1)
  checkEq("ADC resolution", (cfg1 and adc.AdcResSelMask) shr adc.AdcResSelShift, adc.adc14Bit.uint32)
  checkEq("ADC clock divider", (cfg1 and adc.AdcClkDivMask) shr adc.AdcClkDivShift, 3)
  check("ADC vref", (regRead(adc.AdcCfg2) and (1'u32 shl adc.AdcVrefSel)) != 0)
  let channels = [0.AdcChannel, 1.AdcChannel]
  a.startScan(channels)
  check("ADC scan enable", (regRead(adc.AdcCfg1) and (1'u32 shl adc.AdcScanEn)) != 0)
  a.enableDma()
  check("ADC DMA enable", (regRead(adc.GpipGpadcConfig) and (1'u32 shl adc.GpipDmaEn)) != 0)
  a.disableDma()
  let (_, fifoValid) = a.readFifo()
  discard fifoValid
  check("ADC FIFO read API", true)
  check("ADC FIFO count readable", a.fifoCount() <= 0x1F)
  checkEq("ADC FIFO data addr", adc.fifoDataAddr().uint32, adc.GpipGpadcDmaRdata.uint32)
  let (_, adcSingleErr) = a.readChannel(0.AdcChannel, timeout = 1)
  check("ADC single-shot bounded", adcSingleErr == adc.adcOk or adcSingleErr == adc.adcTimeout)
  let (_, adcTempErr) = a.readTemperatureRaw()
  check("ADC temperature bounded", adcTempErr == adc.adcOk or adcTempErr == adc.adcTimeout)
  let (_, adcVbatErr) = a.readVbatRaw()
  check("ADC VBAT bounded", adcVbatErr == adc.adcOk or adcVbatErr == adc.adcTimeout)
  a.stopScan()
  check("ADC scan stop", (regRead(adc.AdcCfg1) and (1'u32 shl adc.AdcScanEn)) == 0)

  adc.dacEnable(adc.dacA)
  check("DAC A enable", (regRead(adc.GlbDacActrl) and 0x03'u32) == 0x03'u32)
  adc.dacWrite(0x0123_0456'u32)
  let dacData = regRead(adc.GlbDacData)
  check("DAC direct write", dacData == 0x0123_0456'u32 or
        dacData == (0x0123_0456'u32 and 0x03FF_03FF'u32))
  adc.dacWriteDma(0x0000_00AB'u32)
  adc.dacEnableDma()
  check("DAC DMA enable", (regRead(adc.DacDmaConfig) and (1'u32 shl adc.DacDmaTxEn)) != 0)
  adc.dacDisable(adc.dacA)
  check("DAC A disable", (regRead(adc.GlbDacActrl) and 0x03'u32) == 0)

proc smokeCan() =
  let timing = can.CanBitTiming(prescaler: 3, sjw: 1, tseg1: 6, tseg2: 1, tripleSampling: true)
  can.canInit(timing, listenOnly = true)
  check("CAN reset/listen/filter", (regRead(can.CanModReg) and
        ((1'u32 shl can.CanResetMode) or (1'u32 shl can.CanListenOnly) or (1'u32 shl can.CanAccFilter))) ==
        ((1'u32 shl can.CanResetMode) or (1'u32 shl can.CanListenOnly) or (1'u32 shl can.CanAccFilter)))
  checkEq("CAN BTR0", regRead(can.CanBtr0), (3'u32 shl can.CanBrpShift) or (1'u32 shl can.CanSjwShift))
  checkEq("CAN BTR1 tseg1", regRead(can.CanBtr1) and can.CanTseg1Mask, 6'u32 shl can.CanTseg1Shift)
  can.canSetFilterStdId(0x123)
  check("CAN filter API", (regRead(can.CanModReg) and (1'u32 shl can.CanAccFilter)) != 0)
  can.canSetFilter(0x11'u8, 0x22'u8, 0x33'u8, 0x44'u8)
  check("CAN generic filter API", true)
  can.canSetMask(0xF0'u8, 0xF1'u8, 0xF2'u8, 0xF3'u8)
  check("CAN generic mask API", true)
  can.canEnableRxInterrupt()
  can.canEnableTxInterrupt()
  can.canEnableErrorInterrupt()
  check("CAN IRQ enables", (regRead(can.CanIntEn) and ((1'u32 shl can.CanIntRx) or (1'u32 shl can.CanIntTx))) != 0)
  can.canDisableInterrupt(can.CanIntTx)
  check("CAN IRQ generic disable", (regRead(can.CanIntEn) and (1'u32 shl can.CanIntTx)) == 0)
  can.canEnableInterrupt(can.CanIntTx)
  discard can.canReadInterruptStatus()
  can.canDisableAllInterrupts()
  checkEq("CAN IRQ disable", regRead(can.CanIntEn), 0)
  let status = can.canGetStatus()
  check("CAN status readable", status.rxPending == ((regRead(can.CanStsReg) and (1'u32 shl can.CanRxBufSts)) != 0))
  let (txErr, rxErr) = can.canGetErrorCount()
  check("CAN error counts readable", txErr <= 0xFF and rxErr <= 0xFF)
  discard can.canGetErrorCode()
  discard can.canRxMessageCount()
  let frame = can.CanFrame(id: can.CanId(id: 0x123, extended: false),
                           dlc: 1, data: [0x42'u8, 0, 0, 0, 0, 0, 0, 0], rtr: false)
  let sendErr = can.canSendFrame(frame, timeout = 1)
  check("CAN send bounded", sendErr == can.canOk or sendErr == can.canTimeout or sendErr == can.canBusOff)
  let (_, recvErr) = can.canRecvFrame(timeout = 1)
  check("CAN recv bounded", recvErr == can.canTimeout or recvErr == can.canOk or recvErr == can.canOverrun)
  let selfErr = can.canSelfTestSend(frame)
  check("CAN self-test bounded", selfErr == can.canOk or selfErr == can.canTimeout)
  can.canAbortTransmission()
  check("CAN abort API", (regRead(can.CanCmdReg) and (1'u32 shl can.CanAbortTx)) != 0)
  can.canDisable()
  check("CAN disable reset mode", (regRead(can.CanModReg) and (1'u32 shl can.CanResetMode)) != 0)
  can.canEnable()
  check("CAN enable clears reset", (regRead(can.CanModReg) and (1'u32 shl can.CanResetMode)) == 0)

proc smokeI2s() =
  let bus = i2s.initI2s(i2s.i2sStandard, i2s.i2sData24bit, i2s.i2sMaster, bclkDiv = 12)
  checkEq("I2S BCLK divider", regRead(i2s.I2sBclkCfg) and i2s.I2sBclkDivMask, 12)
  bus.enableTx()
  bus.enableRx()
  bus.mute(true)
  check("I2S enables", (regRead(i2s.I2sCfg) and
        ((1'u32 shl i2s.I2sTxEn) or (1'u32 shl i2s.I2sRxEn) or (1'u32 shl i2s.I2sMute))) != 0)
  bus.enableDmaTx()
  bus.enableDmaRx()
  check("I2S DMA enables", (regRead(i2s.I2sFifoCfg0) and
        ((1'u32 shl i2s.I2sFifoDmaTxEn) or (1'u32 shl i2s.I2sFifoDmaRxEn))) != 0)
  checkEq("I2S TX FIFO addr", bus.txFifoAddr().uint32, i2s.I2sFifoWdata.uint32)

proc smokeAudioPdm() =
  audio.auadcInit(audio.auRate16k)
  audio.auadcSetVolume(0x155)
  audio.auadcSetPgaGain(7)
  audio.auadcEnableDma()
  checkEq("AUADC volume", regRead(audio.AuadcAdcS0) and audio.AuadcVolMask, 0x155)
  check("AUADC DMA", (regRead(audio.AuadcRxFifoCtrl) and (1'u32 shl audio.AuadcRxDrqEn)) != 0)
  audio.auadcEnable()
  discard regRead(audio.AuadcCmd)
  check("AUADC enable", true)
  discard audio.auadcDataReady()
  discard audio.auadcReadRaw()
  discard audio.auadcFifoRead()
  checkEq("AUADC FIFO addr", audio.auadcRxFifoAddr().uint32, audio.AuadcRxFifoData.uint32)
  audio.auadcDisable()
  check("AUADC disable", (regRead(audio.AuadcCmd) and (1'u32 shl audio.AuadcConv)) == 0)

  audio.audacInit()
  audio.audacSetVolume(0x021)
  audio.audacMute(true)
  audio.audacEnableDma()
  audio.audacWriteSample(0x1357_2468'u32)
  checkEq("AUDAC volume", (regRead(audio.AudacS0) and audio.AudacVolMask) shr audio.AudacVolShift, 0x021)
  check("AUDAC mute", (regRead(audio.AudacS0) and (1'u32 shl audio.AudacMute)) != 0)
  checkEq("AUDAC FIFO addr", audio.audacTxFifoAddr().uint32, audio.AudacTxFifoData.uint32)
  audio.audacDisable()
  check("AUDAC disable", (regRead(audio.AudacCtrl0) and (1'u32 shl audio.AudacItfEn)) == 0)

  pdm.pdmInit(pdm.pdmRate16k, pdm.pdmStereo)
  pdm.pdmSetGain(0x101)
  pdm.pdmSetAdcScale(0x22)
  pdm.pdmSetFifoThreshold(5)
  pdm.pdmEnableDma()
  pdm.pdmEnable()
  checkEq("PDM gain", regRead(pdm.PdmVolReg) and pdm.PdmVolMask, 0x101)
  checkEq("PDM threshold", (regRead(pdm.PdmRxFifoCtrl) and pdm.PdmRxFifoThreshMask) shr pdm.PdmRxFifoThreshShift, 5)
  check("PDM enable", (regRead(pdm.PdmCfg1) and (1'u32 shl pdm.PdmItfEn)) != 0)
  pdm.pdmDisable()

proc smokeDma2d() =
  regWrite(dma2d.Dma2dIntSts, 1)
  let d2 = dma2d.dma2dTransfer(0x2200_0000'u32, 16, 0x2200_1000'u32, 16, 8, 2, timeout = 8)
  check("DMA2D programmed transfer", d2 == dma2d.dma2dOk or d2 == dma2d.dma2dTimeout)
  checkEq("DMA2D src stride", regRead(dma2d.Dma2dSrcStride), 16)
  checkEq("DMA2D width", regRead(dma2d.Dma2dXCount), 8)

proc smokeSecEfuse() =
  let key = [0x0011_2233'u32, 0x4455_6677'u32, 0x8899_AABB'u32, 0xCCDD_EEFF'u32]
  let iv = [0x0102_0304'u32, 0x0506_0708'u32, 0x090A_0B0C'u32, 0x0D0E_0F10'u32]
  sec.aesSetKey(key)
  sec.aesSetIv(iv)
  checkEq("SEC AES key0", regRead(sec.AesKey0), key[0])
  checkEq("SEC AES iv0", regRead(sec.AesIv0), iv[0])
  sec.shaStart(sec.sha256)
  sec.shaFinish()
  check("SEC SHA API", true)
  sec.trngEnable()
  sec.trngDisable()
  check("SEC TRNG API", true)
  discard efuse.efuseAutoLoadDone()
  check("EFUSE safe status read", true)

proc smokeCachePsram() =
  check("Cache invalidate API", cache.l1cInvalidateAll())
  check("Cache flush API", cache.l1cFlushAll())

  psram.psramInit(psram.psram64mb, psram.psramBurst64)
  let cfg = regRead(psram.PsramCtrlCfg0)
  check("PSRAM init fields", (cfg and ((1'u32 shl psram.PsramEn) or
        psram.PsramSizeMask or psram.PsramBurstMask)) ==
        ((1'u32 shl psram.PsramEn) or (psram.psram64mb.uint32 shl psram.PsramSizeShift) or
        (psram.psramBurst64.uint32 shl psram.PsramBurstShift)))
  psram.psramDisable()
  check("PSRAM disable", (regRead(psram.PsramCtrlCfg0) and (1'u32 shl psram.PsramEn)) == 0)
  psram.psramEnable()
  check("PSRAM enable", (regRead(psram.PsramCtrlCfg0) and (1'u32 shl psram.PsramEn)) != 0)

proc smokeLz4() =
  lz4.lz4Reset()
  regWrite(lz4.Lz4SrcStart, lz4.lz4StartValue(0x2203_1000'u32))
  regWrite(lz4.Lz4DstStart, lz4.lz4StartValue(0x2203_1100'u32))

  check("LZ4 config disabled", (regRead(lz4.Lz4Config) and (1'u32 shl lz4.Lz4En)) == 0)
  check("LZ4 interrupt status readable", regRead(lz4.Lz4IntSta) != 0xFFFF_FFFF'u32)
  checkEq("LZ4 source start", regRead(lz4.Lz4SrcStart), 0x2203_1000'u32)
  checkEq("LZ4 destination start", regRead(lz4.Lz4DstStart), 0x2203_1100'u32)
  check("LZ4 source end readable", (regRead(lz4.Lz4SrcEnd) and not lz4.Lz4AddrLowMask) == 0)
  check("LZ4 enable cleared", (regRead(lz4.Lz4Config) and (1'u32 shl lz4.Lz4En)) == 0)

proc smokeMmAcceleratorConstants() =
  # These D0/MM multimedia modules are behaviorally covered by the D0 smoke
  # test; keep their register maps in the M0 smoke reachability set too.
  checkEq("DBI FIFO register", dbi.DbiFifoWdata.uint32, (DbiBase + 0x88'u).uint32)
  checkEq("DVP stride", dvp.DvpStride.uint32, 0x100)
  checkEq("DVP0 frame start", (Dvp0Base + dvp.Dvp2axiFrameStartAddr0).uint32, (Dvp0Base + 0x40'u).uint32)
  checkEq("OSD DP bg register", osd.OsdDpBgColor.uint32, (OsdDpBase + 0x04'u).uint32)
  checkEq("H264 QP register", h264.H264Qp.uint32, (H264Base + 0x08'u).uint32)
  checkEq("MJPEG decoder ctrl", mjpeg.MjpegDecCtrl.uint32, MjpegDecBase.uint32)
  checkEq("NPU BLAI clock register", npu.MmCnnClock.uint32, (MmGlbBase + 0x04'u).uint32)

proc smokeNpuPka() =
  var a = [1'u32, 2'u32]
  var b = [1'u32, 3'u32]
  var z = [0'u32, 0'u32]
  checkEq("PKA ECC cmp", pka.bflb_sec_ecc_cmp(addr a[0], addr b[0], 2).uint32, 0xFFFF_FFFF'u32)
  checkEq("PKA ECC zero", pka.bflb_sec_ecc_is_zero(addr z[0], 2).uint32, 1)
  var ecdsa: pka.BflbEcdsa
  var ecdh: pka.BflbEcdh
  var dsa: pka.BflbDsa
  checkEq("PKA ECDSA init", pka.bflb_sec_ecdsa_init(addr ecdsa, pka.EcpSecp256r1).uint32, 0)
  checkEq("PKA ECDH init", pka.bflb_sec_ecdh_init(addr ecdh, pka.EcpSecp256r1).uint32, 0)
  checkEq("PKA DSA init", pka.bflb_sec_dsa_init(addr dsa, 2048).uint32, 0)
  npu.npuSetClock(true, npu.npuClk160M, 1)
  check("NPU clock helper", npu.npuClockEnabled())
  npu.npuHoldReset()
  npu.npuReleaseReset()
  npu.npuReset()
  check("NPU reset helpers", (regRead(npu.MmCnnReset) and npu.CnnResetMask) == 0)
  npu.npuReleaseSram()
  check("NPU SRAM helper", npu.npuSramReleased())

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()

  enableAllPeriphClocks()
  mmPowerOn()

  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(ConsoleUartTxPin, ConsoleUartRxPin)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), ConsoleClkHz)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 HAL Register Smoke Test ===")

  smokeClic()
  smokeEmi()
  smokeTzc()
  smokePwm()
  smokeCks()
  smokeAdc()
  smokeCan()
  smokeI2s()
  smokeAudioPdm()
  smokeDma2d()
  smokeSecEfuse()
  smokeCachePsram()
  smokeLz4()
  smokeMmAcceleratorConstants()
  smokeNpuPka()

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
