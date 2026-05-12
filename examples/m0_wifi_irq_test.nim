## M0 Wi-Fi IRQ routing test.
##
## Build:
##   nim c -d:bl808m0 -d:bl808kernel examples/m0_wifi_irq_test.nim
##
## Run:
##   /Users/gabriel/Documents/nimlang/qemu-bl808/build/qemu-system-riscv64 \
##     -M bl808 \
##     -qmp unix:/tmp/bl808-qmp.sock,server=on,wait=off -nographic \
##     -kernel examples/m0_wifi_irq_test
##   printf '%s\n%s\n' '{\"execute\":\"qmp_capabilities\"}' \
##     '{\"execute\":\"qom-set\",\"arguments\":{\"path\":\"/machine\",\"property\":\"wifi-mac-gen-rx-complete\",\"value\":true}}' \
##     | nc -U /tmp/bl808-qmp.sock

import bl808/startup
import bl808/core
import bl808/irq
import bl808/glb, bl808/gpio, bl808/uart
import bl808/mmio
import bl808/wifi, bl808/wifi_fw
import bl808/kernel/log
import bl808/kernel/clock
from std/volatile import volatileLoad, volatileStore

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  DefaultClkHz = 32_000_000'u32
  TimeoutMs = 2_000'u64
  SettleMs = 20'u64
  MacPlIrqStatus0 = 0x44910000'u
  MacPlIrqHandler = 0x44910040'u
  MachwIntcStatusRaw = 0x44B0806C'u
  MachwIntcStatusAck = 0x44B08070'u
  MachwIntcUnmask = 0x44B08074'u
  MachwIntcGenStatus = 0x44B08080'u
  MachwIntcGenRaw = 0x44B08084'u
  MachwIntcIrqSet = 0x44B08088'u
  MachwIntcIrqStat = 0x44B0808C'u
  MachwIrqGlobalEn = 0x80000000'u32
  MachwIrqGen = 0x00000008'u32
  MachwGenGlobalEn = 0x80000000'u32
  MachwGenRxComplete = 0x00000080'u32
  MacGenHandlerIndex = 61'u32

var
  console: Uart
  irqCountStorage: uint32

proc loadCounter(cell: ptr uint32): uint32 {.inline.} =
  volatileLoad(cell)

proc storeCounter(cell: ptr uint32, value: uint32) {.inline.} =
  volatileStore(cell, value)

proc irqCount(): uint32 {.inline.} =
  loadCounter(cast[ptr uint32](addr irqCountStorage))

proc onWifiIrq() {.cdecl.} =
  let countPtr = cast[ptr uint32](addr irqCountStorage)
  storeCounter(countPtr, loadCounter(countPtr) + 1'u32)

proc clearMacIrqs() =
  regWrite(MachwIntcStatusAck, 0xFFFF_FFFF'u32)
  regWrite(MachwIntcIrqSet, 0xFFFF_FFFF'u32)

proc main() {.exportc, cdecl.} =
  systemInit()

  enablePeriphClock(periphUart0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), DefaultClkHz)

  logInit(console)
  registerTrapHandler(IrqM0Wifi, onWifiIrq)
  clicSetLevel(IrqM0Wifi, 1)
  clicEnableIrq(IrqM0Wifi)
  csrWriteMie(csrReadMie() or (1'u32 shl 11))
  enableInterrupts()

  clearMacIrqs()
  regWrite(MachwIntcIrqStat, MachwGenRxComplete)
  regWrite(MachwIntcGenStatus, MachwGenGlobalEn)
  regWrite(MachwIntcUnmask, MachwIrqGlobalEn or MachwIrqGen)

  logInfo "=== BL808 M0 Wi-Fi IRQ Test ==="
  logInfo "Waiting for host-injected wifi-mac-gen-rx-complete event"

  let startMs = ticksToMs(readTick())
  while irqCount() == 0 and (ticksToMs(readTick()) - startMs) < TimeoutMs:
    wfi()

  let finalCount = irqCount()
  let status0 = regRead(MacPlIrqStatus0)
  let handler = regRead(MacPlIrqHandler)
  let rawStatus = regRead(MachwIntcStatusRaw)
  let genRaw = regRead(MachwIntcGenRaw)

  logInfo "Wi-Fi IRQ count: ": lU32(finalCount)
  logInfo "MAC_PL_IRQ_STATUS0=": lHex(status0)
  logInfo "MAC_PL_IRQ_HANDLER=": lHex(handler)
  logInfo "MACHW_INTC_STATUS_RAW=": lHex(rawStatus)
  logInfo "MACHW_INTC_GEN_RAW=": lHex(genRaw)

  regWrite(MachwIntcStatusAck, MachwIrqGen)
  regWrite(MachwIntcIrqSet, MachwGenRxComplete)

  let clearStartMs = ticksToMs(readTick())
  while (ticksToMs(readTick()) - clearStartMs) < SettleMs:
    discard

  let statusAfterClear = regRead(MacPlIrqStatus0)
  logInfo "MAC_PL_IRQ_STATUS0 after clear=": lHex(statusAfterClear)

  if finalCount == 1 and
      (status0 and MachwIrqGen) != 0 and
      (rawStatus and MachwIrqGen) != 0 and
      (genRaw and MachwGenRxComplete) != 0 and
      handler == MacGenHandlerIndex and
      statusAfterClear == 0:
    logInfo "[PASS] Native Wi-Fi MAC interrupt path reached the CLIC"
  else:
    logError "[FAIL] Unexpected native Wi-Fi MAC IRQ behavior"

  while true:
    wfi()
