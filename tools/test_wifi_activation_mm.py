"""Run the MM activation branch with its real admission and publication order."""

from pathlib import Path
import re

import pytest

from test_wifi_activation_exchange import source as exchange_source
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


HARDWARE = r'''
const
  VIF_TYPE_AP = 2'u8
  MM_REMOVE_IF_REQ = 8'u16
  MM_CHAN_CTXT_UPDATE_REQ = 41'u16
  MmChanCtxtUpdatePayloadSize = 12'u32
  TaskIdleState = 0'u16
  TaskGoingIdleState = 2'u16
  MM_HOST_BYPASSED = 3'u8
  MACHW_STATE_CNTRL_REG = 0x1000'u
  MACHW_BASE = 0x2000'u
type MmRemoveIfReqPayload = object
  vifIdx: uint8
var rxl: tuple[processingFlag: uint8]
proc rxlCntrlEnvView(): ptr typeof(rxl) = addr rxl
proc apmPrepareVifRemoval(vif: uint8): bool = true
proc chanUpdateAdmit(p: pointer): bool = true
proc vifEntryAddr(index: uint8): uint = cast[uint](vifChannelForIdx(index))
proc vifChannelAt(address: uint): ptr Vif = cast[ptr Vif](address)
proc ke_task_sm_activating(): bool = state == SM_ACTIVATING_STATE
proc macTimeNow(): uint32 = 100
proc regRead(address: uint): uint32 =
  invoke(onRead)
  0
proc regWrite(address: uint; value: uint32) =
  writes.add((address, value))
  invoke(onWrite)
proc hal_machw_idle_req() = invoke(onIdle)
proc mm_timer_clear(timer: ptr uint32) = invoke(onTimer)
proc mm_timer_set(timer: ptr uint32; value: uint32) =
  timer[] = value
  invoke(onTimer)
proc chan_bcn_detect_start(vif: pointer) = invoke(onBeacon)
proc mm_env_max_ampdu_duration_set(value: uint32) = invoke(onAmpdu)
'''


def source() -> str:
    code = exchange_source()
    code = code.replace("    rateWord: uint16\n", """    rateWord: uint16
    initialRateConfig, aid, listenWindowDuration: uint16
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
                        "listenWindow: uint16, rxFilterBase: uint32]")
    code = code.replace("  holdMMMode: bool\n", """  holdMMMode: bool
  mmState: uint16
  writes: seq[tuple[address: uint, value: uint32]]
  onRead, onWrite, onIdle, onTimer, onBeacon, onAmpdu: proc()
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
    code += HARDWARE + body
    debug = sorted(set(re.findall(r"\bnimFwDbg\w+", body)))
    return "\n".join(f"var {name}: uint32" for name in debug) + "\n" + code


CASES = {
    "replacement_during_idle_request": r'''
begin()
mmState = 1
onIdle = replaceOwner
doAssert dispatchOne()
doAssert state == 6 and connected == 0 and stationReady == 0
for event in events: doAssert event.id != MM_SET_VIF_STATE_CFM
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

for hook in ["onRead", "onTimer", "onBeacon", "onAmpdu", "onWrite", "onState"]:
    CASES[f"replacement_at_{hook}"] = f'''
begin()
{hook} = replaceOwner
doAssert dispatchOne()
doAssert state == 6 and connected == 0 and stationReady == 0
for event in events: doAssert event.id != MM_SET_VIF_STATE_CFM
finish()
'''


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_mm_activation(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
