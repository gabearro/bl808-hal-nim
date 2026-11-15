"""Keep AP RX power-save work bound to the station that triggered it."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rx_power_save import PLATFORM


def source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    names = ("MacDataFrameHeaderView", "MacQosDataFrameHeaderView",
             "MacQos4AddrFrameHeaderView", "MmTrafficReqIndPayload",
             "MmPsChangeIndPayload", "ApmPsSession")
    declarations = []
    for name in names:
        match = re.search(rf"(?m)^  {name}\*?(?: \{{[^\n]+\}})? = object\n(?:    [^\n]*\n)+", layout)
        assert match, name
        declarations.append(match.group(0))
    types = "type\n" + "".join(declarations)
    constants = """
const
  MmTrafficReqIndPayloadSize = sizeof(MmTrafficReqIndPayload).uint32
  MmPsChangeIndPayloadSize = sizeof(MmPsChangeIndPayload).uint32
"""
    code = PLATFORM.replace("import bl808/wifi/fw_messages",
                            f'include "{FW.parent / "fw_messages.nim"}"\n' + types + constants)
    code = code.replace("var\n  stas:", """var
  onBoundary: proc(name: string)
  allocationCount, freeCount: int
  failAllocation: bool
  stas:""", 1)
    code = code.replace("proc staInfoForIdx", """
proc boundary(name: string) =
  doAssert not interruptsEnabled
  if onBoundary != nil: onBoundary(name)
proc staInfoForIdx""", 1)
    code = code.replace(procedure(code, "ke_msg_free_payload"), """
proc ke_msg_free_payload(p: pointer) =
  doAssert p == addr allocation[0]
  inc freeCount
