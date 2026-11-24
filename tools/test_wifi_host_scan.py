"""Exercise the host scan wrapper's submission contract."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import ROOT, procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    wifi = ROOT / "src/bl808/wifi"
    return r'''
type
  Netif = object
    mac: array[6, uint8]
  MacAddr = array[6, uint8]
  MacSsid = array[33, uint8]
  ScanuPara = object
    channels: pointer
    bssid, ssid, mac: pointer
    channelNum: uint16
    mode: uint8
    duration: uint32
const
  channelNumDefault = 11
  SizeScanuPara = sizeof(ScanuPara)
  ScanChannelsOff = offsetof(ScanuPara, channels).uint
  ScanChannelNumOff = offsetof(ScanuPara, channelNum).uint
  ScanBssidOff = offsetof(ScanuPara, bssid).uint
  ScanSsidOff = offsetof(ScanuPara, ssid).uint
  ScanMacOff = offsetof(ScanuPara, mac).uint
  ScanModeOff = offsetof(ScanuPara, mode).uint
  ScanDurationOff = offsetof(ScanuPara, duration).uint
var
  requests: int
  submitted: ScanuPara
  submitStatus: cint
proc zero(p: pointer; size: int) = zeroMem(p, size)
proc put[T](p: pointer; offset: uint; value: T) =
  copyMem(cast[pointer](cast[uint](p) + offset), unsafeAddr value, sizeof(T))
proc storePtr(p: pointer; offset: uint; value: pointer) = put(p, offset, value)
proc storeU16(p: pointer; offset: uint; value: uint16) = put(p, offset, value)
proc storeU8(p: pointer; offset: uint; value: uint8) = put(p, offset, value)
proc storeU32(p: pointer; offset: uint; value: uint32) = put(p, offset, value)
proc netifHwaddr(netif: ptr Netif): pointer = addr netif.mac[0]
proc hwPtr(): pointer = cast[pointer](1)
proc bl_send_scanu_req(hw: pointer; request: ptr ScanuPara): cint =
  doAssert hw == hwPtr()
  inc requests
  submitted = request[]
  submitStatus
''' + procedure((wifi / "msg_tx/channel_plan_parts/fixed_channels.nim").read_text(),
                "bl_get_fixed_channels_is_valid") + (
        wifi / "main/host_ops_parts/scan.nim").read_text()


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_scan_submission_status_and_arguments(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
var netif: Netif
var channels = [1'u16, 11]
var bssid: MacAddr
var ssid: MacSsid
for status in [0.cint, -12, -16, -110]:
  submitStatus = status
  doAssert bl_main_scan(addr netif, addr channels[0], 0, addr bssid, addr ssid, 3, 456) == status
  doAssert submitted.channels == nil and submitted.channelNum == 0
  doAssert submitted.bssid == (addr bssid) and submitted.ssid == (addr ssid)
  doAssert submitted.mac == (addr netif.mac[0])
  doAssert submitted.mode == 3 and submitted.duration == 456
  doAssert bl_main_scan(addr netif, addr channels[0], 2, nil, nil, 0, 0) == status
  doAssert submitted.channels == (addr channels[0]) and submitted.channelNum == 2
doAssert requests == 8
doAssert bl_main_scan(nil, nil, 0, nil, nil, 0, 0) != 0
doAssert bl_main_scan(addr netif, nil, 1, nil, nil, 0, 0) != 0
doAssert bl_main_scan(addr netif, addr channels[0], 12, nil, nil, 0, 0) != 0
for invalid in [0'u16, 12]:
  channels[1] = invalid
  doAssert bl_main_scan(addr netif, addr channels[0], 2, nil, nil, 0, 0) != 0
doAssert requests == 8
''')
