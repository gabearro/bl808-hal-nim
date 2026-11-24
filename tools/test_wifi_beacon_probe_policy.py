"""Check vendor beacon probe gates and MM-owned retry accounting."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const MAX_VIFS = 1
type
  Timer = object
    expiry: uint32
  Vif = object
    chanCtxt: pointer
    staIdx, probeCount, vifType, vifIdx: uint8
    beaconRxCount, lastBeaconMacTime, beaconLossWindow, beaconTimeoutBase: uint32
    beaconCrc: uint32
    listenInterval: uint16
    tbttTimer, keepAliveTimer: Timer
  VifChannelView = Vif
  Sta = object
    listenWindowDuration: uint16
    beaconTimeOffset: uint32
  Channel = object
    band: uint8
    primFreq: uint16
  Context = object
    channel: Channel
var
  mm: MmEnvView
  mmLastBeaconLogTime: uint32
  mmBeaconProbeEpochs: array[MAX_VIFS, uint32]
  ops: BlOpsDataView
  vif: Vif
  sta: Sta
  context: Context
  frameStorage: array[36, uint8]
  payload: BeaconPayloadDescView
  rx: BeaconRxDescView
  clock, sendResult: uint32
  sends, losses: int
  onSend: proc()
  timOut: uint32
let frame = cast[ptr BeaconFrameFixedView](addr frameStorage[0])
proc mmEnvView(): ptr MmEnvView = addr mm
proc irqSave(): uint32 = 0
proc irqRestore(saved: uint32) = discard
proc blOpsData(): ptr BlOpsDataView = addr ops
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc staInfoAt(p: pointer): ptr Sta = cast[ptr Sta](p)
proc chanCtxtAt(p: pointer): ptr Context = cast[ptr Context](p)
proc dsParamSetIeAt(p: pointer): pointer = p
proc dsParamFreq(band: uint8; ie: pointer): uint16 =
  let channel = cast[ptr UncheckedArray[uint8]](ie)[2]
  doAssert band == 0 and channel in 1'u8..13'u8
  2407'u16 + 5 * channel.uint16
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc beaconRxDescView(p: pointer): ptr BeaconRxDescView = cast[ptr BeaconRxDescView](p)
proc beaconPayloadDescView(p: pointer): ptr BeaconPayloadDescView = cast[ptr BeaconPayloadDescView](p)
proc beaconFrameFixedView(p: pointer): ptr BeaconFrameFixedView = cast[ptr BeaconFrameFixedView](p)
proc beaconFrameIeBody(p: ptr BeaconFrameFixedView): pointer = addr p.body[0]
proc macIeAt(p: uint): ptr MacIeView = cast[ptr MacIeView](p)
template totalLen(ie: ptr MacIeView): uint = ie.len.uint + 2
proc macIePayload(p: ptr MacIeView): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](cast[uint](p) + 2)
proc volatileLoad(p: ptr uint32): uint32 = clock
proc mm_ap_traffic_probe_cfm(vif: pointer; status: uint32) {.cdecl.} = discard
proc txl_frame_send_null_frame(station: uint8; callback: pointer; arg: uint32): uint8 =
  doAssert station == vif.staIdx
  doAssert callback == cast[pointer](mm_ap_traffic_probe_cfm)
  doAssert arg == pointerAddrU32(addr vif)
  inc sends
  if onSend != nil: onSend()
  sendResult.uint8
proc mm_send_connection_loss_ind(p: pointer; reason: uint16) =
  doAssert p == (addr vif) and reason == 22
  inc losses
proc mm_check_rssi(p: pointer; rssi: int8) = discard
proc utils_crc32_stream_init(p: pointer) = cast[ptr uint32](p)[] = 0x1234
proc utils_crc32_stream_feed_block(p, data: pointer; length: uint32) = discard
proc utils_crc32_stream_results(p: pointer): uint32 = 0x1234
proc hal_machw_rx_duration(p: pointer; length: uint32): uint32 = 0
proc getLogFunc(offset: int): PlatformLogFunc = nil
proc rxCaptureFrameHeader(header, vifEntry, staEntry: pointer): RxFrameIdentity =
  doAssert header != nil and vifEntry != nil and staEntry != nil
  RxFrameIdentity(descriptor: header)
proc rxFrameCurrent(identity: RxFrameIdentity): bool = true
proc mm_timer_set(p: pointer; expiry: uint32) = cast[ptr Timer](p).expiry = expiry
proc mm_timer_clear(p: pointer) = discard
proc setup() =
  mm = default(MmEnvView)
  mmLastBeaconLogTime = 0
  mmBeaconProbeEpochs[0] = 0
  mm.keepAliveLimit = 3
  ops = default(BlOpsDataView)
  ops.beaconProbeCountdown = 7
  vif = Vif(staIdx: 4, beaconTimeoutBase: 100)
  sta = Sta(listenWindowDuration: 1)
  zeroMem(addr frameStorage[0], frameStorage.len)
  frame.beaconInterval = 100
  payload = BeaconPayloadDescView(frameData: frame)
  rx = BeaconRxDescView(payloadDesc: addr payload, frameLen: 36)
  context = Context(channel: Channel(band: 0, primFreq: 2412))
  clock = 100
  sendResult = 1
  sends = 0
  losses = 0
  onSend = nil
  timOut = 0
proc dsBeacon(storage: var array[45, uint8]; channel: uint8) =
  copyMem(addr storage[0], frame, 36)
  for i, b in [3'u8, 1, channel, 5, 4, 0, 3, 0, 2]: storage[36+i] = b
  payload.frameData = addr storage[0]
  rx.frameLen = storage.len.uint16
  vif.chanCtxt = addr context
proc process() = discard mm_check_beacon(addr rx, addr vif, addr sta, addr timOut)
'''


def source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    runtime = (FW / "global_state/c_runtime.nim").read_text()
    log_type = runtime[runtime.index("type\n"):runtime.index("# Helper:")]
    declarations = []
    for name in ("MmEnvView", "BlOpsDataView", "MacIeView", "RxFrameIdentity", "RxPayloadBufferView", "BeaconRxDescView",
                 "BeaconPayloadDescView", "BeaconFrameFixedView"):
        match = re.search(rf"(?m)^  {name}\*?(?: \{{\.packed\.\}})? = object\n(?:    [^\n]*\n)+", layout)
        assert match, name
        declarations.append(match.group(0))
    platform, checks = PLATFORM.split("proc setup()", 1)
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    return (log_type + "type\n" + "".join(declarations) + platform
            + procedure((FW / "mac_config_debug.nim").read_text(), "mac_ie_find")
            + procedure(kernel, "mmResetBeaconProbeCount")
            + procedure(kernel, "mmCheckBeaconFrame") + procedure(kernel, "mm_check_beacon")
            + "\nproc setup()" + checks)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_probe_requires_mm_enable_and_elapsed_timeout(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for enabled in [0'u8, 1'u8]:
  for elapsed in [0'u32, 29_999_999, 30_000_000, 30_000_001]:
    for start in [100'u32, 0xFFFF0000'u32]:
      setup()
      mm.flagsHigh = enabled
      vif.beaconTimeoutBase = start
      clock = start + elapsed
      # Conflicting adapter values must not become the probe policy.
      ops.beaconTimeoutConfig[3] = 1 - enabled
      let oldOps = ops
      process()
      let expected = enabled != 0 and elapsed > 30_000_000
      doAssert sends == expected.int and losses == 0
      doAssert mm.keepAliveLimit == 3
      doAssert ops == oldOps
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_submission_does_not_advance_mm_retry_budget(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for status in [0'u32, 1'u32, 2'u32]:
  for budget in [0'u32, 1'u32, 10'u32]:
    setup()
    mm.flagsHigh = 1
    mm.keepAliveLimit = budget
    clock = vif.beaconTimeoutBase + 30_000_001
    sendResult = status
    let oldOps = ops
    process()
    doAssert sends == 1
    doAssert losses == 0 and mm.keepAliveLimit == budget and ops == oldOps
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_channel_mismatch_does_not_send_a_probe(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for frequency in [2412'u16, 2437'u16]:
  setup()
  var storage: array[45, uint8]
  dsBeacon(storage, 6)
  mm.flagsHigh = 1
  clock = vif.beaconTimeoutBase + 30_000_001
  context.channel.primFreq = frequency
  vif.probeCount = 100
  vif.lastBeaconMacTime = 99
  let outcome = mm_check_beacon(addr rx, addr vif, addr sta, addr timOut)
  let accepted = frequency == 2437
  doAssert outcome == (if accepted: 1'u32 else: high(uint32))
  doAssert sends == accepted.int and losses == 0
  doAssert mm.keepAliveLimit == 3
  doAssert vif.beaconRxCount == accepted.uint32
  if not accepted:
    doAssert vif.probeCount == 100 and vif.lastBeaconMacTime == 99
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_good_beacon_refreshes_loss_history(tmp_path: Path, mode: str) -> None:
    code = source()
    code = code.replace(procedure(code, "volatileLoad"), r'''
proc volatileLoad(p: ptr uint32): uint32 =
  if cast[uint](p) == 0x24B00120'u:
    result = clock
    inc clock
''', 1)
    run_program(tmp_path, mode, code + r'''
setup()
var storage: array[45, uint8]
dsBeacon(storage, 9)
context.channel.primFreq = 2452
proc check(now, arrival, maxGap: uint32) =
  clock = now
  vif.probeCount = 100
  process()
  doAssert timOut == pointerAddrU32(addr storage[39])
  doAssert vif.probeCount == 0
  doAssert vif.lastBeaconMacTime == arrival
  doAssert vif.beaconLossWindow == maxGap

check(1_000_000, 1_000_000, 0)         # First arrival: no prior gap.
check(1_102_400, 1_102_402, 102_401)   # New max: compare, resample, stamp.
check(1_204_803, 1_204_804, 102_401)   # Equal gap: compare and stamp only.
check(1_307_203, 1_307_204, 102_401)   # Shorter gap, still a good beacon.
vif.lastBeaconMacTime = 0xFFFF_FFF0'u32
vif.beaconLossWindow = 31
check(0x10, 0x12, 33)                  # Unsigned gap of 32 across rollover.
vif.lastBeaconMacTime = 0x100
check(0x8000_0100'u32, 0x8000_0102'u32, 0x8000_0001'u32)
doAssert vif.beaconRxCount == 6
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_long_beacon_tim_is_parsed_from_contiguous_view(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
var storage: array[1741, uint8]
copyMem(addr storage[0], frame, 36)
var cursor = 36
while 1735 - cursor > 257:
  storage[cursor] = 127
  storage[cursor + 1] = 255
  cursor += 257
storage[cursor] = 127
storage[cursor + 1] = (1735 - cursor - 2).uint8
for i, b in [5'u8, 4, 0, 1, 0x22, 0x33]: storage[1735 + i] = b
rx.frameLen = storage.len.uint16
timOut = 0xDEADBEEF'u32
doAssert mm_check_beacon(addr rx, addr vif, addr sta, addr timOut) == high(uint32)
doAssert timOut == 0
var tim: pointer
doAssert mmCheckBeaconFrame(addr rx, addr vif, addr sta, addr storage[0], tim) == 1
doAssert tim == addr storage[1735]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_malformed_beacon_ies_are_rejected_before_state_changes(tmp_path: Path, mode: str) -> None:
    expanded = source().replace("frameStorage: array[36, uint8]",
                                "frameStorage: array[48, uint8]")
    run_program(tmp_path, mode, expanded + r'''
for sample in 0 .. 5:
  setup()
  timOut = 0xDEADBEEF'u32
  case sample
  of 0:
    rx.frameLen = 37
    frameStorage[36] = 3            # incomplete IE header
  of 1:
    rx.frameLen = 38
    frameStorage[36] = 3
    frameStorage[37] = 5            # payload overruns frame
  of 2:
    rx.frameLen = 38
    frameStorage[36] = 3
    frameStorage[37] = 0            # DS channel byte absent
  of 3:
    rx.frameLen = 40
    frameStorage[36] = 3
    frameStorage[37] = 2            # DS payload must have exactly one byte
  of 4:
    rx.frameLen = 41
    frameStorage[36] = 5
    frameStorage[37] = 3            # TIM bitmap byte absent
  else:
    rx.frameLen = 45
    frameStorage[36] = 3
    frameStorage[37] = 1
    frameStorage[38] = 1
    frameStorage[39] = 5
    frameStorage[40] = 4
    frameStorage[41] = 0
    frameStorage[42] = 1
    frameStorage[43] = 0
    frameStorage[44] = 0
  let outcome = mm_check_beacon(addr rx, addr vif, addr sta, addr timOut)
  if sample < 5:
    doAssert outcome == high(uint32)
    doAssert timOut == 0
    doAssert vif.beaconRxCount == 0 and sends == 0 and losses == 0
  else:
    doAssert outcome == 1
    doAssert timOut != 0 and vif.beaconRxCount == 1
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_missing_beacon_arguments_are_rejected(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for missing in 0 .. 3:
  setup()
  timOut = 0xDEADBEEF'u32
  let rxArg = if missing == 0: nil else: cast[pointer](addr rx)
  let vifArg = if missing == 1: nil else: cast[pointer](addr vif)
  let staArg = if missing == 2: nil else: cast[pointer](addr sta)
  let outArg = if missing == 3: nil else: addr timOut
  let outcome = mm_check_beacon(rxArg, vifArg, staArg, outArg)
  doAssert outcome == high(uint32)
  if missing != 3: doAssert timOut == 0
  else: doAssert timOut == 0xDEADBEEF'u32
  doAssert vif.beaconRxCount == 0 and sends == 0 and losses == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_submit_return_does_not_overwrite_callback_budget(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
mm.flagsHigh = 1
clock = vif.beaconTimeoutBase + 30_000_001
onSend = proc() = mm.keepAliveLimit = 5
process()
doAssert sends == 1 and losses == 0 and mm.keepAliveLimit == 5
doAssert ops.beaconProbeCountdown == 7
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_repeated_submit_failures_do_not_report_loss(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
mm.flagsHigh = 1
mm.keepAliveLimit = 2
clock = vif.beaconTimeoutBase + 30_000_001
let statuses = [0'u32, 1, 0, 1, 1]
for index, status in statuses:
  sendResult = status
  process()
  doAssert sends == index + 1 and mm.keepAliveLimit == 2
  doAssert losses == 0
mm.flagsHigh = 0
process()
doAssert sends == 5 and losses == 0 and mm.keepAliveLimit == 2
doAssert ops.beaconProbeCountdown == 7
''')
