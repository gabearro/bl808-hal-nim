"""Measure release depth for SM's scan and registration exchanges."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_registration_exchange import source as exchange_source


def source() -> str:
    code = exchange_source()
    original = procedure(code, "ke_msg_free")
    body = procedure((FW / "kernel_mac_channel.nim").read_text(), "ke_msg_free")
    callbacks = re.findall(r"^  (\w+Forget)\(param\)$", body, re.M)
    stubs = "".join(f"proc {name}(p: pointer) = discard\n" for name in callbacks)
    instrumentation = r'''
var
  freeDepth, peakFreeDepth: int
  freeOrder: seq[pointer]
const KE_EVT_KE_MESSAGE = 0x08000000'u32
proc mmConfigForgetIdleOwner(p: pointer): bool = false
proc chanSwitchForget(p: pointer): bool = false
proc ke_evt_set(bits: uint32) = doAssert false, "scan and registration do not own MM idle"
proc observedFree(p: pointer) =
  let index = live.find(p)
  doAssert index >= 0, "message was freed more than once"
  live.delete(index)
  freeOrder.add(p)
  inc frees
  dealloc(p)
'''
    body = body.replace("  mmTimForget(param)\n", """  inc freeDepth
  peakFreeDepth = max(peakFreeDepth, freeDepth)
  defer: dec freeDepth
  mmTimForget(param)
""", 1).replace("  platformFree(param)\n", "  observedFree(param)\n", 1)
    assert "platformFree(param)" not in body
    code = code.replace(original, instrumentation + stubs + body, 1)
    return code + r'''
proc prepare(incoming: bool) =
  setup()
  resetExchange()
  enabled = incoming
  freeDepth = 0
  peakFreeDepth = 0
  freeOrder.setLen(0)
proc finishFreeCheck(incoming: bool) =
  doAssert live.len == 0 and freeDepth == 0 and enabled == incoming
'''


# SM's scan, join and registration requests are answered in place: each is
# one allocation from send to the release of its answer, and releasing it
# releases nothing else (the former reserved replies were freed from inside
# the request's release, one level deeper).
CASES = {
    "answered_in_place": r'''
for incoming in [false, true]:
  for kind in 0 .. 2:
    prepare(incoming)
    var request: pointer
    if kind == 2: request = issue()
    else:
      begin(kind == 1)
      request = take()
    enabled = incoming
    let reply = if kind == 2: completeRegistration(request) else: complete(request)
    let before = frees
    let header = cast[pointer](keMsgHdrFromPayload(reply))
    release(reply)
    doAssert peakFreeDepth == 1 and frees == before + 1 and freeOrder[^1] == header
    while queued.len != 0: release(take())
    finishFreeCheck(incoming)
''',
    "allocation_failure": r'''
for incoming in [false, true]:
  for joining in [false, true]:
    prepare(incoming)
    failAlloc = true
    submit(joining)
    doAssert queued.len == 0 and peakFreeDepth == 0 and frees == 0
    doAssert failures == @[(14'u16, 0xFFFF'u16)]
    finishFreeCheck(incoming)
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_message_free_depth(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
