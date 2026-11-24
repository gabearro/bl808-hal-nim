"""Exercise the BSS channel helpers with exact-size Country IE buffers."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
type
  FixtureBss {.packed.} = object
    prefix: array[76, uint8]
    channel: pointer
    centerFreq1, centerFreq2: uint16
    padding: array[46, uint8]
    bandwidth, phyBandwidth: uint8
  GuardedBss = object
    before: array[16, uint8]
    value: FixtureBss
    after: array[16, uint8]
var
  bss: GuardedBss
  channel: ScanChannelEntry
proc malloc(n: csize_t): pointer {.importc, header: "<stdlib.h>".}
proc free(p: pointer) {.importc, header: "<stdlib.h>".}
proc macIeAt(p: uint): ptr MacIeView = cast[ptr MacIeView](p)
proc totalLen(p: ptr MacIeView): uint = p.len.uint + 2
template macIePayload(p: ptr MacIeView): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](cast[uint](p) + 2)
proc countryTripletAt(p: pointer): ptr CountryTripletView = cast[ptr CountryTripletView](p)
proc setup(band: uint8; freq: uint16) =
  let bytes = cast[ptr UncheckedArray[uint8]](addr bss)
  for i in 0 ..< sizeof(bss): bytes[i] = 0xA5
  bss.value.channel = addr channel
  bss.value.centerFreq1 = 2472
  bss.value.centerFreq2 = 2484
  bss.value.bandwidth = 3
  bss.value.phyBandwidth = 2
  channel = ScanChannelEntry(prim20Freq: freq, band: band, flags: 0x5A,
    txPower: 31, txPowerTailPadding: 0xBC)
proc applyCountry(payload: openArray[uint8]) =
  doAssert payload.len <= 255
  let bytes = cast[ptr UncheckedArray[uint8]](malloc((payload.len + 2).csize_t))
  doAssert bytes != nil
  bytes[0] = 7
  bytes[1] = payload.len.uint8
  for i in 0 ..< payload.len: bytes[i + 2] = payload[i]
  me_extract_country_reg(bytes, (payload.len + 2).uint32, addr bss.value)
  free(bytes)
'''


def source(*, host_phy: bool = False) -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    layout = (FW / "layout_types.nim").read_text()
    code = layouts("MacIeView", "ScanChannelEntry", "CountryTripletView")
    if "  BssChannelOverlay " in layout:
        code += layouts("BssChannelOverlay")
        code += "\n" + "template bssChannelAt" + layout.split(
            "template bssChannelAt", 1)[1].split("\n\n", 1)[0] + "\n"
    else:
        code += layouts("StaBandwidthOverlay", "CountryRegOutputOverlay", "CountryRegView")
        code += r'''
type StaInfoView = object
proc staInfoAt(p: pointer): ptr StaInfoView = cast[ptr StaInfoView](p)
proc staBandwidthOverlay(p: ptr StaInfoView): ptr StaBandwidthOverlay =
  cast[ptr StaBandwidthOverlay](cast[uint](p) + 76)
proc countryRegOutputAt(p: pointer): ptr CountryRegOutputOverlay =
  cast[ptr CountryRegOutputOverlay](p)
proc countryRegAt(p: pointer): ptr CountryRegView = cast[ptr CountryRegView](p)
'''
    code += "proc me_extract_country_reg*(ieBuf: pointer; ieLen: uint32; out_ptr: pointer) {.exportc, cdecl.}\n"
    code += PLATFORM
    code += procedure((FW / "mac_config_debug.nim").read_text(), "mac_ie_find")
    phy_source = (FW.parent / "msg_tx/channel_plan_parts/phy_conversion.nim"
                  if host_phy else FW / "kernel_mac_channel.nim")
    if host_phy:
        code += "const PHY_BAND_2G4 = 0'u8\n"
    code += procedure(phy_source.read_text(), "phy_channel_to_freq").replace("weakExport, ", "")
    phy = procedure(phy_source.read_text(), "phy_freq_to_channel")
    code += phy.replace("{.weakExport, cdecl.}", "{.cdecl.}")
    code += procedure(scan, "me_bw_check")
    code += procedure(scan, "me_extract_country_reg")
    return code


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_firmware_phy_conversion_boundaries(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for sample in [(0'u8, 0xffff'u16), (1'u8, 2412'u16),
               (13'u8, 2472'u16), (14'u8, 2484'u16),
               (15'u8, 0xffff'u16)]:
  doAssert phy_channel_to_freq(0'u8, sample[0]) == sample[1]
for sample in [(0'u8, 0xffff'u16), (1'u8, 5005'u16),
               (164'u8, 5820'u16), (165'u8, 5825'u16),
               (166'u8, 0xffff'u16)]:
  doAssert phy_channel_to_freq(1'u8, sample[0]) == sample[1]
doAssert phy_channel_to_freq(2'u8, 1'u8) == 0xffff'u16
for sample in [(5000'u16, 0'u8), (5004'u16, 0'u8),
               (5005'u16, 1'u8), (5006'u16, 0'u8),
               (5009'u16, 0'u8), (5010'u16, 2'u8),
               (5820'u16, 164'u8), (5824'u16, 0'u8),
               (5825'u16, 165'u8), (5826'u16, 0'u8)]:
  doAssert phy_freq_to_channel(1'u8, sample[0]) == sample[1]
for sample in [(2411'u16, 0'u8), (2412'u16, 1'u8),
               (2413'u16, 0'u8), (2416'u16, 0'u8),
               (2417'u16, 2'u8), (2472'u16, 13'u8),
               (2473'u16, 0'u8), (2476'u16, 0'u8),
               (2477'u16, 0'u8), (2481'u16, 0'u8),
               (2482'u16, 0'u8), (2483'u16, 0'u8),
               (2484'u16, 14'u8), (2485'u16, 0'u8)]:
  doAssert phy_freq_to_channel(0'u8, sample[0]) == sample[1]
doAssert phy_freq_to_channel(2'u8, 2412'u16) == 0'u8
for channel in 1'u8 .. 14'u8:
  doAssert phy_freq_to_channel(0'u8, phy_channel_to_freq(0'u8, channel)) == channel
for channel in 1'u8 .. 165'u8:
  doAssert phy_freq_to_channel(1'u8, phy_channel_to_freq(1'u8, channel)) == channel
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_linked_host_five_ghz_conversion(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(host_phy=True) + r'''
for sample in [(0.cint, 0xffff'u16), (1.cint, 5005'u16),
               (164.cint, 5820'u16), (165.cint, 5825'u16),
               (166.cint, 0xffff'u16)]:
  doAssert phy_channel_to_freq(1'u8, sample[0]) == sample[1]
for sample in [(5004'u16, 0'u8), (5005'u16, 1'u8),
               (5006'u16, 0'u8), (5824'u16, 0'u8),
               (5820'u16, 164'u8), (5825'u16, 165'u8),
               (5826'u16, 0'u8)]:
  doAssert phy_freq_to_channel(1'u8, sample[0]) == sample[1]
for sample in [(2413'u16, 0'u8), (2477'u16, 0'u8),
               (2483'u16, 0'u8), (2484'u16, 14'u8)]:
  doAssert phy_freq_to_channel(0'u8, sample[0]) == sample[1]
for channel in 1 .. 14:
  doAssert phy_freq_to_channel(0'u8, phy_channel_to_freq(0'u8, channel.cint)) == channel.uint8
for channel in 1 .. 165:
  doAssert phy_freq_to_channel(1'u8, phy_channel_to_freq(1'u8, channel.cint)) == channel.uint8
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_country_power_uses_channel_band_and_frequency(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for test in [(0'u8, 2412'u16, 22'i8), (0'u8, 2437'u16, 22'i8),
             (0'u8, 2484'u16, 22'i8), (1'u8, 5180'u16, 19'i8),
             (1'u8, 5220'u16, 19'i8), (1'u8, 5805'u16, -5'i8),
             (1'u8, 5825'u16, -5'i8)]:
  setup(test[0], test[1])
  let expectedBss = bss
  var expectedChannel = channel
  expectedChannel.txPower = test[2]
  applyCountry([85'u8, 83, 32, 1, 14, 22, 36, 8, 19, 149, 5, 251])
  doAssert channel == expectedChannel and bss == expectedBss
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_country_power_rejects_off_grid_frequency(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for sample in [(0'u8, 2413'u16), (0'u8, 2477'u16),
               (1'u8, 5006'u16), (1'u8, 5824'u16)]:
  setup(sample[0], sample[1])
  let expected = (bss, channel)
  applyCountry([85'u8, 83, 32, 1, 14, 22, 149, 5, 19, 164, 1, 19])
  doAssert (bss, channel) == expected
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_country_power_with_linked_host_phy(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(host_phy=True) + r'''
for number in 1 .. 14:
  let freq = if number == 14: 2484'u16 else: (2407 + number * 5).uint16
  setup(0, freq)
  let expectedBss = bss
  var expectedChannel = channel
  expectedChannel.txPower = 17
  applyCountry([85'u8, 83, 32, 1, 14, 17])
  doAssert channel == expectedChannel and bss == expectedBss
setup(1, 5180)
let expectedBss = bss
var expectedChannel = channel
expectedChannel.txPower = 19
applyCountry([85'u8, 83, 32, 36, 8, 19])
doAssert bss == expectedBss and channel == expectedChannel
setup(1, 5825)
let upperBss = bss
var upperChannel = channel
upperChannel.txPower = -5
applyCountry([85'u8, 83, 32, 149, 5, 251])
doAssert bss == upperBss and channel == upperChannel
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_country_partial_triplets_leave_channel_unchanged(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
let payload = [85'u8, 83, 32, 1, 14, 22, 44, 1]
for size in 0 .. payload.len:
  setup(1, 5220)
  let expected = (bss, channel)
  applyCountry(payload.toOpenArray(0, size - 1))
  doAssert (bss, channel) == expected
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_country_maximum_length_and_nonwrapping_ranges(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
var payload: array[255, uint8]
payload[0] = 85
payload[1] = 83
payload[2] = 32
for offset in countup(3, 252, 3):
  payload[offset] = 200
for size in [254, 255]:
  setup(1, 5220)
  let expected = (bss, channel)
  applyCountry(payload.toOpenArray(0, size - 1))
  doAssert (bss, channel) == expected
payload[252] = 44
payload[253] = 1
payload[254] = 13
setup(1, 5220)
applyCountry(payload)
doAssert channel.txPower == 13
setup(0, 2412)
let expected = (bss, channel)
applyCountry([85'u8, 83, 32, 253, 5, 7])
doAssert (bss, channel) == expected
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_country_missing_channel_and_unmatched_frames(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for test in [(0'u8, 2400'u16), (1'u8, 4900'u16), (2'u8, 2412'u16)]:
  setup(test[0], test[1])
  let expected = (bss, channel)
  applyCountry([85'u8, 83, 32, 0, 14, 17])
  doAssert (bss, channel) == expected
setup(1, 5220)
let unmatched = (bss, channel)
applyCountry([85'u8, 83, 32, 36, 1, 17])
doAssert (bss, channel) == unmatched
setup(0, 2412)
bss.value.channel = nil
let expected = (bss, channel)
applyCountry([85'u8, 83, 32, 1, 14, 17])
doAssert (bss, channel) == expected
me_extract_country_reg(nil, 0, nil)
me_extract_country_reg(nil, 0, addr bss.value)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_bandwidth_reset_uses_bss_channel_layout(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for freq in [2412'u16, 5180'u16]:
  for hasChannel in [false, true]:
    setup(0, freq)
    if not hasChannel: bss.value.channel = nil
    var expected = bss
    let expectedChannel = channel
    expected.value.centerFreq1 = if hasChannel: freq else: 0
    expected.value.centerFreq2 = 0
    expected.value.bandwidth = 0
    me_bw_check(addr bss.value)
    doAssert bss == expected and channel == expectedChannel
me_bw_check(nil)
''')
