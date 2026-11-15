"""Verify failed AP startup drains its rollback before reporting completion."""

from pathlib import Path

import pytest

from test_wifi_ap_start import CHECKS, run_program


DRIVER = CHECKS.split("for vif in 0'u8 .. 1'u8:", 1)[0]

ROLLBACK = r"""
for vif in 0'u8 .. 1:
  for stage in 0 ..< 6:
    for produced in [0, 1]:
      for shared in [false, true]:
        for psOn in [0'u8, 1]:
          reset(vif, false)
          me.psOn = psOn
          let otherMask = if shared: 1'u32 shl (vif xor 1) else: 0'u32
          me.activeMask = otherMask
          me.psDisableMask = otherMask
          var specification: ApmStartReqView
          copyMem(addr specification, request, sizeof(specification))
          doAssert dispatchStart() == KeMsgNoFree
          drainStartup(limit = stage * 2 + produced)
          let allocationsBefore = kernelAllocations
          failAt = kernelAllocations + 1
          vifs[vif].beaconEnabled = 1
          apm_start_cfm(cast[pointer](1'u))
          doAssert apmRollbackActive and apm.connectInfo == request
          doAssert not apmVifRunning(vif)
          doAssert not requestFreed and cfms.len == 0 and channelDeletes == 0
          doAssert vifs[vif].beaconEnabled == 0 and beaconStops == 1
          drainStartup()
          doAssert kernelAllocations == allocationsBefore
          doAssert cfms.len == 1 and cfms[0].status == 1
          doAssert me.activeMask == otherMask and me.psDisableMask == otherMask
          doAssert vifs[vif].state == 0 and vifs[vif].chanCtxt == nil
          doAssert channelDeletes == 1 and requestFreed and allocated.len == 0
          doAssert not apmRollbackActive and not apmStartSideEffects
          doAssert meState == MeIdleState and state == ApmIdleState
          doAssert not apmVifRunning(vif)

          # Reuse the same VIF without resetting ME or APM globals.
          failAt = 0
          request = newMessage(0x1400, TASK_APM, TASK_API, sizeof(specification).uint32)
          requestFreed = false
          copyMem(request, addr specification, sizeof(specification))
          cfms.setLen(0)
          doAssert dispatchStart() == KeMsgNoFree
          drainStartup()
          doAssert cfms.len == 1 and cfms[0].status == 0
          doAssert me.activeMask == (otherMask or (1'u32 shl vif))
          doAssert me.psDisableMask ==
            (if psOn == 0: otherMask else: otherMask or (1'u32 shl vif))
          doAssert allocated.len == 6 and vifs[vif].state == 1
          doAssert apmVifRunning(vif)
"""

DEFERRED = r"""
for vif in 0'u8 .. 1:
  reset(vif, false)
  psDeferred = true
  doAssert dispatchStart() == KeMsgNoFree
  drainStartup(limit = 1)
  doAssert meState == MeBusyState and mmPsModeRequest != nil
  apm_start_cfm(cast[pointer](1'u))
  drainStartup()
  doAssert cfms.len == 0 and not requestFreed and channelDeletes == 0
  doAssert apmRollbackActive and apmStartPendingForVif(vif)
  doAssert not apmVifRunning(vif)
  doAssert me.activeMask == 0 and me.psDisableMask == (1'u32 shl vif)

  # A second start must not overtake the rollback or replace its host request.
  let oldRequest = request
  let replacement = newMessage(0x1400, TASK_APM, TASK_API, sizeof(ApmStartReqView).uint32)
  copyMem(replacement, oldRequest, sizeof(ApmStartReqView))
  doAssert apm_start_req_handler(replacement) == KeMsgConsumed
  ke_msg_free(keMsgHdrFromPayload(replacement))
  doAssert cfms.len == 1 and cfms[0].status == 8
  doAssert apm.connectInfo == oldRequest and not requestFreed
  cfms.setLen(0)

  psDeferred = false
  mmPsModeComplete()
  drainStartup()
  doAssert meState == MeIdleState and mmPsModeRequest == nil
  doAssert me.activeMask == 0 and me.psDisableMask == 0
  doAssert cfms.len == 1 and cfms[0].status == 1
  doAssert requestFreed and allocated.len == 0 and channelDeletes == 1
  doAssert not apmRollbackActive and state == ApmIdleState
"""


@pytest.mark.parametrize("build", ["checked", "release", "asan"])
def test_ap_failure_rollback_and_retry(tmp_path: Path, build: str) -> None:
    run_program(tmp_path, build, DRIVER + ROLLBACK)


@pytest.mark.parametrize("build", ["checked", "release", "asan"])
def test_ap_rollback_waits_for_inflight_me(tmp_path: Path, build: str) -> None:
    run_program(tmp_path, build, DRIVER + DEFERRED)
