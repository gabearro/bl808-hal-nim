## M0 BLE IRQ routing test.
##
## Build:
##   nim c -d:bl808m0 -d:bl808kernel examples/m0_ble_irq_test.nim
##
## Run:
##   /Users/gabriel/Documents/nimlang/qemu-bl808/build/qemu-system-riscv64 \
##     -M bl808 \
##     -qmp unix:/tmp/bl808-qmp.sock,server=on,wait=off -nographic \
##     -kernel examples/m0_ble_irq_test
##   printf '%s\n%s\n' '{"execute":"qmp_capabilities"}' \
##     '{"execute":"qom-set","arguments":{"path":"/machine","property":"ble-intrawstat-pending","value":1}}' \
##     | nc -U /tmp/bl808-qmp.sock

import bl808/startup
import bl808/core
import bl808/irq
import bl808/glb, bl808/gpio, bl808/uart
import bl808/mmio
import bl808/ble, bl808/blecontroller
import bl808/kernel/log
import bl808/kernel/clock
from std/volatile import volatileLoad, volatileStore

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  DefaultClkHz = 32_000_000'u32
  TimeoutMs = 2_000'u64
  SettleMs = 20'u64
  BleBase = 0x28000000'u
  BleIntcntl = BleBase + 0x0C'u
  BleIntstat = BleBase + 0x10'u
  BleIntrawstat = BleBase + 0x14'u
  BleIntack = BleBase + 0x18'u
  BleBasetimecnt = BleBase + 0x1C'u
  BleFinetimecnt = BleBase + 0x20'u
  BleFineTimerIrq = 0x00000001'u32
  BleBasetimeLatch = 0x80000000'u32

var
  console: Uart
  irqCountStorage: uint32

proc loadCounter(cell: ptr uint32): uint32 {.inline.} =
  volatileLoad(cell)

proc storeCounter(cell: ptr uint32, value: uint32) {.inline.} =
  volatileStore(cell, value)

proc irqCount(): uint32 {.inline.} =
  loadCounter(cast[ptr uint32](addr irqCountStorage))

proc onBleIrq() {.cdecl.} =
  let countPtr = cast[ptr uint32](addr irqCountStorage)
  storeCounter(countPtr, loadCounter(countPtr) + 1'u32)

proc main() {.exportc, cdecl.} =
  systemInit()

  enablePeriphClock(periphUart0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), DefaultClkHz)

  logInit(console)
  registerTrapHandler(IrqM0Ble, onBleIrq)
  clicSetLevel(IrqM0Ble, 1)
  clicEnableIrq(IrqM0Ble)
  csrWriteMie(csrReadMie() or (1'u32 shl 11))
  enableInterrupts()

  regWrite(BleIntack, 0xFFFF_FFFF'u32)
  regWrite(BleIntcntl, BleFineTimerIrq)
  regWrite(BleBasetimecnt, BleBasetimeLatch)

  let baseTime = regRead(BleBasetimecnt)
  let fineTime = regRead(BleFinetimecnt)

  logInfo "=== BL808 M0 BLE IRQ Test ==="
  logInfo "Waiting for host-injected ble-intrawstat-pending=1"

  let startMs = ticksToMs(readTick())
  while irqCount() == 0 and (ticksToMs(readTick()) - startMs) < TimeoutMs:
    wfi()

  let finalCount = irqCount()
  let intstat = regRead(BleIntstat)
  let rawstat = regRead(BleIntrawstat)

  logInfo "BLE IRQ count: ": lU32(finalCount)
  logInfo "BLE_BASETIMECNT=": lHex(baseTime)
  logInfo "BLE_FINETIMECNT=": lHex(fineTime)
  logInfo "BLE_INTSTAT=": lHex(intstat)
  logInfo "BLE_INTRAWSTAT=": lHex(rawstat)

  regWrite(BleIntack, BleFineTimerIrq)

  let clearStartMs = ticksToMs(readTick())
  while (ticksToMs(readTick()) - clearStartMs) < SettleMs:
    discard

  let intstatAfterClear = regRead(BleIntstat)
  let rawstatAfterClear = regRead(BleIntrawstat)
  logInfo "BLE_INTSTAT after clear=": lHex(intstatAfterClear)
  logInfo "BLE_INTRAWSTAT after clear=": lHex(rawstatAfterClear)

  if finalCount == 1 and
      (baseTime and BleBasetimeLatch) == 0 and
      fineTime < 625'u32 and
      (intstat and BleFineTimerIrq) != 0 and
      (rawstat and BleFineTimerIrq) != 0 and
      intstatAfterClear == 0 and
      rawstatAfterClear == 0:
    logInfo "[PASS] Native BLE controller path reached the CLIC"
  else:
    logError "[FAIL] Unexpected native BLE IRQ behavior"

  while true:
    wfi()
