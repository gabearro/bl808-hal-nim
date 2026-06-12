## Attestation round-trip test (M0).
##
## Publishes the enclave attestation public key and an attestation quote
## (chip-id ‖ boot-measurement ‖ ECDSA-P256 signature over their hash with the
## supplied nonce) over UART, so a host (tools/puf/.. no -- tools/attest_verify.py)
## can INDEPENDENTLY verify the signature with a standard library. This turns
## "the device produced a signature" into "a third party verified the device's
## attestation", end to end.

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
  scratch {.align: 16.}: array[256, uint8]

proc buf(): ptr UncheckedArray[uint8] = cast[ptr UncheckedArray[uint8]](addr scratch[0])

proc sendHexBytes(c: var Uart, p: ptr UncheckedArray[uint8], off, n: int) =
  const hc = "0123456789abcdef"
  for i in 0 ..< n:
    let b = p[off + i]
    discard c.sendByte(hc[int(b shr 4)].uint8)
    discard c.sendByte(hc[int(b and 0xF)].uint8)

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

  discard console.sendLine("")
  discard console.sendLine("=== BL808 Attestation Round-Trip ===")
  discard vaultInit(rkSoftDev)

  # Publish the attestation public key (x||y, big-endian, 64 bytes).
  if attestationPublicKey(buf()):
    discard console.sendString("ATTEST pubkey=")
    console.sendHexBytes(buf(), 0, 64)
    discard console.sendLine("")

  # Fixed nonce 00..1f for a reproducible verification.
  var nonce {.align: 4.}: array[32, uint8]
  for i in 0 ..< 32: nonce[i] = i.uint8
  for i in 0 ..< 32: buf()[i] = nonce[i]
  let (st, n) = enclaveDispatch(svcGetAttestation, 32, buf(), scratch.len)
  if st == svcOk and n == 104:
    discard console.sendString("ATTEST quote=")    # id(8) ‖ meas(32) ‖ sig r||s(64)
    console.sendHexBytes(buf(), 0, 104)
    discard console.sendLine("")
    discard console.sendString("ATTEST nonce=")
    console.sendHexBytes(cast[ptr UncheckedArray[uint8]](addr nonce[0]), 0, 32)
    discard console.sendLine("")
    discard console.sendLine("=== Attestation Emitted ===")
  else:
    discard console.sendLine("[FAIL] getAttestation failed")

  while true:
    wfi()
