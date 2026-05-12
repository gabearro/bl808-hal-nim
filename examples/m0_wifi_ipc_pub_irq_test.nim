## M0 Wi-Fi IPC PUB IRQ routing test.
##
## Build:
##   nim c -d:bl808m0 -d:bl808kernel examples/m0_wifi_ipc_pub_irq_test.nim
##
## Run:
##   /Users/gabriel/Documents/nimlang/qemu-bl808/build/qemu-system-riscv64 \
##     -M bl808 \
##     -qmp unix:/tmp/bl808-qmp.sock,server=on,wait=off -nographic \
##     -kernel examples/m0_wifi_ipc_pub_irq_test
##   printf '%s\n%s\n' '{\"execute\":\"qmp_capabilities\"}' \
##     '{\"execute\":\"qom-set\",\"arguments\":{\"path\":\"/machine\",\"property\":\"wifi-ipc-status2-pending\",\"value\":2}}' \
##     | nc -U /tmp/bl808-qmp.sock

import bl808/startup
import bl808/core
import bl808/irq
import bl808/glb, bl808/gpio, bl808/uart
import bl808/mmio
import bl808/kernel/log
import bl808/kernel/clock
from std/volatile import volatileLoad, volatileStore

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  DefaultClkHz = 32_000_000'u32
  TimeoutMs = 2_000'u64
  SettleMs = 20'u64
  WifiIpcBase = 0x44800000'u
  WifiIpcStatus = WifiIpcBase + 0x100'u
  WifiIpcUnmaskSet = WifiIpcBase + 0x10C'u
  WifiIpcAck = WifiIpcBase + 0x118'u
  WifiIpcStatus2 = WifiIpcBase + 0x11C'u
  WifiIpcMagic = WifiIpcBase + 0x140'u
  WifiIpcMagicValue = 0x49504332'u32
  WifiIpcMsgBit = 0x00000002'u32

var
  console: Uart
  irqCountStorage: uint32

proc loadCounter(cell: ptr uint32): uint32 {.inline.} =
  volatileLoad(cell)

proc storeCounter(cell: ptr uint32, value: uint32) {.inline.} =
  volatileStore(cell, value)

proc irqCount(): uint32 {.inline.} =
  loadCounter(cast[ptr uint32](addr irqCountStorage))

proc onWifiIpcPubIrq() {.cdecl.} =
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
  registerTrapHandler(IrqM0WifiIpcPub, onWifiIpcPubIrq)
  clicSetLevel(IrqM0WifiIpcPub, 1)
  clicEnableIrq(IrqM0WifiIpcPub)
  csrWriteMie(csrReadMie() or (1'u32 shl 11))
  enableInterrupts()

  regWrite(WifiIpcAck, 0xFFFF_FFFF'u32)
  regWrite(WifiIpcUnmaskSet, WifiIpcMsgBit)

  logInfo "=== BL808 M0 Wi-Fi IPC PUB IRQ Test ==="
  logInfo "Waiting for host-injected wifi-ipc-status2-pending=2"

  let startMs = ticksToMs(readTick())
  while irqCount() == 0 and (ticksToMs(readTick()) - startMs) < TimeoutMs:
    wfi()

  let finalCount = irqCount()
  let magic = regRead(WifiIpcMagic)
  let status = regRead(WifiIpcStatus)
  let status2 = regRead(WifiIpcStatus2)

  logInfo "Wi-Fi IPC PUB IRQ count: ": lU32(finalCount)
  logInfo "WIFI_IPC_MAGIC=": lHex(magic)
  logInfo "WIFI_IPC_STATUS=": lHex(status)
  logInfo "WIFI_IPC_STATUS2=": lHex(status2)

  regWrite(WifiIpcAck, WifiIpcMsgBit)

  let clearStartMs = ticksToMs(readTick())
  while (ticksToMs(readTick()) - clearStartMs) < SettleMs:
    discard

  let status2AfterClear = regRead(WifiIpcStatus2)
  logInfo "WIFI_IPC_STATUS2 after clear=": lHex(status2AfterClear)

  if finalCount == 1 and
      magic == WifiIpcMagicValue and
      (status2 and WifiIpcMsgBit) != 0 and
      status2AfterClear == 0:
    logInfo "[PASS] Native Wi-Fi embedded IPC path reached the CLIC"
  else:
    logError "[FAIL] Unexpected native Wi-Fi embedded IPC behavior"

  while true:
    wfi()
