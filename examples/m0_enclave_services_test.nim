## Enclave services hardware test (M-mode direct dispatch).
##
## Exercises the enclave service + crypto stack on real silicon: partition
## apply, TRNG, software AES-CTR+HMAC AEAD, SHA-256, HKDF derive, and the PKA
## ECDSA attestation path. Validates the trusted-side logic; U-mode/PMP/ecall
## isolation is covered separately by m0_umode_pmp_test.

import bl808/startup, bl808/core
import bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/umode
import bl808/enclave/abi, bl808/enclave/services, bl808/enclave/vault
import bl808/enclave/enclave, bl808/enclave/partition
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

var
  console: Uart
  passed = 0
  failed = 0
  scratch {.align: 16.}: array[512, uint8]

proc buf(): ptr UncheckedArray[uint8] = cast[ptr UncheckedArray[uint8]](addr scratch[0])

proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)
  if ok: inc passed else: inc failed

proc onEcall(f: ptr EcallFrame) {.nimcall.} = discard

proc testSha256() =
  buf()[0] = 0x61; buf()[1] = 0x62; buf()[2] = 0x63   # "abc"
  let (st, n) = enclaveDispatch(svcSha256, 3, buf(), scratch.len)
  # SHA-256("abc") = ba7816bf...
  check("sha256 status", st == svcOk and n == 32)
  check("sha256 digest[0]=0xba", buf()[0] == 0xba and buf()[1] == 0x78)

proc testRandom() =
  wrU32(buf(), 0, 16)
  let (st, n) = enclaveDispatch(svcGetRandom, 4, buf(), scratch.len)
  var nonZero = false
  for i in 0 ..< n:
    if buf()[i] != 0: nonZero = true
  check("getRandom status+nonzero", st == svcOk and n == 16 and nonZero)

proc testDeriveAndAead() =
  # derive a child key from root: parent | outLen=32 | labLen=3 | ctxLen=1 | "key" "1"
  wrU32(buf(), 0, vaultRoot().uint32)
  wrU32(buf(), 4, 32)
  wrU32(buf(), 8, 3)
  wrU32(buf(), 12, 1)
  buf()[16] = byte 'k'; buf()[17] = byte 'e'; buf()[18] = byte 'y'; buf()[19] = byte '1'
  let (st, n) = enclaveDispatch(svcDeriveKey, 20, buf(), scratch.len)
  check("deriveKey status", st == svcOk and n == 4)
  let child = rdU32(buf(), 0)

  # AEAD seal "hello" (5 bytes) under child, nonce=16 zeros, no aad
  let mkReq = proc(): int =
    wrU32(buf(), 0, child)
    wrU32(buf(), 4, 16)   # nonceLen
    wrU32(buf(), 8, 0)    # aadLen
    wrU32(buf(), 12, 5)   # ptLen
    for i in 0 ..< 16: buf()[16 + i] = 0
    let msg = "hello"
    for i in 0 ..< 5: buf()[32 + i] = msg[i].uint8
    32 + 5
  let reqLen = mkReq()
  let (st2, sealedLen) = enclaveDispatch(svcAeadSeal, reqLen, buf(), scratch.len)
  check("aeadSeal status", st2 == svcOk and sealedLen == 5 + 32)

  # capture ciphertext+tag, then open
  var sealed: array[64, uint8]
  for i in 0 ..< sealedLen: sealed[i] = buf()[i]
  wrU32(buf(), 0, child)
  wrU32(buf(), 4, 16)
  wrU32(buf(), 8, 0)
  wrU32(buf(), 12, 5)            # ctLen
  for i in 0 ..< 16: buf()[16 + i] = 0
  for i in 0 ..< sealedLen: buf()[32 + i] = sealed[i]
  let (st3, ptLen) = enclaveDispatch(svcAeadOpen, 32 + sealedLen, buf(), scratch.len)
  var ok = st3 == svcOk and ptLen == 5
  let exp = "hello"
  for i in 0 ..< 5:
    if buf()[i] != exp[i].uint8: ok = false
  check("aeadOpen round-trip", ok)

  # tamper the tag -> must fail
  for i in 0 ..< 16: buf()[16 + i] = 0
  for i in 0 ..< sealedLen: buf()[32 + i] = sealed[i]
  buf()[32 + 5] = buf()[32 + 5] xor 0xFF   # flip first tag byte
  wrU32(buf(), 0, child); wrU32(buf(), 4, 16); wrU32(buf(), 8, 0); wrU32(buf(), 12, 5)
  let (st4, _) = enclaveDispatch(svcAeadOpen, 32 + sealedLen, buf(), scratch.len)
  check("aeadOpen rejects tampered tag", st4 == svcCryptoFail)

proc testSeal() =
  let msg = "secret-data"
  for i in 0 ..< 16: buf()[i] = 0
  for i in 0 ..< msg.len: buf()[16 + i] = msg[i].uint8
  let (st, sealedLen) = enclaveDispatch(svcSealBlob, 16 + msg.len, buf(), scratch.len)
  check("sealBlob status", st == svcOk and sealedLen == msg.len + 32)
  var sealed: array[64, uint8]
  for i in 0 ..< sealedLen: sealed[i] = buf()[i]
  for i in 0 ..< 16: buf()[i] = 0
  for i in 0 ..< sealedLen: buf()[16 + i] = sealed[i]
  let (st2, ptLen) = enclaveDispatch(svcUnsealBlob, 16 + sealedLen, buf(), scratch.len)
  var ok = st2 == svcOk and ptLen == msg.len
  for i in 0 ..< msg.len:
    if buf()[i] != msg[i].uint8: ok = false
  check("unsealBlob round-trip", ok)

proc testAttestation() =
  for i in 0 ..< 32: buf()[i] = i.uint8   # nonce
  let (st, n) = enclaveDispatch(svcGetAttestation, 32, buf(), scratch.len)
  # id(8)+meas(32)+sig(64) = 104; PKA ECDSA exercised here
  check("getAttestation status+len", st == svcOk and n == 104)

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  enableAllPeriphClocks()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(ConsoleUartTxPin, ConsoleUartRxPin)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 Enclave Services Test ===")

  enclaveSetEcallDispatch(onEcall)
  let ok = enclaveInit(defaultPartition(lock = false), rkSoftDev)
  check("enclaveInit", ok)

  testSha256()
  testRandom()
  testDeriveAndAead()
  testSeal()
  testAttestation()

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0:
    discard console.sendLine("=== Test Complete ===")
  else:
    discard console.sendLine("=== Test Failed ===")
  while true:
    wfi()
