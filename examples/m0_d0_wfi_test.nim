## D0 timed WFI sleep/wake validation (C906 application core).
##
## M0 powers the MM domain and releases the D0 running d0_wfi_probe, which sleeps
## on its CLINT machine timer (WFI, vectored mtvec, IRQ 7) and bumps an XRAM counter
## on each of 40 timed wakes, then raises a Ready flag. M0 stays alive, waits for
## Ready (no race), and asserts the wake count — proving genuine timed C906 WFI wake.

import bl808/startup
import bl808/core, bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  D0Counter  = XramBase + 0x3F18'u
  D0TimeDbg  = XramBase + 0x3F1C'u
  D0Ready    = XramBase + 0x3F44'u
  ReadyMagic = 0xD05E_57E5'u32

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

proc shRead(a: uint): uint32 =
  dcacheFlushAll(); dcacheInvalidateAll(); fenceIo(); regRead(a)
proc shWrite(a: uint, v: uint32) =
  regWrite(a, v); dcacheFlushAll(); fenceIo()

proc main() {.exportc, cdecl.} =
  systemInit(); heapInit()
  enableAllPeriphClocks(); enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal); setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

  delayUs(400_000)
  line("")
  line("=== BL808 D0 Timed WFI Sleep ===")

  shWrite(D0Counter, 0xFFFFFFFF'u32)   # sentinel: D0 overwrites with 0,1,2,...
  shWrite(D0Ready, 0)
  mmPowerOn()
  line("[M0] Releasing D0 (C906) WFI sleep firmware")
  releaseD0()

  # Wait for the D0 to boot and start counting.
  var booted = false
  for _ in 0 ..< 400:
    delayUs(10_000)
    if shRead(D0Counter) != 0xFFFFFFFF'u32: booted = true; break
  check("D0 booted and started its WFI sleep loop", booted)

  # The D0 runs 40 timed WFIs then raises Ready; wait for it (no race). M0's delayUs
  # runs faster than its 32 MHz assumption, so use a generous iteration budget.
  var ready = false
  for _ in 0 ..< 20_000:
    delayUs(10_000)
    if shRead(D0Ready) == ReadyMagic: ready = true; break
  check("D0 finished its timed WFI run (Ready handshake)", ready)

  let wakes = shRead(D0Counter)
  kv("[M0] D0 timer wakes  = ", wakes)
  kv("[M0] last D0 mtime   = ", shRead(D0TimeDbg))
  # 40 wakes expected; allow slack for boot/timing but prove genuine repeated wake.
  check("D0 completed >= 30 timed WFI wakes on its CLINT timer", wakes >= 30'u32)
  check("D0 wake count is exact-ish (<= 45)", wakes <= 45'u32)

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0: line("=== Test Complete ===")
  else: line("=== Test Failed ===")
  while true: wfi()
