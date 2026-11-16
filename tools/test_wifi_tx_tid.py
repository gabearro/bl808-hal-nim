"""Reject unsupported TX TIDs before they index the station sequence array."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_tx_sequence import CHECKS, program_source


def source(unchecked: bool = False) -> str:
    code = program_source()
    if unchecked:
        body = procedure(code, "txu_cntrl_push")
        code = code.replace(body, "{.push checks:off.}\n" + body + "\n{.pop.}\n", 1)
    return code + CHECKS.split("proc checkTx(", 1)[0]


CASES = {
    "invalid_tids": r'''
for enabled in [false, true]:
  for station in 0..<STA_INFO_TAB_ENTRIES:
    for tid in 8..254:
      reset()
      interrupts = enabled
      var desc = HostTxDescView(staInfoIdx: station.uint8, staIdx: tid.uint8,
                               vifIdx: 0, frameLen: 0x0008,
                               seqAssigned: 0x7777, seqOut: 0x8888,
                               hdrLen: 0x66, qosExtLen: 0x55, secTailLen: 0x44)
      let before = sta_info_tab
      let beforeVifs = vifs
      calls.setLen(0)
      pushedDesc = nil
      droppedStatus = 0
      let accepted = txu_cntrl_push(addr desc, 2)
      doAssert sta_info_tab == before, "unsupported TID changed station state"
      doAssert not accepted, "unsupported TID reached TX queue"
      doAssert calls == @["irq-save", "drop-count", "confirm", "irq-restore"]
      doAssert droppedStatus == 0xC0020000'u32
      doAssert vifs == beforeVifs and pushedDesc == nil
      doAssert desc.seqAssigned == 0x7777 and desc.seqOut == 0x8888
      doAssert desc.hdrLen == 0x66 and desc.qosExtLen == 0x55 and desc.secTailLen == 0x44
      doAssert desc.staInfoIdx == 0xFF and interrupts == enabled
''',
    "valid_boundaries": r'''
for enabled in [false, true]:
  for tid in [0'u8, 7, 0xFF]:
    reset()
    interrupts = enabled
    var desc = HostTxDescView(staInfoIdx: 0, staIdx: tid, vifIdx: 0,
                             frameLen: 0x0008, seqAssigned: 0x7777)
    let before = sta_info_tab
    calls.setLen(0)
    pushedDesc = nil
    pushResult = 1
    doAssert txu_cntrl_push(addr desc, 2)
    doAssert pushedDesc == (addr desc) and interrupts == enabled
    if tid == 0xFF:
      doAssert sta_info_tab == before and desc.seqAssigned == 0x7777
    else:
      doAssert desc.seqAssigned == (4090 + tid.uint16 * 11) mod 4096
      doAssert readSeq(0, tid) == (desc.seqAssigned + 1) mod 4096
''',
    "changed_tid_before_assignment": r'''
for stage in ["entry", "ready"]:
  reset()
  var desc = HostTxDescView(staInfoIdx: 0, staIdx: 0, vifIdx: 0,
                           frameLen: 0x8E88, seqAssigned: 0x7777)
  onStage = proc(actual: string) =
    if actual == stage: desc.staIdx = 9
  let before = sta_info_tab
  calls.setLen(0)
  pushedDesc = nil
  doAssert not txu_cntrl_push(addr desc, 2)
  doAssert sta_info_tab == before and pushedDesc == nil
  doAssert desc.seqAssigned == 0x7777 and interrupts
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("unchecked", [False, True], ids=["bounds", "unchecked"])
@pytest.mark.parametrize("case", CASES)
def test_tx_tid_bounds(tmp_path: Path, mode: str, unchecked: bool, case: str) -> None:
    code = source(unchecked)
    if case == "changed_tid_before_assignment":
        code = "{.define: bl808WifiConnectTrace.}\n" + code
    run_program(tmp_path, mode, code + CASES[case])
