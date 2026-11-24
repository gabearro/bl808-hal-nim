"""Exercise the ADDBA receive-to-response lifetime across diagnostic callbacks."""

from pathlib import Path
import re

import pytest

from test_wifi_block_ack import PLATFORM
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


LOGGING = r'''
var
  logging: bool
  printCalls, printLookups, failPrint: int
  printed: seq[string]
  printIrqs: seq[bool]
  onPrint: proc()

{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc printMessage(format: cstring) {.cdecl, varargs.} =
  doAssert format != nil
  var output: array[512, char]
  var length: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", length,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert length > 0 and length < output.len.cint
  printed.add($cast[cstring](addr output[0]))
  printIrqs.add(interrupts)
  inc printCalls
  if onPrint != nil: onPrint()
  if printCalls == failPrint:
    raise newException(ValueError, "ADDBA logging stopped")
proc blOpsFunc(offset: int): pointer =
  doAssert offset == 4
  inc printLookups
  if logging: cast[pointer](printMessage) else: nil
proc setupOwner(enabled: bool) =
  reset()
  interrupts = enabled
  logging = true
  printCalls = 0
  printLookups = 0
  failPrint = -1
  printed.setLen(0)
  printIrqs.setLen(0)
  onPrint = nil
proc requestWithDetails(message: var Message; params: uint16;
                        ssn = 0xABCD'u16; timeout = 0xFEDC'u16): pointer =
  result = request(message, 2, params)
  let body = addBaReqActionBodyAt(addr rxuMgtIndMsgAt(result).body[0])
  body.startSeq = ssn
  body.timeout = timeout
'''


def source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n"
    for name in ["TxSessionIdentity", "RxuMgtDispatchView", "RxuMgtIndMsgView",
                 "BamEnvView", "MeAddBaReqParamView", "AddBaReqActionBodyView",
                 "AddBaRspActionBodyView", "DelBaInfoView", "DelBaActionBodyView"]:
        match = re.search(r"(?ms)^  " + name + r"\b.*?(?=^  \w|\Z)", layout)
        assert match, name
        types += match.group(0)
    platform = PLATFORM.replace("proc blOpsFunc(index: int): pointer = nil\n", "")
    assert platform != PLATFORM
    management = (FW / "scan_station_ap_me.nim").read_text()
    return (
        types + platform + LOGGING
        + procedure(management, "me_build_add_ba_rsp")
        + procedure((FW / "block_ack.nim").read_text(), "bam_send_air_action_frame")
        + procedure((FW / "task_handlers.nim").read_text(), "rxu_mgt_ind_handler_bam")
    )


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_session_changes_cancel_the_old_response(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incomingIrq in [false, true]:
  for stage in 1 .. 2:
    for change in 0 .. 8:
      setupOwner(incomingIrq)
      var message: Message
      let p = requestWithDetails(message, 0x1217)
      onPrint = proc() =
        if printCalls != stage: return
        case change
        of 0: discard
        of 1: inc stationEpochs[2]
        of 2: inc rxVifEpochs[0]
        of 3: inc txResetEpoch
        of 4: resetting = true
        of 5: stas[2].valid = 0
        of 6: stas[2].instNbr = 1
        of 7: retiring = true
        else:
          inc stationEpochs[3]
          inc rxVifEpochs[1]
      doAssert rxu_mgt_ind_handler_bam(p) == 0
      doAssert interrupts == incomingIrq
      if change in [0, 8]:
        doAssert printCalls == 2 and allocations == 1 and pushes == 1
        doAssert mmio == 0xABCD0090'u32
      else:
        doAssert allocations == 0 and pushes == 0 and powerUpdates == 0,
          "ADDBA response was rebound after the original session changed"
        doAssert printCalls == stage
        doAssert mmio == 0xABCD0010'u32
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_log_fields_and_request_snapshot(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for params in [0'u16, 3, 0x073E, 0xFFFF]:
  for mutateRequest in [false, true]:
    setupOwner(true)
    var message: Message
    let p = requestWithDetails(message, params)
    onPrint = proc() =
      if mutateRequest and printCalls == 1:
        for byte in message.payload.mitems: byte = 0xCC
    doAssert rxu_mgt_ind_handler_bam(p) == 0
    let tid = ((params shr 2) and 15).uint32
    let count = (params shr 6).uint32
    let accepted = if count == 0: 12'u32 else: min(count, 12'u32)
    let amsdu = if (params and 1) != 0: "Permitted" else: "Not Permitted"
    let policy = if (params and 2) != 0: "Immediate Block Ack" else: "Delayed Block Ack"
    let req = "-----------------> AABA Request:\r\n    A-MSDU: " & amsdu &
      "\r\n    Block Ack Policy: " & policy & "\r\n    TID: " & $tid &
      "\r\n    Number of Buffers: " & $count & "\r\n"
    let rsp = "-----------------> AABA Response:\r\n    A-MSDU: Not Permitted" &
      "\r\n    Block Ack Policy: Immediate Block Ack\r\n    TID: " & $tid &
      "\r\n    Number of Buffers: " & $accepted & "\r\n    ssn: 2748" &
      "\r\n    timeout: 65244\r\n    tid " & $tid & "\r\n"
    doAssert printed == @[req, rsp], "ADDBA diagnostics do not match the captured request"
    doAssert printLookups == 2 and printIrqs == @[true, true]
    doAssert allocations == 1 and pushes == 1 and interrupts
    let body = addBaRspActionBodyAt(addr link.macHeader[24])
    doAssert body.dialogToken == 0xEF and body.timeout == 0
    doAssert body.statusCode == (if tid < 8 and (params and 2) != 0:
      0'u16 else: 37'u16)
    doAssert body.baParams == ((accepted shl 6).uint16 or (params and 0x3E) or 2)
    doAssert mmio == (if tid < 8 and (params and 2) != 0:
      0xABCD0090'u32 else: 0xABCD0010'u32)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "goto", "firmware"])
