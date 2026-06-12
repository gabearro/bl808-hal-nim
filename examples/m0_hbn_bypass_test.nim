## HBN warm-boot bypass closure (A1).
##
## The BootROM reads HbnRsv0 (0x2000F100) before running flash and, if it holds
## "EHBN" (0x4E424845) or "WHBN" (0x4E424857), takes a warm-boot fast path that
## JUMPS to a retained pointer — skipping our secure stage (verify/measure/TZC
## lock). enclaveInit must defang this on cold boot by clearing the magic.
##
## This plants each magic, proves the BootROM WOULD have taken the fast path
## (hbnWarmBootMagicArmed), runs enclaveInit, and proves the magic is gone.

import bl808/startup, bl808/core
import bl808/mmio
import bl808/glb, bl808/gpio, bl808/uart, bl808/pds
import bl808/enclave/enclave, bl808/enclave/partition, bl808/enclave/vault
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  FakeResumePtr = 0x22050000'u32   # a plausible attacker resume target

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

proc plant(magic: uint32) =
  regWrite(HbnRsv0, magic)
  regWrite(HbnRsv1, FakeResumePtr)
  fenceIo()

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  enableAllPeriphClocks()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

  delayUs(400_000)
  line("")
  line("=== BL808 HBN Warm-Boot Bypass Closure ===")

  # 1. Direct unit check: clearing defangs both magics and the retained pointer.
  plant(HbnWarmBootMagicEhbn)
  check("EHBN planted -> BootROM would warm-boot (armed)", hbnWarmBootMagicArmed())
  kv("[M0] HbnRsv0 (EHBN planted) = ", regRead(HbnRsv0))
  hbnClearWarmBootMagic()
  check("EHBN cleared by hbnClearWarmBootMagic", not hbnWarmBootMagicArmed())
  check("HbnRsv0 zeroed", regRead(HbnRsv0) == 0)
  check("HbnRsv1 (retained ptr) zeroed", regRead(HbnRsv1) == 0)

  plant(HbnWarmBootMagicWhbn)
  check("WHBN planted -> armed", hbnWarmBootMagicArmed())
  hbnClearWarmBootMagic()
  check("WHBN cleared", not hbnWarmBootMagicArmed())

  # 2. Wiring check: enclaveInit itself clears a planted magic on cold boot, so a
  #    stale/hostile warm-boot flag cannot survive secure-world bring-up.
  plant(HbnWarmBootMagicEhbn)
  check("EHBN re-planted before enclaveInit -> armed", hbnWarmBootMagicArmed())
  let ok = enclaveInit(defaultPartition(lock = false), rkSoftDev)
  check("enclaveInit succeeded", ok)
  check("enclaveInit cleared the warm-boot magic", not hbnWarmBootMagicArmed())
  kv("[M0] HbnRsv0 (after enclaveInit) = ", regRead(HbnRsv0))

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0: line("=== Test Complete ===")
  else: line("=== Test Failed ===")
  while true: wfi()
