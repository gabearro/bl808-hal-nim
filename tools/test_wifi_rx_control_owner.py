"""Check lower RX ownership through interrupted dispatch and queue replacement."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rx_drain_lifetime import source as drain_source


def source() -> str:
    code = drain_source()
    code = code.replace(procedure(code, "rxl_mpdu_free"), r'''
proc rxl_mpdu_free(p: pointer) =
  let index = ((cast[uint](p) - cast[uint](addr rx_swdesc_tab[0])) div sizeof(RxSwTableDescView).uint).int
  released.add(index)
  inc rxUploadEpochs[index]
  invoke(onFree)
''', 1)
    code += "\nvar nimFwDbgRxuDescPrepare: uint32\n"
    code += procedure((FW / "rx_upper.nim").read_text(), "rxu_cntrl_desc_prepare")
    return code + r'''
proc ownUpload(index: int) =
  let descriptor = rxSwTableDescAt(index)
  descriptor.curDesc = rxPayloadHwDescAt(index)
  rxu_cntrl_desc_prepare(descriptor)
proc drainRest() =
  while env.queue.first != nil: rxl_cntrl_evt()
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_dispatch_error_releases_unclaimed_frame(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [false, true]:
  for phase in 0 .. 3:
    setup()
    interrupts = incoming
    let generation = rxUploadGeneration(rxSwTableDescAt(0))
    let fail = proc() =
      # RX upper may have adjusted the header before a later callback fails.
      if phase == 3: rxHeaderHwDescAt(0).mpduLengthBytes = 20
      raise newException(ValueError, "RX processing stopped")
    case phase
    of 0: onTrace = fail
    of 1: onTick = fail
    of 2: onPower = fail
    else: onUpper = fail
    var raised = false
    try: rxl_cntrl_evt()
    except ValueError: raised = true
    doAssert raised and interrupts == incoming and not rxlControlActive
    doAssert released == @[0], "dequeued frame lost its release on dispatch error"
    doAssert not rxUploadCurrent(rxSwTableDescAt(0), generation)
    doAssert env.queue.first == addr rxSwTableDescAt(1).link
    doAssert (events and 0x100000) != 0
    onTick = nil
    onPower = nil
    drainRest()
    doAssert released == @[0, 1, 2, 3, 4, 5]
    doAssert delivered == (if phase == 3: @[0, 1, 2, 3, 4, 5] else: @[1, 2, 3, 4, 5])
    doAssert interrupts == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_dispatch_cleanup_preserves_transferred_ownership(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [false, true]:
  for hostOwned in [false, true]:
    setup()
    interrupts = incoming
    let generation = rxUploadGeneration(rxSwTableDescAt(0))
    onUpper = proc() =
      if hostOwned:
        rxHeaderHwDescAt(0).uploadDone = 1
        rxPayloadHwDescAt(0).usedFlag = 1
      else:
        co_list_push_back(addr upperEnv.uploadList, addr rxSwTableDescAt(6).link)
        ownUpload(0)
      raise newException(ValueError, "RX upper stopped after handoff")
    var raised = false
    try: rxl_cntrl_evt()
    except ValueError: raised = true
    doAssert raised and released.len == 0 and rxUploadCurrent(rxSwTableDescAt(0), generation)
    doAssert interrupts == incoming and not rxlControlActive
    if hostOwned:
      doAssert upperEnv.uploadList.first == nil
      doAssert rxPayloadHwDescAt(0).usedFlag == 1
    else:
      doAssert upperEnv.uploadList.first == addr rxSwTableDescAt(6).link
      doAssert upperEnv.uploadList.first.next == addr rxSwTableDescAt(0).link
      doAssert upperEnv.uploadList.last == addr rxSwTableDescAt(0).link
      doAssert (events and 0x800000) != 0, "queued upload lost its handoff event"
    drainRest()
    doAssert released == @[1, 2, 3, 4, 5] and interrupts == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_dispatch_cleanup_does_not_release_replacement(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [false, true]:
  for changed in 0 .. 2:
    setup()
    interrupts = incoming
    onUpper = proc() =
      case changed
      of 0: inc rxUploadEpochs[0]
      of 1: rxSwTableDescAt(0).swDesc = rxHeaderHwDescAt(6)
      else: rxHeaderHwDescAt(0).bufferChain = rxPayloadHwDescAt(6)
      raise newException(ValueError, "frame replaced during dispatch")
    var raised = false
    try: rxl_cntrl_evt()
    except ValueError: raised = true
    doAssert raised and released.len == 0 and interrupts == incoming
    doAssert env.queue.first == addr rxSwTableDescAt(1).link
    doAssert (events and 0x100000) != 0 and not rxlControlActive
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_dispatch_cleanup_bounds_pending_queue_walk(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [false, true]:
  for cycle in [false, true]:
    setup(1)
    interrupts = incoming
    if cycle:
      upperEnv.uploadList.first = addr rxSwTableDescAt(2).link
      rxSwTableDescAt(2).link.next = addr rxSwTableDescAt(2).link
    else:
      upperEnv.uploadList.first = cast[ptr CoListHdr](1)
    onTrace = proc() = raise newException(ValueError, "dispatch stopped")
    var raised = false
    try: rxl_cntrl_evt()
    except ValueError: raised = true
    doAssert raised and recovered == 1 and released.len == 0
    doAssert assertIrqs == @[incoming] and interrupts == incoming
    doAssert not rxlControlActive
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_pop_rechecks_head_and_generation_under_lock(tmp_path: Path, mode: str) -> None:
    code = source()
    code = "var onPopLock: proc()\nvar admissionFinished: bool\n" + code
    old = procedure(code, "rxAdmitMpdu")
    code = code.replace(old, old.replace("proc rxAdmitMpdu(", "proc originalAdmitMpdu(", 1) + r'''
proc rxAdmitMpdu(desc: pointer; sw: var ptr RxSwDescView): RxFrameAdmission =
  result = originalAdmitMpdu(desc, sw)
  admissionFinished = true
''', 1)
    old = procedure(code, "irqSave")
    code = code.replace(old, old.replace("  result = interrupts.uint32 * 8", r'''
  if admissionFinished and onPopLock != nil:
    admissionFinished = false
    let callback = onPopLock
    onPopLock = nil
    callback()
  result = interrupts.uint32 * 8''', 1), 1)
    run_program(tmp_path, mode, code + r'''
for replaceGeneration in [false, true]:
  setup()
  admissionFinished = false
  onPopLock = proc() =
    doAssert interrupts
    if replaceGeneration: inc rxUploadEpochs[0]
    else: env.queue.first = addr rxSwTableDescAt(1).link
  drainRest()
  let expected = if replaceGeneration: @[0, 1, 2, 3, 4, 5] else: @[1, 2, 3, 4, 5]
  doAssert delivered == expected, "dequeue consumed a different head or generation"
  doAssert released == expected and interrupts and not rxlControlActive
''')
