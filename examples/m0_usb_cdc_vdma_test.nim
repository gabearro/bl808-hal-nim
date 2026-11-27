## Native USB CDC payload test. The UART reports byte-for-byte verification
## of a deterministic payload received and echoed through the USB controller.

import bl808/[startup, core, glb, gpio, uart]
import bl808/kernel/[cps, log, usbcdc, usbdev]

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz = 40_000_000'u32
  PayloadBytes = 2051
  EchoChunk = 128

var console: Uart

proc runEcho(cdc: UsbCdc): CpsVoidFuture {.cps.} =
  while usbDevGetState() != usbConfigured:
    await sleepMs(10)
  logInfo "USB CDC VDMA configured"

  var echo: array[EchoChunk, byte]
  var offset = 0
  while offset < PayloadBytes:
    let count = min(EchoChunk, PayloadBytes - offset)
    for i in 0 ..< count:
      let index = offset + i
      let expected = byte(((index * 73) xor (index shr 3)) and 0xff)
      let received = await cdc.recv()
      if received != expected:
        logError "[FAIL] Native USB CDC RX mismatch at ": lInt(index)
        return
      echo[i] = received
    while not cdc.trySend(echo.toOpenArray(0, count - 1)):
      await sleepMs(1)
    offset += count

  logInfo "[PASS] USB CDC VDMA RX verified and echo queued"
  logInfo "=== Test Complete ==="

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(baudRate: ConsoleBaud,
    dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)
  logInit(console)
  schedulerInit()
  logInfo "=== BL808 Native USB CDC VDMA Test ==="
  discard runEcho(initUsbCdc())
  runScheduler()
