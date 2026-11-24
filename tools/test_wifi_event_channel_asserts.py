"""Exercise event/channel preconditions against returning firmware assertions."""

from pathlib import Path
import re

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_completion_reentry import host_source
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


EVENT_PLATFORM = r'''
const KE_EVT_MAX = 26
var
  ke_env: array[36, uint8]
  keEvtHandlers: array[KE_EVT_MAX, tuple[handler, param: pointer]]
  assertions: seq[cint]
  calls: seq[pointer]
  onAssert: proc()
template keEnvEventField(): ptr uint32 = cast[ptr uint32](addr ke_env[0])
template keEvtField: untyped = keEnvEventField()[]
proc assert_err(condition, file: cstring; line: cint) =
  assertions.add(line)
  if onAssert != nil: onAssert()
proc nimFwTrace2U32(label: cstring; a, b: uint32) = discard
proc dispatched(p: pointer) {.cdecl.} = calls.add(p)
proc setup() =
  keEvtField = 0
  assertions.setLen(0)
  calls.setLen(0)
  onAssert = nil
  for index in 0 ..< KE_EVT_MAX:
    keEvtHandlers[index] = (cast[pointer](dispatched), cast[pointer](index + 1))
'''


CHANNEL_PLATFORM = r'''
const
  MAX_CHAN_CTXT = 3
  MAX_VIFS = 2
  MACHW_TIMLO_REG = 0x24B00120'u
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  Context = object
    hdr: CoListHdr
    channel: ChanCtxtDefView
    contextIndexOrMarker, linkCount, status: uint8
  Tbtt = object
    hdr: CoListHdr
    state: uint8
  Vif = object
    chanCtxt: pointer
    tbttNode: Tbtt
  Environment = object
    activeList, tbttList: CoList
    slotPeriod, cdeStarted, remainingTimeTarget: uint32
    ctxtCount, flags, schedState: uint8
    currentCtxt, scheduledCtxt, dominantCtxt: pointer
var
  env: Environment
  contexts: array[5, Context]
  vifs: array[MAX_VIFS, Vif]
  chanCtxtLinkEpochs: array[MAX_VIFS, uint32]
  chanCtxtEpochs: array[5, uint32]
  chanConnlessGeneration: uint32
  txResetEpoch: uint32
  scan: ChanScanPoolOverlay
  assertions: seq[cint]
  actions: seq[string]
  onAssert: proc()
  clockValue, clockReads: uint32
  sm_reconn_dominant_flag: uint32
  chanScanPending: bool
  nimFwDbgChanScanChanMeta, nimFwDbgChanScanChanFreq: uint32
proc chanEnvView(): ptr Environment = addr env
proc irqSave(): uint32 = 0
proc irqRestore(saved: uint32) = discard
proc chanCtxtForIdx(index: uint8): ptr Context = addr contexts[index]
proc chanCtxtAt(p: pointer): ptr Context = cast[ptr Context](p)
proc chanCtxtHdr(p: ptr Context): ptr CoListHdr = addr p.hdr
proc chanTbttHdr(p: ptr Tbtt): ptr CoListHdr = addr p.hdr
proc chanTbttPrimaryList(): ptr CoList = addr env.tbttList
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc chanScanPoolOverlay(): ptr ChanScanPoolOverlay = addr scan
proc chanCtxtOpTimer(): pointer = cast[pointer](76)
proc chan_ctxt_trigger(p: pointer) = actions.add("trigger")
proc smDeferredChannelUnlinked(vifIndex: uint8) = discard
proc chan_update_tx_power(p: pointer) = actions.add("power")
proc chan_tbtt_schedule(p: pointer) = actions.add("tbtt")
proc chan_cde_evt(p: pointer) = actions.add("cde")
proc chan_ctxt_op_evt(p: pointer) = actions.add("op")
proc chan_ctxt_del(index: uint8) = actions.add("delete")
proc chanSwitchCancel(p: pointer) = actions.add("cancel")
proc chan_conn_less_delay_prog() = actions.add("delay")
proc chan_switch_start(p: pointer) =
  actions.add(if p == (addr contexts[4]): "roc" else: "scan")
proc chanStartConnlessSwitch(p: pointer) = chan_switch_start(p)
proc mm_timer_clear(p: pointer) = actions.add("clear")
proc c_memcpy(dst, src: pointer; count: csize_t): pointer =
  copyMem(dst, src, count.int)
  dst
proc packChannelMeta(p: ptr ChanCtxtDefView): uint32 = 0
proc packChannelFreq(p: ptr ChanCtxtDefView): uint32 = p.primFreq.uint32
proc encodedArgU32(p: pointer): uint32 = cast[uint](p).uint32
proc nimFwTrace2U32(label: cstring; a, b: uint32) = discard
proc assert_err(condition, file: cstring; line: cint) =
  assertions.add(line)
  if onAssert != nil: onAssert()
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_TIMLO_REG
  inc clockReads
  clockValue
proc setup() =
  env = default(Environment)
  contexts = default(typeof(contexts))
  for index in 0 ..< contexts.len:
    contexts[index].contextIndexOrMarker = index.uint8
  vifs = default(typeof(vifs))
  chanCtxtLinkEpochs = default(typeof(chanCtxtLinkEpochs))
  scan = ChanScanPoolOverlay(slot: 255)
  assertions.setLen(0)
  actions.setLen(0)
  onAssert = nil
  clockReads = 0
  clockValue = 1000
  sm_reconn_dominant_flag = 0
  chanScanPending = false
'''