""")
    code = code.replace("  allocation = default(typeof(allocation))",
                        '  inc allocationCount\n  boundary("allocate")\n  if failAllocation: return nil\n  allocation = default(typeof(allocation))')
    code = code.replace('    actions.add(("traffic", allocation[0].uint32, allocation[1].uint32, allocation[2].uint32))',
                        '    actions.add(("traffic", allocation[0].uint32, allocation[1].uint32, allocation[2].uint32))\n  boundary("notify")')
    code = code.replace('  actions.add(("clear", sta.uint32, 0\'u32, 0\'u32))',
                        '  actions.add(("clear", sta.uint32, 0\'u32, 0\'u32))\n  boundary("clear")')
    code = code.replace("  stas[4].trafficFlags = afterTraffic\n  txCount",
                        '  stas[4].trafficFlags = afterTraffic\n  boundary("drain")\n  txCount')
    code = code.replace('  actions.add(("null", sta.uint32, qos.uint32, stas[4].psStatus))\n  1',
                        '  actions.add(("null", sta.uint32, qos.uint32, stas[4].psStatus))\n  boundary("null")\n  1')
    storage = (FW / "global_state/storage.nim").read_text()
    for name in ("mac_ac2uapsd", "mac_tid2ac"):
        code += "\nvar " + name + "*" + storage.split("var " + name + "*", 1)[1].split("\n]", 1)[0] + "\n]\n"
    apm = (FW / "scan_station_ap_me.nim").read_text()
    for name in ("apmPsCapture", "apmPsSessionCurrent"):
        code += procedure(apm, name)
    code += procedure((FW / "kernel_mac_channel.nim").read_text(), "mm_ps_change_ind")
    rx = (FW / "rx_layer.nim").read_text()
    for name in ("rxlRequestBufferedTraffic", "rxlHandleApPowerSave"):
        code += procedure(rx, name)
    return code + r'''
var frame: MacQos4AddrFrameHeaderView
proc setup(scenario: string) =
  reset()
  onBoundary = nil
  allocationCount = 0
  freeCount = 0
  failAllocation = false
  rxVifEpochs = default(typeof(rxVifEpochs))
  stationEpochs = default(typeof(stationEpochs))
  stas[4] = StaInfoView(valid: 1, infoIdx: 4, instNbr: 1, aid: 17,
    psMode: 1, psState: 15)
  stas[6] = StaInfoView(infoIdx: 6, instNbr: 1)
  vifs[1] = VifChannelView(vifType: VIF_TYPE_AP, vifIdx: 1)
  frame = default(typeof(frame))
  frame.header.frameControl = 0x1188
  case scenario
  of "sleep":
    frame.header.frameControl = 0x1008
    stas[4].psMode = 0
  of "wake":
    frame.header.frameControl = 0x0008
    vifs[1].psBaCounter = 1
  of "poll":
    frame.header.frameControl = 0x10A4
    stas[4].trafficFlags = 2
  of "budget", "tail":
    stas[4].trafficFlags = 8
    stas[4].uapsdBitmap = if scenario == "budget": 1 else: 0
    txCount = 1
  of "host": stas[4].trafficFlags = 4
  else: discard
proc run() = rxlHandleApPowerSave(addr vifs[1], addr stas[4], 4, addr frame)
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_callbacks_do_not_update_replacement_owner(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
let boundaries = [
  ("sleep", "notify", 1), ("sleep", "notify", 2),
  ("wake", "notify", 1), ("wake", "clear", 1), ("wake", "notify", 2),
  ("poll", "drain", 1), ("empty", "null", 1),
  ("budget", "drain", 1), ("budget", "null", 1),
  ("tail", "null", 1), ("host", "notify", 1)]
for (scenario, phase, occurrence) in boundaries:
  for change in 0 .. 3:
    for enabled in [false, true]:
      setup(scenario)
      interruptsEnabled = enabled
      var seen = 0
      var hit = false
      var previousActions: int
      var replacementStation: StaInfoView
      var replacementVif: VifChannelView
      onBoundary = proc(name: string) =
        if name != phase: return
        inc seen
        if seen != occurrence: return
        hit = true
        case change
        of 0: inc stationEpochs[4]
        of 1: inc rxVifEpochs[1]
        of 2: stas[4].aid = 23
        else: stas[4].instNbr = 0
        stas[4].psStatus = 0x76543210
        vifs[1].psBaCounter = 73
        replacementStation = stas[4]
        replacementVif = vifs[1]
        previousActions = actions.len
      run()
      doAssert hit, scenario & "/" & phase
      doAssert stas[4] == replacementStation, "old RX work changed replacement station"
      doAssert vifs[1] == replacementVif, "old RX work changed replacement VIF"
      doAssert actions.len == previousActions, "old RX work emitted another action"
      doAssert interruptsEnabled == enabled
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_allocation_cancellation_drops_private_notifications(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for scenario in ["sleep", "wake", "host"]:
  setup(scenario)
  var replacement: StaInfoView
  onBoundary = proc(name: string) =
    if name != "allocate": return
    inc stationEpochs[4]
    stas[4].psStatus = 0x4321
    replacement = stas[4]
  run()
  doAssert allocationCount == 1 and freeCount == 1
  doAssert actions.len == 0 and stas[4] == replacement
  doAssert interruptsEnabled
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_normal_actions_and_unrelated_changes_continue(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for scenario in ["sleep", "wake", "poll", "empty", "budget", "tail", "host"]:
  for enabled in [false, true]:
    setup(scenario)
    interruptsEnabled = enabled
    onBoundary = proc(name: string) = inc rxVifEpochs[0]
    run()
    let expected = case scenario
      of "sleep": 2
      of "wake": 4
      of "budget", "tail": 2
      else: 1
    doAssert actions.len == expected and freeCount == 0
    doAssert stas[4].psStatus == (if scenario == "host": 4'u32 else: 0'u32)
    doAssert vifs[1].psBaCounter == (if scenario == "sleep": 1'u8 else: 0'u8)
    doAssert interruptsEnabled == enabled
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_changed_service_policy_is_not_overwritten(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for (scenario, phase) in [("empty", "null"), ("poll", "drain"), ("host", "allocate")]:
  for change in 0 .. 2:
    setup(scenario)
    var replacement: StaInfoView
    var previousActions: int
    var hit = false
    onBoundary = proc(name: string) =
      if name != phase: return
      hit = true
      case change
      of 0: stas[4].psStatus = 8
      of 1: stas[4].psMode = 0
      else: stas[4].psState = 0
      replacement = stas[4]
      previousActions = actions.len
    run()
    doAssert hit and stas[4] == replacement and interruptsEnabled
    doAssert actions.len == previousActions
    doAssert freeCount == (if scenario == "host": 1 else: 0)
setup("host")
onBoundary = proc(name: string) =
  if name == "allocate": stas[4].trafficFlags = 0
run()
doAssert freeCount == 1 and actions.len == 0 and stas[4].trafficFlags == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_invalid_ap_bindings_have_no_side_effects(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for invalid in 0 .. 6:
  setup("sleep")
  var targetVif = addr vifs[1]
  var targetSta = addr stas[4]
  var targetFrame = cast[pointer](addr frame)
  var targetIndex = 4'u8
  case invalid
  of 0: targetVif = nil
  of 1: targetSta = nil
  of 2: targetFrame = nil
  of 3: targetIndex = 255
  of 4: stas[4].valid = 0
  of 5: targetVif = addr vifs[0]
  else: vifs[1].vifIdx = 0
  let beforeSta = stas
  let beforeVif = vifs
  rxlHandleApPowerSave(targetVif, targetSta, targetIndex, targetFrame)
  doAssert actions.len == 0 and allocationCount == 0
  doAssert stas == beforeSta and vifs == beforeVif and interruptsEnabled
for index in [7'u8, 255'u8]:
  setup("sleep")
  mm_ps_change_ind(index, 1)
  doAssert actions.len == 0 and allocationCount == 0 and interruptsEnabled
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_failed_notification_allocation_preserves_local_bookkeeping(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for scenario in ["sleep", "wake", "host"]:
  setup(scenario)
  failAllocation = true
  run()
  doAssert freeCount == 0
  if scenario == "host":
    doAssert allocationCount == 1 and actions.len == 0
  elif scenario == "sleep":
    doAssert allocationCount == 2 and actions.len == 0
    doAssert stas[4].psMode == 1 and stas[6].psMode == 1 and vifs[1].psBaCounter == 1
  else:
    doAssert allocationCount == 2 and actions.len == 2
    doAssert stas[4].psMode == 0 and stas[6].psMode == 0 and vifs[1].psBaCounter == 0
  doAssert stas[4].psStatus == 0 and interruptsEnabled
''')
