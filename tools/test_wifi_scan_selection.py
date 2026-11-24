"""Verify retained-SSID selection returns a matching result pointer and index."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program

PLATFORM = r'''
const SCANU_MAX_RESULT_ENTRIES = 6
const IE_ID_SSID = 0'u8
type
  Env = object
    entries: array[SCANU_MAX_RESULT_ENTRIES, ScanuResultEntry]
    pendingJoinRxuMgtInd: pointer
    filterSsidLen: uint8
    filterSsid: array[32, uint8]
  RawFrame = object
    frameLen: uint16
  MacIe = object
    id, len: uint8
  SsidIe = object
    ie: MacIe
    ssidBytes: array[32, uint8]
  ConnectInfo = object
    channelDuration: uint32
  SmEnv = object
    connectInfo: pointer
  Log = proc(a, b: uint32; data: pointer; line: uint32) {.cdecl, varargs.}
var
  scanu_env: Env
  smEnv: SmEnv
  connectInfo: ConnectInfo
  scanuCachedSsids: array[SCANU_MAX_RESULT_ENTRIES, ScanuCachedSsid]
  scanuRequestEpoch: uint32
  nimFwDbgSsidSearch, nimFwDbgSsidEntries, nimFwDbgSsidHits: uint32
  interruptsEnabled = true
proc irqSave(): uint32 =
  result = interruptsEnabled.uint32 * 8
  interruptsEnabled = false
proc irqRestore(saved: uint32) = interruptsEnabled = (saved and 8) != 0
proc c_memcmp(a, b: pointer; size: csize_t): cint {.importc: "memcmp", header: "<string.h>".}
proc lengthPrefixedSsidView(p: pointer): ptr ScanSsidSlotView = cast[ptr ScanSsidSlotView](p)
proc smEnvView(): ptr SmEnv = addr smEnv
proc connectInfoView(p: pointer): ptr ConnectInfo = cast[ptr ConnectInfo](p)
proc nimFwTrace2U32(tag: string; a, b: uint32) = discard
proc nimFwConnectTrace2U32(tag: string; a, b: uint32) = discard
proc getLogFunc(offset: int): Log = nil
proc rxuMgtIndAt(p: pointer): ptr RawFrame = cast[ptr RawFrame](p)
proc rxuMgtIndIeStart(p: pointer): pointer =
  doAssert false, "this fixture exercises retained SSIDs only"
proc mac_ie_find(p: pointer; length: uint32; kind: uint8): pointer =
  doAssert false
proc ssidIeAt(p: pointer): ptr SsidIe = cast[ptr SsidIe](p)
'''


def snapshot_source() -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    body = scan.split("type ScanuResultSnapshot = object", 1)[1].split("\n{.emit:", 1)[0]
    return "type ScanuResultSnapshot = object" + body + "\n"


def source() -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code = layouts("ScanSsidSlotView", "ScanuCachedSsid", "ScanuResultEntry", "ScanChannelEntry") + PLATFORM
    for name in ["scanuCachedSsidFor", "scanuCachedSsidMatches", "scanuCachedSsidMeta"]:
        code += procedure(scan, name)
    code += snapshot_source() + procedure(scan, "scanu_search_by_ssid")
    return code + r'''
var query = ScanSsidSlotView(length: 4)
query.ssidBytes[0 .. 3] = [109'u8, 101, 115, 104]
proc setup() =
  scanu_env = default(Env)
  connectInfo.channelDuration = 0
  smEnv.connectInfo = addr connectInfo
  for slot in 0 ..< SCANU_MAX_RESULT_ENTRIES:
    scanu_env.entries[slot] = ScanuResultEntry(valid: 1, rssi: -60)
    scanuCachedSsids[slot] = ScanuCachedSsid(valid: 1, length: query.length)
    for i in 0 ..< query.length.int:
      scanuCachedSsids[slot].ssidBytes[i] = query.ssidBytes[i]
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_selected_index_matches_entry(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for strongest in 0 ..< SCANU_MAX_RESULT_ENTRIES:
  setup()
  scanu_env.entries[strongest].rssi = -10
  var selected = 0xFFFFFFFF'u32
  let entry = scanu_search_by_ssid(addr query, addr selected)
  doAssert entry == addr scanu_env.entries[strongest]
  doAssert selected == strongest.uint32, "selected index does not identify returned entry"
setup()
var selected = 0xFFFFFFFF'u32
doAssert scanu_search_by_ssid(addr query, addr selected) == addr scanu_env.entries[0]
doAssert selected == 0, "equal RSSI must retain the first entry and its index"
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_no_selection_preserves_index(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for absent in 0 .. 2:
  setup()
  for slot in 0 ..< SCANU_MAX_RESULT_ENTRIES:
    case absent
    of 0: scanu_env.entries[slot].valid = 0
    of 1: scanuCachedSsids[slot].ssidBytes[0] = 120
    else: scanu_env.entries[slot].rssi = -128
  var selected = 0x12345678'u32
  doAssert scanu_search_by_ssid(addr query, addr selected) == nil
  doAssert selected == 0x12345678'u32
setup()
doAssert scanu_search_by_ssid(addr query, nil) == addr scanu_env.entries[0]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_weaker_raw_frame_is_not_parsed(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
scanu_env.entries[0].rssi = -10
var weakerRaw = RawFrame(frameLen: 36)
scanu_env.entries[1].cachedRxuMgtInd = addr weakerRaw
var selected = 0xFFFFFFFF'u32
doAssert scanu_search_by_ssid(addr query, addr selected) == addr scanu_env.entries[0]
doAssert selected == 0'u32
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_directed_filter_controls_lookup(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
scanu_env.filterSsidLen = query.length
for i in 0 ..< query.length.int:
  scanu_env.filterSsid[i] = query.ssidBytes[i]
  scanuCachedSsids[4].ssidBytes[i] = 120
scanu_env.entries[4].rssi = -10
var selected = 0xFFFFFFFF'u32
doAssert scanu_search_by_ssid(addr query, addr selected) == addr scanu_env.entries[4]
doAssert selected == 4

scanu_env.filterSsid[0] = 120
selected = 0x12345678'u32
doAssert scanu_search_by_ssid(addr query, addr selected) == nil
doAssert selected == 0x12345678'u32
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_transition_key_management_selection(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, f'import "{FW / "rsn_parse"}"\n' + r'''
for bits in 0 .. 7:
  let mask = (if (bits and 1) != 0: WifiAuthMaskPsk else: 0'u32) or
    (if (bits and 2) != 0: WifiAuthMaskPskSha256 else: 0'u32) or
    (if (bits and 4) != 0: WifiAuthMaskSae else: 0'u32)
  for pmf in [false, true]:
    for required in [false, true]:
      let expected =
        if pmf or required:
          if (bits and 4) != 0: WifiKeyMgmtSae
          elif (bits and 2) != 0: WifiKeyMgmtPskSha256
          elif not required and (bits and 1) != 0: WifiKeyMgmtPsk
          else: WifiKeyMgmtNone
        elif (bits and 2) != 0: WifiKeyMgmtPskSha256
        elif (bits and 1) != 0: WifiKeyMgmtPsk
        else: WifiKeyMgmtNone
      for extra in [0'u32, 0x80000000'u32]:
        let selected = wifiPreferredKeyMgmtFromMask(mask or extra, pmf, required)
        doAssert selected == expected
        doAssert wifiDot11AuthTypeFromKeyMgmt(selected) ==
          (if expected == WifiKeyMgmtSae: 3'u8 else: 0'u8)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_selected_bss_auth_uses_connection_pmf_policy(tmp_path: Path, mode: str) -> None:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code = f'import "{FW / "rsn_parse"}"\n' + r'''
const MAX_VIFS = 2
const VIF_TYPE_STA = 0'u8
type
  ScanuResultEntry = object
    cachedRxuMgtInd: pointer
    bssid: array[6, uint8]
  ConnectInfoView = object
    channelDuration: uint32
    authType: uint8
    vifIdx: uint8
  RawFrame = object
    frameLen: uint16
  Vif = object
    vifType: uint8
    bssid: array[6, uint8]
  Security = object
    keyMgmt: uint32
    cipher, pmfCapable, pmfRequired: uint8
var
  observedMask: uint32
  observedPmfCapable, observedPmfRequired: bool
  observedCcmpGroup, observedCcmpPairwise: bool
  observedBipCmac128 = true
  nimFwDbgScanKeyMgmt, nimFwDbgScanAT: uint32
  ieBytes: array[2, uint8]
  vif: Vif
  security: Security
proc rxuMgtIndAt(p: pointer): ptr RawFrame = cast[ptr RawFrame](p)
proc rxuMgtIndIeStart(p: pointer): pointer = addr ieBytes[0]
proc vifChannelForIdx(index: uint8): ptr Vif =
  doAssert index == 0
  addr vif
proc vifSecurity(p: ptr Vif): ptr Security =
  doAssert p == addr vif
  addr security
proc wifiRsnAkmInfoFromIeBuffer(p: pointer; length: uint32): WifiRsnAkmInfo =
  doAssert p == cast[pointer](addr ieBytes[0])
  doAssert length == 2
  WifiRsnAkmInfo(authMask: observedMask, pmfCapable: observedPmfCapable,
                 pmfRequired: observedPmfRequired,
                 ccmpGroup: observedCcmpGroup,
                 ccmpPairwise: observedCcmpPairwise,
                 bipCmac128: observedBipCmac128)
'''
    code += procedure(scan, "selectedBssRsnAkmInfo")
    code += procedure(scan, "configureSelectedBssAuth")
    code += r'''
var frame = RawFrame(frameLen: 38)
var entry = ScanuResultEntry(cachedRxuMgtInd: addr frame,
  bssid: [2'u8, 3, 4, 5, 6, 7])
var connection: ConnectInfoView
for mask in [WifiAuthMaskPsk, WifiAuthMaskPskSha256, WifiAuthMaskSae,
             WifiAuthMaskPsk or WifiAuthMaskSae]:
  for flags in [0'u32, 0x200'u32, 0x400'u32, 0x600'u32]:
    observedMask = mask
    observedPmfCapable = true
    observedPmfRequired = false
    observedCcmpGroup = true
    observedCcmpPairwise = true
    connection = ConnectInfoView(channelDuration: flags, authType: 0xAA)
    configureSelectedBssAuth(addr entry, addr connection)
    let expected = wifiPreferredKeyMgmtFromMask(mask,
      (flags and 0x600'u32) != 0, (flags and 0x400'u32) != 0)
    doAssert nimFwDbgScanKeyMgmt == mask and nimFwDbgScanAT == expected
    doAssert connection.authType == wifiDot11AuthTypeFromKeyMgmt(expected)
observedMask = WifiAuthMaskPsk or WifiAuthMaskSae
observedPmfCapable = true
observedPmfRequired = false
vif = Vif(vifType: VIF_TYPE_STA, bssid: entry.bssid)
security = Security(keyMgmt: WifiKeyMgmtSae, cipher: 4,
  pmfCapable: 1, pmfRequired: 1)
connection = ConnectInfoView(channelDuration: 9, authType: 3)
configureSelectedBssAuth(addr entry, addr connection)
doAssert connection.authType == 3 and nimFwDbgScanAT == WifiKeyMgmtSae
vif.bssid[0] = 8
configureSelectedBssAuth(addr entry, addr connection)
doAssert connection.authType == 0 and nimFwDbgScanAT == WifiKeyMgmtPsk
vif.bssid = entry.bssid
security.pmfCapable = 0
connection.authType = 3
configureSelectedBssAuth(addr entry, addr connection)
doAssert connection.authType == 0 and nimFwDbgScanAT == WifiKeyMgmtPsk
observedMask = WifiAuthMaskPsk
security.pmfCapable = 1
connection.authType = 3
configureSelectedBssAuth(addr entry, addr connection)
doAssert connection.authType == 0 and nimFwDbgScanAT == WifiKeyMgmtPsk
observedMask = WifiAuthMaskSae
observedPmfCapable = false
connection = ConnectInfoView(channelDuration: 0x200, authType: 0)
configureSelectedBssAuth(addr entry, addr connection)
doAssert connection.authType == 0 and nimFwDbgScanAT == WifiKeyMgmtNone
observedPmfCapable = true
observedMask = WifiAuthMaskPsk or WifiAuthMaskSae
for missingCcmp in 0 .. 1:
  observedCcmpGroup = missingCcmp != 0
  observedCcmpPairwise = missingCcmp == 0
  connection = ConnectInfoView(channelDuration: 0x200, authType: 0)
  configureSelectedBssAuth(addr entry, addr connection)
  doAssert connection.authType == 0 and nimFwDbgScanAT == WifiKeyMgmtPsk
  security = Security(keyMgmt: WifiKeyMgmtSae, cipher: 4,
    pmfCapable: 1, pmfRequired: 1)
  connection = ConnectInfoView(channelDuration: 9, authType: 3)
  configureSelectedBssAuth(addr entry, addr connection)
  doAssert connection.authType == 0 and nimFwDbgScanAT == WifiKeyMgmtPsk
  observedMask = WifiAuthMaskSae
  connection = ConnectInfoView(channelDuration: 0x200, authType: 0)
  configureSelectedBssAuth(addr entry, addr connection)
  doAssert connection.authType == 0 and nimFwDbgScanAT == WifiKeyMgmtNone
  observedMask = WifiAuthMaskPsk or WifiAuthMaskSae
observedCcmpGroup = true
observedCcmpPairwise = true
observedBipCmac128 = false
observedPmfCapable = true
observedMask = WifiAuthMaskPsk or WifiAuthMaskSae
connection = ConnectInfoView(channelDuration: 0x200, authType: 0)
configureSelectedBssAuth(addr entry, addr connection)
doAssert connection.authType == 0 and nimFwDbgScanAT == WifiKeyMgmtNone
observedBipCmac128 = true
observedPmfCapable = false
observedMask = WifiAuthMaskPsk or WifiAuthMaskSae
connection = ConnectInfoView(channelDuration: 0x200, authType: 0)
configureSelectedBssAuth(addr entry, addr connection)
doAssert connection.authType == 0 and nimFwDbgScanAT == WifiKeyMgmtPsk
connection = ConnectInfoView(channelDuration: 0x400, authType: 0)
configureSelectedBssAuth(addr entry, addr connection)
doAssert connection.authType == 0 and nimFwDbgScanAT == WifiKeyMgmtNone
security = Security(keyMgmt: WifiKeyMgmtSae, cipher: 4,
  pmfCapable: 1, pmfRequired: 1)
connection = ConnectInfoView(channelDuration: 0, authType: 3)
configureSelectedBssAuth(addr entry, addr connection)
doAssert connection.authType == 0 and nimFwDbgScanAT == WifiKeyMgmtPsk
observedMask = WifiAuthMaskPsk
observedPmfRequired = true
connection = ConnectInfoView(channelDuration: 0, authType: 0)
configureSelectedBssAuth(addr entry, addr connection)
doAssert connection.authType == 0 and nimFwDbgScanAT == WifiKeyMgmtNone
observedPmfCapable = false
connection = ConnectInfoView(channelDuration: 0x200, authType: 0)
configureSelectedBssAuth(addr entry, addr connection)
doAssert connection.authType == 0 and nimFwDbgScanAT == WifiKeyMgmtNone
'''
    run_program(tmp_path, mode, code)
