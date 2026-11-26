"""Exercise home-wake telemetry with the real Null builder and TX retirement."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure, ps_machine_source
from test_wifi_frame_preparation import PLATFORM as TX_PLATFORM
from test_wifi_message_allocation import run_program


PLATFORM = r"""
{.pragma: wifiCtrl.}
type
  MmTimerView = object
    callback: pointer
    env, expiry: uint32
  MmTimerDelivery = object
    cancelled: bool
var
  homeContext: uint32
  chanCtxtEpochs: array[3, uint32]
  chanEnv: tuple[currentCtxt, scheduledCtxt: pointer]
  psEnv: tuple[enabled: uint8, statusFlags: uint32]
  psOwn: tuple[pm: bool]
  pendingTimer: ptr MmTimerView
  txEnv: tuple[packetCounter: uint32]
  events: uint32
  rejectPreparation: bool
proc observe(point: string) =
  if point == "power" and rejectPreparation: stas[2].valid = 0
proc chanCtxtForIdx(index: uint8): pointer = addr homeContext
proc chanEnvView(): ptr typeof(chanEnv) = addr chanEnv
proc psEnvView(): ptr typeof(psEnv) = addr psEnv
proc macTimeNow(): uint32 =
  doAssert not interruptsEnabled
  macTime
proc mmTimerActiveDelivery(timer: pointer): ptr MmTimerDelivery = nil
proc mmTimerSetLocked(timer: ptr MmTimerView; expiry, saved: uint32) =
  doAssert not interruptsEnabled
  timer.expiry = expiry
  pendingTimer = timer
proc txControlEnv(): ptr typeof(txEnv) = addr txEnv
proc ke_evt_set(bits: uint32) = events = events or bits
proc ke_evt_clear(bits: uint32) = events = events and not bits
proc nimFwMgmtFcTrace(fc: uint8): bool = false
proc noteMgmtTxConfirm(d: ptr HostTxDescView; status, phase: uint32) = discard
proc fireTimer() =
  let timer = pendingTimer
  doAssert timer != nil
  pendingTimer = nil
  macTime = timer.expiry
  cast[proc(arg: pointer) {.cdecl.}](timer.callback)(cast[pointer](timer.env.uint))
