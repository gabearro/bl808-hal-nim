"""Exercise channel ownership through join submission and registration."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_registration_exchange import source as registration_source


def source() -> str:
    code = r'''
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  TbttNode = object
    hdr: CoListHdr
    state: uint8
''' + registration_source()
    code = code.replace("    channelFreqPair: uint32", """    channelFreqPair: uint32
    chanCtxt: pointer
    tbttNode: TbttNode""", 1)
    for name, declaration in {
        "chan_ctxt_add": "proc chan_ctxt_add*(param: pointer; ctxtIdxOut: ptr uint8): uint8 {.exportc, cdecl.}\n",
        "chan_ctxt_link": "proc chan_ctxt_link*(vifIdx, ctxtIdx: uint8) {.exportc, cdecl.}\n",
        "chanLeaseCurrent": "proc chanLeaseCurrent(lease: ChanCtxtLease): bool\n",
        "chanLeaseAcquire": "proc chanLeaseAcquire(request: pointer; lease: var ChanCtxtLease): uint8\n",
        "chanLeaseLink": "proc chanLeaseLink(lease: var ChanCtxtLease; vifIndex: uint8): bool\n",
        "chanLeaseRelease": "proc chanLeaseRelease(lease: var ChanCtxtLease)\n",
    }.items():
        code = code.replace(procedure(code, name), declaration, 1)
    code += r'''
type
  ChanCtxtView = object
    hdr: CoListHdr
    channel: ChanCtxtDefView
    contextIndexOrMarker, invalidMarker, linkCount, status: uint8
  ChanEnvView = object
    freeList, activeList, tbttList: CoList
    currentCtxt, scheduledCtxt, dominantCtxt: pointer
    slotPeriod, cdeStarted: uint32
    ctxtCount, flags, schedState: uint8
var
  chan_ctxt_pool: array[MAX_CHAN_CTXT, ChanCtxtView]
  chanCtxtLinkEpochs: array[MAX_VIFS, uint32]
  channelEnv: ChanEnvView
  sm_reconn_dominant_flag: uint32
proc chanEnvView(): ptr ChanEnvView = addr channelEnv
proc chanSwitchRetire(target: pointer) = discard
proc chanCtxtAt(p: pointer): ptr ChanCtxtView = cast[ptr ChanCtxtView](p)
proc chanCtxtAt(p: uint): ptr ChanCtxtView = cast[ptr ChanCtxtView](p)
proc chanCtxtForIdx(index: uint8): ptr ChanCtxtView = addr chan_ctxt_pool[index]
proc chanCtxtHdr(p: ptr ChanCtxtView): ptr CoListHdr = addr p.hdr
proc chanTbttHdr(p: ptr TbttNode): ptr CoListHdr = addr p.hdr
proc chanTbttPrimaryList(): ptr CoList = addr channelEnv.tbttList
proc markInvalid(p: ptr ChanCtxtView) =
  p.contextIndexOrMarker = 255
  p.invalidMarker = 255
proc c_memcmp(a, b: pointer; size: csize_t): cint =
  if equalMem(a, b, size.int): 0 else: 1
proc chan_ctxt_trigger(p: pointer) = discard
proc chan_update_tx_power(p: pointer) = invoke(onLink)
proc chan_tbtt_schedule(p: pointer) = discard
proc chanCtxtOpTimer(): pointer = nil
when not declared(mm_timer_clear):  # station_sm.nim's fixture platform has one
  proc mm_timer_clear(p: pointer) = discard
proc chan_ctxt_op_evt(p: pointer) = channelEnv.currentCtxt = nil
proc chan_cde_evt(p: pointer) = discard
'''
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    code += "{.pragma: wifiCtrl.}\nvar txResetEpoch: uint32\nvar rxVifEpochs: array[MAX_VIFS, uint32]\n"
    code += re.search(r"(?ms)^type\n  ChanTbttSnapshot = object.*?(?=^var\n)", kernel).group()
    code += "var\n  chanCtxtEpochs" + kernel.split("var\n  chanCtxtEpochs", 1)[1].split("\nproc chan_init", 1)[0]
    code += "\n"
    for name in ["co_list_push_back", "co_list_pop_front", "co_list_extract",
                 "chan_ctxt_add", "chan_ctxt_del", "chan_ctxt_link", "chan_ctxt_unlink",
                 "chanLeaseCurrent", "chanLeaseAcquire", "chanLeaseLink", "chanLeaseRelease"]:
        body = procedure(kernel, name)
        if name == "chan_ctxt_add":
            body = re.sub(r"(?m)^([ ]*)return 0$", r"\1invoke(onContext)\n\1return 0", body)
        code += body
    return code + r'''
proc freeChannels(): int =
  var node = channelEnv.freeList.first
  while node != nil:
    inc result
    doAssert result <= MAX_CHAN_CTXT
    node = node.next
proc resetChannels() =
  channelEnv = default(ChanEnvView)
  chan_ctxt_pool = default(typeof(chan_ctxt_pool))
  for epoch in chanCtxtEpochs.mitems: inc epoch
  for epoch in chanCtxtLinkEpochs.mitems: inc epoch
  for context in chan_ctxt_pool.mitems:
    markInvalid(addr context)
    co_list_push_back(addr channelEnv.freeList, chanCtxtHdr(addr context))
proc prepareJoin(): pointer =
  resetExchange()
  resetChannels()
  ready()
proc finishChannels() =
  finishExchange()
'''


# The join links the channel context to the STA VIF before it sends
# MM_STA_ADD_REQ, as the blob does; from then on the VIF holds it and the
# teardown of a failed attempt unlinks it (modelled by onFailure below).
CASES = {
    "stale_reply": r'''
let scanReply = prepareJoin()
doAssert scanu_join_cfm_handler(scanReply) == 0
release(scanReply)
let reply = completeRegistration(take())
replaceOwner()
doAssert mm_sta_add_cfm_handler(reply) == 0
release(reply)
finishChannels()
doAssert deletions == 1 and failures.len == 0
# The VIF still holds the context the join linked; its teardown releases it.
doAssert freeChannels() == 2 and vifs[conn.vifIdx].chanCtxt != nil
chan_ctxt_unlink(conn.vifIdx)
doAssert freeChannels() == 3 and channelEnv.ctxtCount == 0
''',
    "successful_handoff": r'''
let scanReply = prepareJoin()
doAssert scanu_join_cfm_handler(scanReply) == 0
release(scanReply)
let reply = completeRegistration(take())
doAssert mm_sta_add_cfm_handler(reply) == 0 and bssCalls == 1
release(reply)
finishChannels()
doAssert freeChannels() == 2 and channelEnv.ctxtCount == 1
doAssert vifs[conn.vifIdx].chanCtxt != nil
chan_ctxt_unlink(conn.vifIdx)
doAssert freeChannels() == 3
''',
    "registration_failure_handoff": r'''
let scanReply = prepareJoin()
doAssert scanu_join_cfm_handler(scanReply) == 0
release(scanReply)
registerStatus = 7
let reply = completeRegistration(take())
onFailure = proc() = chan_ctxt_unlink(conn.vifIdx)
doAssert mm_sta_add_cfm_handler(reply) == 0
release(reply)
finishChannels()
doAssert freeChannels() == 3 and channelEnv.ctxtCount == 0
doAssert failures == @[(15'u16, 0xFFFF'u16)]
''',
    "pool_exhaustion": r'''
let scanReply = prepareJoin()
var definition: ChanCtxtDefView
doAssert smPrepareChannelContext(addr conn, definition)
var occupied: array[3, ChanCtxtLease]
for index in 0..2:
  definition.primFreq += 5
  doAssert chanLeaseAcquire(addr definition, occupied[index]) == 0
doAssert scanu_join_cfm_handler(scanReply) == 0
release(scanReply)
finishChannels()
doAssert freeChannels() == 0 and failures == @[(13'u16, 0xFFFF'u16)]
for lease in occupied.mitems: chanLeaseRelease(lease)
doAssert freeChannels() == 3
''',
    "shared_context": r'''
# A context another VIF already uses is linked, not created; the join's
# failure leaves the other VIF's link alone.
let scanReply = prepareJoin()
var definition: ChanCtxtDefView
doAssert smPrepareChannelContext(addr conn, definition)
var shared: ChanCtxtLease
doAssert chanLeaseAcquire(addr definition, shared) == 0
let otherVif = conn.vifIdx xor 1
doAssert chanLeaseLink(shared, otherVif)
doAssert scanu_join_cfm_handler(scanReply) == 0
release(scanReply)
registerStatus = 7
let reply = completeRegistration(take())
onFailure = proc() = chan_ctxt_unlink(conn.vifIdx)
doAssert mm_sta_add_cfm_handler(reply) == 0
release(reply)
finishChannels()
doAssert freeChannels() == 2 and channelEnv.ctxtCount == 1
doAssert vifs[otherVif].chanCtxt == cast[pointer](chanCtxtForIdx(shared.index))
doAssert chanCtxtForIdx(shared.index).linkCount == 1
doAssert vifs[conn.vifIdx].chanCtxt == nil
chanLeaseRelease(shared)
doAssert freeChannels() == 3
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_registration_channel_ownership(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_context_pool_rejects_invalid_inputs_and_nodes(tmp_path: Path, mode: str) -> None:
    code = source().replace(
        "proc assert_err(a, b: cstring; line: int) = doAssert false",
        "var assertionLines: seq[int]\n"
        "proc assert_err(a, b: cstring; line: int) = assertionLines.add(line)")
    run_program(tmp_path, mode, code + r'''
resetChannels()
var definition: ChanCtxtDefView
definition.primFreq = 2412
var index = 77'u8
doAssert chan_ctxt_add(nil, addr index) == 1 and index == 77
doAssert chan_ctxt_add(addr definition, nil) == 1 and index == 77
doAssert freeChannels() == MAX_CHAN_CTXT

var outside: ChanCtxtView
outside.contextIndexOrMarker = 0xFF
channelEnv.freeList.first = addr outside.hdr
channelEnv.freeList.last = addr outside.hdr
doAssert chan_ctxt_add(addr definition, addr index) == 1 and index == 77
doAssert outside.contextIndexOrMarker == 0xFF and assertionLines.len == 0
doAssert channelEnv.freeList.first == addr outside.hdr

resetChannels()
let active = addr chan_ctxt_pool[0]
active.contextIndexOrMarker = 0
channelEnv.freeList.first = addr active.hdr
channelEnv.freeList.last = addr active.hdr
doAssert chan_ctxt_add(addr definition, addr index) == 1 and index == 77
doAssert active.contextIndexOrMarker == 0
doAssert channelEnv.freeList.first == addr active.hdr

resetChannels()
doAssert chan_ctxt_add(addr definition, addr index) == 0 and index == 0
let allocated = chanCtxtForIdx(index)
allocated.contextIndexOrMarker = 1
chan_ctxt_del(index)
doAssert assertionLines == @[0xAD0] and allocated.contextIndexOrMarker == 1
doAssert freeChannels() == MAX_CHAN_CTXT - 1
''')
