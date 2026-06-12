## TZC cross-master enforcement test (D0 side).
##
## Released by m0_tzc_enforce_test. Signals that it ran, then attempts to read
## M0's secure OCRAM secret and reports the value over XRAM. If TZC denies the
## access by faulting, a tiny silent trap handler halts D0 without printing
## (so an expected denial doesn't look like a crash); M0 then observes the
## result slot unchanged.

import bl808/startup
import bl808/core, bl808/mmio, bl808/memmap
import bl808/panicoverride

const
  SecureAddr   = WramBase + 0x100'u       # 0x22030100 (matches M0 helper)
  D0RanAddr    = XramBase + 0x3F00'u
  D0ResultAddr = XramBase + 0x3F04'u
  D0RanMagic   = 0xD0D0D0D0'u32
  FaultedMark  = 0x0FA017ED'u32

# Silent trap handler: on any D0 trap, mark the result slot and halt without
# touching the UART (avoids a spurious fault banner on an expected denial).
{.emit: """/*TYPESECTION*/
__attribute__((naked, aligned(64)))
void __d0_silent_trap(void) {
  asm volatile(
    "li t0, 0x40003F04\n"     /* D0ResultAddr */
    "li t1, 0x0FA017ED\n"
    "sw t1, 0(t0)\n"
    "fence\n"
    "1: wfi\n"
    "j 1b\n"
  );
}
static void __d0_install_silent_trap(void) {
  asm volatile(
    "la t0, __d0_silent_trap\n"
    "csrw mtvec, t0\n"        /* direct mode */
    ::: "t0"
  );
}
""".}

proc installSilentTrap() {.importc: "__d0_install_silent_trap", nodecl.}

proc shWrite(a: uint, v: uint32) =
  regWrite(a, v); dcacheFlushAll(); fenceIo()

const
  Stage0 = XramBase + 0x3F10'u   # entry marker
  Stage1 = XramBase + 0x3F14'u   # after trap install
  OpenCtrl = XramBase + 0x3F18'u # control: D0 echoes an XRAM read here

proc main() {.exportc, cdecl.} =
  systemInit()
  shWrite(Stage0, 0x11111111'u32)        # D0 reached main
  installSilentTrap()
  shWrite(Stage1, 0x22222222'u32)        # trap installed, XRAM writable

  # Control: prove D0 can do loads from shared memory (read back Stage0).
  shWrite(OpenCtrl, regRead(Stage0))

  # Announce alive before touching the restricted region.
  shWrite(D0RanAddr, D0RanMagic)

  # Attempt the forbidden read. Invalidate first so we'd read M0's real WRAM
  # write if TZC allowed it. If TZC denies by returning data, we report it; if
  # it denies by faulting, the silent trap handler writes FaultedMark.
  dcacheFlushAll(); dcacheInvalidateAll(); fenceIo()
  let v = regRead(SecureAddr)
  shWrite(D0ResultAddr, v)

  discard FaultedMark
  while true:
    wfi()
