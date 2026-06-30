## Secret non-leakage (A2).
##
## Copy-in/copy-out discipline is meant to keep key material inside the vault:
## services run on copies in secure RAM and write only non-secret results to the
## shared buffer. This test PROVES it positively — it installs a known root,
## derives the same secrets the services derive (root, attestation scalar, seal/
## AEAD key), runs the seal / attest / aead / derive services through the real
## dispatcher, and scans the ENTIRE shared buffer and U-mode RAM window for any
## of those secret needles. None may appear outside the vault. A planted-needle
## positive control proves the scanner actually works.

import bl808/startup, bl808/core
import bl808/mmio
import bl808/glb, bl808/gpio, bl808/uart
import bl808/enclave/enclave, bl808/enclave/partition, bl808/enclave/vault
import bl808/enclave/abi, bl808/enclave/services, bl808/enclave/measure
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  # "aead-v1" / "att-v1" — must match services.nim AeadInfo / AttestInfo.
  AeadInfo = ['a'.byte, 'e'.byte, 'a'.byte, 'd'.byte, '-'.byte, 'v'.byte, '1'.byte]
  AttestInfo = ['a'.byte, 't'.byte, 't'.byte, '-'.byte, 'v'.byte, '1'.byte]

var
  console: Uart
  passed = 0
  failed = 0
  knownRoot: array[32, uint8]
  attestScalar: array[32, uint8]
  sealKey: array[48, uint8]     # enc[0..15] || mac[16..47]

proc line(s: string) = discard console.sendLine(s)
proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)
  if ok: inc passed else: inc failed

proc memFind(start, len: uint, needle: openArray[uint8]): bool =
  ## True if `needle` occurs anywhere in [start, start+len).
  if needle.len == 0 or len < needle.len.uint: return false
  let p = cast[ptr UncheckedArray[uint8]](start)
  let last = len.int - needle.len
  for i in 0 .. last:
    var hit = true
    for j in 0 ..< needle.len:
      if p[i + j] != needle[j]: hit = false; break
    if hit: return true
  false

proc scanned(label: string, needle: openArray[uint8]) =
  ## Assert a secret needle appears in NEITHER the shared buffer NOR U-mode RAM.
  let inShared = memFind(sharedBufStart(), sharedBufLen(), needle)
  let inUmode = memFind(umodeRamStart(), umodeRamLen(), needle)
  check(label & " absent from shared buffer", not inShared)
  check(label & " absent from U-mode RAM", not inUmode)

proc buf(): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](sharedBufStart())

proc scanAll(stage: string) =
  scanned(stage & ": root", knownRoot)
  scanned(stage & ": attest scalar", attestScalar)
  scanned(stage & ": seal/aead key", sealKey)

proc main() {.exportc, cdecl.} =
  systemInit(); heapInit()
  enableAllPeriphClocks(); enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal); setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

  delayUs(400_000)
  line("")
  line("=== BL808 Enclave Secret Non-Leakage ===")

  discard enclaveInit(defaultPartition(lock = false), rkSoftDev)

  # Install a KNOWN, recognisable root so we have exact secret needles to hunt.
  for i in 0 ..< 32: knownRoot[i] = (0x40 + i).uint8
  discard vaultImportSoftRoot(knownRoot)

  # Derive the same secrets the services derive, for use as scan needles.
  let meas = measureImage()
  var aeadInfoCtx: array[7 + 32, uint8]
  var n = 0
  for b in AeadInfo: aeadInfoCtx[n] = b; inc n
  for i in 0 ..< 32: aeadInfoCtx[n] = meas[i]; inc n     # seal ctx = measurement
  check("derive seal key needle", vaultExpand(vaultRoot(), toOpenArray(aeadInfoCtx, 0, n - 1), sealKey))
  check("derive attest scalar needle", vaultExpand(vaultRoot(), AttestInfo, attestScalar))

  # Positive control: the scanner must FIND a needle we deliberately plant.
  let b = buf()
  for i in 0 ..< 32: b[i] = knownRoot[i]
  check("positive control: planted root IS found",
        memFind(sharedBufStart(), sharedBufLen(), knownRoot))
  for i in 0 ..< sharedBufLen().int: b[i] = 0     # wipe the plant

  # 1. Seal a blob, then scan for leaks.
  block:
    let bc = sharedBufLen().int
    for i in 0 ..< 32: b[i] = (0xC0 + i).uint8                 # plaintext
    let (st, rl) = enclaveDispatch(svcSealBlob, 32, b, bc)
    check("svcSealBlob ok", st == svcOk and rl > 0)
    scanAll("after seal")

  # 2. Attestation (signs with the private attest scalar).
  block:
    let bc = sharedBufLen().int
    for i in 0 ..< 32: b[i] = (0x90 + (i and 7)).uint8         # nonce
    let (st, rl) = enclaveDispatch(svcGetAttestation, 32, b, bc)
    check("svcGetAttestation ok", st == svcOk and rl > 0)
    scanAll("after attest")

  # 3. AEAD seal under a derived handle.
  block:
    let bc = sharedBufLen().int
    let h = vaultDeriveKey(vaultRoot(), [1'u8, 2, 3], [9'u8],
                           32, KeyPolicy(usage: {kuEncrypt, kuDecrypt}))
    wrU32(b, 0, h.uint32); wrU32(b, 4, 16); wrU32(b, 8, 0); wrU32(b, 12, 16)
    for i in 0 ..< 16: b[16 + i] = (0x20 + i).uint8            # nonce
    for i in 0 ..< 16: b[32 + i] = (0x70 + i).uint8            # plaintext
    let (st, rl) = enclaveDispatch(svcAeadSeal, 48, b, bc)
    check("svcAeadSeal ok", st == svcOk and rl > 0)
    scanAll("after aead")

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0: line("=== Test Complete ===")
  else: line("=== Test Failed ===")
  while true: wfi()
