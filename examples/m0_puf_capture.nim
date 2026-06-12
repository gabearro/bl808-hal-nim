## SRAM-PUF cold-boot capture (M0).
##
## Built with the PUF linker (everything in WRAM/flash), so OCRAM is read back
## exactly as it powered up. Reports the 1-bit fraction (a viable PUF source has
## roughly half its bits set, not 0 = zeroed or 1 = stuck) plus a hash, and
## streams the 4 KB PUF window as hex framed by @PUF_BEGIN/@PUF_END for the host
## collector (tools/puf/puf_collect.py) to gather across cold power cycles.

import bl808/startup, bl808/core
import bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  PufBase = OcramBase + 0x2000'u  # capture window @ 0x22022000 (uninitialised SRAM,
                                  # past the first-4KB boot scratch; chunk 1 ~50% varies)
  PufWords = 1024               # 4 KB window
  FullWords = 16384             # full 64 KB OCRAM (for the popcount summary)
  ChunkWords = 2048             # 8 KB per chunk (8 chunks across 64 KB)

var console: Uart

proc popcount32(x: uint32): int {.inline.} =
  var v = x
  v = v - ((v shr 1) and 0x55555555'u32)
  v = (v and 0x33333333'u32) + ((v shr 2) and 0x33333333'u32)
  v = (v + (v shr 4)) and 0x0F0F0F0F'u32
  (((v * 0x01010101'u32) shr 24) and 0xFF).int

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

  # Capture OCRAM ONCE, immediately, into a WRAM buffer, BEFORE anything else
  # touches it. Then re-print the frame in a loop so the host collector catches
  # it even after the USB-serial re-enumerates a couple seconds post-power-up.
  var ones = 0
  var hash = 0x811C9DC5'u32
  let p = cast[ptr UncheckedArray[uint32]](PufBase)
  for i in 0 ..< FullWords:
    let w = p[i]
    ones += popcount32(w)
    hash = (hash xor w) * 0x01000193'u32
  let pw = cast[ptr UncheckedArray[uint32]](PufBase)
  var window: array[PufWords, uint32]   # WRAM snapshot of the PUF window
  for i in 0 ..< PufWords:
    window[i] = pw[i]
  # Per-8KB-chunk popcount: a chunk whose popcount varies across cold boots is
  # uninitialized SRAM (PUF-viable); a constant one is deterministic.
  var chunkOnes: array[8, int]
  for c in 0 ..< 8:
    var n = 0
    for i in 0 ..< ChunkWords:
      n += popcount32(p[c * ChunkWords + i])
    chunkOnes[c] = n

  discard console.sendLine("")
  discard console.sendLine("=== BL808 SRAM PUF Capture ===")

  let totalBits = FullWords * 32

  proc emitFrame() =
    discard console.sendString("[PUF] ocram64k_ones=")
    console.sendHex32(ones.uint32)
    discard console.sendString(" of_")
    console.sendHex32(totalBits.uint32)
    discard console.sendString(" hash=")
    console.sendHex32(hash)
    discard console.sendLine("")
    discard console.sendString("[PUF] ones_pct_x100=")
    console.sendHex32((ones.uint32 * 10000'u32) div totalBits.uint32)
    discard console.sendLine("")
    discard console.sendString("[PUF] chunk_ones=")
    for c in 0 ..< 8:
      console.sendHex32(chunkOnes[c].uint32)
      discard console.sendString(" ")
    discard console.sendLine("")
    discard console.sendLine("@PUF_BEGIN")
    for i in 0 ..< PufWords:
      console.sendHex32(window[i])
      if (i and 7) == 7:
        discard console.sendLine("")
    discard console.sendLine("")
    discard console.sendLine("@PUF_END")
    discard console.sendLine("=== Capture Complete ===")

  # Re-emit the captured frame periodically so the collector catches it after a
  # reconnect. The data is the snapshot taken once at boot; this does not re-read
  # OCRAM, so the fingerprint stays the cold-boot value.
  while true:
    emitFrame()
    for _ in 0 ..< 30_000_000:
      {.emit: "__asm__ volatile(\"nop\");".}
