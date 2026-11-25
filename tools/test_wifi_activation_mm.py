"""Run the MM activation branch with its real admission and publication order."""

from pathlib import Path
import re

import pytest

from test_wifi_activation_exchange import source as exchange_source
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_channel_update import mm_config_idle_source


HARDWARE = r'''
const
  VIF_TYPE_AP = 2'u8
  MM_REMOVE_IF_REQ = 8'u16
  MM_CHAN_CTXT_UPDATE_REQ = 41'u16
  MM_SET_EDCA_REQ = 22'u16
  MmSetEdcaReqPayloadSize = 8'u32
  MmChanCtxtUpdatePayloadSize = 12'u32
  TaskIdleState = 0'u16
  MM_IDLE = TaskIdleState
  TaskGoingIdleState = 2'u16
  MM_GOING_TO_IDLE = TaskGoingIdleState
  MM_HOST_BYPASSED = 3'u8
  MACHW_STATE_CNTRL_REG = 0x1000'u
  MACHW_BASE = 0x2000'u
type MmRemoveIfReqPayload = object
  vifIdx: uint8
var rxl: tuple[processingFlag: uint8]
var mmEdcaRefresh: tuple[message: pointer]
proc mmEdcaOwner(): ptr Vif =
  if vifs[1].state != 0: addr vifs[1] else: nil
proc mmReplayEdca() = discard
proc rxlCntrlEnvView(): ptr typeof(rxl) = addr rxl
proc apmPrepareVifRemoval(vif: uint8): bool = true
proc chanUpdateAdmit(p: pointer): bool = true
proc vifEntryAddr(index: uint8): uint = cast[uint](vifChannelForIdx(index))
proc vifChannelAt(address: uint): ptr Vif = cast[ptr Vif](address)
proc vifChannelAt(address: pointer): ptr Vif = cast[ptr Vif](address)
proc txlFrameCallbackCurrent(): bool = true
var mmTrafficProbeEpochs: array[MAX_VIFS, uint32]
proc mmPublishConnectionLoss(vif: pointer; reason: uint16; epoch: ptr uint32) =
  doAssert false, "new station inherited the previous probe misses"
proc ke_task_sm_activating(): bool = state == SM_ACTIVATING_STATE
proc macTimeNow(): uint32 =
  const readings = [100'u32, 125'u32, 130'u32]
  doAssert macReads < readings.len
  result = readings[macReads]
  inc macReads
  invoke(onMacRead)
proc regRead(address: uint): uint32 =
  invoke(onRead)
  0
proc regWrite(address: uint; value: uint32) =
  writes.add((address, value))
  invoke(onWrite)
proc hal_machw_idle_req() = invoke(onIdle)
proc ke_evt_field_get(): uint32 = 0
const KE_EVT_IDLE = 0x04000000'u32
proc ke_evt_clear(bits: uint32) = doAssert bits == KE_EVT_IDLE
proc ke_msg_free_payload(p: pointer) = doAssert false
proc mm_timer_clear(timer: ptr uint32) =
  timer[] = 0
  invoke(onTimer)
proc mmTimerClearLocked(timer: ptr uint32; saved: uint32) =
  doAssert not enabled
  timer[] = 0
  irqRestore(saved)
  try: invoke(onTimer)
  finally: discard irqSave()
proc mm_timer_set(timer: ptr uint32; value: uint32) =
  timer[] = value
  invoke(onTimer)
proc chan_bcn_detect_start(vif: pointer) = invoke(onBeacon)
proc mm_env_max_ampdu_duration_set(value: uint32) = invoke(onAmpdu)
'''


def source() -> str:
    code = exchange_source()
    code = code.replace("    rateWord: uint16\n", """    rateWord: uint16
    initialRateConfig: uint32
    aid, listenWindowDuration: uint16
""")
    code = code.replace("    listenInterval: uint16\n    psOptions: uint8\n", """    listenInterval: uint16
    psOptions: uint8
    tbttTimer, keepAliveTimer, securityTimer, flags: uint32
    probeCount, beaconCrc, psLastTime, tbttCount, beaconLossCount: uint32
    beaconTimeoutBase, beaconRxCount, beaconLossWindow, lastBeaconMacTime: uint32
    edcaRegs: array[4, uint32]
""")
    code = code.replace("mm: tuple[rxPromiscUploadFlag: uint8, rxFilterBase: uint32]",
                        "mm: tuple[rxPromiscUploadFlag, hardwareMode, previousState: uint8, "
                        "listenWindow: uint16, rxFilterBase, keepAliveLimit: uint32]")
    code = code.replace("  holdMMMode: bool\n", """  holdMMMode: bool
  mmState: uint16
  macReads: int
  writes: seq[tuple[address: uint, value: uint32]]
  onRead, onWrite, onIdle, onTimer, onBeacon, onAmpdu, onMacRead: proc()
""")
    code = code.replace("if task == TASK_SM: state else: meState",
                        "if task == TASK_SM: state elif task == TASK_ME: meState else: mmState")
    code = code.replace("  else: meState = value\n",
                        "  elif task == TASK_ME: meState = value\n  else: mmState = value\n")
    start = code.index("  of TASK_MM:\n", code.index("proc dispatchOne"))
    end = code.index("  of TASK_API:\n", start)
    code = code[:start] + "  of TASK_MM: outcome = mm_hw_config_handler(p)\n" + code[end:]
    body = procedure((FW / "task_handlers.nim").read_text(), "mm_hw_config_handler")
    prefix = body.split("  # Main dispatch on msgId", 1)[0]
    selected = body.split("  of 24:  # MM_SET_VIF_STATE_REQ", 1)[1].split("\n  of 41:", 1)[0]
    tail = body.split("  # Restore local MM state", 1)[1]
    body = (prefix + "  case msgId.int\n  of 24:  # MM_SET_VIF_STATE_REQ" + selected +
            "\n  else: doAssert false\n  # Restore local MM state" + tail)
    code = "proc mm_hw_config_handler*(param: pointer): cint {.exportc, cdecl.}\n" + code
    code += HARDWARE + mm_config_idle_source() + body
    code += procedure((FW / "power_save.nim").read_text(), "mm_ap_traffic_probe_cfm")
    debug = sorted(set(re.findall(r"\bnimFwDbg\w+", body)))
    return "\n".join(f"var {name}: uint32" for name in debug) + "\n" + code


