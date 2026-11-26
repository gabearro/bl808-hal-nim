"""Check U-APSD timeout, trigger selection, and timer restart behavior."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const
  VIF_TYPE_STA = 0'u8
  MAX_VIFS = 3
  STA_INFO_TAB_ENTRIES = 8
  MACHW_TIMLO_REG = 0x24B00120'u
type
  Vif = object
    next, chanCtxt: pointer
    flags, psLastTime: uint32
    vifType, state, uapsdBitmap, staIdx, vifIdx: uint8
  VifEnv = object
    activeList: tuple[first: pointer]
  MmTimerMutation = object
    cancelled: bool
var
  ps: PsEnvView
  vifs: array[3, Vif]
  vifEnv: VifEnv
  txResetEpoch: uint32
  rxVifEpochs: array[MAX_VIFS, uint32]
  stationEpochs: array[STA_INFO_TAB_ENTRIES, uint32]
  onChannel: array[3, bool]
  clocks: seq[uint32]
  clockIndex: int
  logging: bool
  lookups: int
  sendResult: uint8
  sends: seq[tuple[station: uint8, qos: uint16]]
  schedules: seq[uint32]
  messages: seq[string]
  events: seq[string]
  retireOnLog, retireOnSend: bool
  resetOnSend: bool
  replaceOnLog, clearOnArm: bool
  delivery: MmTimerMutation
  interruptsEnabled: bool
  mutateFlagsOnSend: bool

proc psEnvView(): ptr PsEnvView = addr ps
proc vifMgmtEnvView(): ptr VifEnv = addr vifEnv
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc staDeleteEpoch(index: uint8): uint32 = stationEpochs[index]
proc retireFirstVif() =
  inc rxVifEpochs[0]
  inc stationEpochs[1]
  vifEnv.activeList.first = vifs[0].next
  vifs[0].state = 0
proc chan_is_on_channel(p: pointer): bool =
  for index in 0 ..< vifs.len:
    if p == addr vifs[index]:
      events.add("channel:" & $index)
      return onChannel[index]
  raiseAssert "unexpected VIF pointer"
proc chan_is_on_operational_channel(p: pointer): bool = chan_is_on_channel(p)
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_TIMLO_REG and clockIndex < clocks.len
  result = clocks[clockIndex]
  inc clockIndex
  events.add("time:" & $result)
proc macTimeNow(): uint32 = regRead(MACHW_TIMLO_REG)
proc irqSave(): uint32 =
  result = if interruptsEnabled: 8'u32 else: 0'u32
  interruptsEnabled = false
proc irqRestore(saved: uint32) = interruptsEnabled = saved != 0
proc mmTimerActiveDelivery(timer: pointer): ptr MmTimerMutation =
  doAssert timer == psUapsdTimer()
  addr delivery
proc mm_timer_set(timer: pointer; expiry: uint32) =
  doAssert timer == psUapsdTimer()
  schedules.add(expiry)
  events.add("schedule:" & $expiry)
  if clearOnArm:
    clearOnArm = false
    inc txResetEpoch
    schedules.setLen(0)
    ps.uapsdTimerActive = 0
proc mmTimerSetLocked(timer: pointer; expiry, saved: uint32) =
  doAssert not interruptsEnabled
  irqRestore(saved)
  mm_timer_set(timer, expiry)
  discard irqSave()
proc txlSendUapsdTrigger(station: uint8; qos: uint16; callback: pointer): uint8 =
  doAssert callback == nil
  for vif in vifs:
    if vif.staIdx == station: doAssert (vif.flags and 8) != 0
  sends.add((station, qos))
  events.add("send:" & $station)
  if mutateFlagsOnSend and station == 1:
    vifs[0].flags = vifs[0].flags or 2'u32
  if retireOnSend and station == 1:
    retireFirstVif()
  if resetOnSend:
    # The trigger's allocation recovery flushed AC3 and a protection
    # completion reset TX (PS-N2).
    inc txResetEpoch
  sendResult

{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc logWrite(level: uint32; tag, file: cstring; line: cint; format: cstring)
    {.cdecl, varargs.} =
  doAssert level == 1 and tag == nil and file == cstring("ps.c")
  doAssert line == 567 and format == cstring("apsd timer: UAPSD\r\n")
  var output: array[64, char]
  var length: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", length,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert length == 19
  messages.add($cast[cstring](addr output[0]))
  events.add("log")
  if retireOnLog:
    retireOnLog = false
    retireFirstVif()
  if replaceOnLog:
    delivery.cancelled = true
    schedules.add(999)
proc getLogFunc(slot: int): pointer =
  doAssert slot == 204
  inc lookups
  if logging: cast[pointer](logWrite) else: nil
proc setup() =
  ps = PsEnvView(enabled: 1, uapsdTimerActive: 1, psActive: 1,
                 uapsdTimerState: 0xA5, uapsdPeriod: 20)
  vifs = default(typeof(vifs))
  txResetEpoch = 0
  rxVifEpochs = default(typeof(rxVifEpochs))
  stationEpochs = default(typeof(stationEpochs))
  for index in 0 ..< vifs.len:
    vifs[index] = Vif(state: 1, uapsdBitmap: 8, staIdx: (index + 1).uint8,
                      vifIdx: index.uint8, flags: 0x80000000'u32,
                      psLastTime: 100)
  vifEnv.activeList.first = addr vifs[0]
  onChannel = [true, true, true]
  clocks.setLen(0)
  clockIndex = 0
  logging = false
  lookups = 0
  sendResult = 0
  sends.setLen(0)
  schedules.setLen(0)
  messages.setLen(0)
  events.setLen(0)
  retireOnLog = false
  retireOnSend = false
  resetOnSend = false
  replaceOnLog = false
  clearOnArm = false
  delivery = default(MmTimerMutation)
  interruptsEnabled = true
  mutateFlagsOnSend = false
'''


def source(*, real_channel: bool = False) -> str:
    layout = (FW / "layout_types.nim").read_text()
    logger_type = (FW / "global_state/c_runtime.nim").read_text().split("# Helper:", 1)[0]
    ps_type = "type\n  PsEnvView" + layout.split("  PsEnvView", 1)[1].split(
        "\n\n  ", 1
    )[0] + "\n"
    vif_identity = "type\n  MmVifIdentity" + layout.split("  MmVifIdentity", 1)[1].split(
        "\n\n  ", 1
    )[0] + "\n"
    timer = "template psUapsdTimer" + layout.split(
        "template psUapsdTimer", 1
    )[1].split("\ntemplate ", 1)[0]
    power = (FW / "power_save.nim").read_text()
    mac = (FW / "kernel_mac_channel.nim").read_text()
    # The production view retains native pointers in host tests. M0 builds
    # separately enforce its 32-bit field offsets.
    platform = PLATFORM.replace("proc mmTimerActiveDelivery", timer + "\nproc mmTimerActiveDelivery")
    if real_channel:
        for name in ("chan_is_on_channel", "chan_is_on_operational_channel"):
            platform = platform.replace(procedure(platform, name), "")
        platform += r'''
type Channel = object
  contextIndexOrMarker, altIdx: uint8
var channelEnv: tuple[currentCtxt: pointer]
proc chanEnvView(): ptr typeof(channelEnv) = addr channelEnv
proc chanCtxtAt(p: pointer): ptr Channel = cast[ptr Channel](p)
'''
        for name in ("chan_is_on_channel", "chan_is_on_operational_channel"):
            platform += procedure(mac, name)
    return (ps_type + vif_identity + logger_type + platform
            + procedure(mac, "mmVifCurrent")
            + procedure(power, "ps_uapsd_set")
            + procedure(power, "psUapsdTimerCurrent")
            + procedure(power, "psUapsdPeerCurrent")
            + procedure(power, "psUapsdTriggerTid")
            + procedure(power, "ps_uapsd_timer_handle"))


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_expiry_boundaries_and_trigger_tid(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for last in [0'u32, 100, 0xFFFFFFF8'u32]:
  for period in [0'u32, 1, 20, 21]:
    for offset in [-1, 0, 1]:
      for status in [0'u8, 1]:
        setup()
        ps.uapsdPeriod = period
        vifs[0].psLastTime = last
        sendResult = status
        let deadline = last + period div 2
        let now = if offset < 0: deadline - 1 else: deadline + offset.uint32
        let due = offset == 1
        clocks = if due and status == 0: @[now, now + 2, now + 5] else: @[now, now + 5]
        ps_uapsd_timer_handle()
        if due:
          doAssert sends == @[(1'u8, 7'u16)]
          doAssert lookups == 1
          doAssert vifs[0].flags == (if status == 0: 0x80000008'u32 else: 0x80000000'u32)
          doAssert vifs[0].psLastTime == (if status == 0: now + 2 else: last)
        else:
          doAssert sends.len == 0 and vifs[0].flags == 0x80000000'u32
          doAssert vifs[0].psLastTime == last and lookups == 0
        doAssert schedules == @[now + 5 + period]
        doAssert clockIndex == clocks.len
        doAssert ps.uapsdTimerActive == 1 and ps.uapsdTimerState == 0xA5
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_trigger_tid_uses_an_enabled_category(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
const preferredTid = [0'u16, 1, 0, 0, 4, 4, 4, 4, 7, 7, 7, 7, 7, 7, 7, 7]
for extraBits in [0'u8, 0xF0]:
  for mask in 0'u8 .. 15:
    setup()
    vifs[0].uapsdBitmap = mask or extraBits
    clocks = @[111'u32, 120, 130]
    ps_uapsd_timer_handle()
    if mask == 0:
      doAssert sends.len == 0 and schedules.len == 0
      doAssert ps.uapsdTimerActive == 0
    else:
      doAssert sends == @[(1'u8, preferredTid[mask])]
      doAssert schedules == @[150'u32]

setup()
vifs[0].next = addr vifs[1]
vifs[0].uapsdBitmap = 2
vifs[1].uapsdBitmap = 4
clocks = @[111'u32, 120, 130, 140, 150]
ps_uapsd_timer_handle()
doAssert sends == @[(1'u8, 0'u16), (2'u8, 4'u16)]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_each_vif_uses_current_time(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
vifs[0].next = addr vifs[1]
vifs[0].psLastTime = 0
vifs[1].psLastTime = 12
clocks = @[11'u32, 20, 30, 40, 50]
ps_uapsd_timer_handle()
doAssert sends == @[(1'u8, 7'u16), (2'u8, 7'u16)]
doAssert vifs[0].psLastTime == 20 and vifs[1].psLastTime == 40
doAssert schedules == @[70'u32] and clockIndex == 5
doAssert events == @["channel:0", "time:11", "send:1", "time:20",
                      "channel:1", "time:30", "send:2", "time:40",
                      "time:50", "schedule:70"]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_callback_retirement_skips_stale_vif_and_continues(tmp_path: Path, mode: str) -> None:
    for retire_at in ("log", "send"):
        run_program(tmp_path, mode, source() + f'''
setup()
vifs[0].next = addr vifs[1]
vifs[0].psLastTime = 0
vifs[1].psLastTime = 0
logging = true
retireOnLog = {str(retire_at == "log").lower()}
retireOnSend = {str(retire_at == "send").lower()}
clocks = @[11'u32, 20, 30, 40]
ps_uapsd_timer_handle()
doAssert rxVifEpochs[0] == 1 and stationEpochs[1] == 1
doAssert vifs[0].psLastTime == 0
doAssert vifs[1].psLastTime == 30
doAssert sends == {"@[(2'u8, 7'u16)]" if retire_at == "log" else "@[(1'u8, 7'u16), (2'u8, 7'u16)]"}
doAssert schedules == @[60'u32] and clockIndex == clocks.len
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_retired_only_vif_stops_timer(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
logging = true
retireOnLog = true
vifs[0].psLastTime = 0
clocks = @[11'u32]
ps_uapsd_timer_handle()
doAssert sends.len == 0 and schedules.len == 0
doAssert ps.uapsdTimerActive == 0 and clockIndex == 1
doAssert vifs[0].psLastTime == 0 and vifs[0].flags == 0x80000000'u32
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_failed_send_preserves_other_flag_changes(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for pending in [0'u32, 8]:
  setup()
  vifs[0].flags = vifs[0].flags or pending
  vifs[0].psLastTime = 0
  sendResult = 1
  mutateFlagsOnSend = true
  clocks = @[11'u32, 30, 40]
  ps_uapsd_timer_handle()
  doAssert sends == @[(1'u8, 7'u16)]
  doAssert vifs[0].flags == (0x80000002'u32 or pending) and vifs[0].psLastTime == 0
  doAssert schedules == @[50'u32] and clockIndex == 2
  doAssert ps.uapsdTimerActive == 1
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tx_reset_inside_a_trigger_keeps_the_timer(tmp_path: Path, mode: str) -> None:
    """PS-N2: a TX reset inside the trigger's submission does not end the
    trigger timer; it was left marked active with nothing armed, and
    ps_uapsd_set never armed it again. A stopped timer does not send."""
    run_program(tmp_path, mode, source() + r'''
setup()
resetOnSend = true
vifs[0].psLastTime = 0
clocks = @[11'u32, 20, 30]
ps_uapsd_timer_handle()
doAssert txResetEpoch == 1 and sends == @[(1'u8, 7'u16)]
doAssert vifs[0].flags == 0x80000008'u32 and vifs[0].psLastTime == 20
doAssert schedules == @[50'u32] and ps.uapsdTimerActive == 1
doAssert clockIndex == 3

setup()
ps.uapsdTimerActive = 0
clocks = @[11'u32]
ps_uapsd_timer_handle()
doAssert sends.len == 0 and schedules.len == 0 and clockIndex == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_stopped_timer_can_restart(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for reason in 0 .. 3:
  setup()
  clocks = @[77'u32]
  case reason
  of 0: vifEnv.activeList.first = nil
  of 1: vifs[0].vifType = 2
  of 2: vifs[0].state = 0
  of 3: vifs[0].uapsdBitmap = 0
  else: discard
  ps_uapsd_timer_handle()
  doAssert ps.uapsdTimerActive == 0 and ps.uapsdTimerState == 0xA5
  doAssert ps.psActive == 1 and schedules.len == 0
  doAssert clockIndex == 0 and sends.len == 0 and lookups == 0

  # Exercise the real re-arm guard in ps_uapsd_set after the timer stopped.
  clocks = @[200'u32]
  ps_uapsd_set(addr vifs[0], 3, 1)
  doAssert ps.uapsdTimerActive == 1 and ps.uapsdTimerState == 0xA5
  doAssert (vifs[0].uapsdBitmap and 8) != 0 and schedules == @[220'u32]
  ps_uapsd_set(addr vifs[0], 3, 1)
  doAssert schedules.len == 1 and clockIndex == 1
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_off_channel_timeout_rearms_until_station_returns(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
clocks = @[111'u32, 131, 151, 152, 153]
onChannel[0] = false
ps_uapsd_timer_handle()
ps_uapsd_timer_handle()
doAssert ps.uapsdTimerActive == 1 and schedules == @[131'u32, 151]
doAssert sends.len == 0 and lookups == 0 and clockIndex == 2
doAssert vifs[0].psLastTime == 100 and vifs[0].flags == 0x80000000'u32

onChannel[0] = true
ps_uapsd_timer_handle()
doAssert sends == @[(1'u8, 7'u16)] and vifs[0].psLastTime == 152
doAssert schedules == @[131'u32, 151, 173] and clockIndex == clocks.len
doAssert interruptsEnabled
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_same_vif_scan_or_roc_does_not_send_trigger(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(real_channel=True) + r'''
for marker in [3'u8, 4]:
  setup()
  var home = Channel(contextIndexOrMarker: 0)
  var dwell = Channel(contextIndexOrMarker: marker, altIdx: 0)
  vifs[0].chanCtxt = addr home
  channelEnv.currentCtxt = addr dwell
  doAssert chan_is_on_channel(addr vifs[0])
  doAssert not chan_is_on_operational_channel(addr vifs[0])
  clocks = @[111'u32, 131, 132, 133]
  ps_uapsd_timer_handle()
  doAssert sends.len == 0 and vifs[0].psLastTime == 100
  doAssert vifs[0].flags == 0x80000000'u32 and schedules == @[131'u32]
  channelEnv.currentCtxt = addr home
  ps_uapsd_timer_handle()
  doAssert sends == @[(1'u8, 7'u16)] and vifs[0].psLastTime == 132
  doAssert schedules == @[131'u32, 153] and clockIndex == clocks.len
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reentrant_timer_replacement_preserves_new_state(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
logging = true
replaceOnLog = true
clocks = @[111'u32, 112, 113]
ps_uapsd_timer_handle()
doAssert delivery.cancelled and ps.uapsdTimerActive == 1
doAssert sends.len == 0 and schedules == @[999'u32] and clockIndex == 1
doAssert vifs[0].psLastTime == 100 and vifs[0].flags == 0x80000000'u32

setup()
ps.uapsdTimerActive = 0
clearOnArm = true
clocks = @[200'u32, 210]
ps_uapsd_set(addr vifs[0], 3, 1)
doAssert txResetEpoch == 1 and ps.uapsdTimerActive == 0 and schedules.len == 0
ps_uapsd_set(addr vifs[0], 3, 1)
doAssert ps.uapsdTimerActive == 1 and schedules == @[230'u32]
doAssert interruptsEnabled
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_invalid_uapsd_arguments_leave_state_unchanged(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for ac in [4'u8, 7, 8, 255]:
  for enabled in [0'u32, 1]:
    setup()
    ps.uapsdTimerActive = 0
    vifs[0].uapsdBitmap = 0
    clocks = @[200'u32]
    let beforePs = ps
    let beforeVif = vifs[0]
    ps_uapsd_set(addr vifs[0], ac, enabled)
    doAssert ps == beforePs and vifs[0] == beforeVif
    doAssert schedules.len == 0 and clockIndex == 0
    doAssert events.len == 0

setup()
ps.uapsdTimerActive = 0
let beforePs = ps
ps_uapsd_set(nil, 0, 1)
doAssert ps == beforePs and schedules.len == 0 and events.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_logging_and_ineligible_vifs(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
logging = true
clocks = @[111'u32, 123, 130]
ps_uapsd_timer_handle()
doAssert messages == @["apsd timer: UAPSD\r\n"]
doAssert events == @["channel:0", "time:111", "log", "send:1", "time:123",
                      "time:130", "schedule:150"]
doAssert sends == @[(1'u8, 7'u16)]

for gate in 0 .. 3:
  setup()
  vifs[0].next = addr vifs[1]
  case gate
  of 0: vifs[0].vifType = 2
  of 1: vifs[0].state = 0
  of 2: vifs[0].uapsdBitmap = 0
  of 3: onChannel[0] = false
  else: discard
  clocks = @[111'u32, 120, 130]
  ps_uapsd_timer_handle()
  doAssert sends == @[(2'u8, 7'u16)] and schedules == @[150'u32]
  doAssert vifs[0].psLastTime == 100 and vifs[0].flags == 0x80000000'u32
  doAssert clockIndex == 3 and ps.uapsdTimerActive == 1
''')
