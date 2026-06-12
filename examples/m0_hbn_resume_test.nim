## Measured hibernation resume (logic validation).
##
## Proves the resume-descriptor MAC core: arm a measured resume, confirm the
## BootROM fast path is armed to a TRUSTED entry, validate the descriptor, and
## prove every tamper (resume entry, app PC, MAC tag) is rejected. The full
## HBN sleep/wake round-trip is an HW integration on top of this core; here the
## arm and validate run in one boot where the soft vault root is stable.

import bl808/startup, bl808/core
import bl808/mmio
import bl808/glb, bl808/gpio, bl808/uart, bl808/pds
import bl808/enclave/enclave, bl808/enclave/partition, bl808/enclave/vault
import bl808/enclave/hibernate
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  ResumeEntry  = 0x58000000'u32   # trusted secure resume stub (flash XIP base)
  AppResumePc  = 0x58004321'u32   # where the app would resume

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

# Direct access to the descriptor in HBN retention RAM for tamper injection.
proc slot(): ptr HbnResumeDescriptor = cast[ptr HbnResumeDescriptor](HbnResumeSlot)

proc validates(): bool =
  var pc: uint32
  enclaveValidateHbnResume(pc)

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
  line("=== BL808 Measured HBN Resume ===")

  let ready = enclaveInit(defaultPartition(lock = false), rkSoftDev)
  check("enclaveInit (vault root established)", ready)

  # Arm a measured resume.
  let armed = enclaveArmHbnResume(ResumeEntry, AppResumePc)
  check("enclaveArmHbnResume succeeded", armed)
  check("warm-boot fast path armed", enclaveHbnResumeArmed())
  check("HbnRsv0 holds EHBN magic", regRead(HbnRsv0) == HbnWarmBootMagicEhbn)
  check("HbnRsv1 holds the trusted resume entry", regRead(HbnRsv1) == ResumeEntry)

  # Genuine descriptor validates and yields the verified app PC.
  var pc = 0'u32
  let ok = enclaveValidateHbnResume(pc)
  check("genuine resume descriptor validates", ok)
  check("validated app resume PC matches", pc == AppResumePc)
  kv("[M0] resume PC = ", pc)

  # Tamper 1: flip the app resume PC -> MAC must reject.
  let savedPc = slot().appResumePc
  slot().appResumePc = savedPc xor 0x100'u32
  fenceIo()
  check("tampered app PC rejected", not validates())
  slot().appResumePc = savedPc; fenceIo()
  check("restore -> validates again", validates())

  # Tamper 2: flip the trusted resume entry -> reject.
  let savedEntry = slot().resumeEntry
  slot().resumeEntry = savedEntry xor 0xABCD'u32
  fenceIo()
  check("tampered resume entry rejected", not validates())
  slot().resumeEntry = savedEntry; fenceIo()

  # Tamper 3: flip one MAC tag byte -> reject.
  let savedTag0 = slot().tag[0]
  slot().tag[0] = savedTag0 xor 0xFF'u8
  fenceIo()
  check("tampered MAC tag rejected", not validates())
  slot().tag[0] = savedTag0; fenceIo()
  check("restore tag -> validates again", validates())

  # Clear disarms the fast path and invalidates the descriptor.
  enclaveClearHbnResume()
  check("clear disarms warm-boot magic", not hbnWarmBootMagicArmed())
  check("clear invalidates descriptor", not enclaveHbnResumeArmed())

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0: line("=== Test Complete ===")
  else: line("=== Test Failed ===")
  while true: wfi()