CASES = {
    # SM's cleanup (state 10) sends MM_SET_VIF_STATE_REQ(0) with its reserved
    # reply. The real handler clears the VIF's timers and state and answers
    # with that reply.
    "station_cleanup_state_down": r'''
setup()
discard smGo(10, tdCleanup)
vifs[1].state = 1
vifs[1].tbttTimer = 11
vifs[1].keepAliveTimer = 22
vifs[1].securityTimer = 33
let request = ke_msg_try_alloc(MM_SET_VIF_STATE_REQ, TASK_MM, TASK_SM,
                               MmSetVifStateReqPayloadSize)
cast[ptr MmSetVifStateReqPayload](request)[] = MmSetVifStateReqPayload(vifIdx: 1, state: 0)
doAssert smSendReserved(request)
let reserved = smOwn.reply
doAssert dispatchOne()
doAssert events[^1].id == MM_SET_VIF_STATE_CFM
doAssert keMsgQueueSent.first == keMsgHdrFromPayload(reserved)
doAssert smOwn.answer == reserved and smOwn.request == nil
doAssert vifs[1].state == 0 and vifs[1].tbttTimer == 0 and
         vifs[1].keepAliveTimer == 0 and vifs[1].securityTimer == 0
ke_msg_free(co_list_pop_front(addr keMsgQueueSent))
finish()
''',
    "station_probe_budget_fresh": r'''
begin()
mm.keepAliveLimit = 0
doAssert dispatchOne()
doAssert mm.keepAliveLimit == 10 and vifs[1].beaconTimeoutBase == 130
mm_ap_traffic_probe_cfm(addr vifs[1], 0x80010700'u32)
doAssert mm.keepAliveLimit == 9
finish()
''',
    "station_samples_clock_and_interval_after_tbtt": r'''
begin()
stations[2].initialRateConfig = 102_400
mm.listenWindow = 80
onTimer = proc() =
  doAssert macReads == 1 and vifs[1].tbttTimer == 100 + 102_400
  stations[2].initialRateConfig = 204_800
doAssert dispatchOne()
doAssert macReads == 3 and vifs[1].tbttTimer == 100 + 102_400
doAssert stations[2].listenWindowDuration == 20
doAssert vifs[1].psLastTime == 125 and vifs[1].beaconTimeoutBase == 130
finish()
''',
    "station_applies_each_negotiated_edca_word": r'''
begin()
vifs[1].edcaRegs = [0x0A47'u32, 0x0A43'u32, 0x5E432'u32, 0x2F322'u32]
doAssert dispatchOne()
var edcaWrites: seq[tuple[address: uint, value: uint32]]
for write in writes:
  if write.address in (MACHW_BASE + 0x200'u) .. (MACHW_BASE + 0x20C'u):
    edcaWrites.add(write)
doAssert edcaWrites == @[(MACHW_BASE + 0x200'u, 0x0A47'u32),
  (MACHW_BASE + 0x204'u, 0x0A43'u32), (MACHW_BASE + 0x208'u, 0x5E432'u32),
  (MACHW_BASE + 0x20C'u, 0x2F322'u32)]
finish()
''',
    # The STA VIF is removed with SM's MM_SET_VIF_STATE_REQ queued: the
    # removal ends the attempt (smStaVifRetired), and the real handler drops
    # the request SM no longer waits on without touching the slot, its
    # station or the MAC.
    "retired_vif_request_is_dropped": r'''
begin()
allocateAttempt()
retireVif(1)
doAssert state == SmIdleState and smOwn.request == nil
let queued = events.len
doAssert dispatchOne()
doAssert events.len == queued, "the request was answered"
doAssert vifs[1].state == 0 and vifs[1].tbttTimer == 0 and stations[2].aid == 0
doAssert writes.len == 0 and macReads == 0
drain()
doAssert failures.len == 0 and connected == 0
finish()
''',
    "restore_before_confirmation": r'''
begin()
onSend = proc() =
  doAssert lastSendId == MM_SET_VIF_STATE_CFM
  doAssert mmState == 0 and writes.len > 0
  mmState = 99
  replaceOwner()
doAssert dispatchOne()
doAssert mmState == 99
finish()
''',
}

@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_mm_activation(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
