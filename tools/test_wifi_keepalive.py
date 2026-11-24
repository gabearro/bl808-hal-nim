"""Execute STA TBTT and power-save retry logic against vendor boundary models."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]

PLATFORM = r"""
const MAX_VIFS = 2
const STA_INFO_TAB_ENTRIES = 7
type
  Timer = object
    expiry: uint32
  Vif = object
    state, vifIdx, staIdx, probeCount, psNullRetry: uint8
    flags, tbttCount, beaconTimeoutBase, beaconRxCount: uint32
    tbttTimer, keepAliveTimer: Timer
  VifChannelView = Vif
  ProbeCallbackScope = object
    tracked: bool
    vif: uint8
  Sta = object
    initialRateConfig: uint32
    valid, instNbr: uint8
  MmEnv = object
    keepAliveInterval, keepAliveLimit: uint32
  PsEnv = object
    enabled, pendingCount: uint8
  PsParams = object
    nullRetryLimit: uint32
  Action = tuple[kind: string, value: uint32]
var
  stas: array[7, Sta]
  mm: MmEnv
  ps: PsEnv
  params: PsParams
  currentVif: ptr Vif
  macNow: uint32
  onChannel: bool
  sendResult: uint8
  lastCallback: pointer
  lastCallbackArg: uint32
  actions: seq[Action]
  nimFwWpaPendingMask: uint32
  loggingEnabled: bool
  logCalls: int
  rxVifEpochs: array[2, uint32]
  stationEpochs: array[7, uint32]
  txResetEpoch: uint32
  mmTimerMutationTop: ptr MmTimerMutation
  mmBeaconProbeEpochs, mmTrafficProbeEpochs: array[MAX_VIFS, uint32]
  txActiveFrameCallback: ptr ProbeCallbackScope
  callbackCurrent: bool
  interruptsEnabled = true
const MACHW_TIMLO_REG = 0x24B00120'u

proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc vifChannelForIdx(i: uint8): ptr Vif =
  if currentVif != nil and currentVif.vifIdx == i: currentVif else: nil
proc staDeleteEpoch(i: uint8): uint32 =
  if i < stationEpochs.len.uint8: stationEpochs[i] else: 0
proc txlResetting(): bool = false
proc txlVifIsRetiring(i: uint8): bool = false
proc txlFrameCallbackCurrent(): bool = callbackCurrent
proc irqSave(): uint32 =
  result = interruptsEnabled.uint32 * 8
  interruptsEnabled = false
proc irqRestore(saved: uint32) = interruptsEnabled = (saved and 8) != 0
proc staInfoForIdx(i: uint8): ptr Sta = addr stas[i]
proc mmEnvView(): ptr MmEnv = addr mm
proc psEnvView(): ptr PsEnv = addr ps
proc blPsParamsView(): ptr PsParams = addr params
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc logMessage(level, severity: uint32; file: cstring; line: uint32;
                message: cstring) {.cdecl.} =
  doAssert level == 1 and severity == 0 and line == 624
  doAssert $file == "mm.c" and $message == "mm_sta_tbtt\r\n"
  inc logCalls
proc getLogFunc(offset: int): pointer =
  doAssert offset == 0xCC
  if loggingEnabled: cast[pointer](logMessage) else: nil
proc blOpsFunc(offset: int): pointer =
  doAssert offset == 4
  nil
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_TIMLO_REG
  macNow
proc macTimeNow(): uint32 = macNow
proc mm_timer_set(timer: ptr Timer; expiry: uint32) =
  if timer == addr currentVif.tbttTimer: actions.add(("tbtt", expiry))
  else:
    doAssert timer == addr currentVif.keepAliveTimer
    actions.add(("keepalive", expiry))
  timer.expiry = expiry
proc mmTimerSetLocked(timer: pointer; expiry, saved: uint32) =
  doAssert not interruptsEnabled
  irqRestore(saved)
  try: mm_timer_set(cast[ptr Timer](timer), expiry)
  finally: discard irqSave()
