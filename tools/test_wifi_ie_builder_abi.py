"""Check vendor calling conventions for the linked SSID and rate IE builders."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code = layouts("MacIeView", "RateSetView", "MacIeDataView", "SsidIeView")
    code += r'''
proc ssidIeAt(p: pointer): ptr SsidIeView = cast[ptr SsidIeView](p)
proc rateSetAt(p: pointer): ptr RateSetView = cast[ptr RateSetView](p)
proc macIeDataAt(p: pointer): ptr MacIeDataView = cast[ptr MacIeDataView](p)
proc co_pack8p(dst, src: pointer; count: uint32) =
  if count != 0: copyMem(dst, src, count.int)
'''
    code += procedure(scan, "me_add_ie_ssid")
    code += procedure(scan, "me_add_ie_ext_supp_rates")
    code += procedure(scan, "me_add_ie_customer")
    return code


def ht_oper_source() -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    phy = (FW / "kernel_mac_channel.nim").read_text()
    code = layouts("MacIeView", "HtOperIeView") + r'''
type
  TestChanDef {.packed.} = object
    band, chanType: uint8
    primFreq, centerFreq1: uint16
  TestCtx {.packed.} = object
    prefix: array[4, uint8]
    channel: TestChanDef
  VifChannelView {.packed.} = object
    prefix: array[64, uint8]
    chanCtxt: pointer
proc htOperIeAt(p: pointer): ptr HtOperIeView = cast[ptr HtOperIeView](p)
proc vifChannelAt(p: pointer): ptr VifChannelView = cast[ptr VifChannelView](p)
proc chanCtxtAt(p: pointer): ptr TestCtx = cast[ptr TestCtx](p)
'''
    code += procedure(phy, "phy_freq_to_channel").replace("weakExport, ", "")
    code += procedure(scan, "me_add_ie_ht_oper")
    return code


def bounded_ie_source() -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code = source() + layouts("DsParamSetIeView", "OneByteMacIeView", "TimIeView")
    code += r'''
proc dsParamSetIeAt(p: pointer): ptr DsParamSetIeView = cast[ptr DsParamSetIeView](p)
proc oneByteMacIeAt(p: pointer): ptr OneByteMacIeView = cast[ptr OneByteMacIeView](p)
proc timIeAt(p: pointer): ptr TimIeView = cast[ptr TimIeView](p)
'''
    for name in ("me_add_ie_supp_rates", "me_add_ie_ds", "me_add_ie_erp", "me_add_ie_tim"):
        code += procedure(scan, name)
    return code


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_fixed_ie_builders_reject_missing_or_invalid_inputs(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, bounded_ie_source() + r'''
var bytes: array[32, uint8]
for value in bytes.mitems: value = 0xA5
var cursor: pointer = nil
var rates = [2'u8, 2, 4]
doAssert me_add_ie_supp_rates(nil, addr rates[0]) == 0
doAssert me_add_ie_supp_rates(addr cursor, addr rates[0]) == 0
doAssert me_add_ie_ds(nil, 1) == 0
doAssert me_add_ie_ds(addr cursor, 1) == 0
doAssert me_add_ie_erp(nil, 0) == 0
doAssert me_add_ie_erp(addr cursor, 0) == 0
doAssert me_add_ie_tim(nil, 1) == 0
doAssert me_add_ie_tim(addr cursor, 1) == 0
cursor = addr bytes[4]
doAssert me_add_ie_supp_rates(addr cursor, nil) == 0
for count in [13'u8, 255'u8]:
  rates[0] = count
  doAssert me_add_ie_supp_rates(addr cursor, addr rates[0]) == 0
  doAssert cursor == addr bytes[4]
for value in bytes: doAssert value == 0xA5
rates[0] = 2
doAssert me_add_ie_supp_rates(addr cursor, addr rates[0]) == 4
doAssert bytes[4..7] == [1'u8, 2, 2, 4]
doAssert me_add_ie_ds(addr cursor, 6) == 3
doAssert bytes[8..10] == [3'u8, 1, 6]
doAssert me_add_ie_erp(addr cursor, 7) == 3
doAssert bytes[11..13] == [42'u8, 1, 7]
doAssert me_add_ie_tim(addr cursor, 2) == 6
doAssert bytes[14..19] == [5'u8, 4, 0xA5, 2, 0xA5, 0xA5]
doAssert cursor == addr bytes[20]
for i in 0 ..< 4: doAssert bytes[i] == 0xA5
for i in 20 ..< bytes.len: doAssert bytes[i] == 0xA5
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_ht_operation_ie_initializes_full_body(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, ht_oper_source() + r'''
for sample in [(0'u8, 2412'u16, 0'u8, 2412'u16, 1'u8, 0'u8),
               (0'u8, 2412'u16, 1'u8, 2422'u16, 1'u8, 5'u8),
               (1'u8, 5200'u16, 1'u8, 5190'u16, 40'u8, 7'u8)]:
  var ctx = TestCtx(channel: TestChanDef(band: sample[0], chanType: sample[2],
                                         primFreq: sample[1], centerFreq1: sample[3]))
  var vif = VifChannelView(chanCtxt: addr ctx)
  var bytes: array[32, uint8]
  for value in bytes.mitems: value = 0xA5
  var cursor: pointer = addr bytes[4]
  doAssert me_add_ie_ht_oper(addr cursor, addr vif) == 24
  doAssert cursor == addr bytes[28]
  doAssert bytes[4..12] == [61'u8, 22, sample[4], sample[5], 3, 0, 0, 0, 0xFF]
  for i in 13 .. 27: doAssert bytes[i] == 0
  for i in 0 .. 3: doAssert bytes[i] == 0xA5
  for i in 28 ..< bytes.len: doAssert bytes[i] == 0xA5
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_vendor_ie_builder_abi(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
let ssidBuilder: proc(buf: pointer; ssidLen: uint8; ssid: pointer): uint32 {.cdecl.} =
  me_add_ie_ssid
let extBuilder: proc(buf: pointer; rates: pointer): uint32 {.cdecl.} =
  me_add_ie_ext_supp_rates
var bytes: array[20, uint8]
for value in bytes.mitems: value = 0xA5
var cursor: pointer = addr bytes[4]
var ssid = [65'u8, 66, 67]
doAssert ssidBuilder(addr cursor, ssid.len.uint8, addr ssid[0]) == 5
doAssert cast[uint](cursor) == cast[uint](addr bytes[9])
doAssert bytes[4..8] == [0'u8, 3, 65, 66, 67]
for i in 0 ..< 4: doAssert bytes[i] == 0xA5
for i in 9 ..< bytes.len: doAssert bytes[i] == 0xA5

for value in bytes.mitems: value = 0xA5
cursor = addr bytes[4]
var rates = [10'u8, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
doAssert extBuilder(addr cursor, addr rates[0]) == 4
doAssert cast[uint](cursor) == cast[uint](addr bytes[8])
doAssert bytes[4..7] == [50'u8, 2, 9, 10]
for i in 0 ..< 4: doAssert bytes[i] == 0xA5
for i in 8 ..< bytes.len: doAssert bytes[i] == 0xA5

rates[0] = 12
for value in bytes.mitems: value = 0xA5
cursor = addr bytes[4]
doAssert extBuilder(addr cursor, addr rates[0]) == 6
doAssert bytes[4..9] == [50'u8, 4, 9, 10, 11, 12]
doAssert cursor == addr bytes[10]

for count in [0'u8, 8, 13, 255]:
  for value in bytes.mitems: value = 0xA5
  cursor = addr bytes[4]
  rates[0] = count
  doAssert extBuilder(addr cursor, addr rates[0]) == 0
  doAssert cursor == addr bytes[4]
  for value in bytes: doAssert value == 0xA5
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_ie_builders_reject_missing_source_without_claiming_bytes(
    tmp_path: Path, mode: str
) -> None:
    run_program(tmp_path, mode, source() + r'''
var bytes: array[40, uint8]
for value in bytes.mitems: value = 0xA5
var cursor: pointer = addr bytes[4]
var tooLong: array[33, uint8]
doAssert me_add_ie_ssid(addr cursor, 3, nil) == 0
doAssert me_add_ie_ssid(addr cursor, 33, addr tooLong[0]) == 0
doAssert me_add_ie_ssid(nil, 0, nil) == 0
doAssert cursor == addr bytes[4]
for value in bytes: doAssert value == 0xA5

var customer = [221'u8, 2, 0xAA, 0xBB]
doAssert me_add_ie_customer(addr bytes[4], nil, 4) == 0
doAssert me_add_ie_customer(nil, addr customer[0], 4) == 0
for value in bytes: doAssert value == 0xA5
doAssert me_add_ie_customer(addr bytes[4], addr customer[0], 4) == 4
doAssert bytes[4..7] == customer
for i in 0 ..< 4: doAssert bytes[i] == 0xA5
for i in 8 ..< bytes.len: doAssert bytes[i] == 0xA5
''')
