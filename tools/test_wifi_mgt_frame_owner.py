"""Keep management production tied to its original RX descriptor generation."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_mgt_message_lifetime import run_lifetime
from test_wifi_mgt_receive import management_source


def source() -> str:
    code = ("var onAllocate: proc()\nvar onTrace: proc(label: string)\n"
            "var messageFrees: int\nvar transferFails: bool\n" + management_source())
    code = code.replace("template nimFwTrace2U32(args: varargs[untyped]) = discard", r'''
proc nimFwTrace2U32(label: string; a, b: uint32) =
  if onTrace != nil: onTrace(label)
''', 1)
    old = procedure(code, "rxMgtAllocMessage")
    code = code.replace(old, old.replace("  inc allocationCalls\n",
        "  inc allocationCalls\n  if onAllocate != nil: onAllocate()\n", 1), 1)
    old = procedure(code, "ke_msg_send")
    code = code.replace(old, old.replace("  if onSend != nil: onSend()\n  inc sent\n",
                                        "  inc sent\n  if onSend != nil: onSend()\n", 1), 1)
    old = procedure(code, "ke_msg_free_payload")
    code = code.replace(old, old + "  inc messageFrees\n", 1)
    old = procedure(code, "rxu_mpdu_upload_and_indicate")
    code = code.replace(old, old.replace("  desc.curDesc = addr frame", "  if not transferFails: desc.curDesc = addr frame"), 1)
    return code + r'''
proc prepare(incoming: bool) =
  reset(0xB0, 0, 4)
  desc.curDesc = nil
  interrupts = incoming
  onAllocate = nil
  onSend = nil
  onTrace = nil
  messageFrees = 0
  transferFails = false
proc reuse() =
  inc rxUploadEpochs[0]
  # Same peer and address, but a different RX allocation.
  frame.body[0] = 0xA5
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_receive_stops_after_generation_change(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [false, true]:
  for phase in 0 .. 2:
    prepare(incoming)
    case phase
    of 0: onPolicy = reuse
    of 1: onDecode = reuse
    else: onAllocate = reuse
    doAssert rxu_mgt_frame_check(addr desc, 4) == 0
    doAssert sent == 0 and uploads == 0, "replacement RX frame reached management publication"
    doAssert allocationCalls == (if phase == 2: 1 else: 0)
    doAssert messageFrees == (if phase == 2: 1 else: 0), "abandoned indication was not freed"
    doAssert frame.body[0] == 0xA5 and interrupts == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_publication_does_not_upload_reused_frame(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [false, true]:
  prepare(incoming)
  mm.rxPromiscUploadFlag = 1
  onSend = reuse
  doAssert rxu_mgt_frame_check(addr desc, 4) == 0
  doAssert sent == 1 and messageFrees == 0, "published indication was reclaimed"
  doAssert uploads == 0, "old receive uploaded a replacement descriptor"
  doAssert interrupts == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_failed_raw_transfer_does_not_claim_ownership(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [false, true]:
  for failed in [false, true]:
    prepare(incoming)
    forceIgnore = true
    forceUpload = true
    mm.rxPromiscUploadFlag = 1
    transferFails = failed
    doAssert rxu_mgt_frame_check(addr desc, 4) == (not failed).uint32,
      "raw upload claimed ownership without completing transfer preparation"
    doAssert uploads == 1 and sent == 0 and interrupts == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_allocation_rejects_reused_descriptor(tmp_path: Path, mode: str) -> None:
    run_lifetime(tmp_path, mode, r'''
for incoming in [false, true]:
  setup()
  interrupts = incoming
  onAlloc = proc() = inc rxUploadEpochs[0]
  doAssert rxMgtAllocMessage(addr frame, 4, 68) == nil,
    "message allocation accepted a replacement descriptor"
  doAssert frees == 1 and live.len == 0 and rxMgtIdentities == nil
  doAssert interrupts == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_indication_error_cleanup_obeys_publication(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [false, true]:
  for afterSend in [false, true]:
    prepare(incoming)
    frame.frameControl = 0x10
    env.frameCtrl = 0x10
    if afterSend:
      onSend = proc() = raise newException(ValueError, "message callback stopped")
    else:
      onTrace = proc(label: string) =
        if label == "[WIFI-NIMFW] assoc_copy ":
          raise newException(ValueError, "copy trace stopped")
    var raised = false
    try: discard rxu_mgt_frame_check(addr desc, 4)
    except ValueError: raised = true
    doAssert raised and allocationCalls == 1 and interrupts == incoming
    doAssert sent == afterSend.int
    doAssert messageFrees == (not afterSend).int
    doAssert uploads == 0
''')
