## M0 HBN test — verifies RTC wake reset flow and HBN_OUT0 IRQ delivery.
##
## Build: nim c -d:bl808m0 -d:bl808kernel examples/m0_hbn_test.nim
## Run:
##   qemu-system-riscv64 -M bl808 -nographic \
##     -icount shift=0,align=off,sleep=on \
##     -kernel examples/m0_hbn_test

import bl808/startup
import bl808/core
import bl808/irq
import bl808/mmio
import bl808/glb, bl808/gpio, bl808/uart, bl808/pds
import bl808/kernel/log
import bl808/kernel/clock
import bl808/kernel/boothealth
from std/volatile import volatileLoad, volatileStore

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  DefaultClkHz = 32_000_000'u32
  SleepMs = 100'u32
  BootMagic = 0x48424E31'u32
  HbnRtcStatBit = 16'u32

var console: Uart
var hbnWakeCountStorage: uint32

proc hbnWakeCount(): uint32 {.inline.} =
  volatileLoad(cast[ptr uint32](addr hbnWakeCountStorage))

proc onHbnOut0() {.cdecl.} =
  let countPtr = cast[ptr uint32](addr hbnWakeCountStorage)
  volatileStore(countPtr, volatileLoad(countPtr) + 1'u32)
  hbnClearIrq()

proc initConsole() =
  enablePeriphClock(periphUart0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), DefaultClkHz)
  logInit(console)

proc main() {.exportc, cdecl.} =
  systemInit()
  initConsole()

  logInfo "=== BL808 HBN Test ==="
  if hbnReadRetention(0) != BootMagic:
    logInfo "First boot: arming 100 ms HBN RTC wake"
    hbnWriteRetention(0, BootMagic)
    hbnEnter(SleepMs)

  logInfo "Second boot: checking retained HBN wake state"
  let initialStat = regRead(HbnIrqStat)
  logInfo "Initial HBN_IRQ_STAT=0x": lHex(initialStat)

  registerTrapHandler(IrqM0HbnOut0, onHbnOut0)
  clicSetLevel(IrqM0HbnOut0, 1)
  clicEnableIrq(IrqM0HbnOut0)
  csrWriteMie(csrReadMie() or (1'u32 shl 11))
  enableInterrupts()

  let startMs = ticksToMs(readTick())
  while hbnWakeCount() == 0 and (ticksToMs(readTick()) - startMs) < 200:
    wfi()

  let wakeCount = hbnWakeCount()
  let finalStat = regRead(HbnIrqStat)
  let bootHealth = bootHealthSnapshot()
  let bootHealthOk = bootHealthRecordValid() and bootHealth.bootCount >= 2'u32
  hbnWriteRetention(0, 0)

  logInfo "HBN OUT0 IRQ count: ": lU32(wakeCount)
  logInfo "Final HBN_IRQ_STAT=0x": lHex(finalStat)
  logInfo "Boot health count: ": lU32(bootHealth.bootCount)

  if wakeCount == 1 and
      (initialStat and (1'u32 shl HbnRtcStatBit)) != 0 and
      (finalStat and (1'u32 shl HbnRtcStatBit)) == 0:
    logInfo "[PASS] HBN RTC wake survived reset and raised HBN_OUT0"
  else:
    logError "[FAIL] Unexpected HBN wake/IRQ behavior"

  if bootHealthOk:
    logInfo "[PASS] Boot health survived HBN reset"
  else:
    logError "[FAIL] Boot health did not survive HBN reset"

  logInfo ""
  logInfo "=== Test Complete ==="

  while true:
    wfi()
