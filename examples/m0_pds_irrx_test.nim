## M0 PDS+IRRX test — verifies IR RX wake resumes PDS sleep and asserts IRRX.
##
## Build: nim c -d:bl808m0 -d:bl808kernel examples/m0_pds_irrx_test.nim
## Run:
##   /Users/gabriel/Documents/nimlang/qemu-bl808/build/qemu-system-riscv64 \
##     -M bl808 \
##     -qmp unix:/tmp/bl808-qmp.sock,server=on,wait=off -nographic \
##     -icount shift=0,align=off,sleep=on \
##     -kernel examples/m0_pds_irrx_test
##   printf '%s\n%s\n%s\n%s\n' '{"execute":"qmp_capabilities"}' \
##     '{"execute":"qom-set","arguments":{"path":"/machine","property":"irrx-data","value":2774139135}}' \
##     '{"execute":"qom-set","arguments":{"path":"/machine","property":"irrx-bitcount","value":32}}' \
##     '{"execute":"qom-set","arguments":{"path":"/machine","property":"irrx-inject","value":true}}' \
##     | nc -U /tmp/bl808-qmp.sock

import bl808/startup
import bl808/core
import bl808/irq
import bl808/mmio
import bl808/glb, bl808/gpio, bl808/uart, bl808/pds, bl808/ir
import bl808/kernel/log
import bl808/kernel/clock
from std/volatile import volatileLoad, volatileStore

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  DefaultClkHz = 32_000_000'u32
  MinWakeMs = 1'u64
  MaxWakeMs = 2_000'u64
  TestData = 0xA55A_00FF'u32
  TestBits = 32'u32

  PdsWakeSrcIrRx = 1'u32 shl 14
  PdsWakeEventIrRx = 1'u32 shl 25
  IrRxEndIntBit = 1'u32 shl IrRxEndInt

var
  console: Uart
  pdsWakeCountStorage: uint32
  irRxCountStorage: uint32
  pdsIntSnapshotStorage: uint32
  irRxStatusSnapshotStorage: uint32
  irRxDataSnapshotStorage: uint32
  irRxBitsSnapshotStorage: uint32

proc loadCounter(cell: ptr uint32): uint32 {.inline.} =
  volatileLoad(cell)

proc storeCounter(cell: ptr uint32, value: uint32) {.inline.} =
  volatileStore(cell, value)

proc pdsWakeCount(): uint32 {.inline.} =
  loadCounter(cast[ptr uint32](addr pdsWakeCountStorage))

proc irRxCount(): uint32 {.inline.} =
  loadCounter(cast[ptr uint32](addr irRxCountStorage))

proc pdsIntSnapshot(): uint32 {.inline.} =
  loadCounter(cast[ptr uint32](addr pdsIntSnapshotStorage))

proc irRxStatusSnapshot(): uint32 {.inline.} =
  loadCounter(cast[ptr uint32](addr irRxStatusSnapshotStorage))

proc irRxDataSnapshot(): uint32 {.inline.} =
  loadCounter(cast[ptr uint32](addr irRxDataSnapshotStorage))

proc irRxBitsSnapshot(): uint32 {.inline.} =
  loadCounter(cast[ptr uint32](addr irRxBitsSnapshotStorage))

proc onPdsWake() {.cdecl.} =
  let countPtr = cast[ptr uint32](addr pdsWakeCountStorage)
  let pdsIntPtr = cast[ptr uint32](addr pdsIntSnapshotStorage)

  storeCounter(pdsIntPtr, regRead(PdsInt))
  storeCounter(countPtr, loadCounter(countPtr) + 1'u32)
  pdsClearIrq()

proc onIrRx() {.cdecl.} =
  let countPtr = cast[ptr uint32](addr irRxCountStorage)
  let statusPtr = cast[ptr uint32](addr irRxStatusSnapshotStorage)
  let dataPtr = cast[ptr uint32](addr irRxDataSnapshotStorage)
  let bitsPtr = cast[ptr uint32](addr irRxBitsSnapshotStorage)

  storeCounter(statusPtr, regRead(IrRxIntSts))
  storeCounter(dataPtr, regRead(IrRxDataWord0))
  storeCounter(bitsPtr, irRxGetBitCount())
  storeCounter(countPtr, loadCounter(countPtr) + 1'u32)
  regSet(IrRxIntSts, 1'u32 shl IrRxEndClr)

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
  registerTrapHandler(IrqM0IrRx, onIrRx)
  clicSetLevel(IrqM0PdsWakeup, 2)
  clicSetLevel(IrqM0IrRx, 1)
  clicEnableIrq(IrqM0PdsWakeup)
  clicEnableIrq(IrqM0IrRx)
  csrWriteMie(csrReadMie() or (1'u32 shl 11))
  enableInterrupts()

  pdsClearIrq()
  regSet(IrRxIntSts, 1'u32 shl IrRxEndClr)
  regClear(IrRxIntSts, 1'u32 shl IrRxEndMask)
  regSet(IrRxIntSts, 1'u32 shl IrRxEndEn)
  irRxInit(irNec)
  irRxEnable()

  regWrite(PdsInt, PdsWakeSrcIrRx)

  logInfo "=== BL808 PDS+IRRX Test ==="
  logInfo "Enabling IR RX end interrupt and PDS IRRX wake"
  logInfo "Entering PDS sleep forever, waiting for host-injected IR frame"

  let beforeMs = ticksToMs(readTick())
  pdsSleep(0, {})
  let afterMs = ticksToMs(readTick())
  let sleptMs = afterMs - beforeMs

  var settle = 1_000_000'u32
  while irRxCount() == 0 and settle != 0:
    settle.dec

  let wakeIrqs = pdsWakeCount()
  let irIrqs = irRxCount()
  let pdsSnapshot = pdsIntSnapshot()
  let irSnapshot = irRxStatusSnapshot()
  let irData = irRxDataSnapshot()
  let irBits = irRxBitsSnapshot()
  let irFinal = regRead(IrRxIntSts)

  logInfo "Slept for ": lU64(sleptMs); lStr(" ms")
  logInfo "PDS wake IRQ count: ": lU32(wakeIrqs)
  logInfo "IRRX IRQ count: ": lU32(irIrqs)
  logInfo "PDS_INT snapshot=0x": lHex(pdsSnapshot)
  logInfo "IRRX_INT_STS snapshot=0x": lHex(irSnapshot)
  logInfo "IRRX_DATA_WORD0 snapshot=0x": lHex(irData)
  logInfo "IRRX_DATA_COUNT snapshot=0x": lHex(irBits)
  logInfo "IRRX_INT_STS final=0x": lHex(irFinal)

  if wakeIrqs == 1 and
      irIrqs == 1 and
      sleptMs >= MinWakeMs and sleptMs <= MaxWakeMs and
      (pdsSnapshot and PdsWakeEventIrRx) != 0 and
      (irSnapshot and IrRxEndIntBit) != 0 and
      irData == TestData and
      irBits == TestBits and
      (irFinal and IrRxEndIntBit) == 0:
    logInfo "[PASS] IR RX wake resumed PDS sleep"
  else:
    logError "[FAIL] Unexpected PDS/IRRX wake behavior"

  logInfo ""
  logInfo "=== Test Complete ==="

  while true:
    wfi()
