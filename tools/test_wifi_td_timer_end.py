"""Check traffic timer transitions against td.o's branch behavior.

td_timer_end re-arms its own timer unless td_cfm_set_timer armed it for the
same VIF during the traffic update (tdCfmArmed); td.o passes that back as the
update's return value. Nothing it calls can retire its VIF or entry, and it
does not look at the TX reset epoch.
"""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n"
    for name in ["TdEntryView", "BlPsParamsView"]:
        types += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    helpers = procedure(layout, "clearTrafficCounters").split("\nstatic:", 1)[0]
    return types + r'''
const
  MACHW_TIMLO_REG = 0x24B00120'u
  MAX_VIFS = 2
type
  Vif = object
    chanCtxt: pointer
var
  td: TdEntryView
  params: BlPsParamsView
  vif: Vif
  channel: tuple[currentCtxt: pointer]
  now: uint32
  postResult, updateResult: uint32
  postCalls: int
  notifications: seq[tuple[vifIdx: uint8, status: uint32]]
  schedules: seq[uint32]
  tdCfmArmed: array[MAX_VIFS, bool]
  onPost, onUpdate: proc()
proc blPsParamsView(): ptr BlPsParamsView = addr params
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_TIMLO_REG
  now
proc wifi_hosal_pm_post_event(typ, sev: uint32; output: pointer) =
  doAssert typ == 4 and sev == 0 and output != nil
  inc postCalls
  cast[ptr uint32](output)[] = postResult
  if onPost != nil: onPost()
proc ps_traffic_status_update(vifIdx: uint8; status: uint32): uint32 =
  notifications.add((vifIdx, status))
  if onUpdate != nil: onUpdate()
  updateResult
proc blOpsFunc(slot: int): pointer =
  doAssert slot == 204
  nil
proc vifChannelForIdx(index: uint8): ptr Vif =
  doAssert index == 1
  addr vif
proc chanEnvView(): ptr typeof(channel) = addr channel
proc mm_timer_set(entry: pointer; expiry: uint32) =
  doAssert entry == addr td
  schedules.add(expiry)
template tdEntryAt(p: pointer): ptr TdEntryView = cast[ptr TdEntryView](p)
proc tdEntryForVif(index: uint8): ptr TdEntryView =
  doAssert index == 1
  addr td
''' + helpers + "".join(procedure((FW / "traffic_detection.nim").read_text(), name)
                        for name in ("td_cfm_set_timer",)) + procedure(
        (FW / "power_save.nim").read_text(), "td_timer_end")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_traffic_timer_end(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
params.trafficPeriod = 1000
params.trafficThreshold = 3
now = 0xFFFF_FFF0'u32
channel.currentCtxt = cast[pointer](0x1234'u)
vif.chanCtxt = channel.currentCtxt

# The inactive latch skips the host event and still clears and rearms.
td = TdEntryView(vifIdx: 1, endActive: 0, prevFlags: 12,
  rxCount: 4, txCount: 4, psRxCount: 4, psTxCount: 4)
td_timer_end(addr td)
doAssert postCalls == 0 and notifications.len == 0
doAssert td.prevFlags == 12 and td.endActive == 1
doAssert td.rxCount == 0 and td.txCount == 0 and
  td.psRxCount == 0 and td.psTxCount == 0
doAssert schedules == @[0x3D8'u32]

# Threshold equality sets both ordinary and power-save direction bits.
schedules.setLen(0)
td = TdEntryView(vifIdx: 1, endActive: 1, rxCount: 3, txCount: 2,
  psRxCount: 3, psTxCount: 2)
td_timer_end(addr td)
doAssert postCalls == 1 and notifications == @[(1'u8, 4'u32)]
doAssert td.prevFlags == 5 and td.endActive == 1
doAssert schedules == @[0x3D8'u32]

# A nonzero host response forwards the pending-period flag. The transition
# result alone does not transfer this timer, even if the VIF loses its channel.
schedules.setLen(0)
notifications.setLen(0)
postResult = 1
updateResult = 1
vif.chanCtxt = nil
td = TdEntryView(vifIdx: 1, endActive: 1, period: 40,
  psTxCount: 3, prevFlags: 4)
td_timer_end(addr td)
doAssert postCalls == 2 and notifications == @[(1'u8, 1'u32)]
doAssert td.prevFlags == 8 and td.endActive == 0
doAssert td.period == 40 and td.psTxCount == 0
doAssert schedules == @[0x3D8'u32]

# Without a changed power-save direction, there is no notification.
schedules.setLen(0)
postResult = 0
updateResult = 0
td = TdEntryView(vifIdx: 1, endActive: 1, prevFlags: 8, psTxCount: 3)
td_timer_end(addr td)
doAssert postCalls == 3 and notifications.len == 1
doAssert td.prevFlags == 8 and td.endActive == 0
doAssert schedules == @[0x3D8'u32]
''')


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_timer_end_rejects_invalid_entries(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
td = TdEntryView(vifIdx: 255, endActive: 1, rxCount: 3)
let previousPosts = postCalls
td_timer_end(addr td)
td_timer_end(nil)
doAssert postCalls == previousPosts and td.rxCount == 3
''')


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_synchronous_confirmation_preserves_idle_edge(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
params.trafficPeriod = 1000
params.trafficThreshold = 3
channel.currentCtxt = cast[pointer](0x1234'u)
vif.chanCtxt = channel.currentCtxt
schedules.setLen(0)
notifications.setLen(0)
now = 1000
postResult = 1
updateResult = 1
td = TdEntryView(vifIdx: 1, active: 1, endActive: 1, period: 40, rxCount: 3)
onUpdate = proc() = td_cfm_set_timer(1, 1)
td_timer_end(addr td)
doAssert notifications == @[(1'u8, 1'u32)]
doAssert schedules == @[1040'u32], "periodic timer overwrote the PS confirmation"
doAssert td.prevFlags == 9 and td.rxCount == 0 and td.period == 0
doAssert td.endActive == 1
onUpdate = nil
now = 1040
postResult = 0
updateResult = 0
td_timer_end(addr td)
doAssert notifications == @[(1'u8, 1'u32), (1'u8, 0'u32)],
  "idle edge was not delivered to dynamic PS"
doAssert td.prevFlags == 0 and schedules == @[1040'u32, 2040'u32]
''')


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_confirmation_without_override_keeps_periodic_sampling(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
params.trafficPeriod = 1000
params.trafficThreshold = 3
channel.currentCtxt = cast[pointer](0x1234'u)
vif.chanCtxt = channel.currentCtxt
now = 1000
updateResult = 1
td = TdEntryView(vifIdx: 1, active: 1, endActive: 1, psTxCount: 3)
onUpdate = proc() = td_cfm_set_timer(1, 0)
td_timer_end(addr td)
doAssert notifications == @[(1'u8, 8'u32)]
doAssert td.prevFlags == 8 and td.psTxCount == 0 and td.period == 0
doAssert schedules == @[2000'u32], "wake without TIM override lost the periodic timer"

onUpdate = nil
updateResult = 0
now = 2000
td_timer_end(addr td)
doAssert notifications == @[(1'u8, 8'u32), (1'u8, 0'u32)]
doAssert td.prevFlags == 0 and schedules == @[2000'u32, 3000]
''')
