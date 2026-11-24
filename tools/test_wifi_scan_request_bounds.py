"""Exercise host scan-request bounds before the firmware message is allocated."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import ROOT, procedure
from test_wifi_message_allocation import run_program


MSG = ROOT / "src/bl808/wifi/msg_tx"


def source() -> str:
    code = f'import "{MSG.parent / "host_table_layout.nim"}"\n'
    code += "".join((MSG / path).read_text() + "\n" for path in (
        "layout/host_cmd.nim", "layout/common_payloads.nim",
        "layout/interface_security.nim", "layout/request_sizes.nim",
        "layout/scanu_sm_payloads.nim",
    ))
    code += r'''
const SCANU_START_REQ = 2048'u16
const TASK_SCANU = 2'u8
const DRV_TASK_ID = 255'u8
type
  BlHw = object
  ScanuPara = object
    channels, bssid, ssid, mac: pointer
    channelCount: uint16
    mode: uint8
    duration: uint32
var
  hw: BlHw
  para: ScanuPara
  channelNumDefault: int32
  channels: array[14, uint16]
  ssid: array[34, uint8]
  memory: array[336, uint8]
  allocations, sends: int
  allocationFails: bool
proc ptrAt(base: pointer; offset: uint): pointer =
  cast[pointer](cast[uint](base) + offset)
proc loadPtr(base: pointer; offset: uint): pointer =
  doAssert base == addr para
  case offset
  of ScanParaChannelsOff: para.channels
  of ScanParaBssidOff: para.bssid
  of ScanParaSsidOff: para.ssid
  of ScanParaMacOff: para.mac
  else: doAssert false; nil
proc loadU8(base: pointer; offset: uint): uint8 =
  if base == addr para:
    doAssert offset == ScanParaModeOff
    para.mode
  else:
    doAssert base == (addr ssid[0]) and offset == MacSsidLengthOff
    ssid[0]
proc loadU16(base: pointer; offset: uint): uint16 =
  doAssert base == (addr para) and offset == ScanParaChannelNumOff
  para.channelCount
proc loadU32(base: pointer; offset: uint): uint32 =
  doAssert base == (addr para) and offset == ScanParaDurationOff
  para.duration
proc storeU8(base: pointer; offset: uint; value: uint8) =
  doAssert base == (addr memory[8]) and offset < SizeScanuStartReq.uint
  memory[8 + offset.int] = value
proc storeU16(base: pointer; offset: uint; value: uint16) =
  storeU8(base, offset, value.uint8)
  storeU8(base, offset + 1, (value shr 8).uint8)
proc storeU32(base: pointer; offset: uint; value: uint32) =
  for i in 0 ..< 4: storeU8(base, offset + i.uint, (value shr (i * 8)).uint8)
proc storePtr(base: pointer; offset: uint; value: pointer) =
  doAssert value == nil
  storeU32(base, offset, 0)
proc copyMem(dest, source: pointer; length: uint) =
  let start = cast[uint](addr memory[8])
  doAssert cast[uint](dest) >= start and cast[uint](dest) + length <= start + SizeScanuStartReq.uint
  for i in 0 ..< length.int:
    cast[ptr UncheckedArray[uint8]](dest)[i] = cast[ptr UncheckedArray[uint8]](source)[i]
proc blMsgZalloc(id: uint16; dest, src: uint8; size: uint16): pointer =
  doAssert id == SCANU_START_REQ and dest == TASK_SCANU and src == DRV_TASK_ID
  doAssert size == SizeScanuStartReq
  inc allocations
  if allocationFails: return nil
  for i in 8 ..< 328: memory[i] = 0
  addr memory[8]
proc blSendMsg(device: ptr BlHw; request: pointer; wait: cint;
               response: uint16; output: pointer): cint =
  doAssert device == (addr hw) and request == (addr memory[8])
  doAssert wait == 0 and response == 0 and output == nil
  inc sends
  77
proc setup() =
  para = default(ScanuPara)
  channelNumDefault = 14
  allocations = 0
  sends = 0
  allocationFails = false
  for value in memory.mitems: value = 0xA5
  for i in 0 ..< channels.len: channels[i] = (i + 1).uint16
  for value in ssid.mitems: value = 0
  para.duration = 12345
proc guardsIntact() =
  for i in 0 ..< 8: doAssert memory[i] == 0xA5
  for i in 328 ..< memory.len: doAssert memory[i] == 0xA5
'''
    code += procedure((MSG / "channel_plan_parts/state.nim").read_text(), "channelFreq")
    code += procedure((MSG / "scan_parts/channel_entry.nim").read_text(), "fillScanChan")
    code += procedure((MSG / "scan_parts/scan_request.nim").read_text(), "bl_send_scanu_req")
    return code


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_scan_request_bounds(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
doAssert bl_send_scanu_req(nil, addr para) == -Einval
doAssert bl_send_scanu_req(addr hw, nil) == -Einval
doAssert allocations == 0 and sends == 0

for count in [-1'i32, 0, 11, 14, 15, 255, 256]:
  setup()
  channelNumDefault = count
  let status = bl_send_scanu_req(addr hw, addr para)
  if count <= 0:
    doAssert status == -Einval and allocations == 0 and sends == 0
  else:
    doAssert status == 77 and allocations == 1 and sends == 1
    doAssert memory[8 + ScanuChanCntOff.int] == min(count, 14).uint8
  guardsIntact()

for count in [15'u16, 255, 256, 65535]:
  setup()
  para.channelCount = count
  doAssert bl_send_scanu_req(addr hw, addr para) == -Einval
  doAssert allocations == 0 and sends == 0
  guardsIntact()

for badChannel in [0'u16, 15, 255, 65535]:
  setup()
  para.channelCount = 14
  para.channels = addr channels[0]
  channels[13] = badChannel
  doAssert bl_send_scanu_req(addr hw, addr para) == -Einval
  doAssert allocations == 0 and sends == 0
  guardsIntact()

setup()
channelNumDefault = 11
para.channelCount = 1
para.channels = addr channels[0]
channels[0] = 12
doAssert bl_send_scanu_req(addr hw, addr para) == -Einval
doAssert allocations == 0 and sends == 0
guardsIntact()

for length in [33'u8, 255]:
  setup()
  para.ssid = addr ssid[0]
  ssid[0] = length
  doAssert bl_send_scanu_req(addr hw, addr para) == -Einval
  doAssert allocations == 0 and sends == 0
  guardsIntact()

setup()
para.channelCount = 14
para.channels = addr channels[0]
para.ssid = addr ssid[0]
ssid[0] = 32
for i in 1 .. 32: ssid[i] = uint8(i)
doAssert bl_send_scanu_req(addr hw, addr para) == 77
doAssert allocations == 1 and sends == 1
doAssert memory[8 + ScanuChanCntOff.int] == 14
doAssert memory[8 + ScanuChanOff.int + 13 * ScanChanSize.int] == 0xB4
doAssert memory[8 + ScanuChanOff.int + 13 * ScanChanSize.int + 1] == 0x09
doAssert memory[8 + ScanuSsidOff.int] == 32
for i in 1 .. 32: doAssert memory[8 + ScanuSsidOff.int + i] == uint8(i)
guardsIntact()

setup()
allocationFails = true
doAssert bl_send_scanu_req(addr hw, addr para) == -Enomem
doAssert allocations == 1 and sends == 0
guardsIntact()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", ["missing_list", "bssid"])
def test_scan_request_selection(tmp_path: Path, mode: str, case: str) -> None:
    checks = {
        "missing_list": r'''
for count in [1'u16, 11]:
  setup()
  channelNumDefault = 11
  para.channelCount = count
  doAssert bl_send_scanu_req(addr hw, addr para) == -Einval
  doAssert allocations == 0 and sends == 0
  guardsIntact()
''',
        "bssid": r'''
setup()
var target = [2'u8, 3, 4, 5, 6, 7]
for targeted in [false, true]:
  para.bssid = if targeted: addr target[0] else: nil
  para.channelCount = 1
  channels[0] = 9
  para.channels = addr channels[0]
  doAssert bl_send_scanu_req(addr hw, addr para) == 77
  for i in 0 ..< target.len:
    doAssert memory[8 + ScanuBssidOff.int + i] == (if targeted: target[i] else: 0xFF'u8)
  guardsIntact()
''',
    }
    run_program(tmp_path, mode, source() + checks[case])


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_configured_channel_plans(tmp_path: Path, mode: str) -> None:
    country = (MSG / "channel_plan_parts/country.nim").read_text()
    fixed = (MSG / "channel_plan_parts/fixed_channels.nim").read_text()
    platform = r'''
var countryCode0, countryCode1, countryMaxPower: uint8
proc bl_os_printf(fmt, code: cstring; count: int32) = discard
'''
    run_program(tmp_path, mode, source() + platform + country + "\n" + fixed + r'''
const expectedMhz = [2412'u16, 2417, 2422, 2427, 2432, 2437, 2442,
                     2447, 2452, 2457, 2462, 2467, 2472, 2484]
proc checkEntry(slot, channel: int) =
  let offset = 8 + ScanuChanOff.int + slot * ScanChanSize.int
  let freqOffset = offset + ScanChanFreqOff.int
  let freq = memory[freqOffset].uint16 or (memory[freqOffset + 1].uint16 shl 8)
  doAssert freq == expectedMhz[channel - 1]
  doAssert memory[offset + ScanChanBandOff.int] == NL80211_BAND_2GHZ

for (profile, count) in [("US", 11), ("EU", 13), ("CN", 13), ("JP", 14)]:
  setup()
  bl_msg_update_channel_cfg(profile.cstring)
  doAssert bl_msg_get_channel_nums() == count.cint
  doAssert bl_send_scanu_req(addr hw, addr para) == 77
  doAssert memory[8 + ScanuChanCntOff.int] == count.uint8
  for channel in 1 .. count:
    checkEntry(channel - 1, channel)
  guardsIntact()

  setup()
  bl_msg_update_channel_cfg(profile.cstring)
  para.channelCount = count.uint16
  para.channels = addr channels[0]
  for slot in 0 ..< count:
    channels[slot] = (count - slot).uint16
  doAssert bl_send_scanu_req(addr hw, addr para) == 77
  doAssert memory[8 + ScanuChanCntOff.int] == count.uint8
  for slot in 0 ..< count:
    checkEntry(slot, count - slot)
  guardsIntact()

  for channel in 1 .. expectedMhz.len:
    setup()
    bl_msg_update_channel_cfg(profile.cstring)
    para.channelCount = 1
    para.channels = addr channels[0]
    channels[0] = channel.uint16
    let accepted = channel <= count
    doAssert bl_get_fixed_channels_is_valid(addr channels[0], 1) == accepted.cint
    let result = bl_send_scanu_req(addr hw, addr para)
    if accepted:
      doAssert result == 77 and allocations == 1 and sends == 1
      doAssert memory[8 + ScanuChanCntOff.int] == 1
      checkEntry(0, channel)
    else:
      doAssert result == -Einval and allocations == 0 and sends == 0
    guardsIntact()
''')
