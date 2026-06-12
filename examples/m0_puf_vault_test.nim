## PUF-rooted vault test (B): the SRAM-PUF-derived device key IS the enclave
## vault root, with warm-boot caching.
##
## On a cold boot it reconstructs the root from the pristine SRAM PUF window,
## installs it as the vault root, and caches it; on a warm SWRST it reuses the
## cached root (the SRAM source is no longer pristine). Prints boot kind +
## SHA-256(root) (one-way). The hash must be:
##   - identical across COLD power cycles  -> PUF root is reproducible (the
##     reconstruction itself is already proven by m0_puf_root_test), and
##   - identical on a WARM reboot          -> the cache path reuses it.
##
## Built with -d:bl808puf so OCRAM stays pristine for the PUF window.

import bl808/startup, bl808/core
import bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/puf/helper, bl808/puf/reconstruct
import bl808/enclave/vault, bl808/enclave/sha256
import bl808/panicoverride
import bl808/kernel/alloc
include puf_helper_data

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  PufWindow = OcramBase + 0x2000'u   # 0x22022000, the enrolled window

var console: Uart

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

  var hlp: PufHelper
  hlp.r = PufHelperR
  for i in 0 ..< PufHelperIdx.len:
    hlp.indices[i] = PufHelperIdx[i]
    hlp.offset[i] = PufHelperOff[i]

  # First init: reconstruct (cold) or reuse cache (warm), install as vault root.
  var sha1, sha2: array[32, uint8]
  var warm1, warm2: bool
  let ok1 = vaultInitPufRoot(hlp, PufWindow, sha1, warm1) and
            vaultRoot() != InvalidHandle
  # Second init: the cache is now populated, so this MUST take the warm path and
  # reuse the same root (proves the warm-boot caching logic deterministically;
  # a true warm SWRST that preserves OCRAM exercises the same code).
  let ok2 = vaultInitPufRoot(hlp, PufWindow, sha2, warm2) and
            vaultRoot() != InvalidHandle
  var same = true
  for i in 0 ..< 32:
    if sha1[i] != sha2[i]: same = false

  proc emit() =
    discard console.sendLine("")
    discard console.sendLine("=== BL808 PUF Vault Root Test ===")
    discard console.sendString(if ok1: "[PASS] " else: "[FAIL] ")
    discard console.sendLine("PUF root installed as vault root")
    discard console.sendString("[PUF] firstboot=")
    discard console.sendLine(if warm1: "warm" else: "cold")
    discard console.sendString(if (ok2 and warm2): "[PASS] " else: "[FAIL] ")
    discard console.sendLine("warm-boot path reuses cached root")
    discard console.sendString(if same: "[PASS] " else: "[FAIL] ")
    discard console.sendLine("cached root matches reconstructed root")
    discard console.sendString("[PUF] vaultrootsha=")
    for i in 0 ..< 8:
      console.sendHex32(
        sha1[i*4].uint32 or (sha1[i*4+1].uint32 shl 8) or
        (sha1[i*4+2].uint32 shl 16) or (sha1[i*4+3].uint32 shl 24))
      discard console.sendString(" ")
    discard console.sendLine("")
    discard console.sendLine("=== Vault Root Complete ===")

  # Re-emit so the host catches it after the USB-serial re-enumerates post-boot.
  while true:
    emit()
    for _ in 0 ..< 30_000_000:
      {.emit: "__asm__ volatile(\"nop\");".}
