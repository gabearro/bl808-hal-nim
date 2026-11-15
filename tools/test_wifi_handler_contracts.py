"""Check the registered message ABI and connection-loss replay behavior."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


def registered_handlers() -> list[str]:
    source = (FW / "dispatch_tables.nim").read_text()
    return sorted(set(re.findall(
        r"handler: (?:cast\[pointer\]|keMsgHandlerAddress)\((\w+)\)", source,
    )))


def test_registered_handlers_have_message_result(tmp_path: Path) -> None:
    sources = "\n".join(path.read_text() for path in FW.rglob("*.nim"))
    names = registered_handlers()
    assert len(names) >= 71
    declarations = []
    for name in names:
        match = re.search(r"(?ms)^proc " + re.escape(name) + r"\*?\(.*? =\n", sources)
        assert match, name
        declarations.append(match.group(0) + "  discard\n")
    checks = "\n".join(
        f'  doAssert compiles((block:\n'
        f'    let handler: MessageHandler = {name}\n'
        f'    discard)), "{name} has an incompatible message ABI"'
        for name in names
    )
    run_program(tmp_path, "checked", """
type MessageHandler = proc(param: pointer): cint {.cdecl.}
""" + "\n".join(declarations) + "\nstatic:\n" + checks)


def test_registration_checks_the_handler_type(tmp_path: Path) -> None:
    source = (FW / "dispatch_tables.nim").read_text()
    assert "handler: cast[pointer]" not in source
    helper = re.search(r"(?ms)^template keMsgHandlerAddress\(.*?(?=\n\S|\Z)", source)
    assert helper, "message registration needs an ABI type check"
    run_program(tmp_path, "checked", helper.group(0) + """
proc valid(param: pointer): cint {.cdecl.} = 0
proc noResult(param: pointer) {.cdecl.} = discard
proc wrongArgument(param: uint32): cint {.cdecl.} = 0
proc wrongResult(param: pointer): uint32 {.cdecl.} = 0
proc wrongConvention(param: pointer): cint {.nimcall.} = 0
static:
  doAssert compiles(keMsgHandlerAddress(valid))
  doAssert not compiles(keMsgHandlerAddress(noResult))
  doAssert not compiles(keMsgHandlerAddress(wrongArgument))
  doAssert not compiles(keMsgHandlerAddress(wrongResult))
  doAssert not compiles(keMsgHandlerAddress(wrongConvention))
doAssert keMsgHandlerAddress(valid) == cast[pointer](valid)
""")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_connection_loss_is_saved_until_idle(tmp_path: Path, mode: str) -> None:
    source = """
const
  TASK_SM = 4'u8
  SmIdleState = 0'u16
  SmDisconnectingState = 10'u16
  KeMsgConsumed = 0.cint
  KeMsgSaved = 2.cint
type
  Indication = object
    reason: uint16
    vifIdx, padding: uint8
  Vif = object
    vifType, state: uint8
var
  vifs: array[2, Vif]
  state: uint16
  disconnects, tlvCalls: int
  lastVif: pointer
  lastReason: uint16
proc mmConnectionLossIndView(p: pointer): ptr Indication = cast[ptr Indication](p)
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc ke_state_get(task: uint8): uint16 =
  doAssert task == TASK_SM
  state
proc ke_state_set(task: uint8; value: uint16) =
  doAssert task == TASK_SM
  state = value
proc sm_connection_tlv_set(kind: uint32; data: pointer; length: uint32) =
  doAssert kind == 0 and data == nil and length == 0
  inc tlvCalls
proc sm_disconnect_process(vif: pointer; reason, status: uint16) =
  doAssert state == SmDisconnectingState and status == 0xFFFF
  lastVif = vif
  lastReason = reason
  inc disconnects
"""
    source += procedure((FW / "task_handlers.nim").read_text(), "mm_connection_loss_ind_handler")
    source += """
let handler: proc(param: pointer): cint {.cdecl.} = mm_connection_loss_ind_handler
var ind = Indication(reason: 0x1234, vifIdx: 1)
for busyState in 1'u16 .. 10'u16:
  for vifType in 0'u8 .. 2'u8:
    for active in 0'u8 .. 1'u8:
      state = busyState
      vifs[1] = Vif(vifType: vifType, state: active)
      let count = disconnects
      doAssert handler(addr ind) == KeMsgSaved
      doAssert state == busyState and disconnects == count
      state = SmIdleState
      doAssert handler(addr ind) == KeMsgConsumed
      if vifType == 0 and active != 0:
        doAssert disconnects == count + 1
        doAssert lastVif == cast[pointer](addr vifs[1]) and lastReason == ind.reason
      else:
        doAssert disconnects == count and state == SmIdleState
doAssert tlvCalls == disconnects and disconnects == 10
"""
    run_program(tmp_path, mode, source)
