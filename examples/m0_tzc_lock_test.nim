## TZC lock validation (M0).
##
## The production partition apply locks every assignment until reset. This
## proves the locks actually hold: after locking WRAM region 0 to group 0 and
## DMA0 to group 1, an attempt to re-open the region (grant group 1) and to move
## DMA0 back to group 0 must have NO effect, and a DMA read of the secret must
## still be denied.
##
## NOTE: TZC locks persist across a software reset (cleared only by power-on
## reset), so power-cycle the board before running other TZC tests after this.

import bl808/startup, bl808/core
import bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart, bl808/dma, bl808/tzc
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  SecretAddr = WramBase + 0x100'u
  DstAddr    = XramBase + 0x200'u
  Sentinel   = 0xDEADBEEF'u32
  DstInit    = 0xBADBAD00'u32

var
  console: Uart
  passed = 0
  failed = 0

proc line(s: string) = discard console.sendLine(s)
proc kv(label: string, v: uint32) =
  discard console.sendString(label); console.sendHex32(v); discard console.sendLine("")
proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)
  if ok: inc passed else: inc failed

proc dmaCopySecret(dma: Dma): uint32 =
  regWrite(DstAddr, DstInit); dcacheFlushAll(); fenceIo()
  discard dma.memcopy(0, DstAddr.uint32, SecretAddr.uint32, 4)
  dcacheFlushAll(); dcacheInvalidateAll(); fenceIo()
  regRead(DstAddr)

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  enableAllPeriphClocks()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

  line("")
  line("=== BL808 TZC Lock Validation ===")

  enableDma0Clock()
  let dma = initDma(dma0)
  regWrite(SecretAddr, Sentinel); dcacheFlushAll(); fenceIo()

  # Apply LOCKED partition: WRAM region0 -> group0, DMA0 -> group1, both locked.
  tzcSetMasterGroup(tzcMasterDma0, 1, lock = true)
  discard tzcConfigureWindowRegion(tzcWinWram, 0,
    WramBase.uint32, 0x1000, {0.TzcAuthGroup}, lock = true)
  check("WRAM region 0 reports locked", tzcWindowRegionLocked(tzcWinWram, 0))
  check("DMA denied after locked apply", dmaCopySecret(dma) != Sentinel)

  # Record locked state, then ATTEMPT to undo it (simulating an untrusted re-open).
  let wramCtrlBefore = regRead(TzcSecWramCtrl)
  let dma0GrpBefore = tzcMasterGroup(tzcMasterDma0).uint32
  kv("[M0] WRAM ctrl (locked) = ", wramCtrlBefore)

  tzcSetMasterGroup(tzcMasterDma0, 0, lock = false)              # try: DMA0 -> group0
  discard tzcConfigureWindowRegion(tzcWinWram, 0,               # try: grant group1 too
    WramBase.uint32, 0x1000, {0.TzcAuthGroup, 1.TzcAuthGroup}, lock = false)

  let wramCtrlAfter = regRead(TzcSecWramCtrl)
  let dma0GrpAfter = tzcMasterGroup(tzcMasterDma0).uint32
  kv("[M0] WRAM ctrl (after re-open attempt) = ", wramCtrlAfter)

  # The region-0 group field (bits[3:0]) must be unchanged (still 0x3 = group0
  # only), and DMA0 must still be group 1.
  check("WRAM region-0 group field unchanged by re-open",
        (wramCtrlAfter and 0xF'u32) == (wramCtrlBefore and 0xF'u32))
  check("DMA0 still in group 1 after re-open attempt", dma0GrpAfter == 1'u32)
  check("DMA still denied after re-open attempt", dmaCopySecret(dma) != Sentinel)
  discard dma0GrpBefore

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0:
    line("=== Test Complete ===")
  else:
    line("=== Test Failed ===")
  while true:
    wfi()
