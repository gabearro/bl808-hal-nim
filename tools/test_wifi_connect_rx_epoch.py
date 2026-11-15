"""Check the RX generation boundary in the real connect request handler."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
const
  MAX_VIFS = 2
  TASK_SM = 4'u8
  TASK_API = 9'u8
  SmIdleState = 0'u16
  SM_CONNECT_CFM = 0x1001'u16
  SM_CONNECT_IND_MSG = 0x1002'u16
  KeMsgConsumed = 0.cint
  KeMsgNoFree = 1.cint
  KeMsgSaved = 2.cint
type
  ConnectInfoView = object
    vifIdx, authType: uint8
    channelDuration: uint32
    bssid: array[6, uint8]
  ScanChannelEntry = object
    prim20Freq: uint16
    band, flags: uint8
    txPower: int8
    txPowerTailPadding: uint8
  Vif = object
    vifType, state, staIdx: uint8
    chanCtxt: pointer
    macAddr: array[6, uint8]
  SmEnv = object
    connectInfo, connectIndMsg: pointer
    connectFlags, connectModeFlags, cancelRequested: uint8
    scanResultIndex: uint32
    vendorIeLen: uint16
  StatusCfmPayload = object
    status: uint8
const StatusCfmPayloadSize = sizeof(StatusCfmPayload).uint32
var
  rxVifEpochs: array[MAX_VIFS, uint32]
  sm: SmEnv
  vifs: array[MAX_VIFS, Vif]
  request: ConnectInfoView
  storage: array[2, array[860, uint8]]
  currentState: uint16
  allocations, confirmations, joins, scans, cleanups: int
  confirmationStatus: uint8
  failAlloc, directJoin: bool
  retired: bool
  hint: ScanChannelEntry
  released: seq[pointer]
  nimFwWpaPendingMask: uint32
  interrupts = true
  onBoundary: proc()
proc irqSave(): uint32 =
  result = interrupts.uint32 * 8
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = (saved and 8) != 0
proc txlHaltVifQueues(vif: uint8; selected: var uint8): bool = true
proc txl_retire_vif(vif: uint8; selected: uint8) = retired = true
proc connectInfoView(p: pointer): ptr ConnectInfoView = cast[ptr ConnectInfoView](p)
proc vifChannelForIdx(i: uint8): ptr Vif =
  doAssert i < MAX_VIFS, "invalid VIF indexed before validation"
  addr vifs[i]
proc smEnvView(): ptr SmEnv = addr sm
proc ke_state_get(task: uint8): uint16 = currentState
proc boundary(allowDisabled = false) =
  doAssert interrupts or allowDisabled
  if onBoundary != nil: onBoundary()
proc chan_ctxt_unlink(vif: uint8) =
  boundary()
  inc cleanups
proc assert_err(a, b: cstring; line: int) = doAssert false
proc sm_connection_tlv_set(vif: uint8; param: pointer; length: uint16) =
  doAssert sm.connectModeFlags == 0 and sm.cancelRequested == 0
  boundary()
proc connectInfoHasChannelHint(req: ptr ConnectInfoView): bool = directJoin
proc connectInfoChannelHint(p: pointer): pointer = addr hint
proc sm_get_bss_params(bss, channel: ptr pointer): bool =
  boundary(true)
  bss[] = nil
  channel[] = nil
  false
proc scanu_prune_scanresult_raw_frames_except_bssid(bssid: pointer) = boundary()
proc scanu_prune_scanresult_raw_frames() = boundary()
proc ke_msg_alloc(id: uint16; dst, src: uint8; length: uint32): pointer =
  boundary()
  doAssert dst == TASK_API and src == TASK_SM
  doAssert allocations < storage.len
  doAssert length == (if id == SM_CONNECT_CFM: 1'u32 else: 860'u32)
  result = addr storage[allocations][0]
  inc allocations
  if failAlloc: result = nil
proc ke_msg_send(p: pointer) =
  boundary()
  doAssert p == addr storage[0][0]
  confirmationStatus = cast[ptr StatusCfmPayload](p).status
  inc confirmations
proc keMsgHdrFromPayload(p: pointer): pointer = p
proc ke_msg_free(p: pointer) =
  doAssert p != nil and p notin released
  released.add(p)
proc c_memset(p: pointer; value: cint; length: csize_t): pointer =
  doAssert value == 0 and length == 64
  zeroMem(p, length.int)
  p
proc sm_join_bss(mac, bss, channel: pointer; flag: uint32) =
  boundary()
  doAssert cast[ptr array[6, uint8]](mac)[] == vifs[request.vifIdx].macAddr
  inc joins
proc sm_scan_bss(mac, bss, channel: pointer) =
  boundary()
  doAssert cast[ptr array[6, uint8]](mac)[] == vifs[request.vifIdx].macAddr
  inc scans
proc reset(vif: uint8 = 0) =
  request = ConnectInfoView(vifIdx: vif, channelDuration: 0x1234,
                            bssid: [2'u8, 3, 4, 5, 6, 7])
  sm = SmEnv(vendorIeLen: 0x1234, connectModeFlags: 0xA5, cancelRequested: 1)
  vifs = default(typeof(vifs))
  for v in vifs.mitems: v.staIdx = 255
  storage = default(typeof(storage))
  currentState = 0
  allocations = 0
  confirmations = 0
  confirmationStatus = 255
  joins = 0
  scans = 0
  cleanups = 0
  failAlloc = false
  directJoin = false
  retired = false
  hint = ScanChannelEntry(prim20Freq: 2437)
  released.setLen(0)
  onBoundary = nil
  interrupts = true
"""

