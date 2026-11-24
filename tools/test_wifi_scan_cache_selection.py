"""Exercise host scan-cache ranking, filters, and retained retry penalties."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = ROOT / "src/bl808/wifi/support"


def source() -> str:
    code = "{.pragma: allcoreHttpPsramBss.}\n"
    code += (SUPPORT.parent / "fw_constants/status_codes.nim").read_text() + "\n"
    for name in ["local_types.nim", "vendor_layout_parts/events.nim",
                 "vendor_layout_parts/vif_table.nim"]:
        code += (SUPPORT / "defs_parts" / name).read_text() + "\n"
    state = (SUPPORT / "state.nim").read_text()
    code += state[state.index("var scanCache "):state.index("var nimfwDbgStaConnectStage")]
    code += r'''
proc zero(p: pointer; size: uint) = zeroMem(p, size.int)
proc ptrAt(p: pointer; offset: uint): pointer = cast[pointer](cast[uint](p) + offset)
proc loadU8(p: pointer; offset: uint): uint8 = cast[ptr uint8](ptrAt(p, offset))[]
proc loadI8(p: pointer; offset: uint): int8 = cast[int8](loadU8(p, offset))
proc loadI32(p: pointer; offset: uint): int32 = copyMem(addr result, ptrAt(p, offset), 4)
proc bl_msg_get_channel_nums(): cint = 14
'''
    scan = (SUPPORT / "scan_diag.nim").read_text()
    for name in ["scanCacheReset", "scanCacheClearSelection", "scannedBssidIsSpecific", "ssidBytesMatch",
                 "packBssidLo", "packBssidHi", "sameBssid", "scanCacheFailureLookup",
                 "scanCacheFailureRecord", "scanCacheStore", "scanCacheFind",
                 "scanCacheRecordConnectResult"]:
        code += procedure(scan, name)
    return code + r'''
proc setup() =
  scanCacheReset()
  scanCacheFailureUsed = default(typeof(scanCacheFailureUsed))
  scanCacheFailureCount = default(typeof(scanCacheFailureCount))
  scanCacheFailureBssid = default(typeof(scanCacheFailureBssid))

proc candidate(slot: int; signal: int8; failures: uint8; channel = 6'u8;
               ssid = "mesh") =
  scanCache[slot] = ScanCacheItem(used: 1, rssi: signal, failCount: failures,
    channel: channel, auth: 3, cipher: 4, ssidLen: ssid.len.uint8,
    bssid: [2'u8, 1, 2, 3, 4, slot.uint8])
  for i, ch in ssid: scanCache[slot].ssid[i] = ch.uint8

proc select(expected: int; candidates: uint32; bssid: ptr uint8 = nil;
            channel = 0'u8; ssid = "mesh") =
  var selectedBssid = [0xA5'u8, 1, 2, 3, 4, 5]
  var selectedChannel = 0xA5'u8
  var selectedRssi = 99'i8
  let before = scanCache
  let oldHits = nimfwDbgScanCacheHit
  let oldFinds = nimfwDbgScanCacheFind
  let found = scanCacheFind(ssid.cstring, ssid.len.csize_t, bssid, channel,
    addr selectedBssid, addr selectedChannel, addr selectedRssi)
  doAssert found == (expected >= 0), "candidate unexpectedly lost or selected"
  doAssert scanCache == before, "lookup changed candidate state"
  doAssert nimfwDbgScanCacheFind == oldFinds + 1
  doAssert nimfwDbgScanCacheCandidates == candidates
  doAssert scanCacheConnectPending == found
  doAssert nimfwDbgScanCacheHit == oldHits + found.uint32
  if found:
    let entry = scanCache[expected]
    doAssert selectedBssid == entry.bssid and selectedChannel == entry.channel
    doAssert scanCachePendingBssid == selectedBssid
    doAssert selectedRssi == entry.rssi
    doAssert nimfwDbgScanCacheSelectedSlot == expected.uint32
    doAssert nimfwDbgScanCacheSelectedBssidLo == packBssidLo(addr scanCache[expected].bssid)
    doAssert nimfwDbgScanCacheSelectedBssidHi == packBssidHi(addr scanCache[expected].bssid)
    doAssert nimfwDbgScanCacheSelectedMeta == (entry.channel.uint32 or
      (cast[uint8](entry.rssi).uint32 shl 8) or (entry.auth.uint32 shl 16) or
      (entry.cipher.uint32 shl 24))
  else:
    doAssert selectedBssid == [0xA5'u8, 1, 2, 3, 4, 5]
    doAssert selectedChannel == 0xA5 and selectedRssi == 99
    doAssert nimfwDbgScanCacheSelectedSlot == high(uint32)
    doAssert nimfwDbgScanCacheSelectedMeta == 0
    doAssert nimfwDbgScanCacheSelectedBssidLo == 0 and nimfwDbgScanCacheSelectedBssidHi == 0

proc storeAgain(entry: ScanCacheItem) =
  var beacon: array[64, uint8]
  let length = entry.ssidLen.int32
  copyMem(addr beacon[WifiBeaconSsidLenOff], unsafeAddr length, 4)
  copyMem(addr beacon[WifiBeaconBssidOff], unsafeAddr entry.bssid[0], 6)
  copyMem(addr beacon[WifiBeaconSsidOff], unsafeAddr entry.ssid[0], length)
  beacon[WifiBeaconChannelOff] = entry.channel
  beacon[WifiBeaconRssiOff] = cast[uint8](entry.rssi)
  beacon[WifiBeaconAuthOff] = entry.auth
  beacon[WifiBeaconCipherOff] = entry.cipher
  scanCacheStore(addr beacon[0])
'''


@pytest.mark.parametrize("mode", ["checked", "release"])
def test_station_join_uses_only_one_successful_scan_hint(tmp_path: Path, mode: str) -> None:
    manager = (SUPPORT / "mgmr_facade_parts/scan_connect.nim").read_text()
    manager = manager.split("\nproc wifi_mgmr_sta_disconnect*", 1)[0]
    run_program(tmp_path, mode, source() + r'''
type
  ScanCompleteCb = proc()
  MacAddr = array[6, uint8]
  Netif = object
const ScanActive = 1'u8
const WifiConnectDefault = 1'u32
const WifiConnectPmfCapable = 2'u32
var
  staEnabled = true
  busy: bool
  recoveryStatus, submitStatus: cint
  scanDoneCount, scanItemCount, scanConfirmationStatus: uint32
  connectDone, disconnectDone, lastStatusCode, lastReasonCode: int32
  sm_state: uint16
  nimfwDbgStaConnectStage, nimfwDbgStaConnectResult, nimfwDbgStaConnectState: uint32
  nimfwDbgStaConnectFreq, nimfwDbgStaConnectBssidLo, nimfwDbgStaConnectBssidHi: uint32
  lastBssid: MacAddr
  lastFreq: uint16
  hasBssid: bool
proc beginStationControl(): bool =
  if busy: return false
  busy = true
  true
proc endStationControl() = busy = false
proc wifi_mgmr_recover_terminal_connect_failure(joinAfterScan = false): cint = recoveryStatus
proc staIface(): pointer = nil
proc ifaceNetif(iface: pointer): pointer = nil
proc hwPtr(): pointer = nil
proc scanDiagReset() = discard
proc vendorPutsRaw(s: cstring) = discard
proc vendorPrintU32(n, base: uint32) = discard
proc loadU32(p: pointer; offset: uint): uint32 = copyMem(addr result, ptrAt(p, offset), 4)
proc loadU16(p: pointer; offset: uint): uint16 = copyMem(addr result, ptrAt(p, offset), 2)
proc c_strlen(s: cstring): csize_t = s.len.csize_t
proc wifiChannelToFreq(ch: uint8): uint16 = (2407 + 5 * ch.int).uint16
proc bl_main_scan(nif: ptr Netif; channels: ptr uint16; count: uint16; bssid: ptr MacAddr;
                  ssid: pointer; scanMode: uint8; duration: uint32): cint = submitStatus
proc bl_main_connect(s: ptr uint8; slen: cint; psk: ptr uint8; plen: cint;
                     pmk: ptr uint8; mlen: cint; bssid: ptr uint8; band: uint8;
                     freq: uint16; flags: uint32): cint =
  hasBssid = bssid != nil
  if hasBssid: lastBssid = cast[ptr MacAddr](bssid)[]
  lastFreq = freq
  0
''' + manager + r'''
var iface: pointer
proc join(bssid: ptr uint8 = nil) =
  doAssert wifi_mgmr_sta_connect(addr iface, "mesh", nil, nil, bssid, 0, 6) == 0
  doAssert lastFreq == 2437
proc populate() =
  doAssert wifi_mgmr_scan(nil, nil) == 0
  candidate(0, -30, 0)
  scanConfirmationStatus = 0
  scanDoneCount = 1

populate()
let prior = scanCache
busy = true
doAssert wifi_mgmr_scan(nil, nil) == -16
busy = false
join()
doAssert not hasBssid and scanCache == prior and not scanCacheConnectPending

populate()
recoveryStatus = -5
doAssert wifi_mgmr_scan(nil, nil) == -5
recoveryStatus = 0
join()
doAssert not hasBssid and scanCache == prior

doAssert wifi_mgmr_scan(nil, nil) == 0
scanConfirmationStatus = 0
scanDoneCount = 1
join()
doAssert not hasBssid

doAssert wifi_mgmr_scan(nil, nil) == 0
candidate(0, -30, 0)
scanDoneCount = 1 # Notification without an actual confirmation is insufficient.
join()
doAssert not hasBssid and scanCache == prior

populate()
scanConfirmationStatus = 1
join()
doAssert not hasBssid and scanCache == prior

submitStatus = -12
doAssert wifi_mgmr_scan(nil, nil) == -12
candidate(0, -30, 0)
scanConfirmationStatus = 0
scanDoneCount = 1
join()
doAssert not hasBssid
submitStatus = 0

populate()
join()
doAssert hasBssid and lastBssid == prior[0].bssid and scanCacheConnectPending
join()
doAssert not hasBssid and not scanCacheConnectPending and scanCache == prior
var explicit = [2'u8, 5, 6, 7, 8, 9]
join(addr explicit[0])
doAssert hasBssid and lastBssid == explicit
''', defines=("bl808WifiConnectCacheHint",))


CASES = {
    "score_domain": r'''
setup()
candidate(63, -128, 0)
for signal in low(int8).int .. high(int8).int:
  for failures in 0 .. high(uint8).int:
    scanCache[63].rssi = signal.int8
    scanCache[63].failCount = failures.uint8
    for directed in [false, true]:
      let bssid = if directed: addr scanCache[63].bssid[0] else: nil
      select(63, 1, bssid)
      select(63, 1, bssid, 6)
''',
    "ranking_and_filters": r'''
setup()
select(-1, 0)
candidate(2, -50, 0)
candidate(4, -20, 2)
candidate(63, -70, 1)
select(2, 3)
candidate(2, -96, 80)
candidate(4, -120, 79)
candidate(63, -110, 75)
select(63, 3)
scanCache[63].used = 0
select(2, 2) # Equal adjusted scores retain the first entry.
select(4, 1, addr scanCache[4].bssid[0])
scanCache[4].channel = 11
select(4, 1, channel = 11)
select(-1, 0, addr scanCache[4].bssid[0], 6)
select(-1, 0, channel = 14)
select(-1, 0, ssid = "mes")
select(-1, 0, ssid = "meshes")
select(-1, 0, ssid = "Mesh")
var absent = [2'u8, 6, 7, 8, 9, 10]
select(-1, 0, addr absent[0])
for wildcard in [[0'u8, 0, 0, 0, 0, 0], [255'u8, 255, 255, 255, 255, 255],
                 [1'u8, 1, 2, 3, 4, 5]]:
  var bssid = wildcard
  select(2, 2, addr bssid[0])
candidate(2, -100, 255, ssid = "a\0b")
select(2, 1, ssid = "a\0b")
select(-1, 0, ssid = "a")
''',
    "retry_lifecycle": r'''
setup()
candidate(0, -70, 0)
for attempt in 1 .. 300:
  select(0, 1)
  scanCacheRecordConnectResult(addr scanCache[0].bssid, WLAN_FW_AUTHENTICATION_FAIILURE)
  let expected = min(attempt, 255).uint8
  doAssert scanCache[0].failCount == expected
  doAssert scanCacheFailureLookup(addr scanCache[0].bssid[0]) == expected
  doAssert nimfwDbgScanCacheFailureCount == expected.uint32
  doAssert nimfwDbgScanCacheFailureMarks == attempt.uint32
  if attempt mod 25 == 0:
    let entry = scanCache[0]
    scanCacheReset()
    doAssert not scanCacheConnectPending
    storeAgain(entry)
    doAssert scanCache[0].failCount == expected
  select(0, 1, addr scanCache[0].bssid[0], 6)
scanCacheRecordConnectResult(addr scanCache[0].bssid, WLAN_FW_SUCCESSFUL)
doAssert scanCache[0].failCount == 0
doAssert scanCacheFailureLookup(addr scanCache[0].bssid[0]) == 0
let entry = scanCache[0]
scanCacheReset()
storeAgain(entry)
select(0, 1)
doAssert scanCache[0].failCount == 0
''',
    "attempt_identity": r'''
setup()
for slot in 0 ..< scanCache.len:
  candidate(slot, -60, 0, ssid = "other")
candidate(7, -90, 0)
select(7, 1)
var selected = scanCache[7]
var other = scanCache[0]
other.bssid[1] = 9
storeAgain(other) # Reuses the weakest slot before the result arrives.
doAssert scanCache[7].bssid == other.bssid
scanCacheRecordConnectResult(addr other.bssid, WLAN_FW_AUTHENTICATION_FAIILURE)
doAssert scanCacheConnectPending
scanCacheRecordConnectResult(addr selected.bssid, WLAN_FW_AUTHENTICATION_FAIILURE)
doAssert not scanCacheConnectPending
doAssert scanCache[7].failCount == 0
doAssert scanCacheFailureLookup(addr other.bssid) == 0
doAssert scanCacheFailureLookup(addr selected.bssid) == 1
scanCacheRecordConnectResult(addr selected.bssid, WLAN_FW_AUTHENTICATION_FAIILURE)
doAssert scanCacheFailureLookup(addr selected.bssid) == 1
scanCacheReset()
storeAgain(selected)
doAssert scanCache[0].failCount == 1
''',
    "local_failure_does_not_penalize": r'''
setup()
candidate(0, -50, 0)
candidate(1, -60, 0)
let bssid = addr scanCache[0].bssid
for status in [WLAN_FW_TX_AUTH_FRAME_ALLOCATE_FAIILURE,
    WLAN_FW_TX_ASSOC_FRAME_ALLOCATE_FAIILURE,
    WLAN_FW_CREATE_CHANNEL_CTX_FAILURE_WHEN_JOIN_NETWORK, WLAN_FW_ADD_STA_FAILURE,
    WLAN_FW_CONNECT_ABORT_WHEN_JOINING_NETWORK]:
  select(0, 2)
  scanCacheRecordConnectResult(bssid, status.uint16)
  doAssert not scanCacheConnectPending
  doAssert nimfwDbgScanCacheFailureMarks == 0
  doAssert scanCacheFailureLookup(bssid) == 0
scanCacheRecordConnectResult(bssid, WLAN_FW_AUTHENTICATION_FAIILURE)
doAssert scanCacheFailureLookup(bssid) == 0
select(0, 2)
scanCacheRecordConnectResult(bssid, WLAN_FW_AUTHENTICATION_FAIILURE)
select(1, 2)
''',
    "history_replacement": r'''
for success in [false, true]:
  setup()
  for slot in 0 ..< scanCacheFailureUsed.len:
    candidate(slot, -40, 0)
    scanCacheFailureUsed[slot] = 1
    scanCacheFailureBssid[slot] = scanCache[slot].bssid
    scanCacheFailureCount[slot] = 20
  scanCacheFailureCount[7] = 9
  scanCacheFailureCount[19] = 9
  let original = scanCacheFailureBssid
  var replacement = [2'u8, 20, 30, 40, 50, 60]
  let expected = (not success).uint8
  doAssert scanCacheFailureRecord(addr replacement, success) == expected
  doAssert scanCacheFailureBssid[7] == replacement
  doAssert scanCacheFailureLookup(addr replacement[0]) == expected
  var retired = original[7]
  doAssert scanCacheFailureLookup(addr retired[0]) == 0
  for slot in 0 ..< scanCacheFailureUsed.len:
    if slot == 7: continue
    doAssert scanCacheFailureBssid[slot] == original[slot]
    doAssert scanCacheFailureCount[slot] == (if slot == 19: 9'u8 else: 20'u8)
  doAssert scanCacheFailureRecord(addr replacement, false) == expected + 1
  scanCacheReset()
  candidate(0, -40, 0)
  scanCache[0].bssid = replacement
  let entry = scanCache[0]
  scanCacheReset()
  storeAgain(entry)
  doAssert scanCache[0].failCount == expected + 1
  select(0, 1)
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_scan_cache_selection(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
