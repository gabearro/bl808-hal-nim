## M0 async SPI controller test.
##
## No external SPI peer is attached on the Ox64 board model. SPI0 transfers on
## the modeled bus read back 0x00, which matches QEMU's BL808 board wiring for
## an unhandled transfer. This test verifies the native SPI register contract,
## IRQ-driven transfers, receive-only behavior, a send longer than the FIFO,
## and that abandoned transfers give their interrupt-bridge slots back.
##
## Build: nim c -d:bl808m0 -d:bl808kernel examples/m0_spi_test.nim
## Run:
##   qemu-system-riscv32 -M bl808 -nographic \
##     -icount shift=0,align=off,sleep=on \
##     -kernel examples/m0_spi_test

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/spi
import bl808/kernel/cps
import bl808/kernel/log
import bl808/kernel/asyncspi
import bl808/kernel/isrbridge

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  DefaultClkHz = 32_000_000'u32

var console: Uart

proc spiTestTask(): CpsVoidFuture {.cps.} =
  enablePeriphClock(periphSpi)
  enableSpiClock()

  var aspi = initAsyncSpi(spi0, SpiConfig(
    mode: spiMode0, frameSize: frame8bit, role: spiMaster,
    prescaler: 16, deglitch: false,
  ))
  logInfo "[SPI] Initialized"

  # Full-duplex transfer with no selected peer on the modeled SPI0 bus.
  var txData = [0x48'u8, 0x65, 0x6C, 0x6C, 0x6F]  # "Hello"
  var rxBuf: array[5, uint8]
  let err1 = await aspi.transferPtr(
    cast[ptr UncheckedArray[uint8]](addr txData[0]),
    cast[ptr UncheckedArray[uint8]](addr rxBuf[0]), 5)
  if err1 == spiOk:
    logInfo "[OK] transfer 5 bytes"
  else:
    logError "[FAIL] transfer err=": lInt(err1.int)

  # Verify no-peer receive data
  var noPeerReadback = true
  for i in 0 ..< txData.len:
    if rxBuf[i] != 0x00'u8:
      noPeerReadback = false
  if noPeerReadback:
    logInfo "[PASS] Full-duplex no-peer readback: 0x00"
  else:
    logError "[FAIL] Unexpected full-duplex RX data"
    logError "  expected": lStr(" "); lHex(0x00'u32); lStr(" "); lHex(0x00'u32); lStr(" "); lHex(0x00'u32)
    logError "  got":      lStr(" "); lHex(rxBuf[0].uint32); lStr(" "); lHex(rxBuf[1].uint32); lStr(" "); lHex(rxBuf[2].uint32)

  # Send-only
  var sendData = [0xAA'u8, 0xBB]
  let err2 = await aspi.sendPtr(
    cast[ptr UncheckedArray[uint8]](addr sendData[0]), 2)
  if err2 == spiOk:
    logInfo "[OK] send 2 bytes"
  else:
    logError "[FAIL] send err=": lInt(err2.int)

  # Receive-only (sends 0xFF and samples the no-peer bus)
  var recvBuf: array[3, uint8]
  let err3 = await aspi.recvPtr(
    cast[ptr UncheckedArray[uint8]](addr recvBuf[0]), 3)
  if err3 == spiOk:
    logInfo "[OK] recv 3 bytes"
    # Verify modeled no-peer readback.
    if recvBuf[0] == 0x00 and recvBuf[1] == 0x00 and recvBuf[2] == 0x00:
      logInfo "[PASS] Recv no-peer bus: 0x00 0x00 0x00"
    else:
      logError "[FAIL] recv data": lStr(" "); lHex(recvBuf[0].uint32); lStr(" "); lHex(recvBuf[1].uint32); lStr(" "); lHex(recvBuf[2].uint32)
  else:
    logError "[FAIL] recv err=": lInt(err3.int)

  # Send more than the FIFO holds: the rest is fed from the interrupt.
  var longData: array[100, uint8]
  for i in 0 ..< longData.len: longData[i] = i.uint8
  let err4 = await aspi.sendPtr(
    cast[ptr UncheckedArray[uint8]](addr longData[0]), longData.len)
  if err4 == spiOk:
    logInfo "[OK] send 100 bytes"
  else:
    logError "[FAIL] long send err=": lInt(err4.int)

  # Abandon more transfers than the interrupt bridge has slots.
  var cancelled = 0
  for i in 0 ..< MaxIsrSlots + 8:
    var pending: CpsFuture[SpiError]
    withInterruptsDisabled:   # before its interrupt can finish it
      pending = aspi.sendPtr(
        cast[ptr UncheckedArray[uint8]](addr longData[0]), longData.len)
      aspi.cancel()
    let outcome = await pending
    if outcome == spiCancelled: cancelled.inc
  let err5 = await aspi.sendPtr(
    cast[ptr UncheckedArray[uint8]](addr sendData[0]), 2)
  if cancelled == MaxIsrSlots + 8 and err5 == spiOk and
     isrBridgeActiveSlotsCount() == 0:
    logInfo "[PASS] Cancelled transfers release their slots"
  else:
    logError "[FAIL] cancel": lStr(" cancelled="); lInt(cancelled); lStr(" err="); lInt(err5.int); lStr(" slots="); lInt(isrBridgeActiveSlotsCount())

  logInfo ""
  logInfo "=== Test Complete ==="

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()

  enablePeriphClock(periphUart0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), DefaultClkHz)

  logInit(console)
  logInfo "=== BL808 Async SPI Test ==="
  logInfo ""

  schedulerInit()
  discard spiTestTask()
  runScheduler()
