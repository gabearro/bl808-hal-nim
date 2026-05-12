## M0 HAL communication feature test.
##
## Covers UART, SPI, I2C, CAN, and IR register-level APIs without requiring
## attached peripherals. Transfers are bounded and accept no-peer timeout
## results where appropriate.

import bl808/startup
import bl808/core
import bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/can, bl808/i2c, bl808/ir, bl808/spi
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

proc smokeUart() =
  enablePeriphClock(periphUart1)
  let u = initUart(uart1, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), ConsoleClkHz)
  check("uart fifo status", u.txFifoFree() <= 63 and u.rxFifoCount() <= 63)
  u.setRxFifoThreshold(7)
  checkEq("uart rx fifo threshold", (regRead(u.baseAddr() + UartFifoConfig1) and
          FifoRxThreshMask) shr FifoRxThreshShift, 7)
  discard u.txFifoFull()
  discard u.rxAvailable()
  discard u.txBusy()
  discard u.trySendByte(0x55'u8)
  discard u.txFifoEmpty()
  discard u.tryRecvByte()
  let (_, recvErr) = u.recvByte(timeout = 1)
  check("uart bounded receive", recvErr == uartTimeout or recvErr == uartOk)
  u.clearFifos()
  u.enableDmaTx()
  u.enableDmaRx()
  checkEq("uart tx fifo address", u.txFifoAddr().uint32, (u.baseAddr() + UartFifoWdata).uint32)
  u.disableDmaTx()
  u.disableDmaRx()
  u.setInterruptEnable(0x0000_000F'u32)
  u.enableInterrupt(IntUrxFifoReady)
  discard u.readInterruptStatus()
  u.clearInterrupt(IntUrxFifoReady)
  u.disableInterrupt(IntUrxFifoReady)
  check("uart irq and dma APIs", (regRead(u.baseAddr() + UartFifoConfig0) and
        ((1'u32 shl FifoDmaTxEn) or (1'u32 shl FifoDmaRxEn))) == 0)
  u.flushTx()
  u.deinitUart()
  check("uart deinit", (regRead(u.baseAddr() + UartUtxConfig) and (1'u32 shl UtxEn)) == 0)

proc smokeSpi() =
  enablePeriphClock(periphSpi)
  enableSpiClock()
  let s = initSpi(spi0, SpiConfig(
    mode: spiMode0, frameSize: frame8bit, role: spiMaster,
    prescaler: 8, deglitch: true,
  ))
  checkEq("spi base address", s.baseAddr().uint32, Spi0Base.uint32)
  checkEq("spi fifo depth", s.fifoDepth(), 32)
  discard s.txFifoFree()
  discard s.txFifoCount()
  discard s.rxFifoCount()
  discard s.busy()
  let (_, byteErr) = s.transferByte(0xA5'u8)
  check("spi bounded byte transfer", byteErr == spiOk or byteErr == spiTimeout)
  s.clearFifos()
  s.enableDmaTx()
  s.enableDmaRx()
  checkEq("spi tx fifo address", s.txFifoAddr().uint32, (Spi0Base + SpiFifoWdata).uint32)
  s.enableInterrupt(SpiIntEnd)
  s.clearInterrupt(SpiIntEnd)
  s.disableInterrupt(SpiIntEnd)
  s.deinitSpi()
  check("spi deinit", (regRead(Spi0Base + SpiConfigReg) and
        ((1'u32 shl SpiMasterEn) or (1'u32 shl SpiSlaveEn))) == 0)

proc smokeI2c() =
  enablePeriphClock(periphI2c0)
  enableI2cClock()
  let bus = initI2c(i2c0, i2cFast, ConsoleClkHz)
  checkEq("i2c tx fifo address", bus.txFifoAddr().uint32, (I2c0Base + I2cFifoWdata).uint32)
  bus.enableDmaTx()
  bus.enableDmaRx()
  check("i2c dma enable", (regRead(bus.base + I2cFifoConfig0) and
        ((1'u32 shl I2cFifoDmaTxEn) or (1'u32 shl I2cFifoDmaRxEn))) != 0)
  let wrErr = bus.writeRegByte(0x50'u8, 0x00'u8, 0xA5'u8)
  let (_, rdErr) = bus.readRegByte(0x50'u8, 0x00'u8)
  check("i2c bounded register helpers", wrErr in {i2cOk, i2cNak, i2cArbLost, i2cTimeout} and
        rdErr in {i2cOk, i2cNak, i2cArbLost, i2cTimeout})
  discard bus.busy()
  bus.deinitI2c()
  check("i2c deinit", (regRead(bus.base + I2cConfig) and (1'u32 shl I2cMasterEn)) == 0)

proc smokeCan() =
  let timing = CanBitTiming(prescaler: 3, sjw: 1, tseg1: 6, tseg2: 1, tripleSampling: true)
  canInit(timing, listenOnly = true)
  canSetFilterStdId(0x123)
  canSetFilter(0x11'u8, 0x22'u8, 0x33'u8, 0x44'u8)
  canSetMask(0xF0'u8, 0xF1'u8, 0xF2'u8, 0xF3'u8)
  canEnableRxInterrupt()
  canEnableTxInterrupt()
  canEnableErrorInterrupt()
  canDisableInterrupt(CanIntTx)
  canEnableInterrupt(CanIntTx)
  discard canReadInterruptStatus()
  canDisableAllInterrupts()
  discard canGetStatus()
  discard canGetErrorCount()
  discard canGetErrorCode()
  discard canRxMessageCount()
  let frame = CanFrame(id: CanId(id: 0x123, extended: false),
                       dlc: 1, data: [0x42'u8, 0, 0, 0, 0, 0, 0, 0], rtr: false)
  let sendErr = canSendFrame(frame, timeout = 1)
  let (_, recvErr) = canRecvFrame(timeout = 1)
  let selfErr = canSelfTestSend(frame)
  check("can bounded transfer APIs", sendErr in {canOk, canTimeout, canBusOff} and
        recvErr in {canOk, canTimeout, canOverrun} and
        selfErr in {canOk, canTimeout})
  canAbortTransmission()
  canDisable()
  canEnable()
  check("can control APIs", true)

proc smokeIr() =
  setIrClockDiv(7)
  enableIrClock()
  irTxInit(irNec)
  irTxSend(0x00FF_00FF'u32, 32)
  irTxSendNec(0x12'u8, 0x34'u8)
  irRxInit(irNec)
  irRxEnable()
  let (_, rxErr) = irRxRead(timeout = 1)
  discard irRxGetBitCount()
  discard irRxFifoCount()
  discard irRxFifoRead()
  irRxDisable()
  check("ir tx/rx bounded APIs", rxErr == irTimeout or rxErr == irOk)

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
  discard console.sendLine("=== BL808 HAL Comms Test ===")

  smokeUart()
  smokeSpi()
  smokeI2c()
  smokeCan()
  smokeIr()

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
