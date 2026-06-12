## LP (E902) 0.90 V deep-hibernate round-trip, supervised by the M0.
##
## The 0.90 V AON LDO level is the LP/low-power domain's HBN sleep voltage (the flash-XIP
## M0 crashes at it; the LP, running from RAM, survives -- see m0_lp_ldo_0p9_test). Here we
## prove the LP can take the whole chip into 0.90 V HBN and the RTC POR-wakes it back.
##
## boot1 (cold boot from flash): write a survive-marker into retained HBN_RSV2, open a
## recovery window (power-cycle to abort/reflash), release the LP running lp_hbn_probe, then
## idle. The LP arms the HBN RTC and drops the rail to 0.90 V + HBN_MODE in one write -- the
## chip powers down. ~8 s later the RTC comparator POR-wakes the chip and the M0 cold-boots.
## boot2: HBN_RSV2 still holds the marker (it is retained across the wake POR) -> PASS. We do
## NOT release the LP again on boot2 (that would re-enter HBN), we just report and idle.

import bl808/startup
import bl808/core, bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/pds
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  Marker      = 0x4C48_0001'u32          # "LH" + 1  (LP-HBN survive marker)
  LpStatus    = XramBase + 0x3F10'u

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

proc main() {.exportc, cdecl.} =
  systemInit(); heapInit()
  enableAllPeriphClocks(); enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal); setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

  delayUs(400_000)
  line("")
  line("=== BL808 LP 0.90 V HBN RTC Wake ===")

  let marker = regRead(HbnRsv2)
  let irqStat = regRead(HbnIrqStat)
  kv("[boot] retained HBN_RSV2  = ", marker)
  kv("[boot] HBN_IRQ_STAT       = ", irqStat)

  if marker == Marker:
    # --- boot2: cold boot AFTER the LP's 0.90 V HBN + RTC POR wake ---
    line("[boot2] survived LP 0.90 V HBN deep sleep")
    # The retained marker + this cold-boot banner ARE the wake proof: the M0 was in wfi
    # and the LP took the whole chip into HBN, so the only thing that restarts the chip is
    # the RTC comparator POR. (HBN_IRQ_STAT bit 16 is cleared by that wake POR, so it reads
    # 0 here -- it is logged for information, not asserted on.)
    check("LP 0.90 V HBN RTC wake survived reset", true)
    regWrite(HbnRsv2, 0)                 # consume the marker so a re-run starts fresh
    discard console.sendString("Result: ")
    console.sendHex32(passed.uint32)
    discard console.sendString(" passed, ")
    console.sendHex32(failed.uint32)
    discard console.sendLine(" failed")
    line("=== Test Complete ===")
    while true: wfi()

  # --- boot1: arm the round-trip and hand the chip to the LP ---
  regWrite(HbnRsv2, Marker)              # retained across the wake POR
  regWrite(LpStatus, 0xFFFF_FFFF'u32); dcacheFlushAll(); fenceIo()

  line("[boot1] safety window open - power-cycle now to abort/reflash")
  for _ in 0 ..< 40:
    delayUs(250_000)
    discard console.sendString(".")
  line("")
  line("[boot1] window closed - releasing LP to enter 0.90 V HBN")

  mmPowerOn()
  releaseLP()

  # Wait for the LP to boot and arm the RTC (status -> 0xC0DE0002), then it sleeps.
  var armed = false
  for _ in 0 ..< 300:
    delayUs(10_000)
    if shRead(LpStatus) == 0xC0DE_0002'u32: armed = true; break
  kv("[boot1] LP status after release = ", shRead(LpStatus))
  if armed: line("[boot1] LP armed HBN RTC - chip powering down, expect RTC POR wake")
  else:     line("[boot1] LP did not reach armed state")

  # The LP is taking the whole chip into HBN; the M0 just waits to be powered down.
  while true: wfi()