"""

CHECKS = r'''
when defined(bl808WifiBenchConnectedScanAB):
  {.emit: """
  extern NU32 nimfw_dbg_home_wake_ab[7];
  static void *home_wake_ab_address(void) { return nimfw_dbg_home_wake_ab; }
  """.}
  proc abAddress(): pointer {.importc: "home_wake_ab_address", nodecl.}
  doAssert abAddress() == addr nimFwDbgHomeWakeAb[0]
else:
  static: doAssert not declared(nimFwDbgHomeWakeAb)

template checkAb(expected: array[7, uint32]) =
  when defined(bl808WifiBenchConnectedScanAB):
    doAssert nimFwDbgHomeWakeAb == expected

proc checkFrame(): ptr HostTxDescView =
  result = hostTxDescAt(pushed[^1])
  let f = hostTxDataHeader(result)
  doAssert f.frameControl == 0x0148 and f.duration == 0
  doAssert f.addr1 == stas[2].macAddr and f.addr3 == stas[2].macAddr
  doAssert f.addr2 == vifs[1].macAddr and f.seqCtrl == sequence
  doAssert result.staInfoIdx == 2 and result.vifIdx == 1
  doAssert result.callbackArg == nil and result.retryFlag == 0
  let hw = hostTxHwDescAt(result.hwDesc)
  doAssert hw.ackPolicyControl == 0x200 and hw.retryLimitControl == 0
  let owner = txFrameIdentities[txl_frame_desc_index(result)]
  doAssert owner.leased
  when defined(bl808WifiBenchConnectedScanAB):
    doAssert result.callback == cast[pointer](chanHomeWakeComplete)
  else:
    doAssert result.callback == nil

proc finish(frame: ptr HostTxDescView; raw: uint32) =
  let lease = txlFrameLeaseToken(frame)
  let seedIrq = interruptsEnabled
  let sent = pushes
  hostTxHwDescAt(frame.hwDesc).confirmStatus = raw
  inc txEnv.packetCounter
  txl_frame_cfm(frame)
  doAssert events == 0x80000
  txl_frame_evt()
  doAssert interruptsEnabled == seedIrq and txActiveFrameCallback == nil
  doAssert frameEnv.usedList.first == nil and not txlFrameLeaseMatches(frame, lease)
  doAssert txEnv.packetCounter == 0 and events == 0
  doAssert pushes == sent and pendingTimer == nil

for incoming in [false, true]:
  initPool()
  interruptsEnabled = incoming
  vifs[1] = Vif(vifIdx: 1, staIdx: 2, state: 1, chanCtxt: addr homeContext,
                macAddr: [4'u8, 5, 6, 7, 8, 9])
  stas[2].valid = 1
  stas[2].instNbr = 1
  stas[2].macAddr = [2'u8, 3, 4, 5, 6, 7]
  chanEnv.currentCtxt = addr homeContext
  pushes = 0
  pushed.setLen(0)
  when defined(bl808WifiBenchConnectedScanAB): nimFwDbgHomeWakeAb = default(array[7, uint32])
  when defined(bl808WifiBenchConnectedScan): nimFwDbgHomeWakeQueued = 0

  # An empty pool arms the same retry without a TX submission or completion.
  var held: array[4, pointer]
  for frame in held.mitems: frame = txl_frame_get(24)
  macTime = high(uint32) - 1000
  chanHomeWakeRequest(addr vifs[1], 0)
  let requestTime = macTime
  checkAb([1'u32, requestTime, 0, 0, 0, 0, 0])
  doAssert pushes == 0 and flushes == 0 and interruptsEnabled == incoming
  doAssert pendingTimer != nil and pendingTimer.expiry == 3999
  txl_frame_release(held[0], false)

  # Actual builder rejection releases its lease and does not count as queued.
  rejectPreparation = true
  fireTimer()
  checkAb([1'u32, requestTime, 0, 0, 0, 0, 0])
  doAssert pushes == 0 and interruptsEnabled == incoming
  doAssert co_list_cnt(addr frameEnv.freeList) == 1
  doAssert pendingTimer != nil and pendingTimer.expiry == 8999
  rejectPreparation = false
  stas[2].valid = 1
  fireTimer()
  doAssert pushes == 1 and interruptsEnabled == incoming and pendingTimer == nil
  checkAb([1'u32, requestTime, 1, 0, 0, 0, 0])
  finish(checkFrame(), 0x80800017'u32)
  checkAb([1'u32, requestTime, 1, 1, 0, 0, 0x80800017'u32])

  # Reuse the same frame slot. No ACK and ACK-without-DONE are distinct.
  inc macTime
  chanHomeWakeRequest(addr vifs[1], 0)
  doAssert pushed[^1] == held[0]
  finish(checkFrame(), 0x80000002'u32)
  checkAb([2'u32, macTime, 2, 1, 1, 0, 0x80000002'u32])
  inc macTime
  chanHomeWakeRequest(addr vifs[1], 0)
  finish(checkFrame(), 0x00800000'u32)
  checkAb([3'u32, macTime, 3, 1, 1, 1, 0x00800000'u32])

  # A stale session's event substitutes the software retirement word.
  inc macTime
  chanHomeWakeRequest(addr vifs[1], 0)
  let stale = checkFrame()
  inc stationEpochs[2]
  finish(stale, 0x80800000'u32)
  checkAb([4'u32, macTime, 4, 1, 1, 2, 0x40000000'u32])

  # Postponed retirement releases first and delivers status zero.
  inc macTime
  chanHomeWakeRequest(addr vifs[1], 0)
  let postponed = checkFrame()
  let lease = txlFrameLeaseToken(postponed)
  var postponedList: CoList
  postponed.postponeFlag = 1
  co_list_push_back(addr postponedList, addr postponed.link)
  frameEnv.postponedCount = 1
  txlDrainRetiredPostponed(addr postponedList)
  doAssert not txlFrameLeaseMatches(postponed, lease)
  doAssert postponedList.first == nil and frameEnv.postponedCount == 0
  doAssert interruptsEnabled == incoming and txActiveFrameCallback == nil
  checkAb([5'u32, macTime, 5, 1, 1, 3, 0])
  when defined(bl808WifiBenchConnectedScan): doAssert nimFwDbgHomeWakeQueued == 5

  # An unrelated PM=0 submission must not contribute to home-wake telemetry.
  doAssert txl_frame_send_null_frame(2, nil, 0) == 0
  let unrelated = hostTxDescAt(pushed[^1])
  doAssert unrelated.callback == nil
  finish(unrelated, 0x80800000'u32)
  checkAb([5'u32, macTime, 5, 1, 1, 3, 0])
  doAssert pushes == 6 and co_list_cnt(addr frameEnv.freeList) == 1
'''


@pytest.mark.parametrize("defines", [
    (),
    ("bl808WifiBenchConnectedScan",),
    ("bl808WifiBenchConnectedScanAB",),
    ("bl808WifiBenchConnectedScan", "bl808WifiBenchConnectedScanAB"),
])
def test_home_wake_ab(tmp_path: Path, defines: tuple[str, ...]) -> None:
    tx = (FW / "tx_layer.nim").read_text()
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    layout = (FW / "layout_types.nim").read_text()
    wake = (FW / "channel_home_wake.nim").read_text()
    types = "type\n" + "".join(
        "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
        for name in ("TxSessionIdentity", "MacDataFrameHeaderView", "MacQosDataFrameHeaderView",
                     "MacCtsFrameHeaderView", "MmVifIdentity")
    )
    platform = TX_PLATFORM.replace(
        "    vifIdx, vifType, state: uint8",
        "    vifIdx, vifType, state, staIdx: uint8\n    chanCtxt: pointer",
    )
    split = platform.index("const NUM_TX_QUEUES")
    functions = "".join(procedure(tx, name) for name in (
        "txl_frame_desc_index", "txlCaptureFrameIdentity", "txlFrameBeginLease",
        "txlFrameEndLease", "txlFrameLeaseToken", "txlFrameLeaseMatches",
        "txlFrameIdentityCurrent", "txlFrameSessionCurrent", "txlCaptureFrameCallback",
        "txlInvokeFrameCallback", "txlCaptureSession", "txlSessionCurrent", "txlStationAdmits",
        "txlFramePreparationCurrent", "txl_frame_free_list_pop", "txl_frame_get",
        "txl_frame_release", "txlFramePushPrepared", "txl_frame_push", "txl_frame_send_null_frame",
        "txl_frame_cfm", "txlFrameConfirmPending", "txl_frame_evt", "txlDrainRetiredPostponed",
    ))
    functions += "".join(procedure(kernel, name) for name in (
        "mmCaptureVif", "mmVifCurrent", "mmStaOwnerCurrent", "mmStaTimerCurrent",
    ))
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", functions)))
    ) + "  nimFwDbgAutoNullSkipped: uint32\n"
    functions += ps_machine_source("psAwake", record=False)
    code = platform[:split] + types + platform[split:] + PLATFORM + debug + functions + wake
    run_program(tmp_path, "firmware", code + CHECKS, defines=defines)
