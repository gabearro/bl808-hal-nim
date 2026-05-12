## M0 USB CDC ACM (virtual serial port) test.
##
## QEMU auto-enumerates the device and provides bulk data loopback.
##
## Build: nim c -d:bl808m0 -d:bl808kernel examples/m0_usb_cdc_test.nim
## Run:
##   qemu-system-riscv32 -M bl808 -nographic \
##     -icount shift=0,align=off,sleep=on \
##     -kernel examples/m0_usb_cdc_test

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/cps
import bl808/kernel/log
import bl808/kernel/usbdev
import bl808/kernel/usbcdc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  DefaultClkHz = 32_000_000'u32

var console: Uart

const TestData = [0x48'u8, 0x65, 0x6C, 0x6C, 0x6F,
                  0x20, 0x55, 0x53, 0x42, 0x21]  # "Hello USB!"

proc usbTestTask(cdc: UsbCdc): CpsVoidFuture {.cps.} =
  logInfo "Waiting for USB enumeration..."

  # Wait for QEMU auto-enumeration to complete
  for i in 0 ..< 20:
    await sleepMs(100)
    if usbDevGetState() == usbConfigured:
      break

  if usbDevGetState() == usbConfigured:
    logInfo "[OK] USB device enumerated and configured"
  else:
    logError "[FAIL] USB enumeration timed out"
    return

  # Send data to host (goes to bulk IN FIFO0)
  cdc.send(TestData)
  logInfo "[OK] Sent 10 bytes to host"

  # QEMU loopback: data should appear in bulk OUT FIFO1
  # Wait for loopback data
  await sleepMs(500)

  var rxBuf: array[10, uint8]
  var rxCount = 0
  for i in 0 ..< 10:
    let b = await cdc.recv()
    rxBuf[i] = b
    rxCount.inc

  logInfo "[OK] Received ": lInt(rxCount); lStr(" bytes")

  # Verify loopback
  var match = true
  for i in 0 ..< TestData.len:
    if rxBuf[i] != TestData[i]:
      match = false

  if match:
    logInfo "[PASS] USB CDC loopback verified: Hello USB!"
  else:
    logError "[FAIL] Loopback mismatch"
    for i in 0 ..< TestData.len:
      if rxBuf[i] != TestData[i]:
        logError "  byte ": lInt(i); lStr(": expected "); lHex(TestData[i].uint32); lStr(" got "); lHex(rxBuf[i].uint32)

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
  logInfo "=== BL808 USB CDC Test ==="
  logInfo ""

  schedulerInit()

  let cdc = initUsbCdc()
  logInfo "USB CDC initialized"

  discard usbTestTask(cdc)
  runScheduler()
