"""Verify the normal manager's configured-network selection policy."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program


POLICY = Path(__file__).resolve().parents[1] / "examples" / "wifi_known_networks.nim"
MANAGER = POLICY.with_name("m0_allcore_wasm_cps_live_test.nim")


@pytest.mark.parametrize("mode", ["checked", "release"])
def test_known_network_selection(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, f'include "{POLICY}"\n' + r'''
let primaryOnly = {wifiTargetPrimary}
let fallbackOnly = {wifiTargetFallback}
let both = {wifiTargetPrimary, wifiTargetFallback}
let neither: KnownWifiMatches = {}

doAssert bootWifiTarget(neither, true) == wifiTargetNone
doAssert bootWifiTarget(fallbackOnly, false) == wifiTargetNone
doAssert bootWifiTarget(fallbackOnly, true) == wifiTargetFallback
doAssert bootWifiTarget(both, false) == wifiTargetPrimary
doAssert bootWifiTarget(both, true) == wifiTargetFallback
doAssert bootWifiTarget(primaryOnly, true) == wifiTargetPrimary

for target in [wifiTargetPrimary, wifiTargetFallback]:
  doAssert reconnectWifiTarget(target, both) == target
  doAssert reconnectWifiTarget(target, neither) == target
  doAssert reconnectWifiTarget(target, primaryOnly) == wifiTargetPrimary
  doAssert reconnectWifiTarget(target, fallbackOnly) == wifiTargetFallback

let observed = [65'u8, 80, 0]
doAssert matchesKnownWifi(observed, 2, 1, 0, "AP")
doAssert matchesKnownWifi(observed, 2, 6, 6, "AP")
doAssert not matchesKnownWifi(observed, 2, 11, 6, "AP")
doAssert not matchesKnownWifi(observed, 2, 1, 0, "A")
doAssert not matchesKnownWifi(observed, 2, 1, 0, "AZ")
doAssert not matchesKnownWifi(observed, 0, 1, 0, "")
doAssert not matchesKnownWifi(observed, 4, 1, 0, "APxy")
''')


def test_manager_scan_matches_fallback_beyond_log_limit(tmp_path: Path) -> None:
    collect = procedure(MANAGER.read_text().replace("\n  proc ", "\nproc "),
                        "matchingKnownScanEntries")
    # The manager's outer `when` contributes two spaces to the body.
    head, body = collect.split("\n", 1)
    collect = head + "\n" + "\n".join(line[2:] for line in body.splitlines()) + "\n"
    run_program(tmp_path, "checked", f'include "{POLICY}"\n' + r'''
const
  WifiSsid = "First"
  WifiChannel = 1
  WifiFallbackSsid = "Second"
  WifiResolvedFallbackChannel = 11'u8
var first = true
var loggedMatches, loggedRows: uint32
proc printHex(label: string; value: uint32) =
  if label == "[M0] allcore_http_scan_match_slot=": inc loggedRows
  elif label == "[M0] allcore_http_scan_match_count=": loggedMatches = value
proc bl808_wifi_backend_scan_diag_count(): uint32 = 10
proc bl808_wifi_backend_scan_diag_get(index: uint32;
    ssidLen, ssid, channel, rssi, auth, cipher, bssid: pointer): cint =
  if index < 9 and not first: return -1
  let name = if index < 9: WifiSsid else: WifiFallbackSsid
  cast[ptr uint8](ssidLen)[] = name.len.uint8
  cast[ptr uint8](channel)[] = if index < 9: 1'u8 else: 11'u8
  let bytes = cast[ptr UncheckedArray[uint8]](ssid)
  for i in 0 ..< name.len: bytes[i] = name[i].uint8
  0
''' + collect + r'''
doAssert matchingKnownScanEntries(true) == {wifiTargetPrimary, wifiTargetFallback}
doAssert loggedRows == 8 and loggedMatches == 10
first = false
let fallback = matchingKnownScanEntries(false)
doAssert fallback == {wifiTargetFallback}
doAssert bootWifiTarget(fallback, true) == wifiTargetFallback
doAssert reconnectWifiTarget(wifiTargetPrimary, fallback) == wifiTargetFallback
doAssert loggedRows == 8 and loggedMatches == 10
''')
