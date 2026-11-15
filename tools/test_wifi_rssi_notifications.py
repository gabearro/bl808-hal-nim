"""Check RSSI report policy and VIF ownership across message callbacks."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const MAX_VIFS = 2
type
  Vif = object
    vifIdx, staIdx: uint8
    rssiLast, rssiThreshold: int8
    rssiHysteresis, rssiState: uint8
  Report = tuple[id: uint16, vif, state, rssi: uint8, reason: uint16]
var
  vifs: array[MAX_VIFS, Vif]
  rxVifEpochs: array[MAX_VIFS, uint32]
  stationEpochs: array[7, uint32]
  clock, reportTime, nimFwDbgConnLossInd: uint32
  allocations: array[8, array[16, uint8]]
  ids: array[8, uint16]
  attempts, freed: int
  reports: seq[Report]
  onAllocate, onSend: proc()
  failAllocation: bool
  enabled = true
proc irqSave(): uint32 =
  result = enabled.uint32 * 8
  enabled = false
proc irqRestore(saved: uint32) = enabled = (saved and 8) != 0
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
proc staDeleteEpoch(i: uint8): uint32 =
  if i < stationEpochs.len.uint8: stationEpochs[i] else: 0
proc chanRssiLastReportTime(): ptr uint32 = addr reportTime
proc macTimeNow(): uint32 = clock
proc invoke(hook: var proc()) =
  if hook != nil:
    let action = hook
    hook = nil
    action()
proc ke_msg_alloc(id: uint16; dst, src: uint8; length: uint32): pointer =
  let slot = attempts
  inc attempts
  doAssert slot < allocations.len
  doAssert src == 0
  doAssert (id == 0x43 and dst == 9 and length == 3) or
           (id == 0x31 and dst == 4 and length == 4)
  ids[slot] = id
  allocations[slot] = default(typeof(allocations[slot]))
  invoke(onAllocate)
  if failAllocation: return nil
  addr allocations[slot][0]
proc ke_msg_free_payload(p: pointer) =
  doAssert p != nil
  inc freed
proc ke_msg_send(p: pointer) =
  var slot = -1
  for index in 0 ..< attempts:
    if p == addr allocations[index][0]: slot = index
  doAssert slot >= 0
  let bytes = allocations[slot]
  if ids[slot] == 0x43:
    reports.add((ids[slot], bytes[0], bytes[1], bytes[2], 0'u16))
  else:
    reports.add((ids[slot], bytes[2], 0'u8, 0'u8,
                 bytes[0].uint16 or (bytes[1].uint16 shl 8)))
  invoke(onSend)
proc setup(old = -50'i8; threshold = -60'i8; hysteresis = 7'u8; state = 0'u8) =
  vifs = default(typeof(vifs))
  for i in 0 ..< MAX_VIFS: vifs[i].vifIdx = i.uint8
  vifs[0].rssiLast = old
  vifs[0].rssiThreshold = threshold
  vifs[0].rssiHysteresis = hysteresis
  vifs[0].rssiState = state
  attempts = 0
  freed = 0
  reports.setLen(0)
  onAllocate = nil
  onSend = nil
  failAllocation = false
  clock = 100
  reportTime = 0
  enabled = true
proc recycle() =
  inc rxVifEpochs[0]
  vifs[0] = Vif(vifIdx: 0, rssiLast: -10, rssiThreshold: -15,
                rssiHysteresis: 2, rssiState: 7)
'''


def source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    declarations = []
    for name in ("MmRssiStatusIndPayload", "MmConnectionLossIndPayload", "MmVifIdentity"):
        match = re.search(rf"(?m)^  {name}(?: \{{\.packed\.\}})? = object\n(?:    [^\n]*\n)+", layout)
        assert match, name
        declarations.append(match.group(0))
    code = "type\n" + "".join(declarations) + r'''
const
  MmRssiStatusIndPayloadSize = sizeof(MmRssiStatusIndPayload).uint32
  MmConnectionLossIndPayloadSize = sizeof(MmConnectionLossIndPayload).uint32
  MM_CONNECTION_LOSS_IND = 0x31'u16
  TASK_SM = 4'u8
  TASK_MM = 0'u8
''' + PLATFORM
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    for name in ("mmCaptureVif", "mmVifCurrent", "mm_send_connection_loss_ind", "mm_check_rssi"):
        if re.search(rf"(?m)^proc {name}\*?\(", kernel):
            code += procedure(kernel, name)
    return code


def transition(old: int, new: int, threshold: int, hysteresis: int, state: int) -> int:
    hysteresis = hysteresis if hysteresis < 128 else hysteresis - 256
    if threshold == 0:
        return state
    if state == 0 and new < old:
        return int(new < threshold - hysteresis)
    if state != 0 and new > old:
        return int(new <= threshold + hysteresis)
    return state


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_thresholds_and_periodic_reports_follow_vendor(tmp_path: Path, mode: str) -> None:
    cases = [(-50, -68, -60, 7, 0), (-50, -67, -60, 7, 0),
             (-80, -54, -60, 7, 1), (-80, -53, -60, 7, 1),
             (-50, -70, -60, 12, 0), (-50, -73, -60, 12, 0),
             (-80, -60, -60, 0, 1), (-50, -61, -60, 0, 0),
             (-50, -40, -60, 7, 0), (-80, -90, -60, 7, 1),
             (-50, -60, 0, 7, 0), (-50, -100, -120, 127, 0),
             (-50, -60, -60, 255, 0), (0, -75, -60, 7, 0)]
    checks = ""
    for old, new, threshold, hysteresis, state in cases:
        for elapsed in (100, 2_000_000, 2_000_001):
            result = transition(old, new, threshold, hysteresis, state)
            periodic = old == 0 or elapsed > 2_000_000
            expected = []
            if periodic: expected.append((state, new & 255))
            if result != state: expected.append((result, new & 255))
            reports = "@[" + ", ".join(f"(0x43'u16, 0'u8, {s}'u8, {r}'u8, 0'u16)" for s, r in expected) + "]"
            checks += f'''
setup({old}, {threshold}, {hysteresis}, {state})
clock = {elapsed}
mm_check_rssi(addr vifs[0], {new})
doAssert vifs[0].rssiLast == {new} and vifs[0].rssiState == {result}
doAssert reports == {reports}
doAssert reportTime == {elapsed if periodic else 0}'u32
doAssert enabled
'''
    checks += r'''
setup()
reportTime = 0xFFF00000'u32
clock = reportTime + 2_000_001'u32
mm_check_rssi(addr vifs[0], -50)
doAssert reports.len == 1 and reportTime == clock
'''
    run_program(tmp_path, mode, source() + checks)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_rssi_callbacks_do_not_touch_replacement_vif(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for periodic in [false, true]:
  for allocationBoundary in [false, true]:
    for incoming in [false, true]:
      setup(if periodic: 0'i8 else: -50'i8)
      enabled = incoming
      if allocationBoundary: onAllocate = recycle
      else: onSend = recycle
      mm_check_rssi(addr vifs[0], -75)
      doAssert vifs[0].rssiLast == -10 and vifs[0].rssiState == 7
      doAssert reports.len == (if allocationBoundary: 0 else: 1)
      doAssert freed == allocationBoundary.int and attempts == 1
      doAssert enabled == incoming
      if allocationBoundary: doAssert reportTime == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_nested_rssi_and_allocation_failure_preserve_report_state(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
onAllocate = proc() = mm_check_rssi(addr vifs[0], -40)
mm_check_rssi(addr vifs[0], -75)
doAssert reports.len == 0 and freed == 1
doAssert vifs[0].rssiLast == -40 and vifs[0].rssiState == 0
setup()
onAllocate = proc() = mm_check_rssi(addr vifs[0], -75)
mm_check_rssi(addr vifs[0], -75)
doAssert reports.len == 1 and reports[0].state == 1 and freed == 0
doAssert vifs[0].rssiLast == -75 and vifs[0].rssiState == 1
setup()
onSend = proc() = mm_check_rssi(addr vifs[0], -40)
mm_check_rssi(addr vifs[0], -75)
doAssert reports.len == 2 and reports[0].state == 1 and reports[1].state == 0
doAssert vifs[0].rssiLast == -40 and vifs[0].rssiState == 0
setup()
failAllocation = true
mm_check_rssi(addr vifs[0], -75)
doAssert reports.len == 0 and vifs[0].rssiState == 0 and reportTime == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_nested_other_vif_does_not_roll_back_periodic_clock(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup(0, 0)
clock = 1000
onAllocate = proc() =
  clock = 2_500_000
  mm_check_rssi(addr vifs[1], -40)
  clock = 1000
mm_check_rssi(addr vifs[0], -50)
doAssert reports.len == 2 and reports[0].vif == 1 and reports[1].vif == 0
doAssert reportTime == 2_500_000
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_connection_loss_is_bound_to_original_vif(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [false, true]:
  setup()
  enabled = incoming
  mm_send_connection_loss_ind(addr vifs[0], 22)
  doAssert reports == @[(0x31'u16, 0'u8, 0'u8, 0'u8, 22'u16)]
  doAssert enabled == incoming
  setup()
  enabled = incoming
  onAllocate = recycle
  mm_send_connection_loss_ind(addr vifs[0], 22)
  doAssert reports.len == 0 and freed == 1 and enabled == incoming
setup()
mm_send_connection_loss_ind(nil, 22)
mm_check_rssi(nil, -50)
doAssert attempts == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_station_replacement_on_same_vif_cancels_notification(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for loss in [false, true]:
  for binding in [false, true]:
    setup()
    onAllocate = proc() =
      if binding: vifs[0].staIdx = 1
      else: inc stationEpochs[0]
    if loss: mm_send_connection_loss_ind(addr vifs[0], 22)
    else: mm_check_rssi(addr vifs[0], -75)
    doAssert reports.len == 0 and freed == 1
    doAssert vifs[0].rssiState == 0 and enabled
''')
