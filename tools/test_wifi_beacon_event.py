"""Check beacon timer logging, TBTT event ordering, and TX clear cleanup."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
import std/sequtils
const
  MACHW_TIMLO_REG = 0x24B00120'u
  VIF_TYPE_AP = 2'u8
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
type
  PlatformLogFunc = proc(level: uint32; sev: uint32; file: pointer;
                         line: uint32) {.cdecl, varargs.}
  Timer = object
    expiry: uint32
  Vif = object
    next, chanCtxt: pointer
    vifIdx, vifType, state, staIdx, probeCount, beaconCountdown, beaconDivisor: uint8
    flags, tbttCount, beaconLossCount, beaconRxCount: uint32
    apBeaconInterval: uint16
    tbttTimer, keepAliveTimer: Timer
  Sta = object
    initialRateConfig: uint32
    valid, instNbr: uint8
  MmEnv = object
    keepAliveInterval: uint32
  VifEnv = object
    activeList: tuple[first: pointer]
  Message = tuple[line: cint, text: string]
var
  vifs: array[2, Vif]
  stations: array[7, Sta]
  mm: MmEnv
  env: VifEnv
  keEvtField: uint32
  mmTbttAgingCount0, mmTbttAgingCount1: uint8
  logging, failLog: bool
  onLog: proc(line: cint)
  onTimerArm: proc(timer: ptr Timer)
  logLookups: int
  messages: seq[Message]
  assertions: seq[tuple[condition, file: string, line: cint]]
  interrupts: bool
  operations: seq[string]
  failure: string
  clockValue, beaconOffset: uint32
  switchTimes: seq[uint32]
  programmed: seq[pointer]
  aged: int
  rxVifEpochs: array[2, uint32]
  stationEpochs: array[7, uint32]
  txResetEpoch: uint32
  resetting: bool
  retiring: array[2, bool]
  mmTbttActive: bool
  mmBeaconProbeEpochs: array[MAX_VIFS, uint32]
  mmTimerMutationTop: ptr MmTimerMutation

template keEnvEventField(): ptr uint32 = addr keEvtField

proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
proc staDeleteEpoch(i: uint8): uint32 =
  if i < stationEpochs.len.uint8: stationEpochs[i] else: 0
proc txlResetting(): bool = resetting
proc txlVifIsRetiring(i: uint8): bool = retiring[i]
proc vifMgmtEnvView(): ptr VifEnv = addr env
proc staInfoForIdx(index: uint8): ptr Sta = addr stations[index]
proc mmEnvView(): ptr MmEnv = addr mm
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc irqSave(): uint32 =
  result = if interrupts: 8'u32 else: 0'u32
  interrupts = false
  operations.add("save")
proc irqRestore(saved: uint32) =
  interrupts = (saved and 8) != 0
  operations.add("restore")
proc txl_cntrl_halt_ac(ac: uint8): bool =
  doAssert ac == 4 and not interrupts
  operations.add("halt")
  if failure == "halt": raise newException(ValueError, "halt observation stopped")
  true
proc txl_cntrl_flush_ac(ac: uint8; mask: uint32) =
  doAssert ac == 4 and mask == 0x40000000'u32 and not interrupts
  operations.add("flush")
  if failure == "flush": raise newException(ValueError, "completion stopped")
proc assert_err(condition, file: cstring; line: cint) =
  assertions.add(($condition, $file, line))
  operations.add("assert")
proc ke_evt_clear(mask: uint32) =
  operations.add("clear")
  keEvtField = keEvtField and not mask
proc regRead(address: uint): uint32 =
  case address
  of MACHW_TIMLO_REG: clockValue
  of 0x24B08040'u: beaconOffset
  else: raiseAssert "unexpected register"
proc vif_mgmt_bcn_to_prog(p: pointer) =
  operations.add("program")
  programmed.add(p)
proc chan_tbtt_switch_update(p: pointer; expiry: uint32) =
  doAssert p == (addr vifs[0]) or p == (addr vifs[1])
  operations.add("switch")
  switchTimes.add(expiry)
proc mm_bcn_transmit(index: uint8) =
  doAssert index == 0
  operations.add("transmit")
proc sta_mgmt_aging_postponed_desc(p: pointer; status: uint32): uint32 =
  doAssert p == nil and status == 0
  inc aged
  operations.add("age")
proc mm_timer_set(timer: ptr Timer; expiry: uint32) =
  timer.expiry = expiry
  operations.add("timer")
  if onTimerArm != nil: onTimerArm(timer)
proc mmTimerSetLocked(timer: pointer; expiry, saved: uint32) =
  doAssert not interrupts
  irqRestore(saved)
  try: mm_timer_set(cast[ptr Timer](timer), expiry)
  finally: discard irqSave()
proc chan_is_on_channel(p: pointer): bool = false
proc ps_check_tbtt(p: pointer) = raiseAssert "unexpected on-channel operation"
proc mmStaBeaconProbeCfm(p: pointer; status: uint32) {.cdecl.} = discard
proc txl_frame_send_null_frame(sta: uint8; callback: pointer; arg: uint32): uint8 =
  raiseAssert "unexpected on-channel transmission"
proc wifi_hosal_pm_post_event(event, value: uint32; arg: pointer) =
  raiseAssert "unexpected on-channel power event"

{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc renderPointer(format: cstring; p: pointer): string =
  var output: array[128, char]
  var length: cint
  {.emit: [length, " = snprintf((char*)", output, ", sizeof(", output,
    "), ", format, ", ", p, ");"].}
  doAssert length > 0 and length < output.len.cint
  $cast[cstring](addr output[0])
proc logMessage(level: uint32; tag, file: cstring; line: cint; format: cstring)
    {.cdecl, varargs.} =
  doAssert level == 1 and tag == nil and file == cstring("mm.c"),
    "beacon logging metadata differs from the vendor"
  doAssert format != nil, "beacon logger received a nil format"
  case line
  of 600: doAssert format == cstring("beacon timeout %p\r\n")
  of 611: doAssert format == cstring("data timeout %p\r\n")
  of 624: doAssert format == cstring("mm_sta_tbtt\r\n")
  of 898: doAssert format == cstring("mm_tbtt_evt\r\n")
  else: raiseAssert "unexpected beacon log line"
  var output: array[128, char]
  var length: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", length,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert length > 0 and length < output.len.cint
  messages.add((line, $cast[cstring](addr output[0])))
  operations.add("log")
  if onLog != nil: onLog(line)
  if failLog: raise newException(ValueError, "logger stopped")
proc getLogFunc(slot: int): PlatformLogFunc =
  doAssert slot == 204
  inc logLookups
  if logging: cast[PlatformLogFunc](logMessage) else: nil
proc setup() =
  vifs = default(typeof(vifs))
  stations = default(typeof(stations))
  rxVifEpochs = default(typeof(rxVifEpochs))
  stationEpochs = default(typeof(stationEpochs))
  txResetEpoch = 0
  resetting = false
  retiring = default(typeof(retiring))
  mmTbttActive = false
  mmTimerMutationTop = nil
  for i in 0 ..< vifs.len: vifs[i].vifIdx = i.uint8
  for sta in stations.mitems: sta.valid = 1
  mm = default(MmEnv)
  env = default(VifEnv)
  keEvtField = 0x01000020'u32
  mmTbttAgingCount0 = 2
  mmTbttAgingCount1 = 10
  logging = false
  failLog = false
  onLog = nil
  onTimerArm = nil
  logLookups = 0
  messages.setLen(0)
  assertions.setLen(0)
  interrupts = true
  operations.setLen(0)
  failure = ""
  clockValue = 0xFFFFFF00'u32
  beaconOffset = 0x80000003'u32
  switchTimes.setLen(0)
  programmed.setLen(0)
  aged = 0
'''


def source() -> str:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    tx = (FW / "tx_layer.nim").read_text()
    layout = (FW / "layout_types.nim").read_text()
    types = "".join(re.search(rf"(?ms)^  {name}\b.*?(?=^  \w|\Z)", layout).group()
                    for name in ("MmVifIdentity", "MmTimerMutation"))
    code = procedure(tx, "txl_cntrl_clear_bcn_ac")
    for name in ["mmCaptureVif", "mmVifCurrent", "mmTimerActiveDelivery", "mmStaTimerCurrent",
                 "mmStaTbttCurrent"]:
        if re.search(r"^proc " + name + r"\(", kernel, re.M):
            code += procedure(kernel, name)
    for name in ("mm_sta_tbtt", "mm_tbtt_evt", "mm_sta_timer_bcn_timeout",
                 "mm_sta_timer_data_timeout"):
        code += procedure(kernel, name)
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n"
        for name in sorted(set(re.findall(r"\bnimFwDbg\w+", code)))
    )
    return "type\n" + types + PLATFORM + debug + code


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "goto"])
def test_timer_logs_use_vendor_formats_and_preserve_state(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for enabled in [false, true]:
  for previous in [0'u32, 7, 0xFFFFFFFF'u32]:
    setup()
    logging = enabled
    let p = cast[pointer](addr vifs[0])
    vifs[0].flags = 0xA5A50003'u32
    vifs[0].beaconLossCount = previous
    mm_sta_timer_bcn_timeout(p)
    doAssert vifs[0].beaconLossCount == previous + 1
    doAssert vifs[0].flags == 0xA5A50002'u32
    mm_sta_timer_data_timeout(p)
    doAssert vifs[0].beaconLossCount == previous + 1
    doAssert vifs[0].flags == 0xA5A50002'u32
    mm_sta_tbtt(p)
    doAssert vifs[0].tbttCount == 0 and vifs[0].state == 0
    doAssert logLookups == 3
    if enabled:
      doAssert messages == @[
        (600.cint, renderPointer("beacon timeout %p\r\n", p)),
        (611.cint, renderPointer("data timeout %p\r\n", p)),
        (624.cint, "mm_sta_tbtt\r\n")]
      doAssert operations.filterIt(it notin ["save", "restore"]) == @["log", "log", "log"]
    else:
      doAssert messages.len == 0
      doAssert operations.filterIt(it notin ["save", "restore"]).len == 0
    doAssert interrupts

setup()
logging = true
vifs[0].state = 1
vifs[0].staIdx = 3
vifs[0].tbttTimer.expiry = 0xFFFFFF80'u32
stations[3].initialRateConfig = 1024
mm.keepAliveInterval = 500
mm_sta_tbtt(addr vifs[0])
doAssert vifs[0].tbttTimer.expiry == 0x380
doAssert vifs[0].keepAliveTimer.expiry == 244
doAssert vifs[0].tbttCount == 1
doAssert messages == @[(624.cint, "mm_sta_tbtt\r\n")]
doAssert operations.filterIt(it notin ["save", "restore"]) == @["log", "timer", "timer", "program", "switch"]
doAssert interrupts
''')


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_beacon_received_during_tbtt_rearm_supersedes_watchdog(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
let vif = addr vifs[0]
vif.state = 1
vif.staIdx = 3
vif.tbttTimer.expiry = 50
vif.beaconRxCount = high(uint32)
stations[3].initialRateConfig = 1024
mm.keepAliveInterval = 500
onTimerArm = proc(timer: ptr Timer) =
  if timer == addr vif.tbttTimer:
    doAssert interrupts
    inc vif.beaconRxCount
    # A valid Beacon advances its own TBTT and cancels the previous watchdog.
    vif.tbttTimer.expiry = 1200
    vif.keepAliveTimer.expiry = 0
mm_sta_tbtt(vif)
doAssert vif.beaconRxCount == 0 and vif.tbttTimer.expiry == 1200
doAssert vif.keepAliveTimer.expiry == 0, "old TBTT armed watchdog after Beacon"
doAssert interrupts
''')


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_beacon_received_during_timeout_log_prevents_false_miss(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
logging = true
let vif = addr vifs[0]
vif.state = 1
vif.flags = 1
vif.beaconLossCount = 41
onLog = proc(line: cint) =
  doAssert line == 600 and interrupts
  inc vif.beaconRxCount
mm_sta_timer_bcn_timeout(vif)
doAssert vif.beaconRxCount == 1
doAssert vif.beaconLossCount == 41 and vif.flags == 1, "old timeout marked new Beacon missed"
doAssert interrupts
''')


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_rearmed_delivery_cannot_mark_replacement_watchdog_expired(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for cancelBeforeCallback in [false, true]:
  setup()
  logging = true
  let vif = addr vifs[0]
  vif.state = 1
  vif.flags = 1
  vif.beaconLossCount = 41
  var delivery = MmTimerMutation(timer: addr vif.keepAliveTimer,
    delivering: true, cancelled: cancelBeforeCallback)
  mmTimerMutationTop = addr delivery
  onLog = proc(line: cint) =
    doAssert line == 600 and interrupts
    delivery.cancelled = true
  mm_sta_timer_bcn_timeout(vif)
  doAssert logLookups == (if cancelBeforeCallback: 0 else: 1)
  doAssert vif.beaconRxCount == 0 and vif.beaconLossCount == 41 and vif.flags == 1
  doAssert interrupts
  mmTimerMutationTop = nil
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "goto"])
def test_tbtt_event_order_and_beacon_timing(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for enabled in [false, true]:
  for incomingIrq in [false, true]:
    for eventMask in [0'u32, 0x01000000, 0x02000000, 0x03000000]:
      for countdown in [0'u8, 1, 2]:
        setup()
        logging = enabled
        interrupts = incomingIrq
        keEvtField = eventMask or 0x20
        mmTbttAgingCount0 = 1
        mmTbttAgingCount1 = 1
        env.activeList.first = addr vifs[0]
        vifs[0].vifType = VIF_TYPE_AP
        vifs[0].beaconCountdown = countdown
        vifs[0].beaconDivisor = 3
        vifs[0].apBeaconInterval = 100
        vifs[0].chanCtxt = addr mm
        vifs[0].next = addr vifs[1]
        vifs[1].vifType = 0
        vifs[1].beaconCountdown = 77
        mm_tbtt_evt()
        doAssert interrupts == incomingIrq
        doAssert keEvtField == 0x20 and logLookups == 1
        doAssert mmTbttAgingCount0 == 2 and mmTbttAgingCount1 == 10 and aged == 1
        doAssert vifs[1].beaconCountdown == 77
        var expected: seq[string]
        if enabled:
          expected.add("log")
          doAssert messages == @[(898.cint, "mm_tbtt_evt\r\n")]
        else: doAssert messages.len == 0
        if eventMask == 0x03000000'u32:
          expected.add("assert")
          doAssert assertions == @[("evt != MM_TBTT_EVT_MASK", "module", 902.cint)]
        else: doAssert assertions.len == 0
        expected.add(@["clear", "save", "halt", "flush", "restore"])
        if countdown == 1:
          expected.add(@["program", "switch"])
          doAssert programmed == @[cast[pointer](addr vifs[0])]
          let deadline = clockValue + 0xFFFFF448'u32 +
            (beaconOffset shl 5) + (100'u32 shl 10)
          doAssert switchTimes == @[deadline]
          doAssert vifs[0].beaconCountdown == 3
        else:
          doAssert vifs[0].beaconCountdown == countdown - 1
          doAssert switchTimes.len == 0 and programmed.len == 0
        expected.add(@["transmit", "age"])
        doAssert operations.filterIt(it notin ["save", "restore"]) ==
          expected.filterIt(it notin ["save", "restore"])
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "goto"])
def test_tbtt_clear_errors_restore_irq_and_stop_later_work(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incomingIrq in [false, true]:
  for stage in ["halt", "flush"]:
    setup()
    interrupts = incomingIrq
    failure = stage
    env.activeList.first = addr vifs[0]
    vifs[0].vifType = VIF_TYPE_AP
    vifs[0].beaconCountdown = 1
    var raised = false
    try: mm_tbtt_evt()
    except ValueError: raised = true
    doAssert raised
    doAssert interrupts == incomingIrq, "beacon event lost incoming IRQ state"
    doAssert keEvtField == 0x20
    doAssert vifs[0].beaconCountdown == 1
    doAssert mmTbttAgingCount0 == 2 and mmTbttAgingCount1 == 10
    doAssert programmed.len == 0 and switchTimes.len == 0 and aged == 0
    let expected = if stage == "halt": @["clear", "save", "halt", "restore"]
      else: @["clear", "save", "halt", "flush", "restore"]
    doAssert operations.filterIt(it notin ["save", "restore"]) ==
      expected.filterIt(it notin ["save", "restore"])
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "goto", "firmware"])
def test_logger_errors_precede_state_changes(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for action in 0 .. 3:
  setup()
  logging = true
  failLog = true
  vifs[0].state = 1
  vifs[0].flags = 3
  vifs[0].beaconLossCount = 7
  var raised = false
  try:
    case action
    of 0: mm_sta_timer_bcn_timeout(addr vifs[0])
    of 1: mm_sta_timer_data_timeout(addr vifs[0])
    of 2: mm_sta_tbtt(addr vifs[0])
    else: mm_tbtt_evt()
  except ValueError: raised = true
  doAssert raised and interrupts
  doAssert operations.filterIt(it notin ["save", "restore"]) == @["log"] and messages.len == 1
  doAssert vifs[0].flags == 3 and vifs[0].beaconLossCount == 7
  doAssert vifs[0].tbttCount == 0 and keEvtField == 0x01000020'u32
  doAssert mmTbttAgingCount0 == 2 and mmTbttAgingCount1 == 10
''')
