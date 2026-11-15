"""Check scan-result filtering and refresh behavior against the vendor flow."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_scan_frame_request import source as admission_source


def source() -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    base = admission_source().split("proc scanu_frame_handler", 1)[0]
    base = base.replace(
        "const MAX_VIFS", layouts("SsidIeView", "DsParamSetIeView") + "const MAX_VIFS", 1)
    base = base.replace(
        "tuple[paramPtr: pointer, bssidFilterEnabled: uint8]",
        "tuple[paramPtr, pendingJoinRxuMgtInd: pointer, bssidFilterEnabled: uint8, resultCount: uint16]")
    base = base.replace(procedure(base, "mac_ie_find"), "")
    base = base.replace(procedure(base, "dsParamSetIeAt"), """
proc dsParamSetIeAt(p: pointer): ptr DsParamSetIeView = cast[ptr DsParamSetIeView](p)
""")
    base = base.replace(procedure(base, "dsParamFreq"), """
proc dsParamFreq(band: uint8; p: ptr DsParamSetIeView): uint16 =
  2407'u16 + 5'u16 * p.currentChannel.uint16
""")
    base += r'''
const IE_ID_SSID = 0'u8
type SmTxBuildContext = object
var
  scan_env: tuple[abortFlag: uint8]
  channel: ScanChannelEntry
  oldFrame, copiedFrame: array[96, uint8]
  allocations, frees: int
  nimFwDbgScanSsidLast, nimFwDbgBssRxFreq: uint32
  nimFwDbgBssDsFreq, nimFwDbgBssSelectedFreq: uint32
  nimFwDbgScanFrameAccepted, nimFwDbgScanFrameLast: uint32
proc macIeAt(p: uint): ptr MacIeView = cast[ptr MacIeView](p)
proc ssidIeAt(p: pointer): ptr SsidIeView = cast[ptr SsidIeView](p)
proc smTxOwnerCurrent(owner: SmTxBuildContext): bool = true
proc scanuCachedChannelFor(p: ptr ScanuResultEntry): ptr ScanChannelEntry = addr channel
proc configuredScanChannelEntryForFreq(freq: uint16): ptr ScanChannelEntry = nil
proc c_memcmp(a, b: pointer; size: csize_t): cint =
  if equalMem(a, b, size.int): 0 else: 1
proc c_memcpy(dest, src: pointer; size: csize_t): pointer =
  doAssert dest == (addr copiedFrame[0]) and src == (addr frame[0])
  doAssert size == rxuMgtIndAt(src).frameLen.uint32 + 32
  doAssert entry.cachedRxuMgtInd != dest
  copyMem(dest, src, size.int)
  dest
proc ke_msg_free_payload(p: pointer) =
  if p == nil: return
  doAssert p == (addr oldFrame[0])
  inc frees
proc ke_msg_try_alloc(id: uint16; dst, src: uint8; size: uint32): pointer =
  doAssert id == 0x1C00 and dst == 2 and src == 2
  doAssert size <= copiedFrame.len.uint32
  inc allocations
  addr copiedFrame[0]
proc prepareUpdate(hasDs: bool; strength: int8; ssid = 65'u8) =
  setup(1)
  original.flags = 0
  scanu_env.resultCount = 1
  scanu_env.pendingJoinRxuMgtInd = nil
  scan_env.abortFlag = 0
  channel = ScanChannelEntry(prim20Freq: 2412, band: 0, txPower: 20)
  entry.chanPtr = addr channel
  entry.beaconPeriod = 100
  entry.capInfo = 1
  entry.band = 1
  entry.rssi = -30
  entry.noiseFloor1 = -90
  entry.noiseFloor2 = -91
  entry.securityType = 0x101
  entry.securityAuth = 1
  entry.cachedRxuMgtInd = addr oldFrame[0]
  cached.valid = 1
  cached.length = 1
  cached.ssidBytes[0] = 90
  oldFrame = default(typeof(oldFrame))
  copiedFrame = default(typeof(copiedFrame))
  allocations = 0
  frees = 0
  let rx = rxuMgtIndAt(addr frame[0])
  rx.frameLen = if hasDs: 42 else: 39
  rx.rssi = strength
  rx.freq = 2462
  rx.beaconPeriod = 200
  rx.capInfo = 0
  rx.noiseFloor1 = -80
  rx.noiseFloor2 = -81
  frame[68] = IE_ID_SSID
  frame[69] = 1
  frame[70] = ssid
  if hasDs:
    frame[71] = IE_ID_DS_PARAM
    frame[72] = 1
    frame[73] = 6
'''
    base += procedure((FW / "mac_config_debug.nim").read_text(), "mac_ie_find")
    for name in ["scanuResetCachedSsid", "scanuCacheSsid", "scanuCacheChannel",
                 "scanuPublishFrameResult"]:
        base += procedure(scan, name)
    common = procedure(scan, "scanu_frame_handler").split("  var directedOwner:", 1)[0]
    return base + common + r'''
  reachedCommit = true
  scanuPublishFrameResult(frame, scanResultEntry, scanParam, scanEpoch,
    resultGeneration, numSsids, bfOn)
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_accepted_response_refreshes_result(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for directed in [0'u8, 1'u8]:
  for hasDs in [false, true]:
    for strength in [-75'i8, -30'i8, -20'i8]:
      for irq in [false, true]:
        prepareUpdate(hasDs, strength)
        scanu_env.bssidFilterEnabled = directed
        enabled = irq
        scanu_frame_handler(addr frame[0], frame.len.uint32)
        doAssert reachedCommit and forwards == 1 and enabled == irq
        doAssert entry.rssi == max(-30'i8, strength)
        doAssert entry.beaconPeriod == 200 and entry.capInfo == 0 and entry.band == 2
        doAssert entry.noiseFloor1 == -80 and entry.noiseFloor2 == -81
        if directed == 0:
          doAssert entry.securityType == 0 and entry.securityAuth == 0
        else:
          doAssert entry.securityType == 0x101 and entry.securityAuth == 1
        doAssert cached.valid == 1 and cached.length == 1 and cached.ssidBytes[0] == 65
        doAssert cached.generation == 10
        let expectedFreq: uint16 = if hasDs: 2437 elif strength > -30: 2462 else: 2412
        doAssert entry.chanPtr == (addr channel) and channel.prim20Freq == expectedFreq
        doAssert scanu_env.resultCount == 1
        if directed == 0:
          doAssert allocations == 1 and frees == 1
          doAssert entry.cachedRxuMgtInd == (addr copiedFrame[0])
          doAssert equalMem(addr copiedFrame[0], addr frame[0],
            (rxuMgtIndAt(addr frame[0]).frameLen + 32).int)
        else:
          doAssert allocations == 0 and frees == 0
          doAssert entry.cachedRxuMgtInd == (addr oldFrame[0])
        finish()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_rejected_ssid_preserves_result(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for directed in [0'u8, 1'u8]:
  for hasDs in [false, true]:
    for strength in [-75'i8, -20'i8]:
      for irq in [false, true]:
        prepareUpdate(hasDs, strength, 66)
        scanu_env.bssidFilterEnabled = directed
        enabled = irq
        let expected = (entry, cached, channel)
        scanu_frame_handler(addr frame[0], frame.len.uint32)
        doAssert not reachedCommit and forwards == 1 and enabled == irq
        doAssert (entry, cached, channel) == expected
        doAssert allocations == 0 and frees == 0 and scanu_env.resultCount == 1
        finish()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_first_response_initializes_result(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for hasDs in [false, true]:
  prepareUpdate(hasDs, -75)
  entry.valid = 0
  entry.rssi = -128
  entry.cachedRxuMgtInd = nil
  scanu_env.resultCount = 0
  scanu_frame_handler(addr frame[0], frame.len.uint32)
  doAssert reachedCommit and forwards == 1
  doAssert entry.valid == 1 and entry.rssi == -75
  doAssert scanu_env.resultCount == 1 and allocations == 1 and frees == 0
  doAssert cached.generation == 10 and cached.ssidBytes[0] == 65
  doAssert channel.prim20Freq == (if hasDs: 2437 else: 2462)
  finish()
''')
