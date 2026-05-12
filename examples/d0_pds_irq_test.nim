## D0 PDS IRQ routing test.
##
## Build:
##   nim c -d:bl808m0 -d:bl808kernel examples/m0_d0_pds_irq_test.nim
##   nim c -d:bl808d0 -d:bl808kernel examples/d0_pds_irq_test.nim
##
## Run:
##   /Users/gabriel/Documents/nimlang/qemu-bl808/build/qemu-system-riscv64 \
##     -M bl808,d0-firmware=examples/d0_pds_irq_test \
##     -qmp unix:/tmp/bl808-qmp.sock,server=on,wait=off -nographic \
##     -serial file:/tmp/m0.txt -serial file:/tmp/d0.txt \
##     -kernel examples/m0_d0_pds_irq_test
##   printf '%s\n%s\n' '{\"execute\":\"qmp_capabilities\"}' \
##     '{\"execute\":\"qom-set\",\"arguments\":{\"path\":\"/machine\",\"property\":\"wifi-wakeup-event\",\"value\":true}}' \
##     | nc -U /tmp/bl808-qmp.sock

import bl808/startup
import bl808/core
import bl808/irq
import bl808/mmio
import bl808/uart
import bl808/pds
import bl808/kernel/log
import bl808/kernel/clock
from std/volatile import volatileLoad, volatileStore

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  DefaultClkHz = 32_000_000'u32
  TimeoutMs = 2_000'u64
  PdsWakeBit = 1'u32 shl 0
  PdsWakeEventWifi = 1'u32 shl 26

var
  console: Uart
  irqCountStorage: uint32
  pdsSnapshotStorage: uint32

proc loadCounter(cell: ptr uint32): uint32 {.inline.} =
  volatileLoad(cell)

proc storeCounter(cell: ptr uint32, value: uint32) {.inline.} =
  volatileStore(cell, value)

proc irqCount(): uint32 {.inline.} =
  loadCounter(cast[ptr uint32](addr irqCountStorage))

proc pdsSnapshot(): uint32 {.inline.} =
  loadCounter(cast[ptr uint32](addr pdsSnapshotStorage))

proc onPdsIrq() {.cdecl.} =
  let countPtr = cast[ptr uint32](addr irqCountStorage)
  let snapshotPtr = cast[ptr uint32](addr pdsSnapshotStorage)
  let count = loadCounter(countPtr)

  if count == 0:
    storeCounter(snapshotPtr, regRead(PdsInt))
    plicDisableIrq(IrqD0Pds)
  storeCounter(countPtr, count + 1'u32)
  pdsClearIrq()

proc main() {.exportc, cdecl.} =
  systemInit()

  console = initUart(uart1, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), DefaultClkHz)

  logInit(console)
  pdsClearIrq()
  plicInit()
  registerTrapHandler(IrqD0Pds, onPdsIrq)
  plicSetPriority(IrqD0Pds, 1)
  plicEnableIrq(IrqD0Pds)
  plicSetThreshold(0)
  csrWriteMie(csrReadMie() or (1'u shl 11))
  enableInterrupts()

  logInfo "=== BL808 D0 PDS IRQ Test ==="
  logInfo "Waiting for host-triggered wifi-wakeup-event"

  let startMs = ticksToMs(readTick())
  while irqCount() == 0 and (ticksToMs(readTick()) - startMs) < TimeoutMs:
    wfi()

  let finalCount = irqCount()
  let snapshot = pdsSnapshot()
  logInfo "D0 PDS IRQ count: ": lU32(finalCount)
  logInfo "PDS_INT snapshot=": lHex(snapshot)

  if finalCount >= 1 and
      (snapshot and PdsWakeBit) != 0 and
      (snapshot and PdsWakeEventWifi) != 0:
    logInfo "[PASS] D0 PDS IRQ followed the native PDS wake fabric"
  else:
    logError "[FAIL] Unexpected D0 PDS IRQ behavior"

  while true:
    wfi()
