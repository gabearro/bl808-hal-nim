## Measurement-binding test (C): attestation + seal bind to the secure-boot
## chain's COMBINED measurement, not the enclave's own code hash.
##
## Flow: verify the genuine image set (real PKA) -> combine the per-image hashes
## -> publish that as the enclave boot measurement -> then:
##   1. the value equals the host-computed expected combined measurement,
##   2. an attestation quote carries that combined measurement,
##   3. a blob sealed under it unseals only under the same measurement (changing
##      the booted set makes the sealed blob un-recoverable).

import bl808/startup, bl808/core
import bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/secureboot/container, bl808/secureboot/verify
import bl808/secureboot/rollback, bl808/secureboot/securestage
import bl808/enclave/abi, bl808/enclave/services, bl808/enclave/vault
import bl808/enclave/measure
import bl808/panicoverride
import bl808/kernel/alloc
include sb_chain_vector

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  Msg = "bound-secret"

var
  console: Uart
  passed = 0
  failed = 0
  scratch {.align: 16.}: array[256, uint8]
  m0buf: array[GoodM0Len, uint8]
  d0buf: array[GoodD0Len, uint8]
  encbuf: array[GoodEncLen, uint8]

proc buf(): ptr UncheckedArray[uint8] = cast[ptr UncheckedArray[uint8]](addr scratch[0])
proc line(s: string) = discard console.sendLine(s)
proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)
  if ok: inc passed else: inc failed

proc load[T](dst: var T, src: openArray[uint8]) =
  for i in 0 ..< src.len: dst[i] = src[i]

proc stageImg(b: var openArray[uint8]): StageImage =
  StageImage(flashAddr: cast[uint32](addr b[0]), maxLen: b.len.uint32)

proc runChainCombined(): (Measurement, int) =
  ## Verify the genuine set on real PKA, fold the accepted payload hashes into a
  ## combined measurement.
  let floor = RollbackRecord(magic: RollbackMagic, seqNo: 1,
                             m0Sec: 1, d0Sec: 1, lpSec: 1, enclaveSec: 1)
  var hdr: Nsb1Header
  var meas: BootMeasurements
  if verifyImageAt(stageImg(m0buf), RootPubX, RootPubY, floor, hdr) == stageOk:
    meas.digests[meas.count] = measurement(hdr); inc meas.count
  if verifyImageAt(stageImg(d0buf), RootPubX, RootPubY, floor, hdr) == stageOk:
    meas.digests[meas.count] = measurement(hdr); inc meas.count
  if verifyImageAt(stageImg(encbuf), RootPubX, RootPubY, floor, hdr) == stageOk:
    meas.digests[meas.count] = measurement(hdr); inc meas.count
  (combineMeasurement(meas), meas.count)

proc trySeal(): int =
  for i in 0 ..< Msg.len: buf()[i] = Msg[i].uint8
  let (st, n) = enclaveDispatch(svcSealBlob, Msg.len, buf(), scratch.len)
  if st != svcOk: -1 else: n

proc tryUnseal(sealed: openArray[uint8]): bool =
  for i in 0 ..< sealed.len: buf()[i] = sealed[i]
  let (st, n) = enclaveDispatch(svcUnsealBlob, sealed.len, buf(), scratch.len)
  if st != svcOk or n != Msg.len: return false
  for i in 0 ..< Msg.len:
    if buf()[i] != Msg[i].uint8: return false
  true

proc main() {.exportc, cdecl.} =
  systemInit(); heapInit()
  enableAllPeriphClocks(); enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal); setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

  delayUs(400_000)   # let host UART capture open before the first markers
  line("")
  line("=== BL808 Measurement-Binding Test ===")
  discard vaultInit(rkSoftDev)
  load(m0buf, GoodM0); load(d0buf, GoodD0); load(encbuf, GoodEnc)

  # 1. Run the chain, publish its combined measurement.
  let (combined, count) = runChainCombined()
  check("chain verified the 3-image set", count == 3)
  setBootMeasurement(combined)   # what securestage.publishBootMeasurement does
  var eqExp = true
  for i in 0 ..< 32:
    if combined[i] != ExpectedMeasurement[i]: eqExp = false
  check("published boot measurement == host-expected combined", eqExp)

  # 2. Attestation quotes the combined measurement.
  for i in 0 ..< 32: buf()[i] = (0xA0 + i).uint8           # nonce
  let (ast, an) = enclaveDispatch(svcGetAttestation, 32, buf(), scratch.len)
  check("attestation produced a quote", ast == svcOk and an == 8 + 32 + 64)
  var attMatch = (ast == svcOk)
  for i in 0 ..< 32:
    if buf()[8 + i] != combined[i]: attMatch = false
  check("attestation quote carries the chain combined measurement", attMatch)

  # 3. Seal binds to the booted set.
  let sn = trySeal()
  check("seal under chain measurement ok", sn > 0)
  var sealed: array[64, uint8]
  for i in 0 ..< sn: sealed[i] = buf()[i]
  check("unseal under same measurement recovers secret",
        tryUnseal(toOpenArray(sealed, 0, sn - 1)))

  var other = combined
  other[0] = other[0] xor 0xFF
  setBootMeasurement(other)                                # simulate a different booted set
  check("unseal FAILS under a different boot measurement",
        not tryUnseal(toOpenArray(sealed, 0, sn - 1)))

  setBootMeasurement(combined)                             # restore
  check("unseal works again after restoring measurement",
        tryUnseal(toOpenArray(sealed, 0, sn - 1)))

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0: line("=== Test Complete ===")
  else: line("=== Test Failed ===")
  while true: wfi()
