"""Check RX release ownership and the matching platform critical-section pair."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rx_chain import PLATFORM


def source() -> str:
    code = PLATFORM
    for name in ("rxUploadGeneration", "rxUploadCurrent", "rxInvalidateUpload"):
        code = code.replace(procedure(code, name), "", 1)
    code = r'''
var onEnter, onLeave: proc()
var replacedLeave, missingEnter, missingLeave: bool
var wrongLeaves: int
var rxUploadEpochs: array[1, uint32]
proc invoke(hook: var proc()) =
  if hook != nil:
    let action = hook
    hook = nil
    action()
''' + code
    code = code.replace(procedure(code, "enter"), r'''
proc enter(): uint32 {.cdecl.} =
  result = level
  level = 0
  inc entered
  invoke(onEnter)
''', 1)
    code = code.replace(procedure(code, "leave"), r'''
proc leave(saved: uint32) {.cdecl.} =
  doAssert level == 0
  level = saved
  inc exited
  invoke(onLeave)
proc wrongLeave(saved: uint32) {.cdecl.} =
  inc wrongLeaves
  level = saved
''', 1)
    code = code.replace(procedure(code, "blOpsFunc"), r'''
proc blOpsFunc(offset: int): pointer =
  case offset
  of 20: (if missingEnter: nil else: cast[pointer](enter))
  of 24: (if missingLeave: nil elif replacedLeave: cast[pointer](wrongLeave)
          else: cast[pointer](leave))
  else: nil
''', 1)
    lower = (FW / "rx_layer.nim").read_text()
    code += r'''
proc rxMpduDescIndex(p: pointer): int =
  if p == addr desc: 0 else: -1
'''
    for name in ("rxUploadGeneration", "rxUploadCurrent", "rxInvalidateUpload",
                 "rxPayloadDescIndex", "rxPayloadChainBounds", "rxl_mpdu_free"):
        code += procedure(lower, name)
    return code + r'''
var otherHeader: RxSwDescView
proc setup(count = 2; terminal = true; incoming = 8'u32) =
  zeroMem(addr rx_payload_desc[0], sizeof(rx_payload_desc))
  sw = default(RxSwDescView)
  otherHeader = default(RxSwDescView)
  desc = RxMpduDescView(swDesc: addr sw, descFlag: 3)
  level = incoming
  expectedLevel = incoming
  assertions = 0
  entered = 0
  exited = 0
  released = 0
  wrongLeaves = 0
  onEnter = nil
  onLeave = nil
  replacedLeave = false
  missingEnter = false
  missingLeave = false
  releaseThrows = false
  for i in 0 ..< count:
    let payload = rxPayloadHwDescAt(i)
    payload.usedFlag = 0x1234
    if i + 1 < count: payload.next = rxPayloadHwDescAt(i + 1)
    elif terminal: payload.status = 1
  if count != 0: sw.bufferChain = rxPayloadHwDescAt(0)
  sw.uploadDone = 1
proc reuse() =
  inc rxUploadEpochs[0]
  sw.uploadDone = 77
  desc.prevDesc = cast[pointer](11)
  desc.curDesc = cast[pointer](12)
  for i in 0 .. 2: rxPayloadHwDescAt(i).usedFlag = 88
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_release_stops_after_enter_recycles_or_rebinds(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for variant in 0 .. 2:
  for incoming in [0'u32, 8]:
    setup(incoming = incoming)
    onEnter = proc() =
      case variant
      of 0: reuse()
      of 1: desc.swDesc = addr otherHeader
      else: sw.bufferChain = rxPayloadHwDescAt(2)
    rxl_mpdu_free(addr desc)
    doAssert released == 0 and entered == 1 and exited == 1
    doAssert assertions == 0 and level == incoming
    doAssert rxPayloadHwDescAt(0).usedFlag == (if variant == 0: 88'u32 else: 0x1234'u32)
    doAssert sw.uploadDone == (if variant == 0: 77'u32 else: 1'u32)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_release_uses_captured_leave_callback(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
onEnter = proc() = replacedLeave = true
rxl_mpdu_free(addr desc)
doAssert released == 1 and exited == 1 and wrongLeaves == 0 and level == 8
doAssert sw.uploadDone == 0
setup()
onLeave = reuse
rxl_mpdu_free(addr desc)
doAssert released == 1 and exited == 1 and sw.uploadDone == 77
doAssert rxPayloadHwDescAt(0).usedFlag == 88 and desc.curDesc == cast[pointer](12)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_release_error_paths_balance_platform_state(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [0'u32, 8]:
  setup(2, false, incoming)
  rxl_mpdu_free(addr desc)
  doAssert released == 0 and assertions == 1 and entered == 1 and exited == 1
  doAssert sw.uploadDone == 1 and level == incoming
  setup(2, true, incoming)
  releaseThrows = true
  var raised = false
  try: rxl_mpdu_free(addr desc)
  except ValueError: raised = true
  doAssert raised and entered == 1 and exited == 1 and level == incoming
for missing in [0, 1]:
  setup()
  missingEnter = missing == 0
  missingLeave = missing == 1
  rxl_mpdu_free(addr desc)
  doAssert entered == 0 and exited == 0 and assertions == 1 and released == 0
  doAssert level == 8 and sw.uploadDone == 1
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_bounded_release_chains(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for count in [1, 2, 4, 41]:
  setup(count)
  rxl_mpdu_free(addr desc)
  doAssert released == 1 and entered == 1 and exited == 1 and level == 8
  doAssert sw.uploadDone == 0 and desc.curDesc == rxPayloadHwDescAt(count - 1)
  doAssert desc.prevDesc == (if count == 1: nil else: cast[pointer](rxPayloadHwDescAt(count - 2)))
  for i in 0 ..< count: doAssert rxPayloadHwDescAt(i).usedFlag == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_release_recovery_does_not_target_replacement(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup(2, false)
onLeave = reuse
rxl_mpdu_free(addr desc)
doAssert assertions == 0 and released == 0 and entered == 1 and exited == 1
doAssert sw.uploadDone == 77 and rxPayloadHwDescAt(0).usedFlag == 88
doAssert desc.curDesc == cast[pointer](12) and level == 8

setup()
rxl_mpdu_free(nil)
rxl_mpdu_free(cast[pointer](1))
desc.swDesc = nil
rxl_mpdu_free(addr desc)
doAssert assertions == 3 and entered == 0 and exited == 0 and released == 0
doAssert sw.uploadDone == 1 and level == 8
''')
