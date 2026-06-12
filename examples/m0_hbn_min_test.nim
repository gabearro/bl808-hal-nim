## M0 HBN bisection test — MINIMAL entry, with a recovery safety window.
##
## Enters HBN with the bare minimum: RC32K on + F32K_SEL, arm the RTC comparator,
## set HBN_MODE. LDO / ROOT_CLK / SRAM / DCDC are left at their boot defaults (the
## arm-diag showed those defaults are already LEVEL_0 + POR-twice). This isolates
## whether the no-wake seen with the full vendor HBN_Enable is caused by one of its
## AON-touching steps (0.90 V LDO, ROOT_CLK=RC32M, ...).
##
## RECOVERY: before sleeping, boot 1 prints a ~20 s countdown. If this bricks (no
## wake), power-cycle ONCE; the chip re-prints the countdown, and a JTAG flash of a
## benign image during that window halts the core before it sleeps — no BOOT button.
##
## Detection on wake (clean cold boot after RTC POR): marker in HbnRsv3 + HBN_IRQ_STAT
## bit 16. Required markers include both boot-1 and boot-2 lines, so it only passes on
## a genuine sleep->wake round-trip.

import bl808/startup
import bl808/core, bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/pds
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  Marker        = 0x48424D33'u32       # "3MBH" minimal-HBN marker (fresh; not EHBN/WHBN)
  MarkerSlot    = 2                     # HbnRsv2 — survives the wake cleanly (RSV3 does not)
  SleepSeconds  = 5'u32
  HbnRtcStatBit = 1'u32 shl 16
  WindowTicks   = 40                    # countdown iterations (~20 s real, delayUs is fast)

var console: Uart
proc line(s: string) = discard console.sendLine(s)
proc kv(label: string, v: uint32) =
  discard console.sendString(label); console.sendHex32(v); discard console.sendLine("")

proc initConsole() =
  enableAllPeriphClocks(); enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal); setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

proc enterHbnMinimal(seconds: uint32) {.noreturn.} =
  ## Bare-minimum HBN entry: arm the RTC, then set HBN_MODE. Nothing else touched.
  disableInterrupts()
  # Clean cold boot on wake: RSV0 must be non-magic (no fast-path) AND non-zero
  # (RSV0=0 makes the ROM fail to flash-boot on wake — HW-verified).
  regWrite(HbnRsv0, 0x5A5A_0000'u32)
  regWrite(HbnRsv1, 0x5A5A_0001'u32)
  regWrite(HbnIrqClr, 0xFFFF_FFFF'u32); regWrite(HbnIrqClr, 0); fenceIo()
  hbnPowerOnRc32k()
  regModify(pds.HbnGlb, HbnGlbF32kSelMask, 0)        # F32K_SEL = RC32K
  fenceIo()
  hbnClearRtcCounter()
  let comp = hbnReadRtc() + seconds.uint64 * Rc32kHz
  hbnSetRtcTimer(comp)
  hbnEnableRtcCounter()
  fenceIo()
  # Bisection: add one faithful HBN_Enable step at a time over the working minimal,
  # to find which one breaks the wake. Enable via -d:hbnAdd<Step>.
  when defined(hbnAddSramRet):
    regSet(HbnSram, 1'u32 shl HbnRetramRet)
    regClear(HbnSram, 1'u32 shl HbnRetramSlp)
  when defined(hbnAddLdo):
    regModify(HbnCtl, HbnLdoVoutSelMask shl HbnLdo11AonVoutSelShift,
              HbnLdoLevel0p90V shl HbnLdo11AonVoutSelShift)
    regModify(HbnCtl, HbnLdoVoutSelMask shl HbnLdo11RtVoutSelShift,
              HbnLdoLevel0p90V shl HbnLdo11RtVoutSelShift)
  when defined(hbnAddDcdc):
    regClear(HbnCtl, (1'u32 shl HbnCtlPuDcdcAon) or (1'u32 shl HbnCtlPuDcdc18Aon))
  when defined(hbnAddRootClk):
    regModify(pds.HbnGlb, HbnGlbRootClkSelMask, 0)   # HBN root clk = RC32M
  fenceIo()
  regSet(HbnCtl, 1'u32 shl HbnMode)                  # enter HBN
  while true:
    delayMs(1000)

proc main() {.exportc, cdecl.} =
  systemInit(); heapInit()
  initConsole()
  delayUs(200_000)
  line("")
  line("=== BL808 M0 HBN Minimal ===")

  # Detect the wake via the marker in HbnRsv2 (verified to survive the wake POR;
  # RSV3's low half is clobbered by the boot path, and HBN_IRQ_STAT bit 16 is reset).
  let mark = hbnReadRetention(MarkerSlot)
  kv("[boot] retained marker = ", mark)
  if mark == Marker:
    # ---- Boot 2: woke from minimal HBN via the RTC POR ----
    line("[boot2] survived MINIMAL HBN - cold boot after RTC POR")
    hbnWriteRetention(MarkerSlot, 0)      # consume the marker
    hbnClearIrq()
    line("[PASS] minimal HBN RTC wake survived reset")
    line("=== Test Complete ===")
    while true: wfi()
  else:
    # ---- Boot 1: arm the wake and hibernate ----
    line("[boot1] minimal HBN test - safety window open (power-cycle to abort/reflash)")
    var i = 0
    while i < WindowTicks:
      discard console.sendString(".")
      delayMs(500)
      inc i
    line("")
    line("[boot1] window closed - arming 5 s HBN RTC wake, entering hibernation")
    hbnClearIrq()
    hbnWriteRetention(MarkerSlot, Marker)
    dcacheFlushAll(); fenceIo()
    delayMs(50)
    enterHbnMinimal(SleepSeconds)
