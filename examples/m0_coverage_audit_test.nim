## Secure-coverage completeness audit (A5).
##
## Per-test assertions elsewhere prove individual protections; this proves the
## INVARIANT that ties them together, so coverage can't silently drift as the
## carveouts move: every secret-bearing region (vault key store, boot
## measurement) lands physically inside the secure RAM window, that window is
## disjoint from everything U-mode can touch (its RAM + the shared buffer), and
## after a LOCKED apply the window reads back as group-0-only, enabled, and
## frozen. Run last in a power cycle — the lock persists until power-on reset.

import bl808/startup, bl808/core
import bl808/mmio
import bl808/glb, bl808/gpio, bl808/uart, bl808/tzc
import bl808/enclave/enclave, bl808/enclave/partition, bl808/enclave/vault
import bl808/enclave/measure
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

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

proc within(a, lo, hi: uint): bool = a >= lo and a < hi
proc spanWithin(start: uint, size: int, lo, hi: uint): bool =
  start >= lo and (start + size.uint) <= hi
proc disjoint(aLo, aHi, bLo, bHi: uint): bool = aHi <= bLo or bHi <= aLo

proc main() {.exportc, cdecl.} =
  systemInit(); heapInit()
  enableAllPeriphClocks(); enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal); setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

  delayUs(400_000)
  line("")
  line("=== BL808 Secure Coverage Audit ===")

  # Initialise the vault/measurement so their storage is live and addressable.
  discard enclaveInit(defaultPartition(lock = false), rkSoftDev)

  let secLo = secureRamStart()
  let secHi = secureRamEnd()
  let uLo = umodeRamStart()
  let uHi = umodeStackTop()
  let shLo = sharedBufStart()
  let shHi = shLo + sharedBufLen()
  kv("[M0] secure RAM start = ", secLo.uint32)
  kv("[M0] secure RAM end   = ", secHi.uint32)
  kv("[M0] vault table @     = ", vaultTableAddr().uint32)
  kv("[M0] boot measure @    = ", bootMeasurementAddr().uint32)

  # 1. The secure window is a real, non-empty region.
  check("secure RAM window non-empty", secLo < secHi)

  # 2. Every secret-bearing region lives inside the secure window.
  check("vault key store inside secure window",
        spanWithin(vaultTableAddr(), vaultTableSize(), secLo, secHi))
  check("boot measurement inside secure window",
        within(bootMeasurementAddr(), secLo, secHi))

  # 3. The secure window is disjoint from everything U-mode can reach.
  check("secure window disjoint from U-mode RAM", disjoint(secLo, secHi, uLo, uHi))
  check("secure window disjoint from shared buffer", disjoint(secLo, secHi, shLo, shHi))
  check("shared buffer is NOT inside the secure window",
        not within(shLo, secLo, secHi))

  # 4. Apply the LOCKED partition, then read the OCRAM window back.
  applyPartition(defaultPartition(lock = true))
  # OCRAM is a width-4 window: each group g owns the bit-pair (0b11 shl 2*g).
  # group-0-only => bits[1:0]=0b11 (group 0 IBUS+DBUS) AND bits[3:2]=0 (group 1
  # denied). 0x3 is therefore the correct "group-0 only" value, not 0x1.
  let grp = tzcWindowRegionGroupField(tzcWinOcram, 0)
  kv("[M0] OCRAM region0 group field = ", grp)
  check("secure OCRAM group-0 allowed (bits[1:0]=0b11)", (grp and 0x3'u32) == 0x3'u32)
  check("secure OCRAM group-1 DENIED (bits[3:2]=0)", (grp and 0xC'u32) == 0'u32)
  check("secure OCRAM window enabled", tzcWindowRegionEnabled(tzcWinOcram, 0))
  check("secure OCRAM window locked", tzcWindowRegionLocked(tzcWinOcram, 0))

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0: line("=== Test Complete ===")
  else: line("=== Test Failed ===")
  while true: wfi()
