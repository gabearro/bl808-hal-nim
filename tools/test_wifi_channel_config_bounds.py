"""Keep frequency lookups inside the fixed-size ME channel table."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code = layouts("ScanChannelEntry", "MeChannelConfigEntry", "MeChannelConfigView",
                   "ScanuChannelConfigOverlay", "ScanuResultEntry", "RxuMgtIndView",
                   "MacIeView", "DsParamSetIeView")
    code += r'''
const SCANU_MAX_RESULT_ENTRIES = 6
const IE_ID_DS_PARAM = 3'u8
const IE_LEN_DS_PARAM = 1'u8
var config: MeChannelConfigView
var scanu_env: tuple[entries: array[SCANU_MAX_RESULT_ENTRIES, ScanuResultEntry]]
var scanuCachedChannels: array[SCANU_MAX_RESULT_ENTRIES, ScanChannelEntry]
var assertionCount: int
var nimFwDbgBssChanFixMeta, nimFwDbgBssChanFixRaw, nimFwDbgBssChanFixPtr: uint32
proc meChannelConfigView(): ptr MeChannelConfigView = addr config
proc scanuChannelConfig(): ptr ScanuChannelConfigOverlay =
  cast[ptr ScanuChannelConfigOverlay](addr config)
proc rxuMgtIndAt(p: pointer): ptr RxuMgtIndView = cast[ptr RxuMgtIndView](p)
proc rxuMgtIndIeStart(p: pointer): pointer = addr rxuMgtIndAt(p).ieData[0]
proc dsParamSetIeAt(p: pointer): ptr DsParamSetIeView =
  cast[ptr DsParamSetIeView](p)
proc dsParamFreq(band: uint8; ds: ptr DsParamSetIeView): uint16 =
  if band == 0 and ds.currentChannel in 1'u8 .. 13'u8:
    2407'u16 + ds.currentChannel.uint16 * 5'u16
  else:
    0xFFFF'u16
proc mac_ie_find(buf: pointer; n: uint32; id: uint8): pointer =
  var pos = cast[uint](buf)
  var remaining = n
  while remaining >= 2:
    let ie = cast[ptr MacIeView](pos)
    let size = ie.len.uint32 + 2'u32
    if size > remaining: return nil
    if ie.id == id: return cast[pointer](pos)
    pos += size.uint
    remaining -= size
  nil
proc c_memset(p: pointer; value: cint; n: csize_t): pointer =
  doAssert value == 0
  zeroMem(p, n.int)
  p
proc assert_err(condition, file: cstring; line: cint) =
  inc assertionCount
'''
    for name in ("configuredScanChannelEntryForFreq", "configuredChannelPtrForFreq",
                 "scanuCachedChannelFor", "scanuCacheChannel", "me_freq_to_chan_ptr",
                 "rxuMgtChannelPtr", "scanResultChannelPtr"):
        code += procedure(scan, name)
    return code


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_frequency_lookups_reject_oversized_table_count(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
config.count = 14
config.entries[0].freq = 2412
config.entries[13].freq = 2484
doAssert configuredScanChannelEntryForFreq(2412) ==
  cast[ptr ScanChannelEntry](addr config.entries[0])
doAssert configuredChannelPtrForFreq(2484) == addr config.entries[13]
doAssert me_freq_to_chan_ptr(0, 2484) == addr config.entries[13]
doAssert me_freq_to_chan_ptr(0, 5200) == nil
doAssert assertionCount == 0

# A corrupt count must not search beyond entries[13], even if the out-of-table
# bytes happen to resemble a requested frequency.
for count in [15'u8, 255'u8]:
  config.count = count
  doAssert configuredScanChannelEntryForFreq(2412) == nil
  doAssert configuredChannelPtrForFreq(2484) == nil
  doAssert me_freq_to_chan_ptr(0, 2484) == nil
doAssert assertionCount == 0
config.count = 1
doAssert me_freq_to_chan_ptr(1, 2412) == nil
doAssert assertionCount == 1
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_scan_result_uses_only_configured_channel(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
let entry = addr scanu_env.entries[0]
config.count = 1
config.entries[0] = MeChannelConfigEntry(freq: 2412, band: 0,
  flags: 3, txPower: 7)
doAssert scanuCacheChannel(entry, 0, 2412) == addr scanuCachedChannels[0]
doAssert scanuCachedChannels[0].prim20Freq == 2412
doAssert scanuCachedChannels[0].flags == 3
doAssert scanuCachedChannels[0].txPower == 7
doAssert scanuCacheChannel(entry, 0, 2437) == nil
doAssert scanuCachedChannels[0].prim20Freq == 0
doAssert scanuCacheChannel(entry, 1, 2412) == nil
doAssert scanuCachedChannels[0].txPower == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_cached_frame_fallback_keeps_ds_channel(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
var frame: array[96, uint8]
let entry = addr scanu_env.entries[0]
entry.cachedRxuMgtInd = addr frame[0]
let rx = rxuMgtIndAt(addr frame[0])
rx.frameLen = 39
rx.freq = 2412
rx.band = 0
config.count = 1
config.entries[0] = MeChannelConfigEntry(freq: 2412, band: 0)
frame[68] = IE_ID_DS_PARAM
frame[69] = 1
frame[70] = 6
doAssert scanResultChannelPtr(entry) == nil
doAssert entry.chanPtr == nil

config.count = 2
config.entries[1] = MeChannelConfigEntry(freq: 2437, band: 0)
doAssert scanResultChannelPtr(entry) == addr config.entries[1]
doAssert (nimFwDbgBssChanFixMeta and 0xFFFF'u32) == 2437'u32

entry.chanPtr = nil
frame[68] = 0
frame[69] = 1
frame[70] = 65
doAssert scanResultChannelPtr(entry) == addr config.entries[0]

entry.chanPtr = nil
config.entries[0].band = 1
doAssert scanResultChannelPtr(entry) == nil
doAssert entry.chanPtr == nil

rx.band = 1
rx.freq = 5200
config.entries[0].freq = 5200
doAssert scanResultChannelPtr(entry) == addr config.entries[0]
doAssert assertionCount == 0
entry.chanPtr = nil
rx.band = 0
rx.freq = 2412

frame[68] = IE_ID_DS_PARAM
frame[69] = 0
rx.frameLen = 38
doAssert scanResultChannelPtr(entry) == nil
rx.frameLen = 35
doAssert scanResultChannelPtr(entry) == nil
''')
