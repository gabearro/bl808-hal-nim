"""Keep the first sustained Wi-Fi outage snapshot intact through recovery."""

from pathlib import Path
from textwrap import dedent

import pytest

from test_wifi_disconnect_tx import ROOT
from test_wifi_message_allocation import run_program


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_link_drop_snapshot(tmp_path: Path, mode: str) -> None:
    app = (ROOT / "examples/m0_allcore_wasm_cps_live_test.nim").read_text()
    link_type = app.split("  type AllcoreLinkDrop", 1)[1].splitlines()[0]
    source = "type AllcoreLinkDrop" + link_type + "\n"
    source += dedent("    var linkDropSnapshot" + app.split("    var linkDropSnapshot", 1)[1]
                     .split("  when defined(bl808WifiDiagWarmScan):", 1)[0])
    platform = r'''
type BeaconEvidence = object
  valid: bool
  vifIndex, stationIndex, missed: uint8
  received, lastBeaconUs, sampleUs, probeEpoch: uint32
var
  sm_state: uint16
  wpa, nimfw_dbg_tx_fc_state, nimfw_dbg_deauth, nimfw_dbg_connloss: uint32
  nimfw_dbg_rxl_frame_seen: uint32
  beacon: BeaconEvidence
  nimfw_dbg_traffic_probe: array[5, uint32]
  status, reason, connected: cint
  now, nimfw_dbg_sta_recovery_stage: uint32
  nimfw_dbg_sta_recovery_result: int32
  scanObservation: tuple[kind, code: uint32]
proc bl808_wifi_backend_last_status(): cint = status
proc bl808_wifi_backend_last_reason(): cint = reason
proc bl808_wifi_backend_connected(): cint = connected
proc bl808WpaCurrentState(): uint32 = wpa
proc nowMs(): uint32 = now
proc wifiLastScanObservation(): tuple[kind, code: uint32] = scanObservation
proc nimFwSnapshotStaBeaconEvidence(): BeaconEvidence = beacon
'''
    checks = r'''
sm_state = 12
wpa = 10
connected = 1
status = -1
reason = 7
nimfw_dbg_tx_fc_state = 0xCC443311'u32
nimfw_dbg_deauth = 4
nimfw_dbg_connloss = 3
nimfw_dbg_traffic_probe = [21'u32, 2, 10, 8, 0x80010700'u32]
let candidate = observeAllcoreLinkDrop(91124, 8010, 0, true, false, true)
doAssert linkDropSnapshot == default(AllcoreLinkDrop)

# A transient candidate is never published. The next loss gets its own edge
# data, and the status must be the one from the edge, not the recovery attempt.
status = 7
sm_state = 10
connected = 0
wpa = 1
beacon = BeaconEvidence(valid: true, vifIndex: 1, stationIndex: 3, missed: 2,
  received: 318, lastBeaconUs: 70_020, sampleUs: 80_012, probeEpoch: 40)
nimfw_dbg_rxl_frame_seen = 808
sampleAllcoreStaRx(109902)
let sustained = observeAllcoreLinkDrop(109911, 34, 5981, false, true, true)
status = 19
reason = 3
nimfw_dbg_traffic_probe[4] = 0x80800000'u32
inc beacon.received
inc nimfw_dbg_rxl_frame_seen
sampleAllcoreStaRx(109912)
publishFirstAllcoreLinkDrop(sustained)
doAssert candidate[2] == 0x0007FFFF
doAssert candidate[3] == 0x070A000C
doAssert linkDropSnapshot == [0x4C494E4B'u32, 109911, 0x00070007,
  0x0A01000A, 34, 5981, 0xCC443311'u32, 4, 3, 21, 2, 10, 8, 0x80010700'u32,
  0x80000301'u32, 109902, 808, 318, 70_020, 80_012, 40, 2]
let first = linkDropSnapshot
publishFirstAllcoreLinkDrop(observeAllcoreLinkDrop(200000, 0, 0, false, false, false))
doAssert linkDropSnapshot == first

# A forced run cannot overwrite evidence. The first natural failure keeps
# its own timestamp and scan outcome, not status from a later retry.
now = 21
nimfw_dbg_sta_recovery_stage = 4
nimfw_dbg_sta_recovery_result = -16
recordFirstReconnectFailure(true, 8, 10, reconnectDisconnect, 1, 2)
doAssert reconnectFailure == default(typeof(reconnectFailure))
scanObservation = (2'u32, cast[uint32](-16'i32))
recordReconnectScanFailure(false, 9, high(uint32) - 3)
doAssert reconnectFailure == [0x5245434E'u32, 9, 2, 0xFFFFFFFC'u32, 25,
  0xFFFFFFF0'u32, 2, 0xFFF0040A'u32, 0x00030013'u32]
let firstFailure = reconnectFailure
sm_state = 0
status = 8
recordFirstReconnectFailure(false, 10, 21, reconnectJoin, 1, 0)
recordFirstReconnectFailure(true, 11, 21, reconnectDhcp, 1, 0)
doAssert reconnectFailure == firstFailure and linkDropSnapshot == first
'''
    run_program(tmp_path, mode, platform + source + checks, defines=("bl808WifiNimFw",))
