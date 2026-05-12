## D0 WL_ALL IRQ routing test.
##
## Build:
##   nim c -d:bl808m0 -d:bl808kernel examples/m0_d0_pds_irq_test.nim
##   nim c -d:bl808d0 -d:bl808kernel examples/d0_wl_all_irq_test.nim
##
## Run:
##   /Users/gabriel/Documents/nimlang/qemu-bl808/build/qemu-system-riscv64 \
##     -M bl808,d0-firmware=examples/d0_wl_all_irq_test \
##     -qmp unix:/tmp/bl808-qmp.sock,server=on,wait=off -nographic \
##     -serial file:/tmp/m0.txt -serial file:/tmp/d0.txt \
##     -kernel examples/m0_d0_pds_irq_test
##   printf '%s\n%s\n' '{\"execute\":\"qmp_capabilities\"}' \
##     '{\"execute\":\"qom-set\",\"arguments\":{\"path\":\"/machine\",\"property\":\"ble-intrawstat-pending\",\"value\":1}}' \
##     | nc -U /tmp/bl808-qmp.sock

import bl808/startup
import bl808/core
import bl808/irq
import bl808/uart
import bl808/kernel/log
import bl808/kernel/clock
from std/volatile import volatileLoad, volatileStore

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  DefaultClkHz = 32_000_000'u32
  TimeoutMs = 2_000'u64

var
  console: Uart
  irqCountStorage: uint32

proc loadCounter(cell: ptr uint32): uint32 {.inline.} =
  volatileLoad(cell)

proc storeCounter(cell: ptr uint32, value: uint32) {.inline.} =
  volatileStore(cell, value)

proc irqCount(): uint32 {.inline.} =
  loadCounter(cast[ptr uint32](addr irqCountStorage))

proc onWlAllIrq() {.cdecl.} =
  let countPtr = cast[ptr uint32](addr irqCountStorage)
  storeCounter(countPtr, loadCounter(countPtr) + 1'u32)

proc main() {.exportc, cdecl.} =
  systemInit()

  console = initUart(uart1, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), DefaultClkHz)

  logInit(console)
  plicInit()
  registerTrapHandler(IrqD0WlAll, onWlAllIrq)
  plicSetPriority(IrqD0WlAll, 1)
  plicEnableIrq(IrqD0WlAll)
  plicSetThreshold(0)
  csrWriteMie(csrReadMie() or (1'u shl 11))
  enableInterrupts()

  logInfo "=== BL808 D0 WL_ALL IRQ Test ==="
  logInfo "Waiting for host-injected BLE wireless event"

  let startMs = ticksToMs(readTick())
  while irqCount() == 0 and (ticksToMs(readTick()) - startMs) < TimeoutMs:
    wfi()

  let finalCount = irqCount()
  logInfo "D0 WL_ALL IRQ count: ": lU32(finalCount)
  if finalCount == 1:
    logInfo "[PASS] D0 WL_ALL IRQ reached the PLIC"
  else:
    logError "[FAIL] Unexpected D0 WL_ALL IRQ behavior"

  while true:
    wfi()
