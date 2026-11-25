"""Check station-side registration encoding against the vendor bit extraction."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_sm_scan_completion import source as completion_source


def source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    declaration = "  MmStaAddReqPayload" + layout.split("  MmStaAddReqPayload", 1)[1].split("\n\n  ", 1)[0]
    declaration += "\n  ChanCtxtDefView" + layout.split("  ChanCtxtDefView", 1)[1].split("\n\n  ", 1)[0]
    declaration += "\n  ChanCtxtLease" + layout.split("  ChanCtxtLease", 1)[1].split("\n\n  ", 1)[0]
    code = completion_source()
    code = code.replace("type\n", "type\n" + declaration + "\n", 1)
    code = code.replace("  Vif = object", """  Ap = object
    securityFlags: uint32
  Keys = object
    flags: uint32
  Ht = object
    ampduParams: uint8
  BssStatus = object
    phyBandwidth: uint8
  Vif = object""", 1)
    code = code.replace("    macAddr: array[6, uint8]", """    macAddr, bssid: array[6, uint8]
    operChan: pointer
    channelFreqPair: uint32
    ap: Ap
    keys: Keys
    ht: Ht
    bss: BssStatus""", 1)
    code = code.replace("    channelDuration: uint32", "    channelDuration: uint32\n    chanType: uint8", 1)
    code = code.replace("joinBssFlag, cancelRequested: uint8]",
                        "connectFlags, joinBssFlag, cancelRequested, connectModeFlags: uint8]", 1)
    code = code.replace("cast[pointer](addr indication), 7'u8, 0'u8)",
                        "cast[pointer](addr indication), 0'u8, 7'u8, 0'u8, 0'u8)", 1)
    code = code.replace("  else:\n    doAssert id in [SCANU_START_CFM, SCANU_JOIN_CFM]", """  elif id == 10:
    doAssert dst == 0 and src == TASK_SM and size == sizeof(MmStaAddReqPayload).uint32
  else:
    doAssert id in [SCANU_START_CFM, SCANU_JOIN_CFM]""", 1)
    code += r'''
const
  TASK_MM = 0'u8
  MM_STA_ADD_REQ = 10'u16
  MmStaAddReqPayloadSize = sizeof(MmStaAddReqPayload).uint32
  SmAddingChanState = 3'u16
  MAX_CHAN_CTXT = 3
var
  links, contextAdds: int
  contextStatus, contextIndex: uint8
  onContext, onLink, onFailure: proc()
  nimFwDbgPreauthStaReq, nimFwDbgPreauthStaReqMeta: uint32
  nimFwDbgPreauthStaReqBssid0, nimFwDbgPreauthStaReqBssid1: uint32
  nimFwDbgSmChanCtxReq0, nimFwDbgSmChanCtxReq1: uint32
  nimFwDbgSmChanCtxPtrs, nimFwDbgSmChanCtxResult: uint32
  lastChannel: ChanCtxtDefView
proc vifApConfig(v: ptr Vif): ptr Ap = addr v.ap
proc vifKeyPointers(v: ptr Vif): ptr Keys = addr v.keys
proc vifHtCapabilities(v: ptr Vif): ptr Ht = addr v.ht
proc vifBssStatus(v: ptr Vif): ptr BssStatus = addr v.bss
proc connectInfoChannelContext(p: pointer): ptr ConnectInfoView = connectInfoView(p)
proc vifChannelCenterFreq2(v: ptr Vif): uint16 = (v.channelFreqPair shr 16).uint16
proc vifChannelCenterFreq1(v: ptr Vif; fallback: uint16): uint16 =
  let value = (v.channelFreqPair and 0xFFFF).uint16
  if value == 0: fallback else: value
proc pointerAddrU32(p: pointer): uint32 = cast[uint](p).uint32
proc chan_ctxt_add(request: pointer; output: ptr uint8): uint8 =
  inc contextAdds
  lastChannel = cast[ptr ChanCtxtDefView](request)[]
  output[] = contextIndex
  invoke(onContext)
  contextStatus
proc chan_ctxt_link(vif, index: uint8) =
  doAssert index == 1 and vif == conn.vifIdx
  inc links
  invoke(onLink)
proc chanLeaseCurrent(lease: ChanCtxtLease): bool = lease.held
proc chanLeaseAcquire(request: pointer; lease: var ChanCtxtLease): uint8 =
  var index = 255'u8
  result = chan_ctxt_add(request, addr index)
  if result == 0 and index < MAX_CHAN_CTXT.uint8:
    lease = ChanCtxtLease(index: index, held: true, created: true)
  else: result = 1
proc chanLeaseLink(lease: var ChanCtxtLease; vifIndex: uint8): bool =
  chan_ctxt_link(vifIndex, lease.index)
  lease.linked = true
  lease.vif = vifIndex
  true
proc chanLeaseRelease(lease: var ChanCtxtLease) = lease = default(ChanCtxtLease)
'''
    code = code.replace(
        "proc sm_connect_ind(status, reason: uint16) = failures.add((status, reason))",
        "proc sm_connect_ind(status, reason: uint16) =\n"
        "  failures.add((status, reason))\n  invoke(onFailure)", 1)
    code = "var onFailure: proc()\n" + code.replace("  onContext, onLink, onFailure: proc()",
                                                    "  onContext, onLink: proc()", 1)
    if re.search(r"^proc mmStaFillAggregation\*?\(", layout, re.M):
        code += procedure(layout, "mmStaFillAggregation")
    scan = (FW / "scan_station_ap_me.nim").read_text()
    for name in ["smPrepareChannelContext", "smAddPreparedChannelContext", "sm_add_chan_ctx"]:
        code += procedure(scan, name)
    code += procedure((FW / "task_handlers.nim").read_text(), "scanu_join_cfm_handler")
    return code


def submission_source() -> str:
    return source() + r'''
proc ready(incoming = true): pointer =
  begin(true)
  result = complete(take())
  let vif = addr vifs[conn.vifIdx]
  vif.ap.securityFlags = 0x80000002'u32
  vif.ht.ampduParams = 19
  vif.bssid = target
  vif.operChan = addr channel
  vif.keys.flags = 0xAABBCCDD'u32
  links = 0
  contextAdds = 0
  contextStatus = 0
  contextIndex = 1
  onContext = nil
  onLink = nil
  onFailure = nil
  enabled = incoming
proc finishJoin(reply: pointer) =
  release(reply)
  while queued.len != 0: release(take())
  finish()
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_join_registration_aggregation(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for ampdu in 0'u16 .. 255'u16:
  for aggregate in [false, true]:
    begin(true)
    let vif = addr vifs[conn.vifIdx]
    vif.ap.securityFlags = 0x80000000'u32 or (if aggregate: 2'u32 else: 0'u32)
    vif.ht.ampduParams = ampdu.uint8
    vif.bssid = target
    vif.operChan = addr channel
    links = 0
    contextIndex = 1
    let reply = complete(take())
    doAssert scanu_join_cfm_handler(reply) == 0
    release(reply)
    doAssert queued.len == 1 and state == SmAddingChanState and links == 1
    let request = take()
    let header = keMsgHdrFromPayload(request)
    doAssert header.id == MM_STA_ADD_REQ and header.destId == TASK_MM
    doAssert header.srcId == TASK_SM and header.paramLen == 28
    let translated = cast[ptr MmStaAddReqPayload](request)
    let exponent = ampdu and 3
    let spacing = (ampdu shr 2) and 7
    let expectedMask = if aggregate: ((1'u32 shl (exponent + 13)) - 1).uint16 else: 0'u16
    let expectedSpacing = if not aggregate: 0'u8
      elif spacing < 3: 1'u8 else: (1'u16 shl (spacing - 3)).uint8
    doAssert translated.rateMask == expectedMask
    doAssert translated.bw == expectedSpacing,
      "spacing mismatch for A-MPDU byte " & $ampdu
    doAssert translated.bssid == target and translated.vifIdx == conn.vifIdx
    doAssert translated.compatWord0 == 0 and translated.quickConn == 0
    doAssert translated.rssi == 0 and translated.tsfLow == 0 and translated.tsfHigh == 0
    doAssert translated.dataRate == 0 and translated.quickConnTailPadding == 0
    release(request)
    finish()
''')


SUBMISSION_CASES = {
    "synchronous_completion": r'''
let reply = ready()
onSend = proc() =
  doAssert state == SmAddingChanState
  state = 4
  vifs[conn.vifIdx].keys.flags = 0xDEADBEEF'u32
  vifs[conn.vifIdx].ap.securityFlags = 0x1234
doAssert scanu_join_cfm_handler(reply) == 0
doAssert state == 4 and vifs[conn.vifIdx].keys.flags == 0xDEADBEEF'u32
doAssert vifs[conn.vifIdx].ap.securityFlags == 0x1234
finishJoin(reply)
''',
    "allocation_failure": r'''
let reply = ready()
failAlloc = true
doAssert scanu_join_cfm_handler(reply) == 0
doAssert queued.len == 0 and state == SmWaitingState
doAssert contextAdds == 0 and links == 0
doAssert failures == @[(14'u16, 0xFFFF'u16)]
finishJoin(reply)
''',
    "invalid_context_index": r'''
for index in [3'u8, 255'u8]:
  let reply = ready()
  contextIndex = index
  doAssert scanu_join_cfm_handler(reply) == 0
  doAssert queued.len == 0 and state == SmWaitingState and links == 0
  doAssert failures == @[(13'u16, 0xFFFF'u16)]
  finishJoin(reply)
''',
    "snapshot_before_allocation": r'''
let reply = ready()
sm.connectFlags = 1
conn.channelDuration = 0x80000204'u32  # live VIF flags, not the latched quick bit
let expectedFlags = conn.channelDuration
let expectedChannel = channel
onAlloc = proc() =
  sm.connectFlags = 0
  conn.channelDuration = 0
  vifs[conn.vifIdx].bssid = default(typeof(target))
  vifs[conn.vifIdx].ht.ampduParams = 0
  vifs[conn.vifIdx].ap.securityFlags = 0
  channel.prim20Freq = 5180
  channel.band = 1
doAssert scanu_join_cfm_handler(reply) == 0
doAssert queued.len == 1
let request = cast[ptr MmStaAddReqPayload](queued[0])
doAssert request.bssid == target and request.rateMask == 65535
doAssert request.bw == 2 and request.quickConn == 1
doAssert vifs[conn.vifIdx].keys.flags == expectedFlags
doAssert lastChannel.primFreq == expectedChannel.prim20Freq and lastChannel.band == expectedChannel.band
finishJoin(reply)
''',
    "missing_channel": r'''
let reply = ready()
vifs[conn.vifIdx].operChan = nil
doAssert scanu_join_cfm_handler(reply) == 0
doAssert queued.len == 0 and contextAdds == 0 and links == 0
doAssert failures == @[(13'u16, 0xFFFF'u16)]
finishJoin(reply)
''',
    "context_failure_callback": r'''
let reply = ready()
contextStatus = 1
onFailure = proc() =
  replaceOwner()
  vifs[conn.vifIdx].keys.flags = 0x76543210
doAssert scanu_join_cfm_handler(reply) == 0
doAssert failures == @[(13'u16, 0xFFFF'u16)]
doAssert queued.len == 0 and state == 6 and links == 0
doAssert vifs[conn.vifIdx].keys.flags == 0x76543210
finishJoin(reply)
''',
    "interrupt_state": r'''
for incoming in [false, true]:
  let reply = ready(incoming)
  doAssert scanu_join_cfm_handler(reply) == 0
  doAssert enabled == incoming and state == SmAddingChanState
  finishJoin(reply)
''',
    "cancelled_join": r'''
let reply = ready()
sm.cancelRequested = 1
doAssert scanu_join_cfm_handler(reply) == 0
doAssert sm.cancelRequested == 0 and failures == @[(25'u16, 0xFFFF'u16)]
doAssert queued.len == 0 and contextAdds == 0
finishJoin(reply)
''',
    "not_ready_failures": r'''
for flags in [0'u8, 1'u8, 2'u8, 3'u8]:
  let reply = ready()
  vifs[conn.vifIdx].ap.securityFlags = 0
  sm.joinBssFlag = 0
  sm.connectModeFlags = flags
  doAssert scanu_join_cfm_handler(reply) == 0
  let expected = if (flags and 1) != 0: 17'u16
    elif (flags and 2) != 0: 18'u16 else: 14'u16
  doAssert failures == @[(expected, 0xFFFF'u16)]
  doAssert queued.len == 0 and contextAdds == 0
  finishJoin(reply)
''',
    "not_ready_retry": r'''
let reply = ready()
vifs[conn.vifIdx].ap.securityFlags = 0
vifs[conn.vifIdx].operChan = addr channel
sm.joinBssFlag = 1
doAssert scanu_join_cfm_handler(reply) == 0
doAssert queued.len == 1 and state == SmWaitingState
doAssert keMsgHdrFromPayload(queued[0]).id == SCANU_JOIN_REQ
doAssert failures.len == 0 and contextAdds == 0
finishJoin(reply)
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", SUBMISSION_CASES)
def test_join_submission(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, submission_source() + SUBMISSION_CASES[case])


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_channel_definition_uses_vif_width(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, submission_source() + r'''
let reply = ready()
channel.band = 1
channel.prim20Freq = 5180
channel.txPower = -3
conn.chanType = 7
vifs[conn.vifIdx].bss.phyBandwidth = 2
vifs[conn.vifIdx].channelFreqPair = 5210'u32 or (5290'u32 shl 16)
var prepared: ChanCtxtDefView
doAssert smPrepareChannelContext(addr conn, prepared)
doAssert prepared.chanType == 2
doAssert prepared.band == 1 and prepared.primFreq == 5180
doAssert prepared.centerFreq1 == 5210 and prepared.centerFreq2 == 5290
doAssert prepared.txPower == 253 and prepared.phyEnvFlags == 0
channel.band = 0
vifs[conn.vifIdx].bss.phyBandwidth = 1
doAssert smPrepareChannelContext(addr conn, prepared) and prepared.chanType == 1
channel.prim20Freq = 0
vifs[conn.vifIdx].channelFreqPair = 2437
doAssert smPrepareChannelContext(addr conn, prepared)
doAssert prepared.primFreq == 0 and prepared.centerFreq1 == 2437
doAssert prepared.centerFreq2 == 0
vifs[conn.vifIdx].operChan = nil
doAssert not smPrepareChannelContext(addr conn, prepared)
doAssert not smPrepareChannelContext(nil, prepared)
vifs[conn.vifIdx].operChan = addr channel
var index: uint8
doAssert sm_add_chan_ctx(addr index) == 0 and index == 1
doAssert lastChannel.primFreq == 0
doAssert sm_add_chan_ctx(nil) != 0
finishJoin(reply)
''')
