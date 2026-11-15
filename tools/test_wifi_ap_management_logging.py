"""Check AP station-management logging, state updates, and reply routing."""

from pathlib import Path

import pytest

import test_wifi_ap_teardown as teardown
from test_wifi_message_allocation import run_program


def source() -> str:
    layout = (teardown.FW / "layout_types.nim").read_text()
    name = "ApmConfMaxStaReqPayload"
    declaration = "type\n  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    return teardown.program_source() + declaration + r'''
const
  APM_CONF_MAX_STA_CFM = 0x140A'u16
  ApmConfMaxStaReqPayloadSize = sizeof(ApmConfMaxStaReqPayload).uint32
var basicSent: seq[tuple[id, destination, source: uint16]]
proc apmConfMaxStaReqView(p: pointer): ptr ApmConfMaxStaReqPayload =
  cast[ptr ApmConfMaxStaReqPayload](p)
proc ke_msg_send_basic(id, destination, source: uint16) =
  basicSent.add((id, destination, source))
''' + teardown.procedure((teardown.FW / "task_handlers.nim").read_text(),
                         "apm_conf_max_sta_req_handler")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_station_limit_arguments_and_routing(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for enabled in [false, true]:
  for limit in [0'u8, 1, 4, 5, 6, 255]:
    for sender in [9'u16, 37]:
      reset()
      logEnabled = enabled
      basicSent.setLen(0)
      apm.maxSta = 99
      request[0] = limit
      requestHeader = Header(srcId: sender, destId: TASK_APM, paramLen: 1)
      doAssert apm_conf_max_sta_req_handler(addr request[0]) == 0
      let expected = min(limit, 5'u8)
      doAssert apm.maxSta == expected
      doAssert basicSent == @[(APM_CONF_MAX_STA_CFM, sender, TASK_APM)]
      doAssert logs == enabled.int
      if enabled:
        doAssert logRecords == @[(2'u32, "apm_task.c", 447.cint,
          "Adjust max_sta_supported to " & $expected & "\r\n")]

reset()
basicSent.setLen(0)
apm.maxSta = 4
requestHeader.paramLen = 0
doAssert apm_conf_max_sta_req_handler(nil) == 0
doAssert apm_conf_max_sta_req_handler(addr request[0]) == 0
doAssert apm.maxSta == 4 and basicSent.len == 0 and logs == 0

reset()
basicSent.setLen(0)
logEnabled = true
request[0] = 5
requestHeader = Header(srcId: 9, destId: TASK_APM, paramLen: 1)
callbackSite = "logWrite"
callbackHook = proc() =
  request[0] = 3
  requestHeader.srcId = 37
  doAssert apm_conf_max_sta_req_handler(addr request[0]) == 0
doAssert apm_conf_max_sta_req_handler(addr request[0]) == 0
doAssert apm.maxSta == 3
doAssert basicSent == @[(APM_CONF_MAX_STA_CFM, 37'u16, TASK_APM),
                       (APM_CONF_MAX_STA_CFM, 9'u16, TASK_APM)]
doAssert logRecords[0].message == "Adjust max_sta_supported to 5\r\n"
doAssert logRecords[1].message == "Adjust max_sta_supported to 3\r\n"
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_teardown_arguments_and_signed_elapsed(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for times in [(80000'u32, 100'u32, "79900"),
              (20'u32, 0xFFFFFFF0'u32, "36"),
              (0'u32, 0x80000000'u32, "-2147483648")]:
  reset()
  logEnabled = true
  now = times[0]
  stations[3].connectionStart = times[1]
  doAssert apm_sta_delete(3, addr rx.staMac[0], 4, 0xBEEF)
  checkDeletion(4, 0xBEEF)
  doAssert logRecords == @[(2'u32, "apm.c", 583.cint,
    "apm_sta_delete:3, aid:4, last seen " & times[2] & "\r\n")]

reset()
logEnabled = true
doAssert apm_sta_remove(1, 3, 6, 0xBEEF)
checkDeletion(6, 0xBEEF)
doAssert logRecords[0] == (2'u32, "apm.c", 1090.cint,
  "apm_sta_remove: sta_idx = 3, sta->mac_addr: 302:504:706\r\n")
doAssert logRecords.len == 2

for disassoc in [false, true]:
  reset()
  logEnabled = true
  rx.reason = 0xBEEF
  if disassoc: apm_disassoc_handler(addr rx)
  else: apm_deauth_handler(addr rx)
  checkDeletion(if disassoc: 3'u16 else: 2'u16, 0xBEEF)
  doAssert logRecords[0] == (2'u32, "apm.c",
    (if disassoc: 1074.cint else: 1054.cint),
    (if disassoc: "Disassociate" else: "Deauth") &
      " by STA, Wlan802.11 reason code = 48879\r\n")
  doAssert logRecords.len == 2

for missingClock in [false, true]:
  reset()
  clockEnabled = not missingClock
  logEnabled = missingClock
  doAssert apm_sta_delete(3, addr rx.staMac[0], 4, 0xBEEF)
  checkDeletion(4, 0xBEEF)
  doAssert logs == 0

reset()
logEnabled = true
callbackSite = "logWrite"
callbackHook = proc() =
  inc staDeleteEpochs[3]
  stations[3].apmWpaContext = cast[pointer](0x76543210)
doAssert not apm_sta_delete(3, addr rx.staMac[0], 4, 0xBEEF)
doAssert logs == 1 and freeCount == 2 and sent.len == 0
doAssert stations[3].apmWpaContext == cast[pointer](0x76543210)
''')
