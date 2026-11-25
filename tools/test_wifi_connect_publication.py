"""Exercise connect preparation and callback ownership with real message storage."""

from pathlib import Path

import pytest

from test_wifi_connect_admission import transaction_source
from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    code = transaction_source()
    prefix = r'''
var connectHook: proc(point: string)
var replacement, replacementIndication: pointer
var useSelected, directHint: bool
proc connectBoundary(point: string) =
  if point notin ["retire", "select"]: doAssert interruptsEnabled
  if connectHook != nil: connectHook(point)
'''
    code = code.replace("proc sm_connection_tlv_set", prefix + "proc sm_connection_tlv_set", 1)
    code = code.replace(procedure(code, "ke_msg_alloc"), r'''
proc connectBoundary(point: string)
proc ke_msg_alloc(id: uint16; dst, src: uint8; n: uint32): pointer =
  inc kernelAllocations
  if kernelAllocations == failAt: return nil
  result = newMessage(id, dst, src, n)
  if id == SM_CONNECT_CFM: connectBoundary("allocate_cfm")
  elif id == SM_CONNECT_IND_MSG: connectBoundary("allocate_ind")
''', 1)
    code = code.replace(procedure(code, "txl_retire_vif"), r'''
proc txl_retire_vif(vif: uint8; selected: uint8) = connectBoundary("retire")
''', 1)
    code = code.replace(procedure(code, "sm_connection_tlv_set"), r'''
proc sm_connection_tlv_set() = connectBoundary("tlv")
''', 1)
    code = code.replace(procedure(code, "connectInfoHasChannelHint"), r'''
proc connectInfoHasChannelHint(req: ptr ConnectInfoView): bool = directHint
''', 1)
    support = r'''
var sourceBssid, handedMac, handedBssid: array[6, uint8]
var sourceChannel, handedChannel: ScanChannelEntry
var handedBssidPresent, handedChannelPresent: bool
proc handoff(mac, bssid, channel: pointer) =
  handedMac = cast[ptr array[6, uint8]](mac)[]
  handedBssidPresent = bssid != nil
  handedChannelPresent = channel != nil
  if bssid != nil: handedBssid = cast[ptr array[6, uint8]](bssid)[]
  if channel != nil: handedChannel = cast[ptr ScanChannelEntry](channel)[]
  connectBoundary("handoff")
proc replaceConnection() =
  let retired = sm.connectInfo
  let retiredIndication = sm.connectIndMsg
  sm.connectInfo = nil
  sm.connectIndMsg = nil
  if retired != nil: ke_msg_free(keMsgHdrFromPayload(retired))
  if retiredIndication != nil: ke_msg_free(keMsgHdrFromPayload(retiredIndication))
  inc rxVifEpochs[0]
  replacement = newMessage(SM_CONNECT_REQ, TASK_SM, TASK_API, 192)
  connectInfoView(replacement)[] = ConnectInfoView(vifIdx: 0)
  replacementIndication = newMessage(SM_CONNECT_IND_MSG, TASK_API, TASK_SM, 860)
  sm.connectInfo = replacement
  sm.connectIndMsg = replacementIndication
'''
    code = code.replace("proc sm_connection_tlv_set", support + "proc sm_connection_tlv_set", 1)
    code = code.replace(procedure(code, "connectInfoChannelHint"), r'''
proc connectInfoChannelHint(p: pointer): pointer = addr sourceChannel
''', 1)
    code = code.replace(procedure(code, "sm_get_bss_params"), r'''
proc sm_get_bss_params(bss, channel: ptr pointer) =
  if useSelected:
    bss[] = addr sourceBssid[0]
    channel[] = addr sourceChannel
  connectBoundary("select")
''', 1)
    code = code.replace(procedure(code, "scanu_prune_scanresult_raw_frames_except_bssid"), r'''
proc scanu_prune_scanresult_raw_frames_except_bssid(p: pointer) = connectBoundary("prune")
''', 1)
    code = code.replace(procedure(code, "scanu_prune_scanresult_raw_frames"), r'''
proc scanu_prune_scanresult_raw_frames() = connectBoundary("prune")
''', 1)
    code = code.replace(procedure(code, "sm_join_bss"), r'''
proc sm_join_bss(mac, bss, channel: pointer; flags: bool) =
  inc reconnectJoins
  handoff(mac, bss, channel)
''', 1)
    code = code.replace(procedure(code, "sm_scan_bss"), r'''
proc sm_scan_bss(mac, bss, channel: pointer) =
  inc reconnectScans
  handoff(mac, bss, channel)
''', 1)
    code = code.replace("    reconnectConfirmations.add(cast[ptr StatusCfmPayload](p).status)\n",
                        "    reconnectConfirmations.add(cast[ptr StatusCfmPayload](p).status)\n"
                        '    connectBoundary("confirm")\n', 1)
    return code


