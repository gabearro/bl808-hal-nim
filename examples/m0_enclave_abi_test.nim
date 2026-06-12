## Enclave ABI confused-deputy hardening test (M0).
##
## A malicious untrusted caller controls the request length (a1) and the length
## fields inside the request (labLen/aadLen/ptLen/ctLen). The dispatcher must
## reject anything out of bounds without reading/writing past the shared buffer
## or faulting. This feeds a battery of adversarial requests directly to
## enclaveDispatch and confirms each returns an error while a valid request still
## works.

import bl808/startup, bl808/core
import bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/umode
import bl808/enclave/abi, bl808/enclave/services, bl808/enclave/vault
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

var
  console: Uart
  passed = 0
  failed = 0
  scratch {.align: 16.}: array[512, uint8]

proc buf(): ptr UncheckedArray[uint8] = cast[ptr UncheckedArray[uint8]](addr scratch[0])
proc cap(): int = scratch.len
proc line(s: string) = discard console.sendLine(s)
proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)
  if ok: inc passed else: inc failed

proc onEcall(f: ptr EcallFrame) {.nimcall.} = discard

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
  enclaveSetEcallDispatch(onEcall)

  line("")
  line("=== BL808 Enclave ABI Hardening Test ===")
  discard vaultInit(rkSoftDev)

  # reqLen larger than the buffer must be rejected outright.
  var (st, _) = enclaveDispatch(svcSha256, cap() + 1000, buf(), cap())
  check("oversized reqLen rejected", st == svcBadRequest)

  # deriveKey with a huge labelLen (overflow attempt) -> rejected, no OOB read.
  wrU32(buf(), 0, vaultRoot().uint32)
  wrU32(buf(), 4, 32)              # outLen
  wrU32(buf(), 8, 0xFFFFFFFF'u32)  # labLen (huge)
  wrU32(buf(), 12, 0)              # ctxLen
  (st, _) = enclaveDispatch(svcDeriveKey, 64, buf(), cap())
  check("deriveKey huge labelLen rejected", st == svcBadRequest)

  wrU32(buf(), 8, 0x7FFFFFFF'u32)  # labLen (overflow boundary)
  (st, _) = enclaveDispatch(svcDeriveKey, 64, buf(), cap())
  check("deriveKey overflow labelLen rejected", st == svcBadRequest)

  # aeadSeal with a huge ptLen -> rejected (no huge alloc / OOB).
  wrU32(buf(), 0, vaultRoot().uint32)
  wrU32(buf(), 4, 16)              # nonceLen
  wrU32(buf(), 8, 0)               # aadLen
  wrU32(buf(), 12, 0xFFFFFFFF'u32) # ptLen (huge)
  (st, _) = enclaveDispatch(svcAeadSeal, 64, buf(), cap())
  check("aeadSeal huge ptLen rejected", st == svcBadRequest)

  wrU32(buf(), 8, 0x40000000'u32)  # aadLen huge
  wrU32(buf(), 12, 16)
  (st, _) = enclaveDispatch(svcAeadSeal, 64, buf(), cap())
  check("aeadSeal huge aadLen rejected", st == svcBadRequest)

  # aeadOpen with a huge ctLen -> rejected.
  wrU32(buf(), 0, vaultRoot().uint32)
  wrU32(buf(), 4, 16)
  wrU32(buf(), 8, 0)
  wrU32(buf(), 12, 0xFFFFFFFF'u32) # ctLen huge
  (st, _) = enclaveDispatch(svcAeadOpen, 64, buf(), cap())
  check("aeadOpen huge ctLen rejected", st == svcBadRequest)

  # A valid sha256 request still works (hardening didn't break normal use).
  buf()[0] = 0x61; buf()[1] = 0x62; buf()[2] = 0x63   # "abc"
  let (st2, n2) = enclaveDispatch(svcSha256, 3, buf(), cap())
  check("valid request still works", st2 == svcOk and n2 == 32 and buf()[0] == 0xBA'u8)

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0: line("=== Test Complete ===")
  else: line("=== Test Failed ===")
  while true: wfi()
