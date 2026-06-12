## Encrypted secure-boot image test (E): the AES-CTR confidentiality path.
##
## An NSB1 image whose payload is AES-128-CTR encrypted must: verify its ECDSA
## signature, decrypt with the right key (header nonce), and only then match the
## plaintext payload hash. A wrong key decrypts to garbage and is rejected. Runs
## the real PKA + software AES-CTR on silicon (verify.verifyNsb1Encrypted).

import bl808/startup, bl808/core
import bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/secureboot/container, bl808/secureboot/verify
import bl808/panicoverride
import bl808/kernel/alloc
include sb_chain_vector

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32

var
  console: Uart
  passed = 0
  failed = 0
  encbuf: array[EncImgLen, uint8]
  plain: array[EncPlainLen, uint8]

proc line(s: string) = discard console.sendLine(s)
proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)
  if ok: inc passed else: inc failed

proc keyArr(src: openArray[uint8]): array[16, uint8] =
  for i in 0 ..< 16: result[i] = src[i]

proc plaintextMatches(): bool =
  if EncPlainLen != EncPlain.len: return false
  for i in 0 ..< EncPlainLen:
    if plain[i] != EncPlain[i]: return false
  true

proc main() {.exportc, cdecl.} =
  systemInit(); heapInit()
  enableAllPeriphClocks(); enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal); setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

  delayUs(400_000)
  line("")
  line("=== BL808 Encrypted Secure-Boot Image Test ===")

  let key = keyArr(EncKey)
  var wrongKey = key
  wrongKey[0] = wrongKey[0] xor 0xFF
  var hdr: Nsb1Header

  # 1. Correct key: signature ok, decrypts, plaintext hash matches.
  for i in 0 ..< EncImgLen: encbuf[i] = EncImg[i]
  let r1 = verifyNsb1Encrypted(encbuf, RootPubX, RootPubY, key, hdr, plain)
  check("encrypted image verifies + decrypts with correct key", r1 == vrOk)
  check("decrypted plaintext matches the original payload", plaintextMatches())

  # 2. Wrong key: signature still ok, but plaintext hash fails.
  for i in 0 ..< EncImgLen: encbuf[i] = EncImg[i]
  let r2 = verifyNsb1Encrypted(encbuf, RootPubX, RootPubY, wrongKey, hdr, plain)
  check("wrong key rejected (plaintext hash mismatch)", r2 == vrBadHash)

  # 3. Tampered signature: rejected before any decryption.
  for i in 0 ..< EncImgLen: encbuf[i] = EncImg[i]
  encbuf[OffSignature + 5] = encbuf[OffSignature + 5] xor 0xFF
  let r3 = verifyNsb1Encrypted(encbuf, RootPubX, RootPubY, key, hdr, plain)
  check("tampered signature rejected", r3 == vrBadSignature)

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0: line("=== Test Complete ===")
  else: line("=== Test Failed ===")
  while true: wfi()
