## TRNG liveness / health (A3).
##
## Attestation nonces and AEAD/seal nonces depend on the SEC_ENG TRNG; a stuck
## or biased RNG silently destroys those guarantees (repeated nonces). This test
## pulls many samples and asserts the generator is live and unbiased enough to
## rely on: no repeats, no all-zero / all-ones sample, no stuck first word, and
## an aggregate monobit ratio near 0.5. It is a sanity gate, not a NIST suite.

import bl808/startup, bl808/core
import bl808/mmio
import bl808/glb, bl808/gpio, bl808/uart, bl808/sec
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  Samples = 64
  SampleLen = 32

var
  console: Uart
  passed = 0
  failed = 0
  store: array[Samples, array[SampleLen, uint8]]

proc line(s: string) = discard console.sendLine(s)
proc kv(label: string, v: uint32) =
  discard console.sendString(label); console.sendHex32(v); discard console.sendLine("")
proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)
  if ok: inc passed else: inc failed

proc popcount8(x: uint8): int =
  var v = x; var c = 0
  while v != 0: c.inc; v = v and (v - 1)
  c

proc main() {.exportc, cdecl.} =
  systemInit(); heapInit()
  enableAllPeriphClocks(); enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal); setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

  delayUs(400_000)
  line("")
  line("=== BL808 TRNG Health ===")

  # Collect samples; every draw must succeed.
  var drawsOk = true
  for s in 0 ..< Samples:
    if trngFillBuffer(store[s]) != secOk: drawsOk = false
  check("all TRNG draws succeeded", drawsOk)

  # No sample all-zero or all-ones (stuck output).
  var anyStuck = false
  for s in 0 ..< Samples:
    var allZero = true
    var allOne = true
    for b in store[s]:
      if b != 0x00'u8: allZero = false
      if b != 0xFF'u8: allOne = false
    if allZero or allOne: anyStuck = true
  check("no all-zero / all-ones sample", not anyStuck)

  # No two samples identical (repeat => catastrophic for nonces).
  var anyRepeat = false
  for a in 0 ..< Samples:
    for b in (a + 1) ..< Samples:
      var same = true
      for i in 0 ..< SampleLen:
        if store[a][i] != store[b][i]: same = false; break
      if same: anyRepeat = true
  check("no repeated sample", not anyRepeat)

  # No stuck byte position: column j must vary across samples.
  var anyStuckColumn = false
  for j in 0 ..< SampleLen:
    var v0 = store[0][j]
    var varied = false
    for s in 1 ..< Samples:
      if store[s][j] != v0: varied = true; break
    if not varied: anyStuckColumn = true
  check("no stuck byte position across samples", not anyStuckColumn)

  # Aggregate monobit: set-bit ratio over all bits should sit near 0.5.
  var setBits = 0
  for s in 0 ..< Samples:
    for b in store[s]: setBits += popcount8(b)
  let totalBits = Samples * SampleLen * 8
  let pct = (setBits * 100) div totalBits     # integer percent of 1-bits
  kv("[M0] monobit set-bit pct = ", pct.uint32)
  check("monobit ratio in [40,60]%", pct >= 40 and pct <= 60)

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0: line("=== Test Complete ===")
  else: line("=== Test Failed ===")
  while true: wfi()