def test_disabled_replaced_and_failing_print_callbacks(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incomingIrq in [false, true]:
  setupOwner(incomingIrq)
  logging = false
  var message: Message
  let p = requestWithDetails(message, 0x1217)
  doAssert rxu_mgt_ind_handler_bam(p) == 0
  doAssert printCalls == 0 and printLookups == 2
  doAssert allocations == 1 and pushes == 1 and interrupts == incomingIrq

  setupOwner(incomingIrq)
  discard requestWithDetails(message, 0x1217)
  onPrint = proc() = logging = false
  doAssert rxu_mgt_ind_handler_bam(p) == 0
  doAssert printCalls == 1 and printLookups == 2
  doAssert allocations == 1 and pushes == 1 and interrupts == incomingIrq

  for stage in 1 .. 2:
    setupOwner(incomingIrq)
    discard requestWithDetails(message, 0x1217)
    failPrint = stage
    var raised = false
    try: discard rxu_mgt_ind_handler_bam(p)
    except ValueError: raised = true
    doAssert raised and printCalls == stage
    doAssert interrupts == incomingIrq
    doAssert allocations == 0 and pushes == 0 and mmio == 0xABCD0010'u32
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_existing_reset_and_retirement_stop_before_logging(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incomingIrq in [false, true]:
  for gate in 0 .. 1:
    setupOwner(incomingIrq)
    var message: Message
    let p = requestWithDetails(message, 0x1217)
    if gate == 0: resetting = true
    else: retiring = true
    doAssert rxu_mgt_ind_handler_bam(p) == 0
    doAssert printCalls == 0 and printLookups == 0
    doAssert allocations == 0 and pushes == 0 and mmio == 0xABCD0010'u32
    doAssert interrupts == incomingIrq
''')
