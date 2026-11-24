"""Exercise the all-core manager's WPA and DHCP waits with the CPS transform."""

from pathlib import Path
from textwrap import dedent

import pytest

from test_wifi_disconnect_tx import ROOT, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const WpaCompletedState = 10'u32
const WpaFirstKeyExchangeState = 7'u32
const ConfirmedIp = 0x7201A8C0'u32
const ErrOk = 0
const QuietWifiBringup = true
const WifiConnectRetryDelayUs = 1'u64
type Netif = object
  ip: uint32
  leased: bool
  flags: uint8
type Console = object
var
  clockMs, wpaState, lastArpIp: uint32
  sm_state: uint16
  exchangeAt: int
  exchangeState: uint32
  connected: bool
  polls, completeOn, disconnectOn, leaseOn, dhcpStarts, dhcpFailures, arps: int
  netif: Netif
  console: Console
  ready: seq[proc() {.closure.}]
  nimfw_dbg_dhcp_tx, nimfw_dbg_dhcp_tx_msg, nimfw_dbg_dhcp_cfm_ack_ok: uint32
  nimfw_dbg_dhcp_cfm_fail, nimfw_dbg_tcpip_input_dhcp_rx: uint32
  nimfw_dbg_lwip_dhcp_recv_count, nimfw_dbg_lwip_dhcp_offer_count: uint32
  nimfw_dbg_lwip_dhcp_recv_code, nimfw_dbg_lwip_dhcp_create_count: uint32
proc post(cb: proc() {.closure.}) = ready.add(cb)
proc nowMs(): uint32 = clockMs
proc bl808_wifi_backend_connected(): cint = connected.cint
proc bl808WpaCurrentState(): uint32 = wpaState
proc netifIp4(netif: ptr Netif): uint32 = netif.ip
proc netifFlags(netif: ptr Netif): uint8 = netif.flags
proc dhcpSuppliedAddress(netif: ptr Netif): uint8 = netif.leased.uint8
proc etharpGratuitous(netif: ptr Netif): int =
  inc arps
  lastArpIp = netif.ip
  ErrOk
proc sendLine(console: Console; msg: string): bool = true
proc dhcpStart(netif: ptr Netif): int =
  doAssert connected and wpaState == WpaCompletedState
  inc dhcpStarts
  if dhcpFailures == 0: return ErrOk
  dec dhcpFailures
  -1
proc pollNetwork() =
  inc polls
  inc clockMs
  if polls == completeOn: wpaState = WpaCompletedState
  if polls == exchangeAt: wpaState = exchangeState
  if polls == leaseOn: netif = Netif(ip: ConfirmedIp, leased: true)
  if polls == disconnectOn: connected = false
'''

CHECKS = r'''
proc drive[T](fut: CpsFuture[T]): T =
  for _ in 0 .. 8:
    if fut.finished: return fut.read()
    let batch = move ready
    doAssert batch.len > 0
    for cb in batch: cb()
  doAssert false, "network wait did not finish"

proc setup(start: uint32; complete, drop: int) =
  clockMs = start
  wpaState = 0
  connected = true
  polls = 0
  completeOn = complete
  disconnectOn = drop
  exchangeAt = 0
  exchangeState = 0
  leaseOn = 0
  dhcpStarts = 0
  dhcpFailures = 0
  arps = 0
  lastArpIp = 0
  netif = default(Netif)
  doAssert ready.len == 0