def channel_source() -> str:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    channel = layouts("ChanCtxtDefView", "ChanScanPoolOverlay", "ChanScanReqPayload")
    channel += CHANNEL_PLATFORM
    for name in ("co_list_push_back", "co_list_extract", "chan_ctxt_link", "chan_ctxt_unlink",
                 "chan_is_on_operational_channel", "chan_ctxt_get_remaining_time_ms",
                 "chanScanDurationTicks"):
        channel += procedure(kernel, name)
    channel += re.search(r"(?ms)^template chanScanChannel\(.*?(?=^proc )", kernel).group()
    return (channel + procedure(kernel, "chan_scan_req")
            + procedure(kernel, "chanConnlessDelayEvent")
            + procedure(kernel, "chan_conn_less_delay_evt"))


EVENT_CASES = {
    "unregistered": r'''
for index in 0 ..< KE_EVT_MAX:
  setup()
  keEvtField = 1'u32 shl (31 - index)
  keEvtHandlers[index].handler = nil
  let pending = keEvtField
  ke_evt_schedule()
  doAssert assertions == @[236.cint] and calls.len == 0 and keEvtField == pending
''',
    "out_of_range": r'''
for bit in 0 .. 5:
  setup()
  keEvtField = 1'u32 shl bit
  let pending = keEvtField
  ke_evt_schedule()
  doAssert assertions == @[236.cint] and calls.len == 0 and keEvtField == pending
''',
    "priority": r'''
setup()
ke_evt_schedule()
doAssert calls.len == 0 and assertions.len == 0
for index in 0 ..< KE_EVT_MAX:
  setup()
  keEvtField = (1'u32 shl (31 - index)) or 1
  let pending = keEvtField
  ke_evt_schedule()
  doAssert calls == @[cast[pointer](index + 1)] and keEvtField == pending
  doAssert assertions.len == 0
''',
    "assertion_reentry": r'''
setup()
keEvtField = 1'u32 shl 15
keEvtHandlers[16].handler = nil
onAssert = proc() =
  keEvtHandlers[16].handler = cast[pointer](dispatched)
  keEvtField = 0x80000000'u32
ke_evt_schedule()
doAssert assertions == @[236.cint] and calls.len == 0
doAssert keEvtField == 0x80000000'u32
''',
}


