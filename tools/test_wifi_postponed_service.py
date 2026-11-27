"""Exercise postponed-TX callers across station and VIF replacement."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
  VIF_TYPE_STA = 0'u8
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  Sta = object
    link: CoListHdr
    instNbr, valid: uint8
    postponedList: CoList
  Vif = object
    next: pointer
    vifType, state, staIdx: uint8
    postponedStaHead, postponedStaTail: pointer
  StaQueueIdentity = object
    entry: pointer
    stationEpoch, vifEpoch: uint32
    station, vif: uint8
    stationTracked, vifTracked: bool
var
  stas: array[STA_INFO_TAB_ENTRIES, Sta]
  vifs: array[MAX_VIFS, Vif]
  rxVifEpochs: array[MAX_VIFS, uint32]
  stationEpochs: array[STA_INFO_TAB_ENTRIES, uint32]
  txResetEpoch: uint32
  env: tuple[activeList: CoList]
  frameEnv: tuple[postponedCount: uint32]
  frames: array[STA_INFO_TAB_ENTRIES, CoListHdr]
  sent: seq[tuple[vif, station: int]]
  readyHook, sendHook: proc()
  readyCalls, reconcileCalls: int
  ready, resetting, interrupts: bool
  perSend: uint32
proc vifChannelForIdx(index: uint8): ptr Vif =
  doAssert index < MAX_VIFS.uint8
  addr vifs[index]
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc staInfoForIdx(index: uint8): ptr Sta =
  doAssert index < STA_INFO_TAB_ENTRIES.uint8, "station index was not checked"
  addr stas[index]
proc staInfoAt(p: pointer): ptr Sta = cast[ptr Sta](p)
proc txFrameEnv(): ptr typeof(frameEnv) = addr frameEnv
proc staDeleteEpoch(index: uint8): uint32 =
  if index < STA_INFO_TAB_ENTRIES.uint8: stationEpochs[index] else: 0
proc vifMgmtEnvView(): ptr typeof(env) = addr env
proc vifPostponedStaList(vif: ptr Vif): ptr CoList =
  cast[ptr CoList](addr vif.postponedStaHead)
proc irqSave(): uint32 =
  result = interrupts.uint32
  interrupts = false
proc irqRestore(value: uint32) = interrupts = value != 0
proc txlResetting(): bool = resetting
proc co_list_find(list: ptr CoList; node: ptr CoListHdr): bool =
  var cursor = list.first
  var count = 0
  while cursor != nil:
    if cursor == node: return true
    inc count
    doAssert count <= STA_INFO_TAB_ENTRIES
    cursor = cursor.next
proc co_list_extract(list: ptr CoList; node: ptr CoListHdr) =
  var previous: ptr CoListHdr
  var cursor = list.first
  while cursor != nil:
    if cursor == node:
      if previous == nil: list.first = cursor.next
      else: previous.next = cursor.next
      if list.last == cursor: list.last = previous
      cursor.next = nil
      return
    previous = cursor
    cursor = cursor.next
proc txl_cntrl_tx_check(vif: pointer): bool =
  inc readyCalls
  if readyHook != nil:
    let hook = readyHook
    readyHook = nil
    hook()
  ready
proc sta_mgmt_send_postponed_frame(vif, sta: pointer; limit: uint32): uint32 =
  var vi = -1
  var si = -1
  for i in 0 ..< MAX_VIFS:
    if vif == addr vifs[i]: vi = i
  for i in 0 ..< STA_INFO_TAB_ENTRIES:
    if sta == addr stas[i]: si = i
  doAssert vi >= 0 and si >= 0
  sent.add((vi, si))
  if sendHook != nil:
    let hook = sendHook
    sendHook = nil
    hook()
  if limit == 0: perSend else: min(limit, perSend)
proc wifi_nimfw_reconcile_postponed_count() =
  inc reconcileCalls
  frameEnv.postponedCount = 0
  for sta in stas:
    if sta.postponedList.first != nil: inc frameEnv.postponedCount
proc setup(enabled = true) =
  stas = default(typeof(stas))
  vifs = default(typeof(vifs))
  rxVifEpochs = [11'u32, 22]
  stationEpochs = [31'u32, 32, 33, 34, 35, 36, 37]
  txResetEpoch = 41
  for i in 0 ..< MAX_VIFS:
    vifs[i].state = 1
    vifs[i].staIdx = i.uint8
    stas[i].valid = 1
    stas[i].instNbr = i.uint8
  for i in 0 ..< stas.len:
    stas[i].postponedList.first = addr frames[i]
  frameEnv.postponedCount = stas.len.uint32
  env = default(typeof(env))
  sent.setLen(0)
  readyHook = nil
  sendHook = nil
  readyCalls = 0
  reconcileCalls = 0
  ready = true
  resetting = false
  interrupts = enabled
  perSend = 1
proc stationList(indices: openArray[int]) =
  vifs[0].postponedStaHead = nil
  vifs[0].postponedStaTail = nil
  for index in indices:
    stas[index].instNbr = 0
    stas[index].valid = 1
    stas[index].link.next = nil
    if vifs[0].postponedStaTail == nil:
      vifs[0].postponedStaHead = addr stas[index]
    else:
      cast[ptr CoListHdr](vifs[0].postponedStaTail).next = addr stas[index].link
    vifs[0].postponedStaTail = addr stas[index]
proc activeVifs() =
  env.activeList = CoList(first: cast[ptr CoListHdr](addr vifs[0]),
                          last: cast[ptr CoListHdr](addr vifs[1]))
  vifs[0].next = addr vifs[1]
  vifs[1].next = nil
'''


CASES = {
    "scheduler_wakes": r'''
setup()
for sta in stas.mitems: sta.postponedList = default(CoList)
frameEnv.postponedCount = 0
now = high(uint32) - 100
wifi_nimfw_service_tx(1)
doAssert reconcileCalls == 1 and readyCalls == 0
now += 200
wifi_nimfw_service_tx(1)
doAssert reconcileCalls == 1 and readyCalls == 0
doAssert triggers == 2 and confirmations == 2

stas[0].postponedList.first = addr frames[0]
frameEnv.postponedCount = 1
ready = false
requestPostponedTx()
requestPostponedTx()
doAssert notifications == 1 and interrupts
wifi_nimfw_service_tx(1)
doAssert readyCalls == 1 and sent.len == 0 and reconcileCalls == 1
wifi_nimfw_service_tx(1)
doAssert readyCalls == 1, "blocked work kept polling"

ready = true
postponedTxChannelReady()
resetting = true
wifi_nimfw_service_tx(1)
doAssert readyCalls == 1 and sent.len == 0
resetting = false
sendHook = proc() =
  stas[0].postponedList.first = nil
  frameEnv.postponedCount = 0
wifi_nimfw_service_tx(1)
doAssert sent == @[(0, 0)] and notifications == 2

stas[1].postponedList.first = addr frames[1]
# No request was posted and the software count is stale.
now += PostponedTxReconcileUs
sendHook = proc() =
  stas[1].postponedList.first = nil
  frameEnv.postponedCount = 0
wifi_nimfw_service_tx(1)
doAssert reconcileCalls == 2 and sent == @[(0, 0), (1, 1)]

stas[0].postponedList.first = addr frames[0]
frameEnv.postponedCount = 2
requestPostponedTx()
sendHook = proc() = dec frameEnv.postponedCount
wifi_nimfw_service_tx(1)
doAssert notifications == 4, "a full TX budget lost the next wake"
sendHook = proc() =
  stas[0].postponedList.first = nil
  frameEnv.postponedCount = 0
wifi_nimfw_service_tx(1)
doAssert notifications == 4 and sent == @[(0, 0), (1, 1), (0, 0), (0, 0)]
''',
    "service_admission": r'''
for enabled in [false, true]:
  for index in 0 .. 255:
    setup(enabled)
    vifs[1].state = 0
    vifs[0].staIdx = index.uint8
    if index < STA_INFO_TAB_ENTRIES:
      stas[index].instNbr = 0
      stas[index].valid = 1
    let count = wifi_nimfw_service_sta_postponed(1)
    doAssert count == (index < STA_INFO_TAB_ENTRIES).uint32
    doAssert sent.len == count.int and interrupts == enabled
  for invalid in 0 .. 4:
    setup(enabled)
    vifs[1].state = 0
    case invalid
    of 0: stas[0].valid = 0
    of 1: stas[0].instNbr = 1
    of 2: vifs[0].state = 0
    of 3: vifs[0].vifType = 2
    else: resetting = true
    doAssert wifi_nimfw_service_sta_postponed(1) == 0
    doAssert sent.len == 0 and readyCalls == 0 and interrupts == enabled
  for limit in 0'u32 .. 4:
    setup(enabled)
    perSend = 2
    let expected = if limit == 0: 1'u32 else: limit
    doAssert wifi_nimfw_service_sta_postponed(limit) == expected
    doAssert sent.len == (if expected <= 2: 1 else: 2)
    doAssert interrupts == enabled
''',
    "service_readiness": r'''
for enabled in [false, true]:
  for change in 0 .. 9:
    setup(enabled)
    vifs[1].state = 0
    readyHook = proc() =
      case change
      of 0: inc stationEpochs[0]
      of 1: inc rxVifEpochs[0]
      of 2: inc txResetEpoch
      of 3: resetting = true
      of 4: vifs[0].staIdx = 2
      of 5: stas[0].valid = 0
      of 6: stas[0].instNbr = 1
      of 7: vifs[0].state = 0
      of 8: vifs[0].vifType = 2
      else: inc stationEpochs[3]
    let expected = (change == 9).uint32
    doAssert wifi_nimfw_service_sta_postponed(1) == expected
    doAssert sent.len == expected.int and interrupts == enabled
  setup(enabled)
  sendHook = proc() = inc rxVifEpochs[1]
  doAssert wifi_nimfw_service_sta_postponed(2) == 1
  doAssert sent == @[(0, 0)] and interrupts == enabled
''',
    "vif_station_walk": r'''
for enabled in [false, true]:
  for change in 0 .. 6:
    setup(enabled)
    stationList([0, 2, 3])
    sendHook = proc() =
      case change
      of 0: inc stationEpochs[2]
      of 1: inc rxVifEpochs[0]
      of 2: inc txResetEpoch
      of 3: co_list_extract(vifPostponedStaList(addr vifs[0]), addr stas[2].link)
      of 4:
        stas[4].instNbr = 0
        stas[3].link.next = addr stas[4].link
        vifs[0].postponedStaTail = addr stas[4]
      of 5: stas[2].instNbr = 1
      else: inc stationEpochs[4]
    vif_mgmt_send_postponed_frame(addr vifs[0])
    let expected = case change
      of 0, 3, 5: @[(0, 0), (0, 3)]
      of 1, 2: @[(0, 0)]
      else: @[(0, 0), (0, 2), (0, 3)]
    doAssert sent == expected, "VIF walk used replaced or newly appended work"
    doAssert interrupts == enabled
  setup(enabled)
  stationList([0, 2, 3])
  vif_mgmt_send_postponed_frame(addr vifs[0])
  doAssert sent == @[(0, 0), (0, 2), (0, 3)] and interrupts == enabled
''',
    "reset_vif_walk": r'''
for enabled in [false, true]:
  for change in 0 .. 3:
    setup(enabled)
    stationList([0])
    vifs[1].postponedStaHead = addr stas[1]
    vifs[1].postponedStaTail = addr stas[1]
    activeVifs()
    sendHook = proc() =
      case change
      of 0: inc rxVifEpochs[1]
      of 1: inc txResetEpoch
      of 2:
        co_list_extract(addr env.activeList, cast[ptr CoListHdr](addr vifs[1]))
      else: inc stationEpochs[4]
    vif_mgmt_reset()
    let expected = if change == 3: @[(0, 0), (1, 1)] else: @[(0, 0)]
    doAssert sent == expected, "reset walk drained a replacement VIF"
    doAssert interrupts == enabled
''',
    "walk_admission": r'''
for enabled in [false, true]:
  setup(enabled)
  vif_mgmt_send_postponed_frame(nil)
  doAssert sent.len == 0 and interrupts == enabled
  var foreignVif: Vif
  vif_mgmt_send_postponed_frame(addr foreignVif)
  doAssert sent.len == 0 and interrupts == enabled
  for invalid in 0 .. 2:
    setup(enabled)
    stationList([0, 2])
    case invalid
    of 0: vifs[0].postponedStaHead = cast[pointer](1)
    of 1: stas[2].link.next = addr stas[0].link
    else: stas[2].instNbr = 1
    vif_mgmt_send_postponed_frame(addr vifs[0])
    doAssert sent.len == 0 and interrupts == enabled
  for invalid in 0 .. 1:
    setup(enabled)
    stationList([0])
    activeVifs()
    if invalid == 0: env.activeList.first = cast[ptr CoListHdr](1)
    else: vifs[1].next = addr vifs[0]
    vif_mgmt_reset()
    doAssert sent.len == 0 and interrupts == enabled
  setup(enabled)
  stationList([0, 1, 2, 3, 4, 5, 6])
  vif_mgmt_send_postponed_frame(addr vifs[0])
  doAssert sent == @[(0, 0), (0, 1), (0, 2), (0, 3), (0, 4), (0, 5), (0, 6)]
  doAssert interrupts == enabled
''',
}


def source(scheduler: bool) -> str:
    sta = (FW / "sta_management.nim").read_text()
    tx = (FW / "tx_layer.nim").read_text()
    vif = (FW / "vif_management.nim").read_text()
    code = "".join(procedure(sta, name) for name in [
        "staPostponedOwner", "staPostponedOwnerCurrent",
    ])
    code += procedure(tx, "serviceStaPostponed")
    code += procedure(tx, "wifi_nimfw_service_sta_postponed")
    code += procedure(vif, "vif_mgmt_send_postponed_frame")
    code += procedure(vif, "vif_mgmt_reset")
    names = sorted(set(re.findall(r"\bnimFw\w+", code)))
    declarations = "var\n" + "".join(f"  {name}: uint32\n" for name in names)
    support = ""
    if scheduler:
        support = r'''
var now: uint32
var notifications, triggers, confirmations: int
const ClicMtimeBase = 0'u
proc bl808_wifi_backend_signal_work() = inc notifications
proc regRead(address: uint): uint32 = now
proc wifiStepEnter(): bool = true
proc wifiStepLeave() = discard
proc txl_transmit_trigger() = inc triggers
proc txl_frame_evt() = inc confirmations
'''
        support += (FW / "postponed_tx_work.nim").read_text()
        code += procedure((FW / "task_init_main.nim").read_text(), "wifi_nimfw_service_tx")
    return PLATFORM + declarations + support + code


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_postponed_service(tmp_path: Path, mode: str, case: str) -> None:
    scheduler = case == "scheduler_wakes"
    run_program(tmp_path, mode, source(scheduler) + CASES[case],
                defines=("bl808m0",) if scheduler else ())