proc vif_mgmt_bcn_to_prog(vif: pointer) =
  doAssert vif == currentVif
  actions.add(("beacon", 0'u32))
proc chan_tbtt_switch_update(vif: pointer; expiry: uint32) =
  doAssert vif == currentVif
  actions.add(("switch", expiry))
proc chan_is_on_channel(vif: pointer): bool =
  doAssert vif == currentVif
  actions.add(("channel", onChannel.uint32))
  onChannel
proc ps_check_tbtt(vif: pointer) =
  doAssert vif == currentVif
  actions.add(("ps", 0'u32))
proc txl_frame_send_null_frame(sta: uint8; callback: pointer; arg: uint32): uint8 =
  doAssert sta == currentVif.staIdx
  actions.add(("null", sta.uint32))
  lastCallback = callback
  lastCallbackArg = arg
  sendResult
proc wifi_hosal_pm_post_event(event, value: uint32; arg: pointer) =
  doAssert arg == nil
  actions.add(("pm", (event shl 16) or value))
proc mm_send_connection_loss_ind(vif: pointer; reason: uint16) =
  doAssert vif == currentVif
  actions.add(("loss", reason.uint32))
proc mmPublishConnectionLoss(vif: pointer; reason: uint16; epoch: ptr uint32) =
  let freshness = if reason == 22: mmTrafficProbeEpochs[currentVif.vifIdx]
                  else: mmBeaconProbeEpochs[currentVif.vifIdx]
  doAssert epoch != nil and epoch[] == freshness
  mm_send_connection_loss_ind(vif, reason)
proc ps_enable_cfm(vif: pointer; status: uint32) {.cdecl.} = discard
proc ps_disable_cfm(vif: pointer; status: uint32) {.cdecl.} = discard
proc reset() =
  actions.setLen(0)
  lastCallback = nil
  lastCallbackArg = 0
  callbackCurrent = true
  txActiveFrameCallback = nil
  mmBeaconProbeEpochs = default(typeof(mmBeaconProbeEpochs))
  mmTrafficProbeEpochs = default(typeof(mmTrafficProbeEpochs))
  mm = default(MmEnv)
  ps = default(PsEnv)
  params = default(PsParams)
  stas = default(typeof(stas))
  for sta in stas.mitems:
    sta.valid = 1
    sta.instNbr = 1
  loggingEnabled = false
  logCalls = 0
"""

CHECKS = r"""
# Invoke through the timer callback ABI, preserving a full native pointer.
type TimerCallback = proc(env: pointer) {.cdecl.}
let tbttCallback = cast[TimerCallback](mm_sta_tbtt)
reset()
var loggedVif: Vif
currentVif = addr loggedVif
loggingEnabled = true
tbttCallback(addr loggedVif)
doAssert logCalls == 1 and actions.len == 0

# Queue rejection is not liveness evidence. A long miss streak must still
# request a probe on the first eligible TBTT after the queue recovers.
block:
  reset()
  var vif = Vif(state: 1, vifIdx: 1, staIdx: 3, probeCount: 100)
  currentVif = addr vif
  onChannel = true
  sendResult = 1
  for missed in 101 .. 255:
    actions.setLen(0)
    tbttCallback(addr vif)
    doAssert vif.probeCount.int == missed and actions[^1] == ("null", 3'u32)
  sendResult = 0
  onChannel = false
  actions.setLen(0)
  tbttCallback(addr vif)
  doAssert vif.probeCount == 255 and actions[^1] == ("channel", 0'u32)
  onChannel = true
  actions.setLen(0)
  tbttCallback(addr vif)
  doAssert actions[^1] == ("null", 3'u32), "counter wrap suppressed a due probe"
  doAssert vif.probeCount == 255 and mmBeaconProbeEpochs[1] == 0

for active in [false, true]:
  for onChan in [false, true]:
    for priorProbe in [0'u8, 48, 49, 50, 98, 99, 100, 101, 254, 255]:
      for interval in [0'u32, 102400, 0xFFFFFFF0'u32]:
        for expiry in [0'u32, 200, 0xFFFFFFFF'u32]:
          for queued in [0'u8, 1]:
            for wpaPending in [0'u32, 3]:
              reset()
              var vif = Vif(state: active.uint8, vifIdx: 1, staIdx: 3,
                            flags: 0x80, probeCount: priorProbe, tbttCount: 0xFFFFFFFF'u32)
              vif.tbttTimer.expiry = expiry
              currentVif = addr vif
              stas[3].initialRateConfig = interval
              nimFwWpaPendingMask = wpaPending
              onChannel = onChan
              macNow = 0xFFFFFFF0'u32
              mm.keepAliveInterval = 50
              sendResult = queued
              tbttCallback(addr vif)
              var expected: seq[Action]
              if active:
                let due = interval + expiry
                expected = @[("tbtt", due), ("keepalive", macNow + 50),
                             ("beacon", 0'u32), ("switch", due), ("channel", onChan.uint32)]
                doAssert vif.tbttTimer.expiry == due and vif.keepAliveTimer.expiry == macNow + 50
                doAssert vif.tbttCount == 0
                if onChan:
                  expected.add(("ps", 0'u32))
                  let nextProbe = min(priorProbe.int + 1, 255).uint8
                  doAssert vif.flags == 0x81 and vif.probeCount == nextProbe
                  if nextProbe > 100:
                    expected.add(("null", 3'u32))
                    doAssert lastCallback == cast[pointer](mmStaBeaconProbeCfm)
                    doAssert lastCallbackArg == mmBeaconProbeEpochs[1]
                  elif nextProbe >= 50:
                    expected.add(("pm", 3'u32 shl 16))
                else:
                  doAssert vif.flags == 0x80 and vif.probeCount == priorProbe
              else:
                doAssert vif.tbttTimer.expiry == expiry and vif.keepAliveTimer.expiry == 0
                doAssert vif.probeCount == priorProbe and vif.tbttCount == 0xFFFFFFFF'u32
              doAssert actions == expected
              doAssert vif.state == active.uint8 and nimFwWpaPendingMask == wpaPending

# Only successful TX confirmation clears the liveness probe count.
for status in [0'u32, 1, 0x00800000, 0x80010700'u32, 0x80800000'u32]:
  reset()
  var vif = Vif(probeCount: 103)
  currentVif = addr vif
  mm_ap_probe_cfm(addr vif, status)
  if (status and 0x80000000'u32) == 0:
    doAssert vif.probeCount == 103 and actions.len == 0
  elif (status and 0x800000) != 0:
    doAssert vif.probeCount == 0 and actions.len == 0
  else:
    doAssert vif.probeCount == 103 and actions == @[("loss", 16'u32)]

# Hold a real TBTT callback across a saturated count. A fresh beacon or ACK,
# an expired TX session, or a software-only retirement invalidates it.
for event in 0 .. 4:
  reset()
  var vif = Vif(state: 1, vifIdx: 1, staIdx: 3, probeCount: 254)
  currentVif = addr vif
  onChannel = true
  mmBeaconProbeEpochs[1] = 0x80000007'u32
  tbttCallback(addr vif)
  doAssert vif.probeCount == 255
  let complete = cast[proc(p: pointer; status: uint32) {.cdecl.}](lastCallback)
  let arg = cast[pointer](lastCallbackArg.uint)
  tbttCallback(addr vif)
  doAssert vif.probeCount == 255 and mmBeaconProbeEpochs[1] == 0x80000007'u32
  actions.setLen(0)
  var scope = ProbeCallbackScope(tracked: true, vif: 1)
  txActiveFrameCallback = addr scope
  case event
  of 1: # A real beacon, followed by enough TBTTs to begin a new miss streak.
    mmResetBeaconProbeCount(addr vif)
    vif.probeCount = 101
  of 2:
    complete(arg, 0x80800000'u32) # Another in-flight probe produced an ACK.
    doAssert vif.probeCount == 0 and mmBeaconProbeEpochs[1] == 0x80000008'u32
  of 3: callbackCurrent = false
  else: discard
  complete(arg, if event == 4: 0x40000000'u32 else: 0x80010700'u32)
  doAssert actions == (if event == 0: @[("loss", 16'u32)] else: @[])
  doAssert interruptsEnabled

# The shared AP probe budget is decremented only when initially nonzero.
for budget in [0'u32, 1, 2, 10, 0xFFFFFFFF'u32]:
  for status in [0'u32, 0x00800000, 0x40000000, 0x80010700'u32, 0x80800000'u32]:
    reset()
    var vif: Vif
    currentVif = addr vif
    mm.keepAliveLimit = budget
    macNow = 0x12345678
    mm_ap_traffic_probe_cfm(addr vif, status)
    if (status and 0x80000000'u32) == 0:
      doAssert mm.keepAliveLimit == budget and actions.len == 0
      doAssert vif.beaconTimeoutBase == 0
    elif (status and 0x00800000) != 0:
      doAssert mm.keepAliveLimit == 10 and vif.beaconTimeoutBase == macNow
      doAssert actions.len == 0
    elif budget == 0:
      doAssert mm.keepAliveLimit == 10 and actions == @[("loss", 22'u32)]
    else:
      doAssert mm.keepAliveLimit == budget - 1 and actions.len == 0

# Full-width retry limits must not be truncated to the byte counter's width.
for previous in 0'u16 .. 255'u16:
  for threshold in [0'u32, 1, 2, 3, 20, 255, 256, 257, 510, 511, 512, 65535, 0xFFFFFFFF'u32]:
    for pending in [0'u8, 1, 2]:
      for enabled in [0'u8, 1]:
        for queued in [0'u8, 1]:
          for enabling in [false, true]:
            reset()
            var vif = Vif(staIdx: 2, psNullRetry: previous.uint8)
            currentVif = addr vif
            ps.enabled = enabled
            ps.pendingCount = pending
            params.nullRetryLimit = threshold
            sendResult = queued
            let callback = if enabling: cast[pointer](ps_enable_cfm) else: cast[pointer](ps_disable_cfm)
            let actual = ps_check_tx_status_part0_nim(addr vif, callback)
            let count = ((previous.uint32 + 1) and 255)
            doAssert vif.psNullRetry.uint32 == count
            var expected: seq[Action]
            var expectedResult = 1'u32
            var expectedEnabled = enabled
            if count == threshold:
              expected.add(("loss", 21'u32))
              expectedEnabled = 0
            elif count == threshold div 2:
              expected.add(("pm", (4'u32 shl 16) or 1))
            elif pending != 0:
              expected.add(("null", 2'u32))
              expectedResult = queued.uint32
              doAssert lastCallback == callback
            doAssert actual == expectedResult and actions == expected
            doAssert ps.enabled == expectedEnabled and ps.pendingCount == pending
"""


def test_keepalive_timers_and_retry_boundaries(tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    base = ROOT / "src/bl808/wifi/fw"
    kernel = (base / "kernel_mac_channel.nim").read_text()
    power = (base / "power_save.nim").read_text()

    def procedure(source: str, name: str, end: str) -> str:
        return "proc " + name + source.split("proc " + name, 1)[1].split(end, 1)[0]

    procedures = "\n".join([
        procedure(kernel, "mmCaptureVif", "\nproc mmVifCurrent"),
        procedure(kernel, "mmVifCurrent", "\nproc mmConnLossTagAt"),
        procedure(kernel, "mmTimerActiveDelivery", "\nproc mmStaTimerCurrent"),
        procedure(kernel, "mmResetBeaconProbeCount", "\nproc mmCheckBeaconFrame"),
        procedure(kernel, "mmStaTimerCurrent", "\nproc mm_sta_tbtt"),
        procedure(kernel, "mm_ap_probe_cfm*", "\nproc mm_bcn_transmitted*"),
        procedure(kernel, "mm_sta_tbtt*", "\nproc mm_tbtt_evt*"),
        procedure(power, "mm_ap_traffic_probe_cfm*", "\nproc td_timer_end*"),
        procedure(power, "ps_check_tx_status_part0_nim*", "\n# Export an alias"),
    ])
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", procedures)))
    )
    source = tmp_path / "keepalive.nim"
    layout = (base / "layout_types.nim").read_text()
    types = "".join(re.search(rf"(?ms)^  {name}\b.*?(?=^  \w|\Z)", layout).group()
                    for name in ("MmVifIdentity", "MmTimerMutation"))
    source.write_text("type\n" + types + PLATFORM + debug + procedures + CHECKS)
    result = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         "--checks:on", f"--nimcache:{tmp_path / 'nimcache'}", f"-o:{tmp_path / 'test'}", str(source)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    assert result.returncode == 0, result.stdout
