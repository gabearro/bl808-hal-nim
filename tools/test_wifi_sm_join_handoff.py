"""Check connect-request channel hints against the vendor SM handoff."""

from pathlib import Path

import pytest

from test_wifi_connect_rx_epoch import FW, PLATFORM
from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    code = r'''
var lookups: int
var cachedBssid = [4'u8, 5, 6, 7, 8, 9]
var handedBssid: array[6, uint8]
var handedChannel: uint16
''' + PLATFORM
    code = code.replace(procedure(code, "sm_get_bss_params"), r'''
var cachedChannel = ScanChannelEntry(prim20Freq: 2462)
proc sm_get_bss_params(bss, channel: ptr pointer) =
  inc lookups
  bss[] = addr cachedBssid[0]
  channel[] = addr cachedChannel
''', 1)
    code = code.replace(procedure(code, "sm_join_bss"), r'''
proc sm_join_bss(mac, bss, channel: pointer; flag: bool) =
  boundary()
  doAssert bss != nil and channel != nil
  inc joins
  handedBssid = cast[ptr array[6, uint8]](bss)[]
  handedChannel = cast[ptr ScanChannelEntry](channel).prim20Freq
''', 1)
    code = code.replace(procedure(code, "sm_scan_bss"), r'''
proc sm_scan_bss(mac, bss, channel: pointer) =
  boundary()
  inc scans
  if bss != nil: handedBssid = cast[ptr array[6, uint8]](bss)[]
  if channel != nil: handedChannel = cast[ptr ScanChannelEntry](channel).prim20Freq
''', 1)
    code += r'''
proc smTeardown(p: pointer): bool = false
'''
    rx = (FW / "rx_layer.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    code += procedure(rx, "rxInvalidateQuiescentVif")
    code += procedure(rx, "rxInvalidateVif")
    code += procedure(tasks, "smConnectReqHasSpecificBssid")
    code += procedure(tasks, "sm_connect_req_handler")
    return code


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_channel_hint_handoff(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for bssid in [[2'u8, 3, 4, 5, 6, 7],
              [0xFF'u8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
              [0'u8, 0, 0, 0, 0, 0]]:
  reset()
  directJoin = true
  lookups = 0
  handedBssid = default(typeof(handedBssid))
  handedChannel = 0
  request.bssid = bssid
  doAssert sm_connect_req_handler(addr request) == KeMsgNoFree
  doAssert lookups == 0 and confirmationStatus == 0
  doAssert handedBssid == bssid and handedChannel == hint.prim20Freq
  let specific = bssid[0] == 2'u8
  doAssert joins == specific.int and scans == (not specific).int

reset()
directJoin = false
lookups = 0
handedBssid = default(typeof(handedBssid))
handedChannel = 0
request.bssid = [0xFF'u8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
doAssert sm_connect_req_handler(addr request) == KeMsgNoFree
doAssert lookups == 1 and joins == 1 and scans == 0
doAssert handedBssid == cachedBssid
doAssert handedChannel == cachedChannel.prim20Freq

for bad in [ScanChannelEntry(prim20Freq: 2472),
            ScanChannelEntry(prim20Freq: 2437, band: 1)]:
  reset()
  directJoin = true
  lookups = 0
  hint = bad
  let epoch = rxVifEpochs[0]
  doAssert sm_connect_req_handler(addr request) == KeMsgConsumed,
    "an unconfigured channel or band was handed to the station join"
  doAssert confirmations == 1 and confirmationStatus != 0 and allocations == 1
  doAssert joins == 0 and scans == 0 and lookups == 0 and not retired
  doAssert sm.connectInfo == nil and rxVifEpochs[0] == epoch

for channel in 1'u16 .. 13'u16:
  reset()
  configuredChannelCount = if channel <= 11: 11 else: 13
  directJoin = true
  hint.prim20Freq = 2407'u16 + 5'u16 * channel
  doAssert sm_connect_req_handler(addr request) == KeMsgNoFree
  doAssert joins == 1 and scans == 0 and confirmationStatus == 0
  doAssert handedChannel == hint.prim20Freq
''')
