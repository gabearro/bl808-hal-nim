"""Check station failure diagnostics through the vendor printf callback ABI."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
import test_wifi_assoc_response as assoc
import test_wifi_sa_query as query
import test_wifi_supplicant_result as supplicant


PRINTF = r'''
var
  printfEnabled: bool
  printedDiagnostics: seq[string]
  printHook: proc()
{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc printfCallback(format: cstring) {.cdecl, varargs.} =
  doAssert format != nil
  var output: array[256, char]
  var length: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ",
           length, " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
           format, ", args); va_end(args);"].}
  doAssert length >= 0 and length < output.len.cint
  printedDiagnostics.add($cast[cstring](addr output[0]))
  if printHook != nil:
    let callback = printHook
    printHook = nil
    callback()
proc blOpsFunc(offset: int): pointer =
  doAssert offset == 4
  if printfEnabled: cast[pointer](printfCallback) else: nil
'''


def with_printf(code: str) -> str:
    return code.replace(procedure(code, "blOpsFunc"), PRINTF, 1)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_association_failure_status(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, with_printf(assoc.source()) + r'''
for enabled in [false, true]:
  for status in [1'u16, 17, 30, 256, 0xBEEF, 0xFFFF]:
    let p = response([], status)
    printfEnabled = enabled
    printedDiagnostics.setLen(0)
    sm_assoc_rsp_handler(p)
    doAssert printedDiagnostics == (if enabled:
      @["Association failure, Wlan802.11 status code = " & $status & "\r\n"]
      else: newSeq[string]())
    doAssert failures == @[(5'u16, status)]
    doAssert sent.len == 0 and rates == 0
    finish(p)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_disconnect_and_query_timeout_reasons(tmp_path: Path, mode: str) -> None:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    code = with_printf(query.platform())
    code += "proc sm_issue_sa_query_request() = discard\n"
    code += procedure(scan, "sm_deauth_handler")
    code += procedure(tasks, "sm_sa_query_timeout_ind_handler")
    code += query.deliver_timeout_source()
    run_program(tmp_path, mode, code + r'''
for enabled in [false, true]:
  for reason in [1'u16, 6, 256, 0xBEEF, 0xFFFF]:
    setupSA(1, 4)
    printfEnabled = enabled
    printedDiagnostics.setLen(0)
    var frame = SmDeauthFrameView(vifIdx: 1, staIdx: 4,
      sa: vifs[1].macAddr, bssid: vifs[1].bssid, reason: reason)
    setFrameLen(addr frame, 26)
    doAssert sm_deauth_handler(addr frame) == 0
    let expected = if enabled:
      @["Deauth/Disassociate by AP, Wlan802.11 reason code = " & $reason & "\r\n"]
      else: newSeq[string]()
    doAssert printedDiagnostics == expected
    doAssert events[^1] == ("disconnect", cast[pointer](addr vifs[1]), 7'u16, reason)

    setupSA(1, 4)
    seedSaQuery(1, armed = true)
    env.saQueryRetryCount = 0
    env.saQueryReason = reason
    printedDiagnostics.setLen(0)
    doAssert deliverSaExpiry() == 0
    doAssert printedDiagnostics == expected and env.saQueryActive == 0
    doAssert events[^1] == ("disconnect", cast[pointer](addr vifs[1]), 7'u16, reason)
    let count = events.len
    doAssert deliverSaExpiry() == 0
    doAssert events.len == count and printedDiagnostics == expected
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_handshake_timeout_before_transmission(tmp_path: Path, mode: str) -> None:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code = "import strutils\n" + with_printf(supplicant.SUPPLICANT_PLATFORM + supplicant.DEAUTH_WAIT +
                                              supplicant.EXTENSION)
    code += "proc sm_supplicant_deauth_cfm(p: pointer; status: uint32) {.cdecl.} = discard\n"
    code += procedure(scan, "me_build_deauthenticate")
    code += supplicant.established_path(scan)
    code += procedure(scan, "sm_handle_supplicant_result")
    run_program(tmp_path, mode, code + r'''
for enabled in [false, true]:
  for rejected in [false, true]:
    resetSupp(1, 4)
    printfEnabled = enabled
    printedDiagnostics.setLen(0)
    pushFail = rejected
    sm_handle_supplicant_result(4, 15)
    doAssert printedDiagnostics == (if enabled:
      @["4-way handshake timeout failure, wlan 802.11 reason code = 15,                try to transmit deauth frame\r\n"]
      else: newSeq[string]())
    doAssert pushCalls == 1 and releases == rejected.int
    doAssert link.macHeader[24] == 15 and link.macHeader[25] == 0
    if rejected: doAssert events[^1] == ("abort", nil, 9'u16, 15'u16)
''')
