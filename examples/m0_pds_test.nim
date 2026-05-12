## M0 PDS sleep test — verifies timed wake from the PDS controller.
##
## Build: nim c -d:bl808m0 -d:bl808kernel examples/m0_pds_test.nim
## Run:
##   qemu-system-riscv32 -M bl808 -nographic \
##     -icount shift=0,align=off,sleep=on \
##     -kernel examples/m0_pds_test

import bl808/startup
import bl808/core
import bl808/irq
import bl808/glb, bl808/gpio, bl808/uart, bl808/pds
import bl808/kernel/log
import bl808/kernel/clock
from std/volatile import volatileLoad, volatileStore

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  DefaultClkHz = 32_000_000'u32
  SleepMs = 100'u32

var console: Uart
var pdsWakeCountStorage: uint32

proc pdsWakeCount(): uint32 {.inline.} =
  volatileLoad(cast[ptr uint32](addr pdsWakeCountStorage))

proc onPdsWake() {.cdecl.} =
  let countPtr = cast[ptr uint32](addr pdsWakeCountStorage)
  volatileStore(countPtr, volatileLoad(countPtr) + 1'u32)
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

  logInfo "=== BL808 PDS Test ==="
  logInfo "Requesting ": lU32(SleepMs); lStr(" ms timed PDS sleep")

  let beforeMs = ticksToMs(readTick())
  pdsSleep(SleepMs, {wakeTimer})
  let afterMs = ticksToMs(readTick())
  let sleptMs = afterMs - beforeMs
  let wakeIrqs = pdsWakeCount()

  logInfo "Slept for ": lU64(sleptMs); lStr(" ms")
  logInfo "PDS wake IRQ count: ": lU32(wakeIrqs)

  if sleptMs >= 80 and sleptMs <= 500 and wakeIrqs == 1:
    logInfo "[PASS] Timed PDS wake resumed execution with IRQ delivery"
  else:
    logError "[FAIL] Unexpected PDS wake behavior"

  logInfo ""
  logInfo "=== Test Complete ==="

  while true:
    wfi()
