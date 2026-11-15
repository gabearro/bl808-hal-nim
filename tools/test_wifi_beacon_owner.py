"""Stop beacon processing when a callback ends the captured RX lifetime."""

from pathlib import Path

import pytest

from test_wifi_beacon_probe_policy import source as probe_source
from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    code = probe_source().replace("frameStorage: array[36, uint8]",
                                  "frameStorage: array[64, uint8]")
    code = r'''
var ownerGeneration: uint32
var onBoundary: proc(name: string)
var steps: seq[string]
proc boundary(name: string) =
  steps.add(name)
  if onBoundary != nil: onBoundary(name)
''' + code
    replacements = {
        "rxCaptureFrameHeader": '''
proc rxCaptureFrameHeader(header, vifEntry, staEntry: pointer): RxFrameIdentity =
  RxFrameIdentity(descriptor: header, generation: ownerGeneration)
''',
        "rxFrameCurrent": '''
proc rxFrameCurrent(identity: RxFrameIdentity): bool =
  identity.descriptor != nil and identity.generation == ownerGeneration
''',
        "txl_frame_send_null_frame": '''
proc txl_frame_send_null_frame(station: uint8; callback: pointer; arg: uint32): uint8 =
  boundary("probe")
  1
''',
        "mm_send_connection_loss_ind": '''
proc mm_send_connection_loss_ind(p: pointer; reason: uint16) = boundary("loss")
''',
        "mm_check_rssi": '''
proc mm_check_rssi(p: pointer; rssi: int8) = boundary("rssi")
''',
        "getLogFunc": '''
proc beaconLog(level: uint32; tag, file: cstring; line: cint;
               format: cstring) {.cdecl, varargs.} =
  boundary("log")
proc getLogFunc(offset: int): PlatformLogFunc = cast[PlatformLogFunc](beaconLog)
''',
        "hal_machw_rx_duration": '''
proc hal_machw_rx_duration(p: pointer; length: uint32): uint32 =
  boundary(if length == 24: "header-duration" else: "full-duration")
  0
''',
        "mm_timer_set": '''
proc mm_timer_set(p: pointer; expiry: uint32) =
  cast[ptr Timer](p).expiry = expiry
  boundary("timer-set")
''',
        "mm_timer_clear": '''
proc mm_timer_clear(p: pointer) = boundary("timer-clear")
''',
    }
    for name, replacement in replacements.items():
        code = code.replace(procedure(code, name), replacement, 1)
    return code + r'''
proc prepare() =
  setup()
  onBoundary = nil
  steps.setLen(0)
  ownerGeneration = 1
  mm.flagsHigh = 1
  mm.keepAliveLimit = 0
  clock = 40_000_000
  frameStorage[36] = 5
  frameStorage[37] = 4
  frameStorage[38] = 0
  frameStorage[39] = 3
  frameStorage[40] = 0
  frameStorage[41] = 1
  rx.frameLen = 42
proc recycle() =
  inc ownerGeneration
  vif.beaconCrc = 0xAABBCCDD'u32
  vif.tbttTimer.expiry = 0x55667788
  mm.keepAliveLimit = 77
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_beacon_stops_at_each_callout(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
let order = @["probe", "loss", "rssi", "log", "full-duration",
              "header-duration", "timer-set", "timer-clear"]
for index, phase in order:
  prepare()
  onBoundary = proc(name: string) =
    if name == phase: recycle()
  let changed = mm_check_beacon(addr rx, addr vif, addr sta, addr timOut)
  doAssert changed == 0 and timOut == 0
  doAssert steps == order[0 .. index], "beacon continued after " & phase
  doAssert vif.beaconCrc == 0xAABBCCDD'u32 and vif.tbttTimer.expiry == 0x55667788
  doAssert mm.keepAliveLimit == 77
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_current_beacon_runs_all_callouts(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
prepare()
doAssert mm_check_beacon(addr rx, addr vif, addr sta, addr timOut) == 1
doAssert timOut == pointerAddrU32(addr frameStorage[36])
doAssert steps == @["probe", "loss", "rssi", "log", "full-duration",
                    "header-duration", "timer-set", "timer-clear"]
''')
