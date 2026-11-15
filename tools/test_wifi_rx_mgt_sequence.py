"""Commit management duplicate state only for a current, accepted frame."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rx_decapsulation import CHECKS, dispatch_source


def source() -> str:
    code = r'''
var
  replayResult = 1.cint
  afterReplay: bool
  interrupts = true
  sessionChecks, managementIrqs: seq[bool]
  managementSequences: seq[uint16]
  onReplay: proc()
  rejectManagement: bool
'''+ dispatch_source()
    code = code.replace(
        "proc rxStationCurrent(p: pointer): bool = sessionCurrent\n",
        "proc rxStationCurrent(p: pointer): bool =\n"
        "  sessionChecks.add(interrupts)\n  sessionCurrent\n",
        1,
    )
    code = code.replace(procedure(code, "rxu_cntrl_check_pn"), r'''
proc rxu_cntrl_check_pn(p: pointer; tid: uint8): cint =
  doAssert tid == RxuMgmtPnTid
  inc replayCalls
  afterReplay = true
  if onReplay != nil: onReplay()
  replayResult
''', 1)
    task = (FW / "task_handlers.nim").read_text()
    commit = ""
    marker = "  # Commit management sequence only after MFP acceptance.\n"
    if marker in task:
        commit = task.split(marker, 1)[1].split("  var frameAccepted", 1)[0]
    code = code.replace(procedure(code, "rxu_mgt_frame_check"), r'''
proc rxu_mgt_frame_check(param: pointer; staIdx: uint8): uint32 =
  doAssert param == (addr mpdu) and staIdx == 0
  if rejectManagement: return 0
  let env = addr envState
  let envSeq = env.seqCtrl
  let mfpAcceptedFlag = 1'u8
''' + commit + r'''
  managementIrqs.add(interrupts)
  managementSequences.add(stations[0].sequences.nonQosSeqCtrl)
  0
''', 1)
    code = code.replace("proc irqSave(): uint32 = 0\n", r'''
proc irqSave(): uint32 =
  result = interrupts.uint32 * 8
  interrupts = false
''', 1).replace("proc irqRestore(flags: uint32) = discard\n",
                 "proc irqRestore(flags: uint32) = interrupts = (flags and 8) != 0\n", 1)
    return code + CHECKS.split("# Unprotected IP", 1)[0] + r'''
proc prepare(fc: uint16; protected: bool; initialIrq = true) =
  setup(fc, (if protected: 32 else: 24), 16)
  replayResult = 1
  afterReplay = false
  interrupts = initialIrq
  sessionChecks.setLen(0)
  managementIrqs.setLen(0)
  managementSequences.setLen(0)
  onReplay = nil
  rejectManagement = false
'''


CASES = {
    "policy_rejected_retry": r'''
for initialIrq in [false, true]:
  prepare(0xC0, false, initialIrq)
  let before = stations[0].sequences
  rejectManagement = true
  discard rxu_cntrl_frame_handle(addr mpdu)
  doAssert stations[0].sequences == before,
    "MFP-rejected frame changed the duplicate cache"
  doAssert managementSequences.len == 0 and replayCalls == 0
  rejectManagement = false
  macDataFrameAt(addr bytes[0]).frameControl = 0x08C0
  discard rxu_cntrl_frame_handle(addr mpdu)
  doAssert managementSequences == @[0x1230'u16],
    "valid retry was suppressed after MFP rejection"
  doAssert interrupts == initialIrq
''',
    "rejected_retry": r'''
for subtype in [0xA0'u16, 0xC0, 0xD0]:
  prepare(subtype or 0x4000, true)
  replayResult = 0
  let before = stations[0].sequences
  discard rxu_cntrl_frame_handle(addr mpdu)
  doAssert replayCalls == 1 and managementSequences.len == 0
  doAssert stations[0].sequences == before,
    "rejected management frame changed duplicate state"
  replayResult = 1
  macDataFrameAt(addr bytes[0]).frameControl = subtype or 0x4800
  discard rxu_cntrl_frame_handle(addr mpdu)
  doAssert replayCalls == 2 and managementSequences == @[0x1230'u16],
    "valid retry was suppressed by a rejected frame"
''',
    "accepted_duplicate": r'''
for initialIrq in [false, true]:
  prepare(0x40D0, true, initialIrq)
  discard rxu_cntrl_frame_handle(addr mpdu)
  doAssert managementSequences == @[0x1230'u16] and replayCalls == 1
  doAssert managementIrqs == @[initialIrq] and interrupts == initialIrq
  macDataFrameAt(addr bytes[0]).frameControl = 0x48D0
  discard rxu_cntrl_frame_handle(addr mpdu)
  doAssert managementSequences.len == 1 and replayCalls == 1
  macDataFrameAt(addr bytes[0]).frameControl = 0x40D0
  discard rxu_cntrl_frame_handle(addr mpdu)
  doAssert managementSequences == @[0x1230'u16, 0x1230'u16]
  doAssert replayCalls == 2 and interrupts == initialIrq
''',
    "plaintext": r'''
for initialIrq in [false, true]:
  prepare(0xB0, false, initialIrq)
  discard rxu_cntrl_frame_handle(addr mpdu)
  doAssert managementSequences == @[0x1230'u16] and replayCalls == 0
  doAssert managementIrqs == @[initialIrq] and interrupts == initialIrq
  macDataFrameAt(addr bytes[0]).frameControl = 0x08B0
  discard rxu_cntrl_frame_handle(addr mpdu)
  doAssert managementSequences.len == 1 and replayCalls == 0
''',
    "session_change": r'''
for initialIrq in [false, true]:
  prepare(0x40D0, true, initialIrq)
  onReplay = proc() =
    sessionCurrent = false
    stations[0].sequences.nonQosSeqCtrl = 0xABCD
  discard rxu_cntrl_frame_handle(addr mpdu)
  doAssert stations[0].sequences.nonQosSeqCtrl == 0xABCD
  doAssert managementSequences.len == 0,
    "management dispatch continued after the receive session changed"
  doAssert sessionChecks.len >= 2 and not sessionChecks[^1],
    "final identity check must share the cache-update critical section"
  doAssert interrupts == initialIrq
''',
    "independent_caches": r'''
prepare(0x40D0, true)
for i in 0 ..< 8: stations[0].sequences.qosSeqCtrl[i] = 0x2460'u16 + i.uint16
stations[1].sequences.nonQosSeqCtrl = 0xBEEF
let others = stations
discard rxu_cntrl_frame_handle(addr mpdu)
doAssert stations[0].sequences.qosSeqCtrl == others[0].sequences.qosSeqCtrl
for i in 1 ..< stations.len: doAssert stations[i] == others[i]
doAssert stations[0].sequences.nonQosSeqCtrl == 0x1230
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_rx_management_sequence(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
