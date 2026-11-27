## M0 DMA test for linked memory, SPI, and UART transfers.
##
## Run with tools/hw_validate.py --test m0_dma_test. The harness sends a
## known UART payload once the receiver has armed its DMA channel.

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart, bl808/spi
import bl808/[dma, dmablock, mmio]
when defined(bl808DmaBench):
  import bl808/irq
  import bl808/kernel/asyncuart
  import bl808/[adc, i2c, peripheraldma]
  import bl808/kernel/asynci2c
import bl808/kernel/cps
import bl808/kernel/log
import bl808/kernel/[asyncdma, asyncspi]

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  DefaultClkHz = 40_000_000'u32
  BlockBytes = 4_113

var
  console: Uart
  src: array[BlockBytes, uint8]
  dst: array[BlockBytes, uint8]
when defined(bl808DmaBench):
  const UartInput = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz"
  var samples: array[64, uint32]

when defined(bl808DmaBench):
  proc benchDmaTest(): CpsVoidFuture {.cps.} =
    let au = initAsyncUart(console, IrqM0Uart0, 0)
    let rx = au.recvInto(dst)
    cancel(rx)
    if not rx.isCancelled:
      logError "[FAIL] Bulk UART receive cancellation"

    let uartRx = au.recvIntoPtr(cast[ptr UncheckedArray[byte]](addr dst[0]), UartInput.len)
    let uartRxDmaOn = (regRead(console.baseAddr() + UartFifoConfig0) and 2) != 0
    logInfo "UART DMA RX ready"
    let uartRxStatus = await withTimeout(uartRx, 2_000)
    var uartReadback = uartRxDmaOn and uartRxStatus == uartOk
    for i in 0 ..< UartInput.len:
      if dst[i] != UartInput[i].uint8: uartReadback = false
    if uartReadback:
      logInfo "[PASS] UART DMA RX payload verified"
    else:
      logError "[FAIL] UART DMA RX data mismatch"
    for b in src.mitems: b = uint8('x')
    const Marker = "\r\n[PASS] Linked UART DMA payload tail\r\n"
    for i in 0 ..< Marker.len:
      src[src.len - Marker.len + i] = Marker[i].uint8
    let tx = au.sendAsync(src)
    let uartDmaOn = (regRead(console.baseAddr() + UartFifoConfig0) and 1) != 0
    let uartStatus = await withTimeout(tx, 1_000)
    if not uartDmaOn or uartStatus != uartOk:
      logError "[FAIL] Bulk UART DMA send"

    enablePeriphClock(periphI2c0)
    enableI2cClock()
    gpioSetupI2c(11, 10)
    let bus = initAsyncI2c(i2c0, i2cStandard, DefaultClkHz)
    let i2cRead = bus.readRegPtr(0x7F, 0, cast[ptr UncheckedArray[byte]](addr dst[0]), 1)
    let i2cDmaOn = (regRead(bus.i2c.base + I2cFifoConfig0) and (1'u32 shl I2cFifoDmaRxEn)) != 0
    await sleepMs(10)
    if not i2cRead.finished: cancel(i2cRead)
    if i2cDmaOn and (regRead(bus.i2c.base + I2cConfig) and (1'u32 shl I2cMasterEn)) == 0 and
        (regRead(bus.i2c.base + I2cFifoConfig0) and (1'u32 shl I2cFifoDmaRxEn)) == 0 and
        (i2cRead.isCancelled or i2cRead.read() == i2cNak):
      logInfo "[PASS] One-byte I2C releases DMA on an absent slave"
    else:
      logError "[FAIL] One-byte I2C DMA cleanup"

    setAdcClockSource(adcClkXtal)
    setAdcClockDiv(1)
    enableAdcClock()
    let adc = initAdc(clkDiv = 3)
    for sample in samples.mitems: sample = high(uint32)
    let scan = fifoTransferAsync(GpadcDmaRx, samples)
    adc.startScan([0.AdcChannel, 1.AdcChannel])
    await sleepMs(20)
    if not scan.finished: cancel(scan)
    adc.stopScan()
    var valid = not scan.isCancelled and scan.read()
    for sample in samples:
      if sample == high(uint32): valid = false
    if valid and (regRead(GpipGpadcConfig) and 1) == 0:
      logInfo "[PASS] GPADC DMA captured 64 samples"
    else:
      logError "[FAIL] GPADC DMA capture"

else:
  proc benchDmaTest(): CpsVoidFuture = completedLocalVoidFuture()

proc dmaTestTask(): CpsVoidFuture {.cps.} =
  # --- Test 1: M2M DMA copy ---
  logInfo "--- Test 1: DMA M2M Copy ---"
  for i in 0 ..< src.len:
    src[i] = uint8(i and 0xFF)
    dst[i] = 0

  let ok1 = await withTimeout(dmaCopyAsync(addr src[0], addr dst[0], src.len), 250)
  if ok1:
    logInfo "[OK] DMA M2M copy completed"
  else:
    logError "[FAIL] DMA M2M copy"

  var match = true
  for i in 0 ..< src.len:
    if dst[i] != src[i]:
      match = false
  if match:
    logInfo "[PASS] Linked M2M data verified (4113 bytes)"
  else:
    logError "[FAIL] M2M data mismatch"
    logError "  dst[0..3]=": lHex(dst[0].uint32); lStr(" "); lHex(dst[1].uint32); lStr(" "); lHex(dst[2].uint32); lStr(" "); lHex(dst[3].uint32)

  # --- Test 2: DMA SPI loopback ---
  logInfo ""
  logInfo "--- Test 2: DMA SPI Transfer ---"
  enablePeriphClock(periphSpi)
  enableSpiClock()
  let aspi = initAsyncSpi(spi0, SpiConfig(
    mode: spiMode0, frameSize: frame8bit, role: spiMaster,
    prescaler: 16, deglitch: false,
  ))

  let aborted = aspi.send(src)
  aspi.cancel()
  if aborted.finished and aborted.read() == spiCancelled and not aspi.active:
    logInfo "[PASS] Cancelled bulk SPI transfer"
  else:
    logError "[FAIL] Bulk SPI cancellation"

  # A two-channel transfer must wait when only one channel is available.
  let controller = openCoreDma()
  var held: array[7, DmaChannel]
  var heldCount = 0
  for i in 0 ..< held.len:
    let ch = controller.reserveChannel()
    if ch < 0: break
    held[heldCount] = DmaChannel(ch)
    inc heldCount
  let deferred = aspi.transferPtr(cast[ptr UncheckedArray[byte]](addr src[0]),
    cast[ptr UncheckedArray[byte]](addr dst[0]), 1)
  await sleepMs(1)
  let waited = heldCount == held.len and not deferred.finished and
    (regRead(aspi.spi.baseAddr() + SpiFifoConfig0) and 3) == 0
  for i in 0 ..< heldCount:
    controller.releaseChannel(held[i])
  let deferredStatus = await withTimeout(deferred, 250)
  if waited and deferredStatus == spiOk:
    logInfo "[PASS] One-byte SPI transfer waits for DMA channels"
  else:
    logError "[FAIL] SPI under DMA channel contention"

  # The input pad has no peer. Capture its value with a blocking byte transfer,
  # then check that both receive descriptors overwrite the destination.
  let idle = aspi.spi.transferByte(0xFF)
  for b in dst.mitems: b = not idle[0]
  let duplex = aspi.transfer(src, dst)
  let spiDmaOn = (regRead(aspi.spi.baseAddr() + SpiFifoConfig0) and 3) == 3
  let status = await withTimeout(duplex, 250)
  var spiReadback = spiDmaOn and idle[1] == spiOk and status == spiOk
  for b in dst:
    if b != idle[0]: spiReadback = false
  if spiReadback:
    logInfo "[PASS] Linked SPI DMA readback (4113 bytes)"
  else:
    logError "[FAIL] Linked SPI DMA readback"

  await benchDmaTest()

  logInfo ""
  logInfo "=== Test Complete ==="

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()

  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  enableDma0Clock()
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), DefaultClkHz)

  logInit(console)
  logInfo "=== BL808 DMA Test ==="
  logInfo ""

  schedulerInit()
  discard dmaTestTask()
  runScheduler()
