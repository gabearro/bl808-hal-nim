"""Measure cleanup depth for real scan and registration request/reply pairs."""

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
    stubs = "".join(f"proc {name}(p: pointer) = discard\n" for name in callbacks
                    if name not in {"smScanForget", "smRegistrationForget"})
    instrumentation = r'''
var
  freeDepth, peakFreeDepth: int
  freeOrder: seq[pointer]
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
proc pair(kind: int; publish: bool): tuple[request, reply: pointer] =
  let owner = smTxBeginForVif(conn.vifIdx)
  if kind == 2:
    result.request = smRegistrationAllocate(owner, addr indication)
    if result.request == nil: return
    cast[ptr MmStaAddReqPayload](result.request).vifIdx = conn.vifIdx
    let tag = smRegistrationTagFor(keMsgHdrFromPayload(result.request))
    doAssert tag != nil and tag.command and tag.reply != nil
    result.reply = tag.reply
    let replyTag = smRegistrationTagFor(keMsgHdrFromPayload(result.reply))
    doAssert replyTag != nil and not replyTag.command and replyTag.reply == nil
    if publish:
      state = SmAddingChanState
      doAssert smRegistrationPublish(result.request)
  else:
    let id = if kind == 0: SCANU_START_REQ else: SCANU_JOIN_REQ
    result.request = smScanAlloc(owner, addr indication, id, SmScanningState)
    if result.request == nil: return
    let tag = smScanTagFor(keMsgHdrFromPayload(result.request))
    doAssert tag != nil and tag.command and tag.reply != nil
    result.reply = tag.reply
    let replyTag = smScanTagFor(keMsgHdrFromPayload(result.reply))
    doAssert replyTag != nil and not replyTag.command and replyTag.reply == nil
    if publish:
      state = SmScanningState
      doAssert smScanPublish(result.request)
proc prepare(incoming: bool) =
  setup()
  resetExchange()
  enabled = incoming
  freeDepth = 0
  peakFreeDepth = 0
  freeOrder.setLen(0)
proc finishFreeCheck(incoming: bool) =
  doAssert live.len == 0 and freeDepth == 0 and enabled == incoming
  doAssert smScanTags == nil and smRegistrationTags == nil
  smScanService()
  smRegistrationService()
'''


CASES = {
    "unclaimed_pairs": r'''
for incoming in [false, true]:
  for publish in [false, true]:
    for count in [1, 8]:
      prepare(incoming)
      var pairs: seq[tuple[request, reply: pointer]]
      for index in 0 ..< count:
        for kind in 0 .. 2: pairs.add(pair(kind, publish))
      for index in countdown(pairs.high, 0):
        let item = pairs[index]
        let requestHeader = cast[pointer](keMsgHdrFromPayload(item.request))
        let replyHeader = cast[pointer](keMsgHdrFromPayload(item.reply))
        let before = freeOrder.len
        ke_msg_free(requestHeader)
        doAssert freeOrder[before ..< freeOrder.len] == @[replyHeader, requestHeader]
      doAssert peakFreeDepth == 2 and frees == count * 6
      finishFreeCheck(incoming)
''',
    "transferred_reply": r'''
for incoming in [false, true]:
  for kind in 0 .. 2:
    prepare(incoming)
    let item = pair(kind, true)
    let reply = if kind == 2: smRegistrationTakeReply(item.request)
      else: smScanCompletionAlloc(item.request,
          (if kind == 0: SCANU_START_CFM else: SCANU_JOIN_CFM), TASK_SM)
    doAssert reply == item.reply
    ke_msg_free(keMsgHdrFromPayload(item.request))
    doAssert peakFreeDepth == 1 and live.len == 1
    doAssert live[0] == cast[pointer](keMsgHdrFromPayload(reply))
    ke_msg_free(keMsgHdrFromPayload(reply))
    doAssert peakFreeDepth == 1 and frees == 2
    finishFreeCheck(incoming)
''',
    "allocation_failure": r'''
for incoming in [false, true]:
  for kind in 0 .. 2:
    for failReply in [false, true]:
      prepare(incoming)
      if failReply:
        onAlloc = proc() = failAlloc = true
      else:
        failAlloc = true
      let item = pair(kind, false)
      doAssert item.request == nil and item.reply == nil
      doAssert peakFreeDepth == failReply.int and frees == failReply.int
      finishFreeCheck(incoming)
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_message_free_depth(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