# Start after a potentially long scan and connection attempt, including wrap.
for start in [30_000'u32, high(uint32) - 1]:
  setup(start, 3, 0)
  doAssert drive(waitForAllcoreWpa(4)) and polls == 3
  setup(start, 0, 0)
  doAssert not drive(waitForAllcoreWpa(4)) and polls == 4
  setup(start, 1, 1)
  doAssert not drive(waitForAllcoreWpa(4)) and polls == 1
  setup(start, 0, 0)
  wpaState = WpaCompletedState
  doAssert drive(waitForAllcoreWpa(0)) and polls == 0
  connected = false
  doAssert not drive(waitForAllcoreWpa(4)) and polls == 0

# An address alone is not a lease on the replacement link.
for start in [40_000'u32, high(uint32) - 1]:
  setup(start, 0, 0)
  wpaState = WpaCompletedState
  netif.ip = 0x4001A8C0'u32
  leaseOn = 3
  doAssert drive(waitForAllcoreDhcpLease(addr netif, 4)) == ConfirmedIp and polls == 3
  setup(start, 0, 0)
  wpaState = WpaCompletedState
  netif.ip = 0x4001A8C0'u32
  doAssert drive(waitForAllcoreDhcpLease(addr netif, 4)) == 0 and polls == 4
  setup(start, 0, 2)
  wpaState = WpaCompletedState
  leaseOn = 2
  doAssert drive(waitForAllcoreDhcpLease(addr netif, 4)) == 0 and polls == 2
  setup(start, 0, 0)
  wpaState = WpaCompletedState
  netif = Netif(ip: ConfirmedIp, leased: true)
  doAssert drive(waitForAllcoreDhcpLease(addr netif, 4)) == ConfirmedIp and polls == 0

# The replacement client starts only once WPA completes. A lease arriving
# after the wait expires is still eligible for publication without a restart.
setup(0, 1, 0)
doAssert not startAllcoreDhcp(addr netif) and dhcpStarts == 0
doAssert drive(waitForAllcoreWpa(4))
doAssert startAllcoreDhcp(addr netif) and dhcpStarts == 1
leaseOn = 4
doAssert drive(waitForAllcoreDhcpLease(addr netif, 2)) == 0 and polls == 3
doAssert allcoreConfirmedLeaseIp(addr netif) == 0
pollNetwork()
doAssert allcoreConfirmedLeaseIp(addr netif) == ConfirmedIp and dhcpStarts == 1
connected = false
doAssert allcoreConfirmedLeaseIp(addr netif) == 0
doAssert not startAllcoreDhcp(addr netif) and dhcpStarts == 1
connected = true
dhcpFailures = 1
doAssert not startAllcoreDhcp(addr netif) and dhcpStarts == 2

# Boot and a cold relink run the same WPA gate even after a failed start.
setup(0, 0, 0)
doAssert not drive(startAllcoreBootDhcp(addr netif)) and dhcpStarts == 0
setup(0, 0, 1)
wpaState = WpaCompletedState
dhcpFailures = 1
doAssert not drive(startAllcoreBootDhcp(addr netif)) and dhcpStarts == 1 and polls == 1
setup(high(uint32) - 1, 0, 0)
wpaState = WpaCompletedState
dhcpFailures = 1
doAssert drive(startAllcoreBootDhcp(addr netif)) and dhcpStarts == 2 and polls == 1
netif.ip = 0x4001A8C0'u32
leaseOn = 4
doAssert drive(waitForAllcoreDhcpLease(addr netif, 2, 3)) == ConfirmedIp
doAssert polls == 4 and dhcpStarts == 2
setup(0, 0, 3)
wpaState = WpaCompletedState
doAssert drive(startAllcoreBootDhcp(addr netif))
doAssert drive(waitForAllcoreDhcpLease(addr netif, 2, 3)) == 0
doAssert polls == 3 and dhcpStarts == 1
setup(0, 0, 0)
wpaState = WpaCompletedState
doAssert drive(startAllcoreBootDhcp(addr netif))
doAssert drive(waitForAllcoreDhcpLease(addr netif, 2, 3)) == 0
doAssert polls == 6 and dhcpStarts == 1

# An in-progress key exchange is not a disconnect. A DHCP lease must not be
# published until the current association returns to the completed state.
for keyState in [7'u32, 8, 9]:
  setup(0, 4, 0)
  wpaState = WpaCompletedState
  doAssert drive(startAllcoreBootDhcp(addr netif))
  exchangeAt = 1
  exchangeState = keyState
  leaseOn = 2
  doAssert drive(waitForAllcoreDhcpLease(addr netif, 3, 2)) == ConfirmedIp
  doAssert polls == 4 and dhcpStarts == 1

  setup(0, 0, 0)
  wpaState = WpaCompletedState
  doAssert startAllcoreDhcp(addr netif)
  exchangeAt = 1
  exchangeState = keyState
  leaseOn = 2
  doAssert drive(waitForAllcoreDhcpLease(addr netif, 3)) == 0
  doAssert polls == 3 and dhcpStarts == 1

  setup(0, 5, 2)
  wpaState = WpaCompletedState
  exchangeAt = 1
  exchangeState = keyState
  doAssert drive(waitForAllcoreDhcpLease(addr netif, 4)) == 0 and polls == 2

for nonKeyState in [0'u32, 6, 11, 12]:
  setup(0, 5, 0)
  wpaState = WpaCompletedState
  exchangeAt = 1
  exchangeState = nonKeyState
  doAssert drive(waitForAllcoreDhcpLease(addr netif, 4)) == 0 and polls == 1

# The first boot miss survives a replacement link's counter updates.
setup(0, 0, 0)
netif.flags = 5
sm_state = 7
wpaState = 9 # Supplicant no longer complete, but the station remains associated.
nimfw_dbg_dhcp_tx = 2
nimfw_dbg_dhcp_tx_msg = 1
nimfw_dbg_dhcp_cfm_ack_ok = 1
nimfw_dbg_dhcp_cfm_fail = 1
nimfw_dbg_lwip_dhcp_create_count = 2
recordBootDhcpMiss(true, addr netif)
doAssert bootDhcpMiss == [0x44484332'u32, 0x07090503, 2, 1, 1, 1, 0, 0, 0, 0, 2]
let firstMiss = bootDhcpMiss
nimfw_dbg_lwip_dhcp_recv_code = 0x85
recordBootDhcpMiss(false, nil)
doAssert bootDhcpMiss == firstMiss

# Renewals, revocation and rebinding don't restart DHCP or require a new join.
setup(0, 0, 0)
wpaState = WpaCompletedState
doAssert startAllcoreDhcp(addr netif)
netif = Netif(ip: ConfirmedIp, leased: true)
var published = ConfirmedIp
doAssert refreshAllcoreHttpLease(addr netif, true, true, published) == 0
doAssert published == ConfirmedIp and arps == 0
netif.leased = false
doAssert refreshAllcoreHttpLease(addr netif, true, true, published) == 0
doAssert published == 0 and arps == 0
const ReplacementIp = ConfirmedIp + 1
netif = Netif(ip: ReplacementIp, leased: true)
doAssert refreshAllcoreHttpLease(addr netif, true, false, published) == 0
doAssert published == 0 and arps == 0
doAssert refreshAllcoreHttpLease(addr netif, true, true, published) == ReplacementIp
doAssert published == ReplacementIp and arps == 1 and lastArpIp == ReplacementIp
doAssert dhcpStarts == 1

# Reject a changed address that is replaced again while the network is polled.
const ThirdIp = ReplacementIp + 1
netif = Netif(ip: ThirdIp, leased: true)
leaseOn = polls + 1
doAssert refreshAllcoreHttpLease(addr netif, true, true, published) == ThirdIp
doAssert published == 0 and arps == 2
doAssert refreshAllcoreHttpLease(addr netif, true, true, published) == ConfirmedIp
doAssert published == ConfirmedIp and arps == 3

# WPA loss between announcement and publication cannot resurrect the old IP.
netif = Netif(ip: ReplacementIp, leased: true)
disconnectOn = polls + 1
doAssert refreshAllcoreHttpLease(addr netif, true, true, published) == ReplacementIp
doAssert published == 0 and arps == 4
doAssert refreshAllcoreHttpLease(addr netif, true, false, published) == 0
connected = true
doAssert refreshAllcoreHttpLease(addr netif, false, true, published) == 0
doAssert published == 0 and arps == 4 and dhcpStarts == 1
'''


@pytest.mark.parametrize("mode", ["checked", "release"])
def test_allcore_network_waits_start_after_association(tmp_path: Path, mode: str) -> None:
    kernel = ROOT / "src/bl808/kernel"
    allcore = (ROOT / "examples/m0_allcore_wasm_cps_live_test.nim").read_text()
    code = f'import "{kernel / "runtime"}", "{kernel / "transform"}"\n'
    code += PLATFORM
    code += procedure((kernel / "sleep.nim").read_text(), "yieldNow").split("\n# ===", 1)[0] + "\n"
    start = allcore.index("  proc allcoreWifiWpaReady(")
    end = allcore.index("  proc dumpAllcoreHttpRuntimeDiag(", start)
    code += dedent(allcore[start:end])
    code += "proc sleepUs(us: uint64): CpsVoidFuture {.cps.} =\n  pollNetwork()\n  await yieldNow()\n"
    start = allcore.index('    var bootDhcpMiss {.exportc:')
    end = allcore.index("  proc startAllcoreBootDhcp(", start)
    code += dedent(allcore[start:end])
    start = allcore.index("  proc startAllcoreBootDhcp(")
    end = allcore.index("  proc runAllcoreHttpManagerAfterSmoke(", start)
    code += dedent(allcore[start:end])
    run_program(tmp_path, mode, code + CHECKS)