CHECKS = r"""
for vif in 0'u8 .. 1:
  for direct in [false, true]:
    for staleStation in [false, true]:
      for allocationFailure in [false, true]:
        reset(vif)
        directJoin = direct
        failAlloc = allocationFailure
        if staleStation:
          vifs[vif].staIdx = 3
          vifs[vif].chanCtxt = cast[pointer](1)
        let before = rxVifEpochs
        if staleStation:
          doAssert sm_connect_req_handler(addr request) == KeMsgSaved
          doAssert currentState == 10 and cleanups == 1
          doAssert rxVifEpochs == before and sm.connectInfo == nil
          doAssert allocations == 0
          vifs[vif].staIdx = 255
          vifs[vif].chanCtxt = nil
          currentState = 0
        onBoundary = proc() =
          doAssert rxVifEpochs[vif] == before[vif] + retired.uint32,
            "RX epoch changed during private preparation or was not advanced before publication"
          doAssert rxVifEpochs[vif xor 1] == before[vif xor 1]
        if allocationFailure:
          doAssert sm_connect_req_handler(addr request) == KeMsgConsumed
          doAssert rxVifEpochs == before and not retired
          doAssert sm.connectInfo == nil and sm.connectIndMsg == nil
          doAssert allocations == 1 and confirmations == 0 and scans == 0 and joins == 0
          continue
        doAssert sm_connect_req_handler(addr request) == KeMsgNoFree
        doAssert rxVifEpochs[vif] == before[vif] + 1
        doAssert sm.connectInfo == addr request
        doAssert sm.connectFlags == 0x34 and sm.scanResultIndex == high(uint32)
        doAssert allocations == 2
        doAssert confirmations == (not allocationFailure).int
        if not allocationFailure: doAssert confirmationStatus == 0
        doAssert joins == direct.int and scans == (not direct).int
        doAssert cleanups == staleStation.int and interrupts

for vif in [0'u8, 1, 2, 7, 255]:
  for state in [0'u16, 1, 6, 8, 9, 10]:
    if vif < MAX_VIFS and state == 0: continue
    reset(vif)
    currentState = state
    let before = rxVifEpochs
    let outcome = sm_connect_req_handler(addr request)
    doAssert rxVifEpochs == before
    doAssert sm.connectModeFlags == 0xA5 and sm.cancelRequested == 1
    doAssert sm.connectInfo == nil and scans == 0 and joins == 0 and cleanups == 0
    if state == 10:
      doAssert outcome == KeMsgSaved and allocations == 0
    else:
      doAssert outcome == KeMsgConsumed and allocations == 1 and confirmations == 1
      doAssert confirmationStatus == (if state == 0: 9'u8 else: 8'u8)

reset()
vifs[0].vifType = 2
vifs[0].state = 1
let beforeRejectedType = rxVifEpochs
doAssert sm_connect_req_handler(addr request) == KeMsgConsumed
doAssert confirmationStatus == 9 and rxVifEpochs == beforeRejectedType
let beforeNil = rxVifEpochs
doAssert sm_connect_req_handler(nil) == KeMsgConsumed
doAssert rxVifEpochs == beforeNil

# A new cancellation raised by a publication hook must not be cleared later.
reset()
onBoundary = proc() = sm.cancelRequested = 1
doAssert sm_connect_req_handler(addr request) == KeMsgNoFree
doAssert sm.cancelRequested == 1 and sm.connectModeFlags == 0
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_connect_rx_epoch(tmp_path: Path, mode: str) -> None:
    tasks = (FW / "task_handlers.nim").read_text()
    source = PLATFORM + r'''
proc smCleanupBegin(p: pointer): bool =
  doAssert sm.connectInfo == nil and sm.connectIndMsg == nil
  inc cleanups
  currentState = 10
  true
'''
    source += procedure((FW / "rx_layer.nim").read_text(), "rxInvalidateQuiescentVif")
    source += procedure((FW / "rx_layer.nim").read_text(), "rxInvalidateVif")
    source += procedure(tasks, "smConnectReqHasSpecificBssid")
    source += procedure(tasks, "sm_connect_req_handler")
    run_program(tmp_path, mode, source + CHECKS)
