"""Exercise host-retained RX release accounting and callback lifetime."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rx_channel_capture import source as channel_source
from test_wifi_rx_chain import PLATFORM as CHAIN_PLATFORM, CHECKS as CHAIN_CHECKS


def source() -> str:
    code = channel_source().replace("    processingFlag: uint8\n",
                                    "    processingFlag: uint8\n    uploadCount: uint32\n")
    code = code.replace(procedure(code, "assert_rec"), r'''
proc assert_rec(file, condition: cstring; line: int) = inc recovered
''', 1)
    code = code.replace(procedure(code, "rxl_mpdu_free"), r'''
proc rxl_mpdu_free(p: pointer) =
  inc freed
  rxInvalidateUpload(p)
  rxSwDescView(rxMpduDescView(p).swDesc).uploadDone = 0
''', 1)
    # The stub above precedes the real generation helpers in this fixture.
    code = "proc rxInvalidateUpload(desc: pointer)\n" + code
    code += r'''
var onEnter, onExit: proc()
var enters, exits, otherExits: int
var switchExit, missingEntry, missingExit: bool
proc enter(): uint32 {.cdecl.} =
  inc enters
  result = irqSave()
  if onEnter != nil:
    let action = onEnter
    onEnter = nil
    action()
proc leave(saved: uint32) {.cdecl.} =
  inc exits
  irqRestore(saved)
  if onExit != nil:
    let action = onExit
    onExit = nil
    action()
proc otherLeave(saved: uint32) {.cdecl.} =
  inc otherExits
  irqRestore(saved)
'''
    code = code.replace(procedure(code, "blOpsFunc"), r'''
proc blOpsFunc(slot: int): pointer =
  case slot
  of 20:
    if not missingEntry: result = cast[pointer](enter)
  of 24:
    if not missingExit:
      result = if switchExit: cast[pointer](otherLeave) else: cast[pointer](leave)
  else: discard
''', 1)
    # Callback declarations must precede the replacement table accessor.
    accessor = procedure(code, "blOpsFunc")
    code = code.replace(accessor, "", 1) + accessor
    code = "proc blOpsFunc(slot: int): pointer\n" + code
    code += procedure((FW / "mac_config_debug.nim").read_text(), "bl60x_firmwre_mpdu_free")
    return code + r'''
proc setupHost() =
  setup()
  enters = 0
  exits = 0
  otherExits = 0
  onEnter = nil
  onExit = nil
  switchExit = false
  missingEntry = false
  missingExit = false
  rxSwTableDescAt(0).descCount = 3
  rxHeaderHwDescAt(0).uploadDone = 1
  env.uploadCount = 7
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_host_release_is_counted_once(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [false, true]:
  setupHost()
  interrupts = incoming
  bl60x_firmwre_mpdu_free(rxSwTableDescAt(0))
  doAssert freed == 1 and env.uploadCount == 4
  doAssert enters == 1 and exits == 1 and interrupts == incoming
  bl60x_firmwre_mpdu_free(rxSwTableDescAt(0))
  doAssert freed == 1 and env.uploadCount == 4
  doAssert enters == 1 and exits == 1 and interrupts == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_entry_reset_does_not_debit_replacement(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setupHost()
onEnter = proc() =
  rxInvalidateUpload(rxSwTableDescAt(0))
  env.uploadCount = 99
  rxSwTableDescAt(0).descCount = 9
bl60x_firmwre_mpdu_free(rxSwTableDescAt(0))
doAssert env.uploadCount == 99 and freed == 0
doAssert enters == 1 and exits == 1 and interrupts
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_exit_replacement_is_not_freed(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setupHost()
onExit = proc() =
  rxInvalidateUpload(rxSwTableDescAt(0))
  env.uploadCount = 99
  rxHeaderHwDescAt(0).uploadDone = 1
bl60x_firmwre_mpdu_free(rxSwTableDescAt(0))
doAssert env.uploadCount == 99 and freed == 0
doAssert enters == 1 and exits == 1 and interrupts
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_release_keeps_original_callback_pair(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setupHost()
onEnter = proc() = switchExit = true
bl60x_firmwre_mpdu_free(rxSwTableDescAt(0))
doAssert freed == 1 and env.uploadCount == 4
doAssert enters == 1 and exits == 1 and otherExits == 0 and interrupts
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_release_reentry_is_not_debited_twice(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [false, true]:
  setupHost()
  interrupts = incoming
  onExit = proc() = bl60x_firmwre_mpdu_free(rxSwTableDescAt(0))
  bl60x_firmwre_mpdu_free(rxSwTableDescAt(0))
  doAssert env.uploadCount == 4 and freed == 1
  doAssert enters == 1 and exits == 1 and interrupts == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_invalid_count_or_callbacks_do_not_change_ownership(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for variant in 0 .. 3:
  for incoming in [false, true]:
    setupHost()
    interrupts = incoming
    case variant
    of 0: env.uploadCount = 2
    of 1: rxSwTableDescAt(0).descCount = 0
    of 2: missingEntry = true
    else: missingExit = true
    let previousCount = env.uploadCount
    bl60x_firmwre_mpdu_free(rxSwTableDescAt(0))
    doAssert env.uploadCount == previousCount and freed == 0
    doAssert rxHeaderHwDescAt(0).uploadDone == 1 and recovered == 1
    doAssert enters == exits and interrupts == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_retained_frame_release_returns_payload_chain(tmp_path: Path, mode: str) -> None:
    code = CHAIN_PLATFORM
    lower = (FW / "rx_layer.nim").read_text()
    for name in ("rxPayloadDescIndex", "rxPayloadChainBounds", "rxl_mpdu_free"):
        code += procedure(lower, name)
    code += procedure((FW / "mac_config_debug.nim").read_text(), "bl60x_firmwre_mpdu_free")
    code += CHAIN_CHECKS.split("\nfor count in 1 .. 41:", 1)[0]
    run_program(tmp_path, mode, code + r'''
for count in [1, 2, 4]:
  for incoming in [0'u32, 8'u32]:
    reset(count)
    level = incoming
    expectedLevel = incoming
    desc.descCount = count.uint8
    sw.uploadDone = 1
    lower.uploadCount = 7
    bl60x_firmwre_mpdu_free(addr desc)
    doAssert lower.uploadCount == (7 - count).uint32
    doAssert sw.uploadDone == 0 and released == 1
    doAssert entered == 2 and exited == 2 and level == incoming
    for i in 0 ..< count: doAssert rxPayloadHwDescAt(i).usedFlag == 0
    bl60x_firmwre_mpdu_free(addr desc)
    doAssert lower.uploadCount == (7 - count).uint32 and released == 1
    doAssert entered == 2 and exited == 2 and level == incoming
''')
