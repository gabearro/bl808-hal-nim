"""Exercise keep-alive completion tracking across the uint32 counter wrap."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
  MACHW_TIMLO_REG = 0x24B00120'u
  WifiTxFrameSuccessfulBit = 0x00800000'u32
type
  Vif = object
    vifType, state, staIdx: uint8
  Sta = object
    valid, instNbr: uint8
  StaQueueIdentity = object
    entry: pointer
    stationEpoch, vifEpoch: uint32
    station, vif: uint8
    stationTracked, vifTracked: bool
  FrameCallback = proc(p: pointer; status: uint32) {.cdecl.}
var
  vifs: array[MAX_VIFS, Vif]
  stas: array[STA_INFO_TAB_ENTRIES, Sta]
  stationEpochs: array[STA_INFO_TAB_ENTRIES, uint32]
  rxVifEpochs: array[MAX_VIFS, uint32]
  txResetEpoch: uint32
  resetting: bool
  frameEnv: tuple[postponedCount: uint32]
  pending: seq[tuple[callback: FrameCallback, generation: uint32]]
  mode: int
  sendCalls, triggers, clears, services, wifiRoles, bleRoles: int
  ready, clearAllowed, completeOnTrigger, drainPostponed: bool
  preserveOnClear: bool
  onBle, onReady, onService, onWifi, onPrepare: proc()
  now: uint32
proc txFrameEnv(): ptr typeof(frameEnv) = addr frameEnv
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc staInfoForIdx(index: uint8): ptr Sta = addr stas[index]
proc staInfoAt(p: pointer): ptr Sta = cast[ptr Sta](p)
proc staDeleteEpoch(index: uint8): uint32 = stationEpochs[index]
proc txlResetting(): bool = resetting
proc txl_cntrl_tx_check(p: pointer): bool =
  if onReady != nil:
    let hook = onReady
    onReady = nil
    hook()
  ready
proc regRead(address: uint): uint32 =
  if address == MACHW_TIMLO_REG: now
  else:
    doAssert address in [0x24B08078'u, 0x24B0808C'u]
    0
proc wlanCoexControl(): uint32 = 0x12345678'u32
proc wlanCoexPti(): uint32 = 0x87654321'u32
proc completeOne(status = WifiTxFrameSuccessfulBit) =
  doAssert pending.len > 0
  let completion = pending[0]
  pending.delete(0)
  completion.callback(cast[pointer](completion.generation.uint), status)
proc submit(station: uint8; callback: pointer; arg: uint32): uint8 =
  doAssert station == 2 and callback != nil
  inc sendCalls
  case mode
  of 1, 4:
    cast[FrameCallback](callback)(cast[pointer](arg.uint),
                                 if mode == 1: WifiTxFrameSuccessfulBit else: 0)
  of 2: return 1
  of 3:
    inc frameEnv.postponedCount
    pending.add((cast[FrameCallback](callback), arg))
  else: pending.add((cast[FrameCallback](callback), arg))
  0
proc txl_frame_send_null_frame(station: uint8; callback: pointer; arg: uint32): uint8 =
  submit(station, callback, arg)
proc txl_frame_send_qosnull_frame(station: uint8; qos: uint16;
                                callback: pointer; arg: uint32): uint8 =
  doAssert qos == 0
  submit(station, callback, arg)
proc txl_cntrl_clear_ac(ac: uint8): bool =
  doAssert ac == 3
  inc clears
  if not clearAllowed: return false
  if not preserveOnClear:
    let count = pending.len
    for i in 0 ..< count: completeOne(0)
  true
proc txl_transmit_trigger() =
  inc triggers
  if completeOnTrigger and pending.len != 0: completeOne()
proc wifi_nimfw_service_sta_postponed(limit: uint32): uint32 =
  doAssert limit == 1
  inc services
  if drainPostponed:
    result = frameEnv.postponedCount
    frameEnv.postponedCount = 0
  if onService != nil:
    let hook = onService
    onService = nil
    hook()
proc wifi_nimfw_coex_force_ble_role() =
  inc bleRoles
  nimFwBleWifiRoleWindowActive = 0
  if onBle != nil:
    let hook = onBle
    onBle = nil
    hook()
proc wifi_nimfw_coex_force_wifi_role(): uint32 =
  inc wifiRoles
  nimFwBleWifiRoleWindowActive = 1
  if onWifi != nil:
    let hook = onWifi
    onWifi = nil
    hook()
  1
proc wifi_nimfw_prepare_sta_tx_channel() =
  if onPrepare != nil:
    let hook = onPrepare
    onPrepare = nil
    hook()
'''


def source() -> str:
    text = (FW / "tx_layer.nim").read_text()
    code = "".join(procedure(text, name) for name in [
        "wifi_nimfw_null_frame_cfm", "wifi_nimfw_send_checked_null_frame",
        "wifi_nimfw_send_checked_qosnull_frame", "wifi_nimfw_send_sta_null_frame",
    ])
    station = (FW / "sta_management.nim").read_text()
    code = "".join(procedure(station, name) for name in [
        "staPostponedOwner", "staPostponedOwnerCurrent",
    ]) + code
    names = sorted(set(re.findall(r"\bnimFw\w+", code + PLATFORM)))
    declarations = "var\n" + "".join(f"  {name}: uint32\n" for name in names)
    resets = "".join(f"  {name} = 0\n" for name in names)
    setup = "\nproc setup(counter: uint32; qos = false; role = false) =\n" + resets + r'''
  nimFwDbgNullFrameCfm = counter
  nimFwKeepaliveQosNullEnabled = qos.uint32
  nimFwBleWifiRoleWindowEnabled = role.uint32
  vifs = default(typeof(vifs))
  vifs[0] = Vif(state: 1, staIdx: 2)
  stas = default(typeof(stas))
  stas[2] = Sta(valid: 1, instNbr: 0)
  stationEpochs = default(typeof(stationEpochs))
  rxVifEpochs = default(typeof(rxVifEpochs))
  txResetEpoch = 0
  resetting = false
  frameEnv = default(typeof(frameEnv))
  pending.setLen(0)
  mode = 0
  sendCalls = 0
  triggers = 0
  clears = 0
  services = 0
  wifiRoles = 0
  bleRoles = 0
  ready = true
  clearAllowed = true
  completeOnTrigger = false
  drainPostponed = false
  preserveOnClear = false
  onBle = nil
  onReady = nil
  onService = nil
  onWifi = nil
  onPrepare = nil
  now = 0xFFFFFFF0'u32
'''
    return declarations + PLATFORM + code + setup


CASES = {
    "delayed_completion": r'''
for counter in [0'u32, 1, 0x7FFFFFFF'u32, 0xFFFFFFFE'u32, 0xFFFFFFFF'u32]:
  for qos in [false, true]:
    for role in [false, true]:
      setup(counter, qos, role)
      doAssert wifi_nimfw_send_sta_null_frame() == 0
      doAssert sendCalls == 1 and pending.len == 1 and nimFwKeepaliveInFlight == 1
      doAssert nimFwKeepaliveTargetCfm == counter + 1'u32
      doAssert wifi_nimfw_send_sta_null_frame() == 2
      doAssert sendCalls == 1 and pending.len == 1 and nimFwKeepaliveInFlight == 1,
        "pending keep-alive was resubmitted at counter rollover"
      completeOne()
      ready = false
      doAssert wifi_nimfw_send_sta_null_frame() == 2
      doAssert sendCalls == 1 and pending.len == 0 and nimFwKeepaliveInFlight == 0
      doAssert nimFwDbgNullFrameCfm == counter + 1'u32 and nimFwDbgNullFrameAckOk == 1
''',
    "inline_completion": r'''
for counter in [0'u32, 1, 0x7FFFFFFF'u32, 0xFFFFFFFE'u32, 0xFFFFFFFF'u32]:
  for qos in [false, true]:
    for role in [false, true]:
      for submitMode in [1, 4]:
        setup(counter, qos, role)
        mode = submitMode
        doAssert wifi_nimfw_send_sta_null_frame() == 0
        doAssert sendCalls == 1 and pending.len == 0
        doAssert nimFwDbgNullFrameCfm == counter + 1'u32
        doAssert nimFwKeepaliveInFlight == 0 and triggers == 0,
          "completed inline frame was recorded as pending"
        doAssert nimFwDbgNullFrameAckOk == (submitMode == 1).uint32
        doAssert nimFwDbgNullFrameAckFail == (submitMode == 4).uint32
''',
    "trigger_and_timeout": r'''
for counter in [0'u32, 0xFFFFFFFF'u32]:
  setup(counter)
  completeOnTrigger = true
  doAssert wifi_nimfw_send_sta_null_frame() == 0
  doAssert pending.len == 0 and nimFwKeepaliveInFlight == 0
  ready = false
  doAssert wifi_nimfw_send_sta_null_frame() == 2
  doAssert sendCalls == 1 and nimFwKeepaliveInFlight == 0

setup(0)
doAssert wifi_nimfw_send_sta_null_frame() == 0
now += 249999'u32
doAssert wifi_nimfw_send_sta_null_frame() == 2
doAssert clears == 0 and sendCalls == 1
inc now
clearAllowed = false
doAssert wifi_nimfw_send_sta_null_frame() == 2
doAssert clears == 1 and sendCalls == 1 and nimFwKeepaliveInFlight == 1
clearAllowed = true
doAssert wifi_nimfw_send_sta_null_frame() == 0
doAssert clears == 2 and sendCalls == 2 and pending.len == 1
doAssert nimFwDbgNullFrameAckFail == 1 and nimFwKeepaliveInFlight == 1
doAssert nimFwKeepaliveTargetCfm == 2
''',
    "admission": r'''
setup(0xFFFFFFFF'u32)
vifs[0].state = 0
doAssert wifi_nimfw_send_sta_null_frame() == 1 and sendCalls == 0
setup(0xFFFFFFFF'u32)
ready = false
doAssert wifi_nimfw_send_sta_null_frame() == 2 and sendCalls == 0
for submitMode in [2, 3]:
  for qos in [false, true]:
    setup(0xFFFFFFFF'u32, qos)
    mode = submitMode
    doAssert wifi_nimfw_send_sta_null_frame() == submitMode.uint8 - 1
    doAssert sendCalls == 1 and nimFwKeepaliveInFlight == (submitMode == 3).uint32
    doAssert nimFwDbgNullFrameCfm == 0xFFFFFFFF'u32 and triggers == 0
setup(7)
frameEnv.postponedCount = 1
doAssert wifi_nimfw_send_sta_null_frame() == 2 and sendCalls == 0
drainPostponed = true
doAssert wifi_nimfw_send_sta_null_frame() == 0 and sendCalls == 1
''',
    "postponed_and_stale_completion": r'''
for counter in [0'u32, 0xFFFFFFFF'u32]:
  setup(counter, role = true)
  mode = 3
  doAssert wifi_nimfw_send_sta_null_frame() == 2
  doAssert nimFwKeepaliveInFlight == 1 and pending.len == 1 and sendCalls == 1
  doAssert pending[0].generation == nimFwKeepaliveGeneration
  mode = 0
  drainPostponed = true
  doAssert wifi_nimfw_send_sta_null_frame() == 2
  doAssert frameEnv.postponedCount == 0 and pending.len == 1 and sendCalls == 1
  completeOne()
  doAssert nimFwKeepaliveInFlight == 0
  doAssert wifi_nimfw_send_sta_null_frame() == 0 and sendCalls == 2

setup(0xFFFFFFFF'u32, role = true)
doAssert wifi_nimfw_send_sta_null_frame() == 0
let oldGeneration = pending[0].generation
now += 250000'u32
preserveOnClear = true
doAssert wifi_nimfw_send_sta_null_frame() == 0
doAssert pending.len == 2 and sendCalls == 2 and nimFwKeepaliveInFlight == 1
doAssert pending[1].generation != oldGeneration
completeOne()
doAssert nimFwDbgNullFrameCfm == 0 and nimFwKeepaliveInFlight == 1
doAssert nimFwBleWifiRoleWindowActive == 1, "stale callback changed the new radio window"
doAssert wifi_nimfw_send_sta_null_frame() == 2 and sendCalls == 2
completeOne()
doAssert nimFwKeepaliveInFlight == 0 and nimFwBleWifiRoleWindowActive == 0
''',
    "reentrant_completion_and_reservation": r'''
setup(10, role = true)
mode = 1
onBle = proc() =
  mode = 0
  doAssert wifi_nimfw_send_sta_null_frame() == 0
doAssert wifi_nimfw_send_sta_null_frame() == 0
doAssert sendCalls == 2 and pending.len == 1 and nimFwKeepaliveInFlight == 1
doAssert pending[0].generation == nimFwKeepaliveGeneration
completeOne()
doAssert nimFwKeepaliveInFlight == 0

setup(10, role = true)
doAssert wifi_nimfw_send_sta_null_frame() == 0
now += 250000'u32
onBle = proc() = doAssert wifi_nimfw_send_sta_null_frame() == 0
doAssert wifi_nimfw_send_sta_null_frame() == 2
doAssert sendCalls == 2 and pending.len == 1 and nimFwKeepaliveInFlight == 1
doAssert pending[0].generation == nimFwKeepaliveGeneration

setup(0)
nimFwKeepaliveGeneration = 0xFFFFFFFF'u32
onReady = proc() = doAssert wifi_nimfw_send_sta_null_frame() == 2
doAssert wifi_nimfw_send_sta_null_frame() == 0
doAssert sendCalls == 1 and pending.len == 1 and nimFwKeepaliveInFlight == 1
doAssert pending[0].generation == 1 and nimFwKeepaliveGeneration == 1
''',
    "nested_service_submission": r'''
for submitMode in [0, 1]:
  setup(0)
  frameEnv.postponedCount = 1
  drainPostponed = true
  mode = submitMode
  onService = proc() = doAssert wifi_nimfw_send_sta_null_frame() == 0
  doAssert wifi_nimfw_send_sta_null_frame() == 2
  doAssert sendCalls == 1, "outer queue drain submitted a second keep-alive"
  doAssert pending.len == (submitMode == 0).int
''',
    "session_changes": r'''
for point in [0, 1, 2]:
  for change in 0 .. 9:
    setup(0, role = true)
    nimFwStaTxChannelPrepareEnabled = 1
    let hook = proc() =
      case change
      of 0: inc stationEpochs[2]
      of 1: inc rxVifEpochs[0]
      of 2: inc txResetEpoch
      of 3: resetting = true
      of 4: stas[2].valid = 0
      of 5: stas[2].instNbr = 1
      of 6: vifs[0].state = 0
      of 7: vifs[0].vifType = 2
      of 8: vifs[0].staIdx = 3
      else: inc stationEpochs[4]
    if point == 0: onReady = hook
    elif point == 1: onWifi = hook
    else: onPrepare = hook
    doAssert wifi_nimfw_send_sta_null_frame() == (if change == 9: 0'u8 else: 2'u8)
    doAssert sendCalls == (change == 9).int and pending.len == (change == 9).int
    doAssert nimFwKeepaliveInFlight == (change == 9).uint32
    doAssert nimFwBleWifiRoleWindowActive == (change == 9).uint32
''',
    "station_admission": r'''
for index in 0 .. 255:
  setup(0)
  vifs[0].staIdx = index.uint8
  let expected = if index == 2: 0'u8 else: 1'u8
  doAssert wifi_nimfw_send_sta_null_frame() == expected
  doAssert sendCalls == (index == 2).int
for invalid in 0 .. 1:
  setup(0)
  if invalid == 0: stas[2].valid = 0
  else: stas[2].instNbr = 1
  doAssert wifi_nimfw_send_sta_null_frame() == 1 and sendCalls == 0
''',
    "service_completes_frame": r'''
setup(0, role = true)
onService = proc() = completeOne()
doAssert wifi_nimfw_send_sta_null_frame() == 0
doAssert sendCalls == 1 and pending.len == 0 and nimFwKeepaliveInFlight == 0
doAssert nimFwBleWifiRoleWindowActive == 0 and triggers == 0,
  "completed frame was triggered again after its radio window closed"
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_keepalive_progress(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
