"""Run AP stop/removal through the real APM and ME/MM control handlers."""

from pathlib import Path

import pytest

from test_wifi_ap_rollback import DRIVER
from test_wifi_ap_start import run_program


STOP_HELPERS = r'''
proc stopRequest(vif: uint8; source = TASK_API): pointer =
  result = newMessage(0x1402, TASK_APM, source, sizeof(ApmStopReqPayload).uint32)
  apmStopReqView(result).vifIdx = vif
proc consumeStop(p: pointer): cint =
  result = apm_stop_req_handler(p)
  if result == KeMsgConsumed: ke_msg_free(keMsgHdrFromPayload(p))
proc expectStopped(vif: uint8; otherMask: uint32) =
  doAssert me.activeMask == otherMask and me.psDisableMask == otherMask
  doAssert vifs[vif].state == 0 and vifs[vif].beaconEnabled == 0
  doAssert vifs[vif].chanCtxt == nil and apm.hostapdCtx == nil
  doAssert apm.cryptoType == 0 and apm.embeddedEnabled == 0
  for value in apm.securityIe: doAssert value == 0
  doAssert state == ApmIdleState and meState == MeIdleState
  doAssert not apmStopActive and not apmRollbackActive
  doAssert apmStoppingVifs == 0 and apmStopRequest == nil
  doAssert allocated.len == 0 and keMsgQueueSent.first == nil
  doAssert keMsgQueueSaved.first == nil
'''

STOP_MATRIX = r'''
for vif in 0'u8 .. 1:
  for secure in [false, true]:
    for shared in [false, true]:
      for psOn in [0'u8, 1]:
        reset(vif, secure)
        me.psOn = psOn
        let otherMask = if shared: 1'u32 shl (vif xor 1) else: 0'u32
        me.activeMask = otherMask
        me.psDisableMask = otherMask
        var specification: ApmStartReqView
        copyMem(addr specification, request, sizeof(specification))
        doAssert dispatchStart() == KeMsgNoFree
        drainStartup()
        doAssert cfms.len == 1 and cfms[0].status == 0 and allocated.len == 6
        vifs[vif].beaconEnabled = 1
        for value in apm.securityIe.mitems: value = 0xA5
        let p = stopRequest(vif, 10)
        let allocationsBefore = kernelAllocations
        failAt = kernelAllocations + 1
        doAssert consumeStop(p) == KeMsgNoFree
        doAssert p == apmStopRequest and p in allocated
        doAssert apmStopActive and apmRollbackActive and state == ApmActiveState
        doAssert cancelled == @[vif] and beaconStops == 1
        doAssert timerClears == @[APM_STA_CONNECT_TIMEOUT_IND]
        doAssert deinitialized == 0 and channelDeletes == 0 and controlReplies.len == 0
        doAssert apm.hostapdCtx == (if secure: addr hostContext else: nil)
        let duplicate = stopRequest(vif)
        doAssert consumeStop(duplicate) == KeMsgSaved
        ke_msg_free(keMsgHdrFromPayload(duplicate))
        drainStartup()
        doAssert kernelAllocations == allocationsBefore
        doAssert deinitialized == secure.int and channelDeletes == 1
        doAssert controlReplies == @[(APM_STOP_CFM, TASK_APM, 10'u8, 0'u32)]
        expectStopped(vif, otherMask)

        # Stop completion permits restart without resetting either control task.
        failAt = 0
        request = newMessage(0x1400, TASK_APM, TASK_API, sizeof(specification).uint32)
        requestFreed = false
        copyMem(request, addr specification, sizeof(specification))
        cfms.setLen(0)
        doAssert dispatchStart() == KeMsgNoFree
        drainStartup()
        doAssert cfms.len == 1 and cfms[0].status == 0 and allocated.len == 6
        doAssert me.activeMask == (otherMask or (1'u32 shl vif))
'''

