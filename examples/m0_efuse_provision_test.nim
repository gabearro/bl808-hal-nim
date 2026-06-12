## eFuse provision plan byte-exactness (B1, device side).
##
## Bucket-B (eFuse-fundamental) properties can't be proven on silicon without an
## irreversible burn — so we never burn. The next best confidence is to prove the
## burn the framework WOULD apply is exactly correct: run the real (pure)
## computeProvisionPlan on the M0 and check every (word, orMask) against a golden
## vector hand-computed from the ef_data_0 bit layout. NOTHING is written to the
## eFuse here — efuseProgramWord is never called. tools/test_efuse_provision.py
## proves the host packer (sbtool gen-efuse) emits the same words.

import bl808/startup, bl808/core
import bl808/mmio
import bl808/glb, bl808/gpio, bl808/uart, bl808/efuse
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  # Golden values, computed by hand from the bit layout:
  GoldCfg0    = 0x4F400010'u32   # sboot(1<<4)|sedbg(1<<22)|jtag1(3<<24)|jtag0(3<<26)|dbg(4<<28)
  GoldSwUsage = 0x00000200'u32   # sign-mode ECC(2)<<8
  GoldLock    = 0x08020000'u32   # rd slot0(1<<27) | wr slot0(1<<17)
  GoldAllLock = (0xF'u32 shl 27) or (0xF'u32 shl 17)

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

proc planWord(plan: ProvisionPlan, word: uint32): uint32 =
  for i in 0 ..< plan.count:
    if plan.writes[i].word == word: return plan.writes[i].orMask
  0xFFFFFFFF'u32

proc main() {.exportc, cdecl.} =
  systemInit(); heapInit()
  enableAllPeriphClocks(); enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal); setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

  delayUs(400_000)
  line("")
  line("=== BL808 eFuse Provision Plan (DRY-RUN, no burn) ===")

  let spec = ProvisionSpec(
    enableSecureBoot: true, signMode: signEccP256, sfAesMode: sfAesNone,
    disableJtag: true, disableSeDbg: true,
    lockKeySlotsRead: {0}, lockKeySlotsWrite: {0})
  let plan = computeProvisionPlan(spec)

  kv("[M0] cfg0 mask      = ", planWord(plan, 0))
  kv("[M0] sw_usage0 mask = ", planWord(plan, 23))
  kv("[M0] lock mask      = ", planWord(plan, 31))

  check("word indices cfg0=0 sw_usage0=23 lock=31",
        EfWordCfg0.uint32 == 0 and EfWordSwUsage0.uint32 == 23 and EfWordLock.uint32 == 31)
  check("cfg0 byte-exact (0x4F400010)", planWord(plan, 0) == GoldCfg0)
  check("sw_usage0 byte-exact (0x200)", planWord(plan, 23) == GoldSwUsage)
  check("lock word byte-exact (0x08020000)", planWord(plan, 31) == GoldLock)
  check("exactly 3 writes emitted", plan.count == 3)

  # An all-default spec must emit NOTHING (add() drops zero masks), so word 0 is
  # absent and planWord returns the 0xFFFFFFFF "absent" sentinel — not 0.
  let empty = computeProvisionPlan(ProvisionSpec(signMode: signNone))
  check("empty spec -> no writes emitted (no accidental defaults)", empty.count == 0)
  check("empty spec -> cfg0 word absent", planWord(empty, 0) == 0xFFFFFFFF'u32)

  let allSlots = computeProvisionPlan(ProvisionSpec(
    signMode: signNone, lockKeySlotsRead: {0, 1, 2, 3}, lockKeySlotsWrite: {0, 1, 2, 3}))
  check("all-slot lock byte-exact", planWord(allSlots, 31) == GoldAllLock)

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0: line("=== Test Complete ===")
  else: line("=== Test Failed ===")
  while true: wfi()
