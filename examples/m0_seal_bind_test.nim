## Seal measurement-binding test (M0).
##
## A sealed blob must only unseal under the same firmware measurement: change
## the boot measurement (simulating different firmware) and the same blob must
## fail to unseal. This proves sealed data is bound to (device root, firmware
## measurement), not just the device.

import bl808/startup, bl808/core
import bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/umode
import bl808/enclave/abi, bl808/enclave/services, bl808/enclave/vault
import bl808/enclave/measure
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

var
  console: Uart
  passed = 0
  failed = 0
  scratch {.align: 16.}: array[256, uint8]

proc buf(): ptr UncheckedArray[uint8] = cast[ptr UncheckedArray[uint8]](addr scratch[0])
proc line(s: string) = discard console.sendLine(s)
proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)
  if ok: inc passed else: inc failed

proc onEcall(f: ptr EcallFrame) {.nimcall.} = discard

const Msg = "sealed-payload"

proc sealMsg(): int =
  for i in 0 ..< Msg.len: buf()[i] = Msg[i].uint8
  let (st, n) = enclaveDispatch(svcSealBlob, Msg.len, buf(), scratch.len)
  if st != svcOk: return -1
  n

proc tryUnseal(sealed: openArray[uint8]): bool =
  ## Returns true if unseal succeeds AND recovers Msg.
  for i in 0 ..< sealed.len: buf()[i] = sealed[i]
  let (st, n) = enclaveDispatch(svcUnsealBlob, sealed.len, buf(), scratch.len)
  if st != svcOk or n != Msg.len: return false
  for i in 0 ..< Msg.len:
    if buf()[i] != Msg[i].uint8: return false
  true

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
  line("=== BL808 Seal Measurement-Binding Test ===")
  discard vaultInit(rkSoftDev)
  discard measureImage()   # establish the boot measurement

  # Seal under the real measurement.
  let n = sealMsg()
  check("sealBlob succeeds", n > 0)
  var sealed: array[64, uint8]
  for i in 0 ..< n: sealed[i] = buf()[i]

  # Unseal under the SAME measurement -> works.
  check("unseal under same measurement recovers plaintext",
        tryUnseal(toOpenArray(sealed, 0, n - 1)))

  # Flip the boot measurement (simulate different firmware) -> unseal must fail.
  let saved0 = bootMeasurement[0]
  bootMeasurement[0] = bootMeasurement[0] xor 0xFF
  check("unseal under DIFFERENT measurement FAILS",
        not tryUnseal(toOpenArray(sealed, 0, n - 1)))

  # Restore -> works again (proves it was the measurement, not corruption).
  bootMeasurement[0] = saved0
  check("unseal works again after restoring measurement",
        tryUnseal(toOpenArray(sealed, 0, n - 1)))

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0: line("=== Test Complete ===")
  else: line("=== Test Failed ===")
  while true: wfi()