DEFERRED = r'''
for vif in 0'u8 .. 1:
  reset(vif)
  var specification: ApmStartReqView
  copyMem(addr specification, request, sizeof(specification))
  doAssert dispatchStart() == KeMsgNoFree
  drainStartup()
  let p = stopRequest(vif)
  psDeferred = true
  doAssert consumeStop(p) == KeMsgNoFree
  drainStartup()
  doAssert psOwn.request != nil and meState == MeBusyState
  doAssert apmStopActive and p in allocated
  doAssert controlReplies.len == 0 and deinitialized == 0 and channelDeletes == 0
  doAssert vifs[vif].chanCtxt != nil and vifs[vif].state == 1
  doAssert not apmPrepareVifRemoval(vif)
  let replacement = newMessage(0x1400, TASK_APM, TASK_API, sizeof(specification).uint32)
  copyMem(replacement, addr specification, sizeof(specification))
  doAssert apm_start_req_handler(replacement) == KeMsgConsumed
  ke_msg_free(keMsgHdrFromPayload(replacement))
  doAssert cfms.len == 2 and cfms[^1].status == 8

  # A synchronous callback sees a detached context and cannot start a new stop.
  let duplicate = stopRequest(vif)
  stopHook = proc() =
    doAssert apmStopActive and apm.hostapdCtx == nil
    doAssert vifs[expectedVif].state == 0 and me.activeMask == 0
    doAssert me.psDisableMask == 0 and controlReplies.len == 0
    doAssert consumeStop(duplicate) == KeMsgSaved
  psDeferred = false
  psComplete()
  drainStartup()
  doAssert deinitialized == 1 and controlReplies.len == 1
  doAssert consumeStop(duplicate) == KeMsgConsumed
  doAssert deinitialized == 1 and controlReplies.len == 2
  expectStopped(vif, 0)
'''

REMOVAL = r'''
for vif in 0'u8 .. 1:
  for stage in 0 ..< 6:
    for produced in [0, 1]:
      reset(vif)
      doAssert dispatchStart() == KeMsgNoFree
      drainStartup(limit = stage * 2 + produced)
      doAssert not apmPrepareVifRemoval(vif)
      doAssert apmRollbackActive and apmStartPendingForVif(vif)
      doAssert vifs[vif].vifType == VIF_TYPE_AP and channelDeletes == 0
      doAssert not apmPrepareVifRemoval(vif)
      let removal = newMessage(8, TASK_MM, TASK_API, 1)
      cast[ptr uint8](removal)[] = vif
      co_list_push_back(addr keMsgQueueSaved, keMsgHdrFromPayload(removal))
      while apmRollbackActive: drainStartup(limit = 1)
      doAssert keMsgPayload(co_list_pop_front(addr keMsgQueueSent)) == removal
      ke_msg_free(keMsgHdrFromPayload(removal))
      doAssert apmPrepareVifRemoval(vif)
      doAssert cfms.len == 1 and cfms[0].status == 1
      expectStopped(vif, 0)

  reset(vif)
  doAssert dispatchStart() == KeMsgNoFree
  drainStartup()
  let allocationsBefore = kernelAllocations
  failAt = kernelAllocations + 1
  doAssert not apmPrepareVifRemoval(vif)
  doAssert apmStopActive and apmStopRequest == nil
  doAssert vifs[vif].vifType == VIF_TYPE_AP and channelDeletes == 0
  let removal = newMessage(8, TASK_MM, TASK_API, 1)
  cast[ptr uint8](removal)[] = vif
  co_list_push_back(addr keMsgQueueSaved, keMsgHdrFromPayload(removal))
  while apmStopActive: drainStartup(limit = 1)
  doAssert keMsgPayload(co_list_pop_front(addr keMsgQueueSent)) == removal
  ke_msg_free(keMsgHdrFromPayload(removal))
  doAssert kernelAllocations == allocationsBefore
  doAssert apmPrepareVifRemoval(vif) and apmPrepareVifRemoval(255)
  doAssert controlReplies.len == 0 and deinitialized == 1
  expectStopped(vif, 0)
'''

