"""Check first-link activation and shared-context power updates."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
var chanCtxtLinkEpochs: array[2, uint32]
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  Channel = object
    txPower: uint8
  Context = object
    hdr: CoListHdr
    channel: Channel
    contextIndexOrMarker, linkCount, status: uint8
  Vif = object
    chanCtxt: pointer
    txPower, maxTxPower: int8
  Environment = object
    activeList: CoList
    slotPeriod: uint32
    ctxtCount, flags: uint8
    currentCtxt, scheduledCtxt: pointer
var
  env: Environment
  contexts: array[3, Context]
  vifs: array[2, Vif]
  activations: seq[tuple[kind: string, target: pointer]]
proc chanEnvView(): ptr Environment = addr env
proc chanCtxtAt(p: pointer): ptr Context = cast[ptr Context](p)
proc chanCtxtForIdx(index: uint8): ptr Context = addr contexts[index]
proc chanCtxtHdr(context: ptr Context): ptr CoListHdr = addr context.hdr
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc assert_err(condition, file: cstring; line: cint) = doAssert false
proc co_list_push_back(list: ptr CoList; node: ptr CoListHdr) =
  node.next = nil
  if list.first == nil: list.first = node
  else: list.last.next = node
  list.last = node
proc chan_switch_start(context: pointer) =
  activations.add(("switch", context))
proc chan_cde_evt(event: pointer) =
  doAssert event != nil and cast[ptr uint8](event)[] == 0
  activations.add(("schedule", nil))
proc reset() =
  env = default(Environment)
  contexts = default(typeof(contexts))
  for index in 0..2:
    contexts[index].contextIndexOrMarker = index.uint8
    contexts[index].channel.txPower = 99
  vifs = [Vif(txPower: 17, maxTxPower: 20), Vif(txPower: 12, maxTxPower: 8)]
  activations.setLen(0)
'''


CHECKS = r'''
for vifIndex in 0'u8..1:
  for contextIndex in 0'u8..2:
    for existingLinks in 0'u8..1:
      for otherContexts in 0'u8..2:
        for flags in [0'u8, 4, 8, 12, 16, 128]:
          for status in [0'u8, 1, 2, 3, 4, 5]:
            for period in [0'u32, 51200, 0xFFFFFF00'u32]:
              reset()
              let selected = addr contexts[contextIndex]
              selected.linkCount = existingLinks
              selected.status = status
              env.flags = flags
              env.slotPeriod = period
              env.ctxtCount = otherContexts + (existingLinks != 0).uint8
              env.currentCtxt = addr contexts[(contextIndex + 1) mod 3]
              env.scheduledCtxt = addr contexts[(contextIndex + 2) mod 3]
              let current = env.currentCtxt
              let scheduled = env.scheduledCtxt
              if existingLinks != 0:
                vifs[1 - vifIndex].chanCtxt = selected
                co_list_push_back(addr env.activeList, selected.chanCtxtHdr)
              chan_ctxt_link(vifIndex, contextIndex)
              doAssert vifs[vifIndex].chanCtxt == selected
              doAssert selected.linkCount == existingLinks + 1
              doAssert env.slotPeriod == period + 51200'u32
              doAssert env.ctxtCount == otherContexts + 1
              doAssert env.flags == flags
              doAssert env.currentCtxt == current and env.scheduledCtxt == scheduled
              doAssert env.activeList.first == selected.chanCtxtHdr
              doAssert env.activeList.last == selected.chanCtxtHdr
              doAssert selected.hdr.next == nil
              doAssert selected.status == (if existingLinks == 0: 1'u8 else: status)
              let power = if existingLinks != 0 or vifIndex == 1: 8'u8 else: 17'u8
              doAssert selected.channel.txPower == power,
                "every link must update the shared channel power limit"
              let activate = existingLinks == 0 and (flags and 12) == 0
              doAssert activations.len == activate.int,
                "only the first VIF may activate a channel context"
              if activate:
                let expected = if otherContexts == 0: ("switch", cast[pointer](selected))
                               else: ("schedule", nil)
                doAssert activations[0] == expected

reset()
chan_ctxt_link(0, 0)
doAssert activations == @[("switch", cast[pointer](addr contexts[0]))]
chan_ctxt_link(1, 0)
doAssert activations.len == 1 and contexts[0].linkCount == 2
doAssert contexts[0].channel.txPower == 8
doAssert env.ctxtCount == 1 and env.slotPeriod == 102400
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_first_link_activates_shared_context(tmp_path: Path, mode: str) -> None:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    code = PLATFORM
    for name in ["chan_ctxt_trigger", "chan_update_tx_power", "chan_ctxt_link"]:
        code += procedure(kernel, name)
    run_program(tmp_path, mode, code + CHECKS)
