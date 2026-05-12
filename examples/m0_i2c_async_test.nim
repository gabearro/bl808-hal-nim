## M0 async I2C test — reads/writes QEMU's built-in EEPROM at address 0x50.
##
## Build: nim c -d:bl808m0 -d:bl808kernel examples/m0_i2c_async_test.nim
## Run:
##   qemu-system-riscv32 -M bl808,attach-default-eeproms=on -nographic \
##     -icount shift=0,align=off,sleep=on \
##     -kernel examples/m0_i2c_async_test

import bl808/startup
import bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/kernel/cps
import bl808/kernel/log
import bl808/kernel/asynci2c
import bl808/i2c

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  DefaultClkHz = 32_000_000'u32
  EepromAddr = 0x50'u8

var console: Uart

proc i2cTestTask(): CpsVoidFuture {.cps.} =
  var ai = initAsyncI2c(i2c0, i2cStandard, DefaultClkHz)
  logInfo "[I2C] Initialized"

  # Write "Hello" to EEPROM at register address 0x00
  var data = [0x48'u8, 0x65, 0x6C, 0x6C, 0x6F]  # "Hello"
  let wErr = await ai.writeRegPtr(EepromAddr, 0x00,
    cast[ptr UncheckedArray[uint8]](addr data[0]), data.len)
  if wErr == i2cOk:
    logInfo "[OK] writeReg 5 bytes to EEPROM"
  else:
    logError "[FAIL] writeReg err=": lInt(wErr.int)

  # Read 5 bytes back from register address 0x00
  var buf: array[5, uint8]
  let rErr = await ai.readRegPtr(EepromAddr, 0x00,
    cast[ptr UncheckedArray[uint8]](addr buf[0]), buf.len)
  if rErr == i2cOk:
    logInfo "[OK] readReg 5 bytes from EEPROM"
  else:
    logError "[FAIL] readReg err=": lInt(rErr.int)

  # Verify
  var match = true
  for i in 0 ..< data.len:
    if buf[i] != data[i]:
      match = false
  if match:
    logInfo "[PASS] Data verified: Hello"
  else:
    logError "[FAIL] Data mismatch"
    logError "  expected": lStr(" "); lHex(data[0].uint32); lStr(" "); lHex(data[1].uint32); lStr(" "); lHex(data[2].uint32); lStr(" "); lHex(data[3].uint32); lStr(" "); lHex(data[4].uint32)
    logError "  got":      lStr(" "); lHex(buf[0].uint32); lStr(" "); lHex(buf[1].uint32); lStr(" "); lHex(buf[2].uint32); lStr(" "); lHex(buf[3].uint32); lStr(" "); lHex(buf[4].uint32)

  # Test NAK: write to non-existent address
  var nakData = [0x42'u8]
  let nakErr = await ai.writePtr(0x99,
    cast[ptr UncheckedArray[uint8]](addr nakData[0]), nakData.len)
  if nakErr == i2cNak:
    logInfo "[PASS] NAK test: non-existent address correctly rejected"
  else:
    logError "[FAIL] NAK test: expected NAK, got err=": lInt(nakErr.int)

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
  logInfo "=== BL808 Async I2C Test ==="
  logInfo ""

  schedulerInit()
  discard i2cTestTask()
  runScheduler()