EDGE_CASES = r'''
for mode in 0 ..< 4:
  reset(0, false)
  ke_msg_free(keMsgHdrFromPayload(request))
  let p = stopRequest(0)
  case mode
  of 0: discard # Already stopped.
  of 1: vifs[0].vifType = 0
  of 2: apmStopReqView(p).vifIdx = 255
  else: keMsgHdrFromPayload(p).paramLen = 0
  doAssert consumeStop(p) == KeMsgConsumed
  doAssert allocated.len == 0 and cancelled.len == 0 and deinitialized == 0
  doAssert controlReplies == @[(APM_STOP_CFM, TASK_APM, TASK_API, 0'u32)]
doAssert apm_stop_req_handler(nil) == KeMsgConsumed
apm_stop(nil)

# A manually established AP without a retained reserve can retry allocation.
for failure in 1 .. 6:
  reset(1, false)
  ke_msg_free(keMsgHdrFromPayload(request))
  vifs[1].beaconEnabled = 1
  let p = stopRequest(1)
  failAt = failure
  doAssert consumeStop(p) == KeMsgSaved
  doAssert allocated == @[p] and cancelled.len == 0 and beaconStops == 0
  doAssert not apmStopActive
  failAt = 0
  doAssert consumeStop(p) == KeMsgNoFree
  drainStartup()
  expectStopped(1, 0)

for taskState in [1'u16, 2, 7]:
  reset(0, false)
  ke_msg_free(keMsgHdrFromPayload(request))
  vifs[0].state = 1
  let p = stopRequest(0)
  state = taskState
  doAssert consumeStop(p) == KeMsgSaved
  doAssert allocated == @[p] and cancelled.len == 0
  state = ApmIdleState
  doAssert consumeStop(p) == KeMsgNoFree
  drainStartup()
  expectStopped(0, 0)
'''

AGING = r'''
for mode in 0 ..< 4:
  reset(0)
  doAssert dispatchStart() == KeMsgNoFree
  drainStartup()
  timers.setLen(0)
  stations[0] = Station(instNbr: 0, valid: 1, connectionStart: 1)
  stations[1] = Station(instNbr: 0, valid: 0, connectionStart: 1)
  stations[2] = Station(instNbr: 1, valid: 1, connectionStart: 1)
  stations[3] = Station(instNbr: 255, valid: 1, connectionStart: 1)
  let p = stopRequest(0)
  case mode
  of 0:
    doAssert apm_sta_connect_timeout_ind_handler(nil) == KeMsgConsumed
    doAssert deleted == @[0'u8] and timers == @[APM_STA_CONNECT_TIMEOUT_IND]
    doAssert consumeStop(p) == KeMsgNoFree
  of 1:
    doAssert consumeStop(p) == KeMsgNoFree
    doAssert apm_sta_connect_timeout_ind_handler(nil) == KeMsgConsumed
    doAssert deleted.len == 0 and timers.len == 0
  of 2:
    stations[1] = Station(instNbr: 0, valid: 1, connectionStart: 1)
    deleteHook = proc() = doAssert consumeStop(p) == KeMsgNoFree
    doAssert apm_sta_connect_timeout_ind_handler(nil) == KeMsgConsumed
    doAssert deleted == @[0'u8] and timers.len == 0
  else:
    vifs[1] = VifChannelView(vifIdx: 1, vifType: VIF_TYPE_AP, state: 1)
    doAssert consumeStop(p) == KeMsgNoFree
    doAssert apm_sta_connect_timeout_ind_handler(nil) == KeMsgConsumed
    doAssert deleted == @[2'u8] and timers == @[APM_STA_CONNECT_TIMEOUT_IND]
  drainStartup()
  expectStopped(0, 0)
'''


@pytest.mark.parametrize("build", ["checked", "release", "asan"])
@pytest.mark.parametrize("checks", [STOP_MATRIX, DEFERRED, REMOVAL, EDGE_CASES, AGING],
                         ids=["stop-restart", "deferred", "removal", "edge-cases", "aging"])
def test_ap_stop_lifecycle(tmp_path: Path, build: str, checks: str) -> None:
    run_program(tmp_path, build, DRIVER + STOP_HELPERS + checks)


def test_remove_guard_precedes_mm_idle_and_vif_mutation() -> None:
    fw = Path(__file__).resolve().parents[1] / "src/bl808/wifi/fw"
    from test_wifi_ap_teardown import procedure

    handler = procedure((fw / "task_handlers.nim").read_text(), "mm_hw_config_handler")
    guard = handler.index("if msgId == MM_REMOVE_IF_REQ:")
    assert guard < handler.index("let curState = ke_state_get(srcId)")
    assert "if not apmPrepareVifRemoval(" in handler[guard:]
    assert "if not vif_mgmt_unregister(vifIdx):\n        return KeMsgSaved" in handler
    unregister = procedure((fw / "vif_management.nim").read_text(), "vif_mgmt_unregister")
    assert unregister.index("let prepared = apmPrepareVifRemoval(vifIdx)") < unregister.index("co_list_extract(")
    assert unregister.index("if not prepared:") < unregister.index("co_list_extract(")
