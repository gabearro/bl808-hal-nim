"""Check the AP startup completion's real C variadic logging contract."""

from pathlib import Path

import pytest

import test_wifi_ap_start as startup
from test_wifi_message_allocation import run_program


LOGGER = r'''
var
  enableStartLog: bool
  startLogs: seq[tuple[level: uint32, line: cint, message: string]]
{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc startLogger(level: uint32; tag, file: cstring; line: cint;
                 format: cstring) {.cdecl, varargs.} =
  doAssert tag == nil and file == cstring("apm.c")
  doAssert cast[uint](format) > 4096
  var output: array[128, char]
  var length: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ",
           length, " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
           format, ", args); va_end(args);"].}
  doAssert length > 0 and length < output.len.cint
  startLogs.add((level, line, $cast[cstring](addr output[0])))
proc getLogFunc(slot: int): PlatformLogFunc =
  doAssert slot == 204
  if enableStartLog: cast[PlatformLogFunc](startLogger) else: nil
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_ap_completion_log_arguments(tmp_path: Path, mode: str) -> None:
    code = startup.program_source()
    code = code.replace(startup.procedure(code, "getLogFunc"), LOGGER, 1)
    run_program(tmp_path, mode, code + r'''
for vif in 0'u8 .. 1:
  for status in [0'u8, 7]:
    for enabled in [false, true]:
      reset(vif, false)
      enableStartLog = enabled
      startLogs.setLen(0)
      state = ApmStartingState
      apm.connectInfo = request
      apmPendingCancelMask = 1'u8 shl vif
      apmStartConfirmation = newMessage(APM_START_CFM, TASK_API, TASK_APM,
                                        ApmStartCfmPayloadSize)
      apmStartVifMessage = newMessage(MM_SET_VIF_STATE_REQ, TASK_MM, TASK_APM,
                                      MmSetVifStateReqPayloadSize)
      contexts[2].contextIndexOrMarker = 2
      vifs[vif].chanCtxt = addr contexts[2]
      let expectedRates = apmStartInfoView(request).beaconRateInfo
      let expectedInterval = apmStartInfoView(request).vifBeaconInterval
      apm_start_cfm(cast[pointer](status.uint))
      doAssert requestFreed and apm.connectInfo == nil and state == ApmIdleState
      doAssert cfms.len == 1 and cfms[0].status == status and cfms[0].vifIdx == vif
      if status == 0:
        doAssert cfms[0].channelContextIndex == 2 and cfms[0].staIdx == vif + 5
        doAssert vifs[vif].key.flags == expectedRates
        doAssert vifs[vif].apStartBeaconInterval == expectedInterval
        doAssert rateInitialized == 1 and stations[vif + 5].valid == 1
        doAssert timers == @[APM_STA_CONNECT_TIMEOUT_IND]
        doAssert apmPendingCancelMask == 0
        let activation = co_list_pop_front(addr keMsgQueueSent)
        doAssert activation != nil and activation.id == MM_SET_VIF_STATE_REQ
        let payload = cast[ptr MmSetVifStateReqPayload](keMsgPayload(activation))
        doAssert payload.state == 1 and payload.vifIdx == vif
        ke_msg_free(activation)
      else:
        doAssert timers.len == 0 and rateInitialized == 0
        doAssert channelDeletes == 1 and vifs[vif].chanCtxt == nil
      doAssert allocated.len == 0 and keMsgQueueSent.first == nil
      let successLogs = @[(2'u32, 94.cint, "--- APM start cfm, apm_start_cfm\r\n"),
                          (1'u32, 120.cint, "apm_start_cfm: start apm timer\r\n")]
      let failureLogs = @[(1'u32, 120.cint, "apm_start_cfm: start apm timer\r\n")]
      doAssert startLogs == (if not enabled: newSeq[tuple[level: uint32,
        line: cint, message: string]]() elif status == 0: successLogs else: failureLogs)

reset(0, false)
enableStartLog = true
startLogs.setLen(0)
apm.connectInfo = request
apm_start_cfm(nil)
doAssert requestFreed and allocated.len == 0 and startLogs.len == 0
apm_start_cfm(nil)
doAssert startLogs.len == 0 and cfms.len == 0
''')
