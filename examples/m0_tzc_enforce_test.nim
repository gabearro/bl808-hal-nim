## TZC cross-master enforcement test (M0 side).
##
## Proves on silicon that TZC stops a *different bus master* (the D0 / C906
## core) from reading M0's secure WRAM — the cross-master half of isolation
## that PMP cannot provide (PMP only constrains the issuing CPU, not other
## masters or DMA).
##
## M0 writes a secret to OCRAM, restricts OCRAM region 0 to auth group 0 and
## puts D0 in group 1 (then locks), releases D0, and reports what D0 managed to
## read back over XRAM. If D0 reads the secret, TZC failed open.

import bl808/startup
import bl808/core, bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart, bl808/tzc
import bl808/panicoverride
import bl808/kernel/alloc   # pulls baremetal_libc (memcpy for the TZC descriptor copy)

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  # Secret in WRAM (the M0 linker uses OCRAM, not WRAM, so writing here does not
  # corrupt M0's own RAM the way an OCRAM alias would).
  SecureAddr   = WramBase + 0x100'u       # 0x22030100, inside restricted WRAM region 0
  Sentinel     = 0xDEADBEEF'u32
  D0RanAddr    = XramBase + 0x3F00'u
  D0ResultAddr = XramBase + 0x3F04'u
  D0RanMagic   = 0xD0D0D0D0'u32
  NotRead      = 0xFFFFFFFF'u32

var console: Uart

proc line(s: string) = discard console.sendLine(s)
proc shRead(a: uint): uint32 =
  # Invalidate so we re-read what D0 wrote, not M0's stale cache line.
  dcacheFlushAll(); dcacheInvalidateAll(); fenceIo(); regRead(a)
proc shWrite(a: uint, v: uint32) =
  regWrite(a, v); dcacheFlushAll(); fenceIo()

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

  line("")
  line("=== BL808 TZC Cross-Master Test ===")

  # Secret in secure WRAM; D0's report slots in shared XRAM.
  regWrite(SecureAddr, Sentinel)
  shWrite(D0RanAddr, 0)
  shWrite(D0ResultAddr, NotRead)

  # Restrict OCRAM region 0 to group 0; put D0 in group 1 (no lock during
  # bring-up so D0 boot is not disturbed; the OCRAM region grant is the
  # enforcement under test).
  when not defined(tzcDiagNoRestrict):
    # D0's accesses into the MCU domain are tagged with the MM-bus master ID, so
    # that is the master that must be placed in group 1 to deny D0 the WRAM.
    tzcSetMasterGroup(tzcMasterD0, 1, lock = false)
    tzcSetMasterGroup(tzcMasterMmBus, 1, lock = false)
    discard tzcConfigureWindowRegion(tzcWinWram, 0,
      WramBase.uint32, 0x1000, {0.TzcAuthGroup}, lock = false)
    line("[M0] TZC: WRAM region0 -> group0 only; D0+MMbus -> group1")
  else:
    line("[M0] TZC DIAG: no restriction (expect D0 reads sentinel)")
  dcacheFlushAll(); fenceIo()

  mmPowerOn()
  line("[M0] Releasing D0")
  releaseD0()

  const
    Stage0 = XramBase + 0x3F10'u
    Stage1 = XramBase + 0x3F14'u
    OpenCtrl = XramBase + 0x3F18'u
  proc dump(label: string, a: uint) =
    discard console.sendString(label)
    console.sendHex32(shRead(a))
    discard console.sendLine("")

  var spins = 0
  while true:
    let ran = shRead(D0RanAddr)
    if ran == D0RanMagic or spins > 200:
      dump("[M0] D0 stage0=", Stage0)
      dump("[M0] D0 stage1=", Stage1)
      dump("[M0] D0 openctrl=", OpenCtrl)
      dump("[M0] D0 ran=", D0RanAddr)
      let got = shRead(D0ResultAddr)
      discard console.sendString("[M0] D0 read result = ")
      console.sendHex32(got)
      discard console.sendLine("")
      if ran != D0RanMagic:
        line("[FAIL] D0 did not report (timeout)")
        line("=== Test Failed ===")
      elif got == Sentinel:
        line("[FAIL] TZC failed open: D0 read the secret")
        line("=== Test Failed ===")
      else:
        line("[PASS] TZC denied D0 access to secure WRAM")
        line("=== Test Complete ===")
      while true: wfi()
    inc spins
    for _ in 0 ..< 2_000_000:
      {.emit: "__asm__ volatile(\"nop\");".}
