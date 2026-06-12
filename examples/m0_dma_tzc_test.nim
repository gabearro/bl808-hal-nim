## DMA cross-master TZC denial test (M0).
##
## DMA exfiltration is the classic enclave bypass: PMP only constrains the CPU,
## not DMA engines, so TZC is the *only* defence against a DMA master reading
## secure RAM. This proves it on silicon:
##   Phase 1 (control): with no restriction, DMA copies the secret out of secure
##     WRAM -> proves the DMA works and can address the region.
##   Phase 2 (enforced): restrict the WRAM region to group 0 and put DMA0 in
##     group 1, repeat -> the DMA must NOT read the secret.

import bl808/startup, bl808/core
import bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart, bl808/dma, bl808/tzc
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  SecretAddr = WramBase + 0x100'u     # 0x22030100, secure WRAM (m0 linker uses OCRAM)
  DstAddr    = XramBase + 0x200'u     # 0x40000200, non-secure DMA destination
  Sentinel   = 0xDEADBEEF'u32
  DstInit    = 0xBADBAD00'u32

var
  console: Uart
  passed = 0
  failed = 0

proc line(s: string) = discard console.sendLine(s)
proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)
  if ok: inc passed else: inc failed

proc dmaCopySecret(dma: Dma): uint32 =
  ## Run a DMA copy of the secret into the non-secure destination and return
  ## what landed there. Cache flush/invalidate around the DMA for coherency.
  regWrite(DstAddr, DstInit)
  dcacheFlushAll(); fenceIo()
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
  line("=== BL808 DMA Cross-Master TZC Test ===")

  enableDma0Clock()
  let dma = initDma(dma0)

  regWrite(SecretAddr, Sentinel)
  dcacheFlushAll(); fenceIo()

  # Phase 1: control — no TZC restriction, DMA should read the secret.
  let got1 = dmaCopySecret(dma)
  discard console.sendString("[M0] control DMA result = ")
  console.sendHex32(got1)
  discard console.sendLine("")
  check("control: DMA reads secret when unrestricted", got1 == Sentinel)

  # Phase 2: enforced — restrict WRAM region 0 to group 0, DMA0 -> group 1.
  tzcSetMasterGroup(tzcMasterDma0, 1, lock = false)
  discard tzcConfigureWindowRegion(tzcWinWram, 0,
    WramBase.uint32, 0x1000, {0.TzcAuthGroup}, lock = false)
  line("[M0] TZC: WRAM region0 -> group0 only; DMA0 -> group1")

  let got2 = dmaCopySecret(dma)
  discard console.sendString("[M0] enforced DMA result = ")
  console.sendHex32(got2)
  discard console.sendLine("")
  check("enforced: TZC denies DMA read of secure WRAM", got2 != Sentinel)

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
