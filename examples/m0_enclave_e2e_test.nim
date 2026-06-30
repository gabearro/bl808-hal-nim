## Full end-to-end enclave test (M0).
##
## The integration the piecewise tests didn't cover: one image that
##   1. enclaveInit with the default partition LOCKED (production apply),
##   2. drops to a U-mode application, which
##   3. calls the REAL enclave services (sha256, getRandom, seal/unseal,
##      attestation) across the ecall + shared-buffer boundary, verifying each
##      result, and reports its tally back through a final ecall.
##
## This exercises the actual enclave in operation: locked TZC/PMP partition +
## U-mode isolation + ecall dispatch + copy-in/out via the shared buffer + the
## real crypto services. Built with -d:bl808enclave.

import bl808/startup, bl808/core
import bl808/mmio, bl808/memmap
import bl808/glb, bl808/gpio, bl808/uart
import bl808/umode
import bl808/enclave/enclave, bl808/enclave/partition, bl808/enclave/vault
import bl808/enclave/abi, bl808/enclave/services
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  SharedAddr = 0x6202F000'u       # SHARED region (bl808_m0_enclave.ld)
  SvcReport  = 0xAA'u32           # test-only: U-mode hands its tally to M0
  SvcProgress = 0xAB'u32           # test-only: progress breadcrumbs
  ExpectTally = 4'u32             # number of service checks the app should pass

var console: Uart

proc line(s: string) = discard console.sendLine(s)
proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)

# ---- M0 dispatch: real services + the test report hook -------------------
proc e2eDispatch(frame: ptr EcallFrame) {.nimcall.} =
  if frame.a0 == SvcReport:
    discard console.sendString("[M0] U-mode service tally = ")
    console.sendHex32(frame.a1)
    discard console.sendLine("")
    check("U-mode ran the real enclave services via ecall", frame.a1 == ExpectTally)
    line("=== Test Complete ===")
    frame.a0 = 0
  elif frame.a0 == SvcProgress:
    discard console.sendString("[M0] U-mode progress = ")
    console.sendHex32(frame.a1)
    discard console.sendLine("")
    frame.a0 = 0
    frame.a1 = 0
  else:
    let buf = cast[ptr UncheckedArray[uint8]](SharedAddr)
    let (st, resp) = enclaveDispatch(
      callerUmodeAppCtx(),
      toSvcId(frame.a0),
      frame.a1.int,
      buf,
      4096,
    )
    frame.a0 = st.uint32
    frame.a1 = resp.uint32

# ---- U-mode application (runs unprivileged; talks only via ecall) ---------
proc uEcall(svc, reqLen: uint32): tuple[status, rlen: uint32] =
  var st = svc
  var rl = reqLen
  {.emit: """
    register unsigned long a0 asm("a0") = `st`;
    register unsigned long a1 asm("a1") = `rl`;
    __asm__ volatile("ecall" : "+r"(a0), "+r"(a1) :: "memory");
    `st` = a0; `rl` = a1;
  """.}
  (st, rl)

proc uProgress(code: uint32) =
  discard uEcall(SvcProgress, code)

proc umodeApp() {.exportc: "umode_app", cdecl.} =
  let buf = cast[ptr UncheckedArray[uint8]](SharedAddr)
  var tally = 0'u32

  # 1. sha256("abc") -> known digest prefix 0xBA 0x78
  uProgress(0xE2000001'u32)
  buf[0] = 0x61; buf[1] = 0x62; buf[2] = 0x63
  var r = uEcall(svcSha256.uint32, 3)
  if r.status == 0 and r.rlen == 32 and buf[0] == 0xBA'u8 and buf[1] == 0x78'u8:
    tally.inc
  uProgress(0xE2000011'u32)

  # 2. getRandom(16) -> non-zero
  uProgress(0xE2000002'u32)
  for i in 0 ..< 4: buf[i] = 0
  buf[0] = 16
  r = uEcall(svcGetRandom.uint32, 4)
  var nz = false
  for i in 0 ..< 16:
    if buf[i] != 0: nz = true
  if r.status == 0 and r.rlen == 16 and nz:
    tally.inc
  uProgress(0xE2000012'u32)

  # 3. sealBlob then unsealBlob round-trip (device-bound, uses the vault root)
  uProgress(0xE2000003'u32)
  let msg = "u-mode-secret"
  for i in 0 ..< msg.len: buf[i] = msg[i].uint8
  r = uEcall(svcSealBlob.uint32, msg.len.uint32)
  if r.status == 0:
    let sealedLen = r.rlen.int
    var sealed: array[64, uint8]
    for i in 0 ..< sealedLen: sealed[i] = buf[i]
    for i in 0 ..< sealedLen: buf[i] = sealed[i]
    let r2 = uEcall(svcUnsealBlob.uint32, sealedLen.uint32)
    var ok = r2.status == 0 and r2.rlen.int == msg.len
    for i in 0 ..< msg.len:
      if buf[i] != msg[i].uint8: ok = false
    if ok: tally.inc
  uProgress(0xE2000013'u32)

  # 4. attestation: id(8)+meas(32)+sig(64) = 104 bytes
  uProgress(0xE2000004'u32)
  for i in 0 ..< 32: buf[i] = i.uint8     # nonce
  r = uEcall(svcGetAttestation.uint32, 32)
  if r.status == 0 and r.rlen == 104:
    tally.inc
  uProgress(0xE2000014'u32)

  # report tally to M0
  discard uEcall(SvcReport, tally)
  while true:
    {.emit: "__asm__ volatile(\"wfi\");".}

proc umodeAppAddr(): uint =
  {.emit: "`result` = (NU)(&umode_app);".}

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
  line("=== BL808 Enclave E2E Test ===")

  let ok = enclaveInit(defaultPartition(lock = true), rkSoftDev)
  check("enclaveInit with LOCKED partition", ok)
  # Wrap dispatch: real services + the test report hook.
  enclaveSetEcallDispatch(e2eDispatch)
  line("[M0] partition locked; entering U-mode...")

  enclaveRunUmode(umodeAppAddr())
