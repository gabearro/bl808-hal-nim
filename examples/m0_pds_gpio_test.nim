## M0 PDS+GPIO test — verifies GLB GPIO IRQ resumes PDS sleep.
##
## Build: nim c -d:bl808m0 -d:bl808kernel examples/m0_pds_gpio_test.nim
## Run:
##   /Users/gabriel/Documents/nimlang/qemu-bl808/build/qemu-system-riscv64 \
##     -M bl808,aon-gpio10-driven=on \
##     -qmp unix:/tmp/bl808-qmp.sock,server=on,wait=off -nographic \
##     -icount shift=0,align=off,sleep=on \
##     -kernel examples/m0_pds_gpio_test
##   printf '%s\n%s\n' '{"execute":"qmp_capabilities"}' \
##     '{"execute":"qom-set","arguments":{"path":"/machine","property":"aon-gpio10-level","value":true}}' \
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
  TestPin = 10'u32
  MinWakeMs = 1'u64
  MaxWakeMs = 2_000'u64

  PdsWakeSrcGlbGpio = 1'u32 shl 12
  PdsWakeEventGlbGpio = 1'u32 shl 23

var
  console: Uart
  pdsWakeCountStorage: uint32
  pdsIntSnapshotStorage: uint32

proc loadCounter(cell: ptr uint32): uint32 {.inline.} =
  volatileLoad(cell)

proc storeCounter(cell: ptr uint32, value: uint32) {.inline.} =
  volatileStore(cell, value)

proc pdsWakeCount(): uint32 {.inline.} =
  loadCounter(cast[ptr uint32](addr pdsWakeCountStorage))

proc pdsIntSnapshot(): uint32 {.inline.} =
  loadCounter(cast[ptr uint32](addr pdsIntSnapshotStorage))

proc onPdsWake() {.cdecl.} =
  let countPtr = cast[ptr uint32](addr pdsWakeCountStorage)
  let pdsIntPtr = cast[ptr uint32](addr pdsIntSnapshotStorage)

  storeCounter(pdsIntPtr, regRead(PdsInt))
  storeCounter(countPtr, loadCounter(countPtr) + 1'u32)
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
  gpioSetInterrupt(TestPin, intRisingEdge)
  pdsClearIrq()

  # Enable only the GLB GPIO wake path so the PDS wake event identifies it.
  regWrite(PdsInt, PdsWakeSrcGlbGpio)

  logInfo "=== BL808 PDS+GPIO Test ==="
  logInfo "Arming GPIO10 rising-edge interrupt"
  logInfo "Entering PDS sleep forever, waiting for host-driven GPIO10 rise"

  let beforeMs = ticksToMs(readTick())
  pdsSleep(0, {})
  let afterMs = ticksToMs(readTick())
  let sleptMs = afterMs - beforeMs
  let wakeIrqs = pdsWakeCount()
  let pdsSnapshot = pdsIntSnapshot()
  let gpioPending = gpioInterruptActive(TestPin)

  logInfo "Slept for ": lU64(sleptMs); lStr(" ms")
  logInfo "PDS wake IRQ count: ": lU32(wakeIrqs)
  logInfo "PDS_INT snapshot=0x": lHex(pdsSnapshot)
  logInfo "GPIO10 pending=": lBool(gpioPending)

  gpioClearInterrupt(TestPin)
  let gpioCleared = gpioInterruptActive(TestPin)

  if wakeIrqs == 1 and
      sleptMs >= MinWakeMs and sleptMs <= MaxWakeMs and
      (pdsSnapshot and PdsWakeEventGlbGpio) != 0 and
      gpioPending and
      not gpioCleared:
    logInfo "[PASS] GLB GPIO wake resumed PDS sleep"
  else:
    logError "[FAIL] Unexpected PDS/GPIO wake behavior"

  logInfo ""
  logInfo "=== Test Complete ==="

  while true:
    wfi()
