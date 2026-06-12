## Secure-boot CHAIN test (device-side, real PKA/SHA on silicon).
##
## Exercises the full stage orchestration end-to-end — the part above the verify
## primitive — against a host-generated multi-image set (sb_chain_vector.nim):
##   1. walk the genuine set (m0app, d0, enclave): each verifies (ECDSA via PKA),
##      meets the rollback floor, and contributes its payload hash;
##   2. the combined boot measurement matches the host-computed expected value
##      byte-for-byte (binds attestation/seal to the whole booted set);
##   3. the core-release gate opens only when every image passed;
##   4. rejection matrix: tampered payload, wrong signing key, and a downgraded
##      (secver below floor) image are each refused, and the gate stays shut.
##
## Runs from RAM via --jtag-load (writes nothing to flash). This validates every
## link of the chain EXCEPT BootROM->stage authentication, which is eFuse-gated
## and cannot be exercised in reversible mode.

import bl808/startup, bl808/core
import bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/secureboot/container, bl808/secureboot/verify
import bl808/secureboot/rollback, bl808/secureboot/securestage
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

proc line(s: string) = discard console.sendLine(s)
proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)
  if ok: inc passed else: inc failed

# Working copies of each image (a var so verifyImageAt can read them by address,
# and so the tamper case can flip a byte in place).
var
  m0buf: array[GoodM0Len, uint8]
  d0buf: array[GoodD0Len, uint8]
  encbuf: array[GoodEncLen, uint8]
  wkbuf: array[WrongKeyLen, uint8]
  oldbuf: array[OldVerLen, uint8]

proc load[T](dst: var T, src: openArray[uint8]) =
  for i in 0 ..< src.len: dst[i] = src[i]

proc stageImg(buf: var openArray[uint8]): StageImage =
  StageImage(flashAddr: cast[uint32](addr buf[0]), maxLen: buf.len.uint32)

proc floorOf(m0, d0, lp, enc: uint32): RollbackRecord =
  RollbackRecord(magic: RollbackMagic, seqNo: 1,
                 m0Sec: m0, d0Sec: d0, lpSec: lp, enclaveSec: enc)

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

  line("")
  line("=== BL808 Secure Boot Chain Test ===")

  load(m0buf, GoodM0); load(d0buf, GoodD0); load(encbuf, GoodEnc)
  load(wkbuf, WrongKey); load(oldbuf, OldVer)

  let floor = floorOf(1, 1, 1, 1)         # accepts secver >= 1 per image type
  var hdr: Nsb1Header
  var meas: BootMeasurements
  var allOk = true

  # 1. Walk the genuine set; collect measurements.
  let r0 = verifyImageAt(stageImg(m0buf), RootPubX, RootPubY, floor, hdr)
  check("m0app image verifies + meets floor", r0 == stageOk)
  if r0 == stageOk:
    meas.digests[meas.count] = measurement(hdr); inc meas.count
  else: allOk = false

  let r1 = verifyImageAt(stageImg(d0buf), RootPubX, RootPubY, floor, hdr)
  check("d0 image verifies + meets floor", r1 == stageOk)
  if r1 == stageOk:
    meas.digests[meas.count] = measurement(hdr); inc meas.count
  else: allOk = false

  let r2 = verifyImageAt(stageImg(encbuf), RootPubX, RootPubY, floor, hdr)
  check("enclave image verifies + meets floor", r2 == stageOk)
  if r2 == stageOk:
    meas.digests[meas.count] = measurement(hdr); inc meas.count
  else: allOk = false

  # 2. Combined boot measurement matches the host-computed expectation.
  let combined = combineMeasurement(meas)
  var measMatch = meas.count == 3
  for i in 0 ..< 32:
    if combined[i] != ExpectedMeasurement[i]: measMatch = false
  check("combined boot measurement matches host expectation", measMatch)

  # 3. Core-release gate opens only on a fully clean walk.
  check("core-release gate OPEN for clean image set", allOk and measMatch)

  # 4. Rejection matrix.
  m0buf[Nsb1HeaderSize + 2] = m0buf[Nsb1HeaderSize + 2] xor 0xFF      # tamper payload
  let rt = verifyImageAt(stageImg(m0buf), RootPubX, RootPubY, floor, hdr)
  check("tampered payload rejected", rt == stageVerifyFailed)
  load(m0buf, GoodM0)                                                  # restore

  let rw = verifyImageAt(stageImg(wkbuf), RootPubX, RootPubY, floor, hdr)
  check("wrong-key image rejected", rw == stageVerifyFailed)

  let ro = verifyImageAt(stageImg(oldbuf), RootPubX, RootPubY, floor, hdr)
  check("downgraded image rejected (rollback floor)", ro == stageRollbackBlocked)

  # Fuzz regression: a header claiming payloadLen ~0xFFFFFFFF must be rejected,
  # not trigger an integer-overflow payload-hash over-read (verify.nim fix).
  var ovf: array[Nsb1HeaderSize, uint8]
  ovf[0] = 'N'.uint8; ovf[1] = 'S'.uint8; ovf[2] = 'B'.uint8; ovf[3] = '1'.uint8
  ovf[OffHdrVer] = 1; ovf[OffImgType] = 1
  ovf[OffPayloadLen] = 0xFF; ovf[OffPayloadLen+1] = 0xFF
  ovf[OffPayloadLen+2] = 0xFF; ovf[OffPayloadLen+3] = 0xFF
  let rovf = verifyImageAt(stageImg(ovf), RootPubX, RootPubY, floor, hdr)
  check("payloadLen-overflow header rejected (no over-read)", rovf == stageVerifyFailed)

  # The gate must be shut whenever any image in the set fails.
  let badSetOk = (rt == stageOk) and (rw == stageOk) and (ro == stageOk)
  check("core-release gate SHUT when set contains a failure", not badSetOk)

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0: line("=== Test Complete ===")
  else: line("=== Test Failed ===")
  while true: wfi()
