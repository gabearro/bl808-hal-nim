## Validate that the 0.90 V HBN AON LDO level is the LP (E902) domain's level.
##
## M0 releases the LP running lp_ldo_0p9_probe, which lowers the shared AON LDO11 to
## 0.90 V and keeps counting in XRAM. M0 stays alive and watches: if the LP's counter
## advances past the post-drop RunBase, the LP SURVIVED 0.90 V (where the flash-XIP M0
## crashes) -> 0.90 V deep hibernate is the LP/low-power domain's level. If the counter
## stays stuck at the BootMark, the LP died at the drop.

import bl808/startup
import bl808/core, bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  LpCounter = XramBase + 0x3F10'u
  BootMark  = 0xAAAA_0000'u32
  RunMask   = 0xFFFF_0000'u32
  RunBase   = 0xBBBB_0000'u32

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
  line("=== BL808 LP AON-LDO 0.90 V Survival ===")

  shWrite(LpCounter, 0xFFFFFFFF'u32)        # sentinel
  mmPowerOn()
  line("[M0] Releasing LP (E902) 0.90 V LDO probe")
  releaseLP()

  # Wait for the LP to boot (write BootMark).
  var booted = false
  for _ in 0 ..< 300:
    delayUs(10_000)
    if shRead(LpCounter) != 0xFFFFFFFF'u32: booted = true; break
  kv("[M0] LP counter after boot = ", shRead(LpCounter))
  check("LP booted and wrote the boot mark", booted)

  # Watch the counter cross into the post-LDO-drop RunBase range and keep advancing.
  var sawRun = false
  var c0 = 0'u32
  for _ in 0 ..< 400:                       # up to ~4 s
    delayUs(10_000)
    let v = shRead(LpCounter)
    if (v and RunMask) == RunBase:
      sawRun = true; c0 = v; break
  kv("[M0] LP counter (post-drop) = ", shRead(LpCounter))
  check("LP reached the post-0.90V-drop run loop", sawRun)

  # Confirm it keeps advancing at 0.90 V (genuinely alive, not a stuck value).
  let a = shRead(LpCounter)
  delayUs(200_000)
  let b = shRead(LpCounter)
  kv("[M0] LP counter sample A = ", a)
  kv("[M0] LP counter sample B = ", b)
  check("LP keeps running at 0.90 V AON LDO (counter advances)",
        sawRun and b != a and (b and RunMask) == RunBase)

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0: line("=== Test Complete ===")
  else: line("=== Test Failed ===")
  while true: wfi()
