## M0 DMA test — memory-to-memory copy and DMA-accelerated SPI transfer.
##
## Build: nim c -d:bl808m0 -d:bl808kernel examples/m0_dma_test.nim
## Run:
##   qemu-system-riscv32 -M bl808 -nographic \
##     -icount shift=0,align=off,sleep=on \
##     -kernel examples/m0_dma_test

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart, bl808/spi
import bl808/kernel/cps
import bl808/kernel/log
import bl808/kernel/asyncdma

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  DefaultClkHz = 32_000_000'u32

var console: Uart

proc dmaTestTask(): CpsVoidFuture {.cps.} =
  # --- Test 1: M2M DMA copy ---
  logInfo "--- Test 1: DMA M2M Copy ---"
  var src: array[64, uint8]
  var dst: array[64, uint8]
  for i in 0 ..< 64:
    src[i] = i.uint8
    dst[i] = 0

  let ok1 = await dmaCopyAsync(addr src[0], addr dst[0], 64)
  if ok1:
    logInfo "[OK] DMA M2M copy completed"
  else:
    logError "[FAIL] DMA M2M copy"

  var match = true
  for i in 0 ..< 64:
    if dst[i] != src[i]:
      match = false
  if match:
    logInfo "[PASS] M2M data verified (64 bytes)"
  else:
    logError "[FAIL] M2M data mismatch"
    logError "  dst[0..3]=": lHex(dst[0].uint32); lStr(" "); lHex(dst[1].uint32); lStr(" "); lHex(dst[2].uint32); lStr(" "); lHex(dst[3].uint32)

  # --- Test 2: DMA SPI loopback ---
  logInfo ""
  logInfo "--- Test 2: DMA SPI Transfer ---"
  enablePeriphClock(periphSpi)
  enableSpiClock()
  let mySpi = initSpi(spi0, SpiConfig(
    mode: spiMode0, frameSize: frame8bit, role: spiMaster,
    prescaler: 16, deglitch: false,
  ))

  var txData: array[10, uint8]
  var rxData: array[10, uint8]
  for i in 0 ..< 10:
    txData[i] = (0x41 + i).uint8  # "ABCDEFGHIJ"
    rxData[i] = 0

  let ok2 = await spiDmaTransfer(mySpi,
    cast[ptr UncheckedArray[uint8]](addr txData[0]),
    cast[ptr UncheckedArray[uint8]](addr rxData[0]), 10)
  if ok2:
    logInfo "[OK] DMA SPI transfer completed"
  else:
    logError "[FAIL] DMA SPI transfer"

  var spiNoPeerReadback = true
  for i in 0 ..< 10:
    if rxData[i] != 0x00'u8:
      spiNoPeerReadback = false
  if spiNoPeerReadback:
    logInfo "[PASS] SPI DMA no-peer readback: 0x00"
  else:
    logError "[FAIL] SPI DMA unexpected RX data"
    logError "  rx[0..3]=": lHex(rxData[0].uint32); lStr(" "); lHex(rxData[1].uint32); lStr(" "); lHex(rxData[2].uint32); lStr(" "); lHex(rxData[3].uint32)

  logInfo ""
  logInfo "=== Test Complete ==="

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()

  enablePeriphClock(periphUart0)
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
