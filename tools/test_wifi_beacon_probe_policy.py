"""Check vendor beacon probe gates and MM-owned retry accounting."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
type
  Timer = object
    expiry: uint32
  Vif = object
    chanCtxt: pointer
    staIdx, probeCount, vifType: uint8
    beaconRxCount, lastBeaconMacTime, beaconLossWindow, beaconTimeoutBase: uint32
    beaconCrc: uint32
    listenInterval: uint16
    tbttTimer, keepAliveTimer: Timer
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
  ops: BlOpsDataView
  vif: Vif
  sta: Sta
  context: Context
  frameStorage: array[36, uint8]
  payload: BeaconPayloadDescView
  rx: BeaconRxDescView
  clock, sendResult: uint32
  sends, losses: int
  wrongChannel: bool
  onSend: proc()
  timOut: uint32
let frame = cast[ptr BeaconFrameFixedView](addr frameStorage[0])
proc mmEnvView(): ptr MmEnvView = addr mm
proc blOpsData(): ptr BlOpsDataView = addr ops
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc staInfoAt(p: pointer): ptr Sta = cast[ptr Sta](p)
proc chanCtxtAt(p: pointer): ptr Context = cast[ptr Context](p)
proc dsParamSetIeAt(p: pointer): pointer = p
proc dsParamFreq(band: uint8; ie: pointer): uint16 = 2437
proc mac_ie_find(p: pointer; length: uint32; id: uint8): pointer =
  if wrongChannel: cast[pointer](1) else: nil
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc beaconRxDescView(p: pointer): ptr BeaconRxDescView = cast[ptr BeaconRxDescView](p)
proc beaconPayloadDescView(p: pointer): ptr BeaconPayloadDescView = cast[ptr BeaconPayloadDescView](p)
proc beaconFrameFixedView(p: pointer): ptr BeaconFrameFixedView = cast[ptr BeaconFrameFixedView](p)
proc beaconFrameIeBody(p: ptr BeaconFrameFixedView): pointer = addr p.body[0]
proc macIeAt(p: uint): ptr MacIeView = cast[ptr MacIeView](p)
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
  RxFrameIdentity(descriptor: header)
proc rxFrameCurrent(identity: RxFrameIdentity): bool = true
proc mm_timer_set(p: pointer; expiry: uint32) = cast[ptr Timer](p).expiry = expiry
proc mm_timer_clear(p: pointer) = discard
proc setup() =
  mm = default(MmEnvView)
  mmLastBeaconLogTime = 0
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
  wrongChannel = false
  onSend = nil
  timOut = 0
proc process() = discard mm_check_beacon(addr rx, addr vif, addr sta, addr timOut)
'''


def source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    runtime = (FW / "global_state/c_runtime.nim").read_text()
    log_type = runtime[runtime.index("type\n"):runtime.index("# Helper:")]
    declarations = []
    for name in ("MmEnvView", "BlOpsDataView", "MacIeView", "RxFrameIdentity", "BeaconRxDescView",
                 "BeaconPayloadDescView", "BeaconFrameFixedView"):
        match = re.search(rf"(?m)^  {name}\*?(?: \{{\.packed\.\}})? = object\n(?:    [^\n]*\n)+", layout)
        assert match, name
        declarations.append(match.group(0))
    platform, checks = PLATFORM.split("proc setup()", 1)
    return (log_type + "type\n" + "".join(declarations) + platform
            + procedure((FW / "kernel_mac_channel.nim").read_text(), "mm_check_beacon")
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
      doAssert mm.keepAliveLimit == (if expected: 2'u32 else: 3'u32)
      doAssert ops == oldOps
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_only_submitted_probes_advance_mm_retry_budget(tmp_path: Path, mode: str) -> None:
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
    doAssert losses == (status != 0 and budget == 0).int
    let expected = if status == 0: budget elif budget == 0: 10'u32 else: budget - 1
    doAssert mm.keepAliveLimit == expected and ops == oldOps
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_channel_mismatch_does_not_send_a_probe(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for frequency in [2412'u16, 2437'u16]:
  setup()
  mm.flagsHigh = 1
  clock = vif.beaconTimeoutBase + 30_000_001
  context.channel.primFreq = frequency
  vif.chanCtxt = addr context
  wrongChannel = true
  process()
  let accepted = frequency == 2437
  doAssert sends == accepted.int and losses == 0
  doAssert mm.keepAliveLimit == (if accepted: 2'u32 else: 3'u32)
  doAssert vif.beaconRxCount == accepted.uint32
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_probe_completion_budget_is_reloaded(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
mm.flagsHigh = 1
clock = vif.beaconTimeoutBase + 30_000_001
onSend = proc() = mm.keepAliveLimit = 5
process()
doAssert sends == 1 and losses == 0 and mm.keepAliveLimit == 4
doAssert ops.beaconProbeCountdown == 7
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_retry_budget_across_repeated_beacons(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
mm.flagsHigh = 1
mm.keepAliveLimit = 2
clock = vif.beaconTimeoutBase + 30_000_001
let statuses = [0'u32, 1, 0, 1, 1]
let expected = [2'u32, 1, 1, 0, 10]
for index, status in statuses:
  sendResult = status
  process()
  doAssert sends == index + 1 and mm.keepAliveLimit == expected[index]
  doAssert losses == (index == 4).int
mm.flagsHigh = 0
process()
doAssert sends == 5 and losses == 1 and mm.keepAliveLimit == 10
doAssert ops.beaconProbeCountdown == 7
''')
