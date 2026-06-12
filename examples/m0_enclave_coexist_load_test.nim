## Enclave + WiFi coexistence UNDER SUSTAINED LOAD (A4).
##
## Task A proved init/scan/crypto coexist with a locked partition for a single
## pass; it left "isolation holds under sustained WiFi traffic" unproven because
## association to the test AP is RF-flaky. This proves the LOAD dimension without
## depending on the AP: a sustained scan loop drives the WiFi MAC to transmit
## probe-request frames and DMA continuously, while the enclave runs hardware
## SHA-256 between every round. We assert that across many rounds of concurrent
## WiFi TX, every enclave digest stays bit-identical (the group-0-locked SE block
## is never disturbed by WiFi's group-1 DMA) and WiFi keeps making progress.

import bl808/startup, bl808/core
import bl808/glb, bl808/gpio, bl808/uart, bl808/mmio, bl808/memmap
import bl808/tzc, bl808/sec
import bl808/wifi
import bl808/panicoverride
import bl808/kernel/alloc

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  WifiSsid {.strdefine.} = ""
  WifiPassword {.strdefine.} = ""
  Rounds = 16                        # sustained scan/TX rounds
  UntrustedMasters = {tzcMasterMmBus, tzcMasterDma0, tzcMasterDma1,
                      tzcMasterUsb, tzcMasterWifi, tzcMasterSdh,
                      tzcMasterEmac, tzcMasterLp, tzcMasterD0, tzcMasterDma2}
  LockedSeBlocks = {tzcSeSha, tzcSeAes, tzcSePka, tzcSeGmac}

var
  console: Uart
  passed = 0
  failed = 0
  # Reserved .bss buffer: the linker places it below the heap arena, so WiFi's
  # heap can never allocate over it (unlike a fixed OcramBase+offset, which aliases
  # WiFi's cached heap and gets clobbered under sustained load).
  shaBuf {.align: 64.}: array[16, uint32]

proc shaSrcPhys(): uint =
  ## Non-cached OCRAM alias of shaBuf (the SE engine reads the non-cached view).
  let a = cast[uint](addr shaBuf)
  if a >= OcramCachedBase and a < OcramCachedBase + 0x10000'u:
    a - (OcramCachedBase - OcramBase)
  else:
    a

proc line(s: string) =
  withInterruptsDisabled:
    console.flushTx(); discard console.sendLine(s); console.flushTx()
proc kv(label: string, v: uint32) =
  withInterruptsDisabled:
    console.flushTx(); discard console.sendString(label); console.sendHex32(v)
    discard console.sendLine(""); console.flushTx()
proc check(label: string, ok: bool) =
  withInterruptsDisabled:
    console.flushTx()
    discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
    discard console.sendLine(label); console.flushTx()
  if ok: inc passed else: inc failed

proc hwSha(): array[8, uint32] =
  for i in 0 ..< 16: shaBuf[i] = 0x1122_3344'u32 + i.uint32
  dcacheFlushAll(); dcacheInvalidateAll(); fenceIo()
  shaStart(sha256); discard shaUpdate(shaSrcPhys().uint32, 64); shaReadHash(result); shaFinish()

proc nonZero(h: array[8, uint32]): bool =
  for w in h:
    if w != 0'u32: return true
  false
proc eq(a, b: array[8, uint32]): bool =
  for i in 0 ..< 8:
    if a[i] != b[i]: return false
  true

proc applyEnclaveLock() =
  ## Master groups (WiFi -> group 1) + SE blocks -> group 0, then freeze. The
  ## secure OCRAM *data* window is intentionally NOT locked over WiFi's heap (the
  ## proven-safe scoped config); the load-bearing isolation is the master/SE lock.
  tzcSetMasterGroup(tzcMasterM0, 0, lock = true)
  for m in UntrustedMasters: tzcSetMasterGroup(m, 1, lock = true)
  for b in LockedSeBlocks: tzcSetSeBlockGroup(b, 0, lock = true)
  tzcLockMasterGroups()
  tzcSetSbootDone()

proc main() {.exportc, cdecl.} =
  systemInit(); heapInit()
  enableAllPeriphClocks(); enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal); setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1, parity: parityNone), ConsoleClkHz)

  delayUs(400_000)
  line("")
  line("=== BL808 Enclave + WiFi Coexistence Under Load ===")

  kv("[M0] sha buffer phys = ", shaSrcPhys().uint32)
  let refDigest = hwSha()
  check("hardware SHA works before lock", nonZero(refDigest))

  applyEnclaveLock()
  check("enclave SHA works under locked partition",
        eq(hwSha(), refDigest))

  check("wifi credentials supplied", WifiSsid.len > 0 and WifiPassword.len > 0)
  check("wifi init under locked partition", wifiInit() == wifiOk)
  var iface = wifi_mgmr_sta_enable()
  check("wifi sta enable", iface != nil)

  # Sustained load: each round issues a scan (transmits probe-request frames +
  # drives MAC DMA) and polls the backend, with an enclave SHA between every
  # round. Each accepted scan (rc==0) is a TX burst; results accumulating proves
  # the RX/DMA path keeps running too. The load-bearing assertion is that the
  # enclave's group-0 SHA digest never drifts under all this concurrent WiFi DMA.
  var scansIssued = 0
  var digestStable = true
  for r in 0 ..< Rounds:
    if wifi_mgmr_scan(addr iface, nil) == 0: inc scansIssued
    for _ in 0 ..< 1200:                    # bounded poll: drive TX/RX this round
      bl808_wifi_backend_poll(8)
      delayUs(700)
    if not eq(hwSha(), refDigest): digestStable = false   # enclave crypto under load

  kv("[M0] scans issued = ", scansIssued.uint32)
  kv("[M0] total scan results = ", bl808_wifi_backend_scan_count())
  check("sustained WiFi TX: >= 12 scan bursts issued under lock", scansIssued >= 12)
  check("WiFi RX/DMA progressed (scan results accumulated)",
        bl808_wifi_backend_scan_count() > 0'u32)
  check("enclave SHA bit-identical across all WiFi load rounds", digestStable)
  check("enclave SHA still correct after the load run", eq(hwSha(), refDigest))

  # SE block is still exclusively the enclave's: WiFi (group 1) cannot have
  # disturbed the group-0-locked SHA engine — proven by the stable digest above.
  discard wifiDisconnect()

  withInterruptsDisabled:
    console.flushTx(); discard console.sendString("Result: ")
    console.sendHex32(passed.uint32); discard console.sendString(" passed, ")
    console.sendHex32(failed.uint32); discard console.sendLine(" failed")
    if failed == 0: discard console.sendLine("=== Test Complete ===")
    else: discard console.sendLine("=== Test Failed ===")
    console.flushTx()
  while true: wfi()
