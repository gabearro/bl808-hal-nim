"""Preserve beacon reservations when preparation crosses a TX reset."""

from pathlib import Path
import re

import pytest

import test_wifi_beacon_update as beacon
from test_wifi_beacon_submit_owner import real_push_program
from test_wifi_beacon_transmit import SETUP


def run(tmp_path: Path, monkeypatch, mode: str, checks: str, *, real_push: bool = False) -> None:
    code = real_push_program() if real_push else beacon.source(transmit=True)
    if not re.search(r"(?m)^\s*txResetEpoch:\s*uint32", code):
        code = "var txResetEpoch: uint32\n" + code
    monkeypatch.setattr(beacon, "source", lambda **_: code)
    beacon.run(tmp_path, SETUP + checks, mode, transmit=True)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reset_before_beacon_submission(tmp_path: Path, monkeypatch, mode: str) -> None:
    run(tmp_path, monkeypatch, mode, r'''
for vif in 0'u8 .. 1:
  for incoming in [false, true]:
    for power in [false, true]:
      install(vif)
      txResetEpoch = 7
      interruptsEnabled = incoming
      let before = (txl_tim_ie_pool, vifs[vif].timCountdown,
        txControl.seqCounter, pool.bytes, descriptors[vif].frameLen)
      if power:
        framePowerHook = proc() =
          framePowerHook = nil
          inc txResetEpoch
      else:
        channelHook = proc() =
          channelHook = nil
          inc txResetEpoch
      mm_bcn_transmit(vif)
      doAssert pushes == 0 and env.pendingCount == 0 and env.active == 0
      doAssert before == (txl_tim_ie_pool, vifs[vif].timCountdown,
        txControl.seqCounter, pool.bytes, descriptors[vif].frameLen)
      doAssert interruptsEnabled == incoming and txResetEpoch == 8
      mm_bcn_transmit(vif)
      doAssert pushes == 1 and env.pendingCount == 1
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reset_rejection_releases_beacon_reservation(tmp_path: Path, monkeypatch, mode: str) -> None:
    run(tmp_path, monkeypatch, mode, r'''
install()
txResetEpoch = 7
for i in 0 .. 1:
  vifs[i].frame.hwDesc = addr descriptors[i]
  vifs[i].frame.bufDesc = addr realLinks[i]
let before = (txl_tim_ie_pool, vifs[0].timCountdown,
              pool.bytes, descriptors[0].frameLen)
actualTraceHook = proc() =
  actualTraceHook = nil
  inc txResetEpoch
mm_bcn_transmit(0)
doAssert realHandoffs == 0 and env.pendingCount == 0 and env.active == 0
doAssert before == (txl_tim_ie_pool, vifs[0].timCountdown,
                    pool.bytes, descriptors[0].frameLen)
doAssert txControl.seqCounter == 1 and interruptsEnabled
''', real_push=True)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reset_after_completion_stops_old_multicast_work(tmp_path: Path, monkeypatch, mode: str) -> None:
    run(tmp_path, monkeypatch, mode, r'''
install()
txResetEpoch = 7
vifs[0].timFlags = 1
stations[5].trafficFlags = 2
pushHook = proc() =
  pushHook = nil
  inc txResetEpoch
  mm_bcn_transmitted(addr vifs[0])
mm_bcn_transmit(0)
doAssert pushes == 1 and env.pendingCount == 0 and env.active == 0
doAssert multicastRequests == 0 and postponed == 0 and allocated.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reset_during_multicast_allocation_releases_message(tmp_path: Path, monkeypatch, mode: str) -> None:
    run(tmp_path, monkeypatch, mode, r'''
install()
txResetEpoch = 7
vifs[0].timFlags = 1
stations[5].trafficFlags = 2
allocationHook = proc(id: uint16) =
  if id != MM_TRAFFIC_REQ_IND: return
  allocationHook = nil
  inc txResetEpoch
  mm_bcn_transmitted(addr vifs[0])
mm_bcn_transmit(0)
doAssert pushes == 1 and env.pendingCount == 0 and env.active == 0
doAssert multicastRequests == 0 and postponed == 0 and allocated.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_existing_beacon_completion_can_drain_during_reset(tmp_path: Path, monkeypatch, mode: str) -> None:
    run(tmp_path, monkeypatch, mode, r'''
for vif in 0'u8 .. 1:
  install(vif)
  txResetEpoch = 7
  mm_bcn_transmit(vif)
  doAssert env.pendingCount == 1
  inc txResetEpoch
  mm_bcn_transmitted(addr vifs[vif])
  doAssert env.pendingCount == 0 and assertions == 0
''')
