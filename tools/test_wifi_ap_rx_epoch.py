"""Run AP stop/restart on the same VIF and verify RX epoch boundaries."""

from pathlib import Path

import pytest

from test_wifi_ap_rollback import DRIVER
from test_wifi_ap_start import run_program
from test_wifi_ap_stop import STOP_HELPERS


EPOCH_CHECKS = r'''
for vif in 0'u8 .. 1:
  for secure in [false, true]:
    reset(vif, secure)
    let beforeStart = rxVifEpochs
    var specification: ApmStartReqView
    copyMem(addr specification, request, sizeof(specification))
    beaconResetHook = proc() =
      doAssert rxVifEpochs[vif] == beforeStart[vif] + 1,
        "AP startup did not invalidate old received frames before a callback"
      doAssert apmStartPendingForVif(vif) and not apmVifRunning(vif)
    doAssert dispatchStart() == KeMsgNoFree
    doAssert rxVifEpochs[vif xor 1] == beforeStart[vif xor 1]
    drainStartup()
    doAssert apmVifRunning(vif)
    let runningEpoch = rxVifEpochs[vif]
    let p = stopRequest(vif)
    cancelHook = proc() =
      doAssert rxVifEpochs[vif] == runningEpoch + 1,
        "AP stop did not invalidate received frames before peer cleanup"
      doAssert apmStopActive and not apmVifRunning(vif)
    doAssert consumeStop(p) == KeMsgNoFree
    let stoppedEpoch = rxVifEpochs[vif]
    let duplicate = stopRequest(vif)
    doAssert consumeStop(duplicate) == KeMsgSaved
    ke_msg_free(keMsgHdrFromPayload(duplicate))
    doAssert rxVifEpochs[vif] == stoppedEpoch
    drainStartup()
    doAssert not apmVifRunning(vif) and rxVifEpochs[vif] == stoppedEpoch
    expectStopped(vif, 0)

    beaconResetHook = nil
    cancelHook = nil
    request = newMessage(0x1400, TASK_APM, TASK_API, sizeof(specification).uint32)
    requestFreed = false
    copyMem(request, addr specification, sizeof(specification))
    cfms.setLen(0)
    doAssert dispatchStart() == KeMsgNoFree
    doAssert rxVifEpochs[vif] == stoppedEpoch + 1 and not apmVifRunning(vif)
    drainStartup()
    doAssert apmVifRunning(vif) and rxVifEpochs[vif] != runningEpoch
    doAssert rxVifEpochs[vif xor 1] == beforeStart[vif xor 1]

# Reserving teardown memory is not yet a stop commitment.
for failure in 1 .. 6:
  reset(1, false)
  ke_msg_free(keMsgHdrFromPayload(request))
  vifs[1].state = 1
  vifs[1].beaconEnabled = 1
  let p = stopRequest(1)
  let before = rxVifEpochs
  failAt = failure
  doAssert consumeStop(p) == KeMsgSaved
  doAssert rxVifEpochs == before and apmVifRunning(1)
  failAt = 0
  doAssert consumeStop(p) == KeMsgNoFree
  doAssert rxVifEpochs[1] == before[1] + 1 and not apmVifRunning(1)
  drainStartup()
  expectStopped(1, 0)

# Pre-admission errors leave the existing epoch unchanged.
for mode in 0 .. 2:
  reset(0, false)
  let before = rxVifEpochs
  case mode
  of 0: apmStartReqView(request).vifIdx = 255
  of 1: failAt = 1
  else: vifs[0].state = 1
  doAssert dispatchStart() == KeMsgConsumed
  doAssert rxVifEpochs == before
'''


@pytest.mark.parametrize("build", ["checked", "release", "asan"])
def test_ap_rx_epoch_boundaries(tmp_path: Path, build: str) -> None:
    run_program(tmp_path, build, DRIVER + STOP_HELPERS + EPOCH_CHECKS)