SETUP = r'''
ke_msg_free(keMsgHdrFromPayload(sm.connectInfo))
sm.connectInfo = nil
sm.connectIndMsg = nil
smState = 0
vifs[0].state = 0
vifs[0].staIdx = 255
vifs[0].chanCtxt = nil
request = newMessage(SM_CONNECT_REQ, TASK_SM, TASK_API, 192)
connectInfoView(request)[] = ConnectInfoView(vifIdx: 0,
  bssid: [2'u8, 3, 4, 5, 6, 7])
sourceBssid = [2'u8, 10, 20, 30, 40, 50]
sourceChannel = ScanChannelEntry(prim20Freq: 2437, band: 0, txPower: 17)
vifs[0].macAddr = [4'u8, 1, 2, 3, 4, 5]
'''

CASES = {
    "selection_snapshot_guard": r'''
useSelected = true
connectHook = proc(point: string) =
  if point == "select": doAssert not interruptsEnabled
doAssert sm_connect_req_handler(request) == KeMsgNoFree
doAssert reconnectJoins == 1 and interruptsEnabled
''',
    "confirmation_replaces_connection": r'''
indicationHook = proc() =
  replaceConnection()
doAssert sm_connect_req_handler(request) == KeMsgNoFree
doAssert sm.connectInfo == replacement and sm.connectIndMsg == replacementIndication
doAssert reconnectScans == 0 and reconnectJoins == 0
''',
    "handoff_replaces_connection": r'''
connectHook = proc(point: string) =
  if point == "handoff":
    connectHook = nil
    replaceConnection()
doAssert sm_connect_req_handler(request) == KeMsgNoFree
doAssert sm.connectInfo == replacement and sm.connectIndMsg == replacementIndication
doAssert reconnectScans == 1 and reconnectConfirmations == @[0'u8]
''',
}

for point in ["allocate_cfm", "allocate_ind", "retire", "tlv", "select", "prune"]:
    transferred = point in ["tlv", "select", "prune"]
    CASES[f"replace_at_{point}"] = f'''
connectHook = proc(point: string) =
  if point == "{point}":
    connectHook = nil
    replaceConnection()
let original = request
doAssert sm_connect_req_handler(original) == {'KeMsgNoFree' if transferred else 'KeMsgConsumed'}
doAssert sm.connectInfo == replacement and sm.connectIndMsg == replacementIndication
doAssert reconnectScans == 0 and reconnectJoins == 0
doAssert reconnectConfirmations == @[8'u8]
doAssert requestFreed == {str(transferred).lower()}
'''

for fail in [1, 2]:
    expected_confirmations = "newSeq[uint8]()" if fail == 1 else "@[8'u8]"
    CASES[f"allocation_failure_{fail}"] = f'''
let before = rxVifEpochs
failAt = kernelAllocations + {fail}
doAssert sm_connect_req_handler(request) == KeMsgConsumed
doAssert sm.connectInfo == nil and sm.connectIndMsg == nil
doAssert reconnectScans == 0 and reconnectJoins == 0
doAssert reconnectConfirmations == {expected_confirmations}
doAssert allocated == @[request] and rxVifEpochs == before
'''

for point in ["prune", "confirm"]:
    CASES[f"snapshot_at_{point}"] = f'''
useSelected = true
let expectedBssid = sourceBssid
let expectedChannel = sourceChannel
let expectedMac = vifs[0].macAddr
connectHook = proc(point: string) =
  if point == "{point}":
    sourceBssid = [6'u8, 1, 1, 1, 1, 1]
    sourceChannel.prim20Freq = 2462
    vifs[0].macAddr = [8'u8, 2, 2, 2, 2, 2]
doAssert sm_connect_req_handler(request) == KeMsgNoFree
doAssert handedBssidPresent and handedChannelPresent
doAssert handedBssid == expectedBssid and handedChannel == expectedChannel
doAssert handedMac == expectedMac and reconnectJoins == 1
'''

CASES["direct_hint_snapshot"] = r'''
directHint = true
expectedFreq = sourceChannel.prim20Freq
let expectedBssid = connectInfoView(request).bssid
let expectedChannel = sourceChannel
connectHook = proc(point: string) =
  if point == "prune":
    connectInfoView(request).bssid = [8'u8, 1, 2, 3, 4, 5]
    sourceChannel.prim20Freq = 2462
doAssert sm_connect_req_handler(request) == KeMsgNoFree
doAssert reconnectJoins == 1 and reconnectScans == 0
doAssert handedBssid == expectedBssid and handedChannel == expectedChannel
'''


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_connect_publication(tmp_path: Path, case: str, mode: str) -> None:
    finish = r'''
indicationHook = nil
connectHook = nil
while allocated.len != 0:
  ke_msg_free(keMsgHdrFromPayload(allocated[^1]))
'''
    run_program(tmp_path, mode, source() + SETUP + CASES[case] + finish)
