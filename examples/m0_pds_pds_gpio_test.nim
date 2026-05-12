## M0 PDS+PDS_GPIO test — verifies the native PDS GPIO wake path resumes PDS.
##
## Build: nim c -d:bl808m0 -d:bl808kernel examples/m0_pds_pds_gpio_test.nim
## Run:
##   /Users/gabriel/Documents/nimlang/qemu-bl808/build/qemu-system-riscv64 \
##     -M bl808,gpio16-driven=on \
##     -qmp unix:/tmp/bl808-qmp.sock,server=on,wait=off -nographic \
##     -icount shift=0,align=off,sleep=on \
##     -kernel examples/m0_pds_pds_gpio_test
##   printf '%s\n%s\n' '{"execute":"qmp_capabilities"}' \
##     '{"execute":"qom-set","arguments":{"path":"/machine","property":"gpio16-level","value":true}}' \
##     | nc -U /tmp/bl808-qmp.sock

import bl808/startup
import bl808/core
import bl808/irq
import bl808/mmio
import bl808/glb, bl808/gpio, bl808/uart, bl808/pds
import bl808/kernel/log
import bl808/kernel/clock
from std/volatile import volatileLoad, volatileStore

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  DefaultClkHz = 32_000_000'u32
  TestPin = 16'u32
  MinWakeMs = 1'u64
  MaxWakeMs = 2_000'u64

  PdsWakeSrcPdsGpio = 1'u32 shl 13
  PdsWakeEventPdsGpio = 1'u32 shl 24
  PdsGpioStatGpio16 = 1'u32 shl 9
  PdsGpioIeGroup16To23 = 1'u32 shl 1
  PdsGpioSet2Clr = 1'u32 shl 10
  PdsGpioSet2ModeShift = 12
  PdsGpioAsyncRising = 9'u32

var
  console: Uart
  pdsWakeCountStorage: uint32
  pdsIntSnapshotStorage: uint32
  pdsGpioStatSnapshotStorage: uint32

proc loadCounter(cell: ptr uint32): uint32 {.inline.} =
  volatileLoad(cell)

proc storeCounter(cell: ptr uint32, value: uint32) {.inline.} =
  volatileStore(cell, value)

proc pdsWakeCount(): uint32 {.inline.} =
  loadCounter(cast[ptr uint32](addr pdsWakeCountStorage))

proc pdsIntSnapshot(): uint32 {.inline.} =
  loadCounter(cast[ptr uint32](addr pdsIntSnapshotStorage))

proc pdsGpioStatSnapshot(): uint32 {.inline.} =
  loadCounter(cast[ptr uint32](addr pdsGpioStatSnapshotStorage))

proc pdsClearGpioSet2Irq() =
  regClear(PdsGpioInt, PdsGpioSet2Clr)
  regSet(PdsGpioInt, PdsGpioSet2Clr)
  regClear(PdsGpioInt, PdsGpioSet2Clr)

proc onPdsWake() {.cdecl.} =
  let countPtr = cast[ptr uint32](addr pdsWakeCountStorage)
  let pdsIntPtr = cast[ptr uint32](addr pdsIntSnapshotStorage)
  let pdsGpioStatPtr = cast[ptr uint32](addr pdsGpioStatSnapshotStorage)

  storeCounter(pdsIntPtr, regRead(PdsInt))
  storeCounter(pdsGpioStatPtr, regRead(PdsGpioStat))
  storeCounter(countPtr, loadCounter(countPtr) + 1'u32)
  pdsClearGpioSet2Irq()
  pdsClearIrq()

proc main() {.exportc, cdecl.} =
  systemInit()

  enablePeriphClock(periphUart0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), DefaultClkHz)

  logInit(console)
  registerTrapHandler(IrqM0PdsWakeup, onPdsWake)
  clicSetLevel(IrqM0PdsWakeup, 1)
  clicEnableIrq(IrqM0PdsWakeup)
  csrWriteMie(csrReadMie() or (1'u32 shl 11))
  enableInterrupts()

  gpioInitInput(TestPin, pullDown)
  gpioClearInterrupt(TestPin)
  pdsClearIrq()
  pdsClearGpioSet2Irq()

  regWrite(PdsGpioISet, PdsGpioIeGroup16To23)
  regWrite(PdsGpioPdSet, 0'u32)
  regWrite(PdsGpioInt, PdsGpioAsyncRising shl PdsGpioSet2ModeShift)
  regWrite(PdsInt, PdsWakeSrcPdsGpio)

  logInfo "=== BL808 PDS+PDS_GPIO Test ==="
  logInfo "Arming native PDS GPIO set-2 rising-edge wake on GPIO16"
  logInfo "Entering PDS sleep forever, waiting for host-driven GPIO16 rise"

  let beforeMs = ticksToMs(readTick())
  pdsSleep(0, {})
  let afterMs = ticksToMs(readTick())
  let sleptMs = afterMs - beforeMs
  let wakeIrqs = pdsWakeCount()
  let pdsSnapshot = pdsIntSnapshot()
  let pdsGpioSnapshot = pdsGpioStatSnapshot()
  let pdsGpioAfterClear = regRead(PdsGpioStat)
  let glbPending = gpioInterruptActive(TestPin)

  logInfo "Slept for ": lU64(sleptMs); lStr(" ms")
  logInfo "PDS wake IRQ count: ": lU32(wakeIrqs)
  logInfo "PDS_INT snapshot=0x": lHex(pdsSnapshot)
  logInfo "PDS_GPIO_STAT snapshot=0x": lHex(pdsGpioSnapshot)
  logInfo "PDS_GPIO_STAT after clear=0x": lHex(pdsGpioAfterClear)
  logInfo "GLB GPIO16 pending=": lBool(glbPending)

  if wakeIrqs == 1 and
      sleptMs >= MinWakeMs and sleptMs <= MaxWakeMs and
      (pdsSnapshot and PdsWakeEventPdsGpio) != 0 and
      (pdsGpioSnapshot and PdsGpioStatGpio16) != 0 and
      (pdsGpioAfterClear and PdsGpioStatGpio16) == 0 and
      not glbPending:
    logInfo "[PASS] Native PDS GPIO wake resumed PDS sleep"
  else:
    logError "[FAIL] Unexpected PDS/PDS_GPIO wake behavior"

  logInfo ""
  logInfo "=== Test Complete ==="

  while true:
    wfi()