CHANNEL_CASES = {
    "link_abi": r'''
for vifIndex in 0'u8 .. 1'u8:
  for contextIndex in 0'u8 .. 2'u8:
    setup()
    chan_ctxt_link(vifIndex, contextIndex)
    doAssert vifs[vifIndex].chanCtxt == (addr contexts[contextIndex])
    doAssert vifs[1 - vifIndex].chanCtxt == nil
    doAssert contexts[contextIndex].linkCount == 1
    doAssert env.ctxtCount == 1 and env.slotPeriod == 51200
    doAssert chanCtxtLinkEpochs[vifIndex] == 1 and chanCtxtLinkEpochs[1 - vifIndex] == 0
    doAssert actions == @["trigger", "power"] and assertions.len == 0
''',
    "link_rejection": r'''
for alreadyLinked in [false, true]:
  setup()
  contexts[0].contextIndexOrMarker = 255
  if alreadyLinked: vifs[0].chanCtxt = addr contexts[1]
  let state = (env, contexts, vifs, chanCtxtLinkEpochs)
  chan_ctxt_link(0, 0)
  doAssert assertions == @[if alreadyLinked: 0xAFE.cint else: 0xAFF.cint]
  doAssert (env, contexts, vifs, chanCtxtLinkEpochs) == state and actions.len == 0
''',
    "unlink_rejection": r'''
setup()
vifs[0].tbttNode.state = 77
let state = (env, contexts, vifs, chanCtxtLinkEpochs)
chan_ctxt_unlink(0)
doAssert assertions == @[0xB2F.cint] and actions.len == 0
doAssert (env, contexts, vifs, chanCtxtLinkEpochs) == state
''',
    "remaining_time": r'''
setup()
env.currentCtxt = addr contexts[0]
env.remainingTimeTarget = 6010
doAssert chan_ctxt_get_remaining_time_ms(nil) == 0
doAssert assertions == @[0xD21.cint] and clockReads == 0
for index in 0'u8 .. 1'u8:
  setup()
  env.currentCtxt = addr contexts[0]
  env.remainingTimeTarget = 6010
  vifs[0].chanCtxt = addr contexts[0]
  vifs[1].chanCtxt = addr contexts[1]
  doAssert chan_ctxt_get_remaining_time_ms(addr vifs[index]) == (if index == 0: 5'u32 else: 0'u32)
  doAssert clockReads == (if index == 0: 1'u32 else: 0'u32)
  doAssert assertions.len == 0
''',
    "remaining_time_boundary": r'''
for irq in [false, true]:
  setup()
  env.currentCtxt = addr contexts[0]
  vifs[0].chanCtxt = addr contexts[0]
  clockValue = 7000
  env.remainingTimeTarget = 6999
  # Like the BL808 sub/divu pair, a passed deadline is not an immediate dwell.
  doAssert chan_ctxt_get_remaining_time_ms(addr vifs[0]) == high(uint32) div 1000
  for target in [7000'u32, 7999'u32]:
    env.remainingTimeTarget = target
    doAssert chan_ctxt_get_remaining_time_ms(addr vifs[0]) == 0
  env.remainingTimeTarget = 8000
  doAssert chan_ctxt_get_remaining_time_ms(addr vifs[0]) == 1
  clockValue = high(uint32) - 500
  env.remainingTimeTarget = 1499
  doAssert chan_ctxt_get_remaining_time_ms(addr vifs[0]) == 2
  doAssert assertions.len == 0 and clockReads == 5
''',
    "scan_busy": r'''
for slot in 0'u8 .. 4'u8:
  setup()
  scan.slot = slot
  scan.durationTicks = 987
  scan.requestVifIdx = 1
  let state = (env, contexts, scan, chanScanPending)
  var request = ChanScanReqPayload(vifIdx: 0, duration: 8192, prim20Freq: 2437)
  chan_scan_req(addr request)
  doAssert assertions == @[0x9E5.cint] and actions.len == 0
  doAssert (env, contexts, scan, chanScanPending) == state
''',
    "scan_valid": r'''
setup()
var request = ChanScanReqPayload(vifIdx: 1, duration: 8192, prim20Freq: 2437,
                                 center1Freq: 2437, txPower: 17)
let original = request
chan_scan_req(addr request)
doAssert assertions.len == 0 and actions == @["cancel", "delay"]
doAssert scan.slot == 3 and scan.vifIdx == 255 and scan.requestVifIdx == 1
doAssert scan.durationTicks == 8 and scan.active == 1 and scan.channel.primFreq == 2437
doAssert scan.channel.txPower == 17 and env.flags == 2 and chanScanPending
doAssert request == original
actions.setLen(0)
request.reqType = 1
chan_scan_req(addr request)
doAssert actions == @["clear", "op"]
''',
    "delay_flags": r'''
for flags in 0 .. 255:
  for scheduled in [false, true]:
    setup()
    env.flags = flags.uint8
    if scheduled: env.scheduledCtxt = addr contexts[0]
    chan_conn_less_delay_evt()
    let roc = (flags and 1) != 0
    let scanPending = not roc and (flags and 2) != 0
    let invalid = (roc and (flags and 4) != 0) or (scanPending and (flags and 8) != 0)
    if invalid:
      doAssert assertions == @[if roc: 874.cint else: 888.cint]
      doAssert env.flags == flags.uint8 and actions.len == 0
    else:
      doAssert assertions.len == 0
      let expected = if roc: (flags and not 1) or 4
                     elif scanPending: (flags and not 2) or 8
                     else: flags
      doAssert env.flags == expected.uint8
      doAssert actions == (if scheduled or (not roc and not scanPending): newSeq[string]()
                           elif roc: @["roc"] else: @["scan"])
''',
    "assertion_reentry": r'''
for operation in 0 .. 5:
  setup()
  contexts[0].contextIndexOrMarker = 255
  scan.slot = 3
  env.flags = if operation == 4: 5 else: 10
  onAssert = proc() =
    env.flags = 128
    env.slotPeriod = 12345
    vifs[0].chanCtxt = addr contexts[2]
    vifs[0].tbttNode.state = 88
    chanCtxtLinkEpochs[0] = 456
    scan.slot = 4
    scan.durationTicks = 777
  case operation
  of 0: chan_ctxt_link(0, 0)
  of 1: chan_ctxt_unlink(0)
  of 2: doAssert chan_ctxt_get_remaining_time_ms(nil) == 0
  of 3:
    var request = ChanScanReqPayload(duration: 8192)
    chan_scan_req(addr request)
  else: chan_conn_less_delay_evt()
  doAssert assertions.len == 1 and actions.len == 0 and clockReads == 0
  doAssert env.flags == 128 and env.slotPeriod == 12345
  doAssert vifs[0].chanCtxt == (addr contexts[2]) and vifs[0].tbttNode.state == 88
  doAssert chanCtxtLinkEpochs[0] == 456 and scan.slot == 4 and scan.durationTicks == 777
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", EVENT_CASES)
def test_event_preconditions(tmp_path: Path, mode: str, case: str) -> None:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    code = EVENT_PLATFORM + "".join(procedure(kernel, name) for name in (
        "eventIndex32", "keDispatchEvent", "ke_evt_schedule"))
    run_program(tmp_path, mode, code + EVENT_CASES[case])


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_event_field_uses_ke_env(tmp_path: Path, mode: str) -> None:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    code = EVENT_PLATFORM + r'''
var interrupts = true
proc irqSave(): uint32 =
  result = if interrupts: 8'u32 else: 0'u32
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = (saved and 8) != 0
'''
    for name in ("ke_evt_field_get", "ke_evt_set", "ke_evt_clear",
                 "eventIndex32", "keDispatchEvent", "ke_evt_schedule"):
        code += procedure(kernel, name)
    run_program(tmp_path, mode, code + r'''
setup()
ke_evt_set(0x80100000'u32)
doAssert interrupts and ke_evt_field_get() == 0x80100000'u32
doAssert keEvtField == 0x80100000'u32
ke_evt_clear(0x80000000'u32)
doAssert interrupts and ke_evt_field_get() == 0x00100000'u32
keEnvEventField()[] = 0x40000000'u32
ke_evt_schedule()
doAssert calls == @[cast[pointer](1 + 1)]
doAssert ke_evt_field_get() == 0x40000000'u32
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CHANNEL_CASES)
def test_channel_preconditions(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, channel_source() + CHANNEL_CASES[case])


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_confirmation_event_rejection(tmp_path: Path, mode: str) -> None:
    code = host_source()
    code = code.replace(procedure(code, "assert_err"), r'''
var assertionDetails: seq[tuple[condition, file: string; line: cint]]
var onAssert: proc()
proc assert_err(condition, file: cstring; line: cint) =
  assertionDetails.add(($condition, $file, line))
  if onAssert != nil: onAssert()
''', 1)
    run_program(tmp_path, mode, code + r'''
for incoming in [false, true]:
  for ac in [0'u8, 1, 2, 3, 4, 5, 31, 32, 255]:
    for replace in [false, true]:
      setup(incoming)
      assertionDetails.setLen(0)
      onAssert = nil
      let index = if ac < 5: ac else: 2'u8
      confirmLists[index] = CoList(first: addr frames[0].link, last: addr frames[0].link)
      frames[0].link.next = nil
      txEnv.packetCounter = 1
      ke_env[0] = 0x80000000'u32
      if replace:
        onAssert = proc() =
          confirmLists[index] = CoList(first: addr frames[1].link, last: addr frames[1].link)
          frames[1].link.next = nil
          ke_env[0] = ke_env[0] or txl_cfm_evt_bit[index]
      txl_cfm_evt(ac)
      doAssert assertionDetails == @[("ke_evt_get() & evt_bit", "module", 346.cint)]
      doAssert txEnv.packetCounter == 1 and hostCompletions.len == 0 and indications.len == 0
      doAssert confirmLists[index].first == (if replace: addr frames[1].link else: addr frames[0].link)
      doAssert ke_env[0] == (if replace: 0x80000000'u32 or txl_cfm_evt_bit[index] else: 0x80000000'u32)
      doAssert txActiveFlush == nil and interruptsEnabled == incoming
''')


def test_tx_assertion_provenance() -> None:
    tx = (FW / "tx_layer.nim").read_text()
    expected = {
        "txl_cfm_evt": 'assert_err("ke_evt_get() & evt_bit", "module", 346)',
        "txl_cntrl_halt_ac": 'assert_err("0", "module", 0x700)',
        "txl_transmit_trigger": 'assert_err("access_category < NX_TXQ_CNT", "module", 0x86C)',
        "txl_frame_push": 'assert_err("(thd->datastartptr & 0x01) == 0", "module", 316)',
        "txl_frame_try_push_force": 'assert_err("(thd->datastartptr & 0x01) == 0", "module", 367)',
    }
    for name, diagnostic in expected.items():
        assert diagnostic in procedure(tx, name)
