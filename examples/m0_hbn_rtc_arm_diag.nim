## SAFE HBN-RTC wake diagnostic — NO sleep, NO brick risk.
##
## Arms the HBN RTC comparator exactly the way pds.hbnEnterRtcWake does (RC32K on,
## F32K_SEL=RC32K, clear/read/set-comp/enable), then stays AWAKE and polls for ~8 s:
##   * does the 40-bit RTC counter actually advance? (RC32K clocking the counter)
##   * does it reach the comparator target?
##   * does HBN_IRQ_STAT bit 16 (the RTC wake event) latch?
## If the event latches here, the comparator path is good and the m0_hbn_rtc_test
## failure was in the HBN power/wake path. If it never latches, the arm itself is
## wrong (counter not running, comp value bad, or comp mode wrong).

import bl808/startup
import bl808/core, bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/pds, bl808/efuse
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  HbnRtcStatBit = 1'u32 shl 16
  WakeSeconds = 1'u32

var console: Uart
proc line(s: string) = discard console.sendLine(s)
proc kv(label: string, v: uint32) =
  discard console.sendString(label); console.sendHex32(v); discard console.sendLine("")
proc check(label: string, ok: bool, passed, failed: var int) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)
  if ok: inc passed else: inc failed

proc main() {.exportc, cdecl.} =
  systemInit(); heapInit()
  enableAllPeriphClocks(); enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal); setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)
  delayUs(300_000)
  line("")
  line("=== BL808 HBN RTC Arm Diagnostic (no sleep) ===")

  var passed, failed = 0

  # --- Validate the efuse RC32K trim (safe; no HBN) ---
  let trimWord = efuseReadWord(0xEC'u32 div 4)
  kv("[trim] efuse W3 raw     = ", trimWord)
  kv("[trim] code[17:8]       = ", (trimWord shr 8) and 0x3FF'u32)
  kv("[trim] parity bit 18    = ", (trimWord shr 18) and 0x1'u32)
  kv("[trim] ext_code_en 19   = ", (trimWord shr 19) and 0x1'u32)
  kv("[trim] RC32K_CTRL0 pre  = ", regRead(HbnRc32kCtrl0))
  hbnPowerOnRc32k()
  hbnTrimRc32k()
  kv("[trim] RC32K_CTRL0 post = ", regRead(HbnRc32kCtrl0))
  check("RC32K efuse trim applied (EXT_CODE_EN set)",
        (regRead(HbnRc32kCtrl0) and (1'u32 shl 19)) != 0, passed, failed)

  # Clear any stale HBN IRQ, then arm exactly like hbnEnterRtcWake.
  hbnClearIrq()
  hbnPowerOnRc32k()
  regModify(pds.HbnGlb, HbnGlbF32kSelMask, 0)    # F32K_SEL = RC32K
  fenceIo()

  hbnClearRtcCounter()
  let c0 = hbnReadRtc()
  kv("[diag] RTC count @arm    = ", (c0 and 0xFFFF_FFFF'u64).uint32)
  let comp = c0 + WakeSeconds.uint64 * Rc32kHz
  hbnSetRtcTimer(comp)
  hbnEnableRtcCounter()
  fenceIo()
  kv("[diag] RTC comp target   = ", (comp and 0xFFFF_FFFF'u64).uint32)
  kv("[diag] HBN_CTL after arm  = ", regRead(HbnCtl))

  # Is the counter advancing? Sample twice ~50 ms apart.
  let s0 = hbnReadRtc()
  delayUs(50_000)
  let s1 = hbnReadRtc()
  kv("[diag] RTC sample 0       = ", (s0 and 0xFFFF_FFFF'u64).uint32)
  kv("[diag] RTC sample 1       = ", (s1 and 0xFFFF_FFFF'u64).uint32)
  check("RTC counter is advancing on RC32K", s1 != s0, passed, failed)

  # Poll until the counter genuinely passes the comparator target (delayUs runs
  # ~4x fast, so use a large cap), tracking whether bit 16 latches and the counter
  # value at the moment it does — to prove the comparator->wake-event causality.
  var reached = false
  var fired = false
  var firedAt = 0'u32
  for i in 0 ..< 40_000:
    delayUs(5_000)
    let cur = hbnReadRtc()
    if cur >= comp: reached = true
    if (regRead(HbnIrqStat) and HbnRtcStatBit) != 0:
      fired = true; firedAt = (cur and 0xFFFF_FFFF'u64).uint32
      break
    if reached and i > 2000: break    # passed target with margin; stop polling
  kv("[diag] HBN_IRQ_STAT final = ", regRead(HbnIrqStat))
  kv("[diag] RTC count final    = ", (hbnReadRtc() and 0xFFFF_FFFF'u64).uint32)
  kv("[diag] RTC count @bit16    = ", firedAt)
  check("RTC counter reached the comparator target", reached, passed, failed)
  check("HBN RTC wake event (HBN_IRQ_STAT bit 16) latched", fired, passed, failed)

  # (The awake 0.90 V/clock/XTAL teardown is intentionally NOT run here: on the
  #  flash-XIP M0 it crashes the core and leaves the chip JTAG-dark. The 0.90 V path
  #  is validated on the LP core instead — see m0_lp_ldo_0p9_test.)

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0: line("=== Diagnostic Complete ===")
  else: line("=== Diagnostic Found Issues ===")
  hbnClearIrq()
  while true: wfi()
