"""Exercise AP probe-request filtering on real RX message and IE layouts."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
const
  MAX_VIFS = 2
  VIF_TYPE_AP = 2'u8
  KeMsgConsumed = 0.cint
  ApmProbeReqViewSize = sizeof(ApmProbeReqView).uint32
  apMac = [2'u8, 11, 12, 13, 14, 15]
  otherMac = [2'u8, 21, 22, 23, 24, 25]
  broadcast = [255'u8, 255, 255, 255, 255, 255]
type
  Vif = object
    vifIdx, vifType, state: uint8
    chanCtxt, operChan: pointer
    macAddr: array[6, uint8]
    ssidStorage: array[420, uint8]
  Header = object
    paramLen: uint32
var
  vifs: array[2, Vif]
  foreign: Vif
  channel: ScanChannelEntry
  apm: tuple[flags, embeddedEnabled, vifIdx: uint8]
  header: Header
  storage: array[512, uint8]
  payload: pointer
  apmPendingCancelMask, apmStoppingVifs, startupMask: uint8
  rxVifEpochs: array[2, uint32]
  sends, compared: int
  lookup: pointer
  interruptEnabled = true
  onCompare: proc()
proc irqSave(): uint32 =
  result = interruptEnabled.uint32
  interruptEnabled = false
proc irqRestore(saved: uint32) = interruptEnabled = saved != 0
proc vifChannelForIdx(i: uint8): ptr Vif =
  doAssert i < 2
  addr vifs[i]
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc vifApProbeSsid(v: ptr Vif): ptr VifApProbeSsidOverlay =
  cast[ptr VifApProbeSsidOverlay](addr v.ssidStorage[0])
proc apmProbeReqView(p: pointer): ptr ApmProbeReqView = cast[ptr ApmProbeReqView](p)
proc rxuMgtIndMsgAt(p: pointer): ptr RxuMgtIndMsgView = cast[ptr RxuMgtIndMsgView](p)
proc apmEnvView(): ptr typeof(apm) = addr apm
proc apmStartPendingForVif(i: uint8): bool = (startupMask and (1'u8 shl i)) != 0
proc vif_mgmt_get_first_ap_inf(): pointer = lookup
proc keMsgHdrFromPayload(p: pointer): ptr Header =
  doAssert p == payload
  addr header
proc rxuMgtDispatchView(p: pointer): ptr RxuMgtDispatchView = cast[ptr RxuMgtDispatchView](p)
proc macIeAt(p: uint): ptr MacIeView = cast[ptr MacIeView](p)
proc totalLen(ie: ptr MacIeView): uint = ie.len.uint + 2
template macIePayload(ie: ptr MacIeView): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](cast[uint](ie) + 2)
proc c_memcmp(a, b: pointer; n: csize_t): cint =
  inc compared
  result = if equalMem(a, b, n.int): 0 else: 1
  if onCompare != nil: onCompare()
proc apm_send_mlme(vif: pointer; frameType: uint16; destination: pointer;
                   callback, argument, extra: pointer) =
  doAssert vif == (addr vifs[1]) and frameType == 0x50
  doAssert callback == nil and argument == nil
  when not defined(bl808WifiApDiscoveryDiag):
    doAssert extra == nil
  doAssert equalMem(destination, addr storage[42], 6)
  inc sends
proc apm_auth_handler(p: pointer) = doAssert false
proc apm_assoc_req_handler(p: pointer; reassoc: uint32) = doAssert false
proc apm_deauth_handler(p: pointer) = doAssert false
proc apm_disassoc_handler(p: pointer) = doAssert false
proc apm_beacon_handler(p: pointer) = doAssert false
proc rxu_mgt_ind_handler_apm(param: pointer): cint
  {.exportc: "rxu_mgt_ind_handler_apm", cdecl, discardable.}
proc malloc(n: csize_t): pointer {.importc, header: "<stdlib.h>".}
proc free(p: pointer) {.importc, header: "<stdlib.h>".}

proc setup(ies: openArray[uint8]; vif = 1'u8; defaultRates = true) =
  var body = @ies
  if defaultRates:
    let afterSsid =
      if body.len >= 2 and body[0] == 0 and body[1].int + 2 <= body.len:
        body[1].int + 2
      else: 0
    body = body[0 ..< afterSsid] & @[1'u8, 1, 2] & body[afterSsid .. ^1]
  for value in storage.mitems: value = 0xA5
  payload = addr storage[0]
  vifs = default(typeof(vifs))
  vifs[1].vifIdx = 1
  vifs[1].vifType = 2
  vifs[1].state = 1
  vifs[1].macAddr = apMac
  vifs[1].chanCtxt = addr channel
  vifs[1].operChan = addr channel
  vifApProbeSsid(addr vifs[1]).ssidLen = 4
  let ssid = cast[ptr UncheckedArray[uint8]](addr vifs[1].ssidStorage[0])
  for i, value in [84'u8, 0, 69, 83]: ssid[387 + i] = value
  channel = ScanChannelEntry(prim20Freq: 2437, band: 0)
  apm.flags = 0
  apm.embeddedEnabled = 1
  apm.vifIdx = 1
  apmPendingCancelMask = 0
  apmStoppingVifs = 0
  startupMask = 0
  rxVifEpochs = default(typeof(rxVifEpochs))
  onCompare = nil
  sends = 0
  compared = 0
  lookup = addr vifs[1]
  let ind = cast[ptr RxuMgtIndMsgView](payload)
  ind.frameLen = (24 + body.len).uint16
  ind.frameCtrl = 0x40
  ind.freq = 2462
  ind.rxuVifIdx = vif
  let frame = cast[ptr MacDataFrameHeaderView](addr ind.body[0])
  frame[] = MacDataFrameHeaderView(frameControl: 0x40,
    addr1: broadcast, addr2: [2'u8, 3, 4, 5, 6, 7], addr3: broadcast)
  for i, value in body: storage[56 + i] = value
  header.paramLen = (56 + body.len).uint32

proc setAddresses(receiver, bssid: array[6, uint8]) =
  let ind = cast[ptr RxuMgtIndMsgView](payload)
  let frame = cast[ptr MacDataFrameHeaderView](addr ind.body[0])
  frame.addr1 = receiver
  frame.addr3 = bssid

proc consume(expected: bool) =
  let before = storage
  let saved = interruptEnabled
  doAssert rxu_mgt_ind_handler_apm(payload) == KeMsgConsumed
  doAssert sends == expected.int, "probe response count " & $sends & ", expected " & $expected.int
  doAssert storage == before and interruptEnabled == saved
"""

CHECKS = r"""
# The DS channel, not a supported-rate byte, determines channel compatibility.
setup([0'u8, 4, 84, 0, 69, 83, 3, 1, 11])
consume(false)

for irq in [false, true]:
  interruptEnabled = irq
  for vif in [1'u8, 255]:
    setup([0'u8, 4, 84, 0, 69, 83, 1, 1, 108, 3, 1, 6], vif,
          defaultRates = false)
    consume(true)
    doAssert compared == 1
    setup([0'u8, 4, 88, 0, 69, 83, 3, 1, 6], vif)
    consume(false)
    # A directed matching request is allowed in hidden mode too.
    for hidden in 0'u8 .. 2:
      setup([0'u8, 4, 84, 0, 69, 83], vif)
      apm.flags = hidden
      consume(true)
      for missing in [false, true]:
        if missing: setup([], vif)
        else: setup([0'u8, 0], vif)
        apm.flags = hidden
        vifApProbeSsid(addr vifs[1]).hiddenSsidMode = if hidden == 0: 2 else: 0
        consume(not missing and hidden == 0)

    # The VIF selection (even a wildcard VIF) doesn't replace address checks.
    for receiver in [broadcast, apMac, otherMac, [1'u8, 0, 94, 0, 0, 1]]:
      for bssid in [broadcast, apMac, otherMac]:
        setup([0'u8, 0], vif)
        setAddresses(receiver, bssid)
        consume(receiver in [broadcast, apMac] and bssid in [broadcast, apMac])

    for hidden in 0'u8 .. 1:
      # Top-level name differs; a valid matching nested name still qualifies.
      setup([0'u8, 1, 88, 84, 9, 0, 1, 89, 0, 4, 84, 0, 69, 83], vif)
      apm.flags = hidden
      consume(true)
      setup([0'u8, 1, 88, 84, 3, 0, 1, 89], vif)
      apm.flags = hidden
      consume(false)
      setup([0'u8, 1, 88, 84, 2, 0, 0], vif)
      apm.flags = hidden
      consume(hidden == 0)

    setup([0'u8, 1, 88, 84, 9, 0, 4, 84, 0, 69, 83, 0, 1, 89], vif)
    onCompare = proc() = inc rxVifEpochs[1]
    consume(false)

  # Invalid mandatory element lengths are not interpreted as wildcards.
  setup([0'u8, 0], defaultRates = false)
  consume(false)
  setup([0'u8, 0, 1, 0], defaultRates = false)
  consume(false)
  setup([0'u8, 0, 1, 9, 2, 2, 2, 2, 2, 2, 2, 2, 2], defaultRates = false)
  consume(false)

  for ies in [@[0'u8, 0, 84, 1, 0], @[0'u8, 0, 84, 2, 1, 0],
              @[0'u8, 0, 84, 3, 0, 2, 1],
              @[0'u8, 0, 84, 7, 0, 4, 84, 0, 69, 83, 0]]:
    setup(ies)
    consume(false)

  for setting in [(0'u8, 2412'u16, 1'u8), (0'u8, 2437'u16, 6'u8),
                  (0'u8, 2484'u16, 14'u8), (1'u8, 5180'u16, 36'u8),
                  (1'u8, 5825'u16, 165'u8)]:
    for same in [false, true]:
      setup([0'u8, 0, 3, 1, if same: setting[2] else: setting[2] - 1])
      channel.band = setting[0]
      channel.prim20Freq = setting[1]
      consume(same)

  # A frequency that the PHY channel plan cannot encode must never match.
  for invalid in [(0'u8, 2413'u16, 1'u8), (0'u8, 2477'u16, 14'u8),
                  (1'u8, 5181'u16, 36'u8), (0'u8, 2411'u16, 0'u8),
                  (2'u8, 2462'u16, 0'u8)]:
    setup([0'u8, 0, 3, 1, invalid[2]])
    channel.band = invalid[0]
    channel.prim20Freq = invalid[1]
    consume(false)
  setup([0'u8, 0])
  channel.prim20Freq = 2438
  consume(false)
  setup([0'u8, 0])
  vifs[1].operChan = nil
  consume(false)

  # The entire IE region must fit, even if the first SSID already matches.
  for ies in [@[0'u8, 4, 84, 0, 69, 83, 3],
              @[0'u8, 4, 84, 0, 69, 83, 3, 2, 6],
              @[0'u8, 4, 84, 0, 69, 83, 3, 0],
              @[0'u8, 4, 84, 0, 69, 83, 3, 2, 6, 0],
              @[0'u8, 4, 84, 0, 69, 83, 221, 5, 1]]:
    setup(ies)
    consume(false)

  setup([0'u8, 4, 84, 0, 69, 83, 0, 1, 88])
  consume(true) # The first occurrence wins, like the vendor's IE search.
  setup([0'u8, 1, 88, 0, 4, 84, 0, 69, 83])
  consume(false)

  for length in [32, 33]:
    var ssidIe = @[0'u8, length.uint8]
    for i in 0 ..< length: ssidIe.add(i.uint8)
    setup(ssidIe)
    vifApProbeSsid(addr vifs[1]).ssidLen = length.uint8
    for i in 0 ..< length: vifs[1].ssidStorage[387 + i] = i.uint8
    consume(length == 32)

  for phase in 0 .. 6:
    setup([0'u8, 0, 3, 1, 6])
    case phase
    of 1: vifs[1].state = 0
    of 2: apmPendingCancelMask = 2
    of 3: apmStoppingVifs = 2
    of 4: startupMask = 2
    of 5: vifs[1].vifType = 0
    of 6: vifs[1].chanCtxt = nil
    else: discard
    consume(phase == 0)
  for invalid in [2'u8, 7, 254]:
    setup([0'u8, 0], invalid)
    consume(false)
  setup([0'u8, 0], 255)
  lookup = nil
  consume(false)
  setup([0'u8, 0], 255)
  foreign = vifs[1]
  lookup = addr foreign
  consume(false)
  setup([0'u8, 0, 3, 1, 6])
  vifs[1].operChan = nil
  consume(false)

  for change in 0 .. 2:
    setup([0'u8, 4, 84, 0, 69, 83])
    case change
    of 0: onCompare = proc() = inc rxVifEpochs[1]
    of 1: onCompare = proc() = apmStoppingVifs = 2
    else: onCompare = proc() = inc rxVifEpochs[0]
    consume(change == 2)

  # Short messages use exact allocations so the ASan run checks read bounds.
  for length in [0, 1, 8, 31, 48, 55]:
    setup([])
    payload = malloc(max(1, length).csize_t)
    doAssert payload != nil
    zeroMem(payload, max(1, length))
    header.paramLen = length.uint32
    apm_probe_req_handler(payload)
    doAssert sends == 0 and interruptEnabled == irq
    free(payload)
  for frameLength in [0'u16, 23, 25, 65535]:
    setup([], defaultRates = false)
    cast[ptr uint16](payload)[] = frameLength
    apm_probe_req_handler(payload)
    doAssert sends == 0 and interruptEnabled == irq
  apm_probe_req_handler(nil)
  doAssert sends == 0 and interruptEnabled == irq
"""


TRACE_CHECKS = r"""
setup([0'u8, 4, 84, 0, 69, 83])
consume(true)
setup([0'u8, 0])
consume(true)
setup([0'u8, 1, 88])
consume(false)
setup([0'u8, 0, 84, 6, 0, 4, 84, 0, 69, 83])
setAddresses(broadcast, otherMac)
consume(false)
setup([0'u8, 4, 84, 0, 69, 83, 3, 1, 11])
consume(false)
setup([0'u8, 4, 84, 0, 69, 83, 0xDD])
consume(false)
apm_probe_req_handler(nil)
doAssert apProbeTrace[apProbeNamed].apmEntered == 4
doAssert apProbeTrace[apProbeNamed].outcomes == [0'u32, 0, 1, 1, 1, 0, 0, 1]
doAssert apProbeTrace[apProbeWildcard].outcomes[apProbeRespond] == 1
doAssert apProbeTrace[apProbeOther].outcomes[apProbeWrongSsid] == 1
doAssert apProbeTrace[apProbeUnknown].outcomes[apProbeBadLength] == 1
doAssert apProbeDsssTrace.count == 1
doAssert apProbeDsssTrace.samples[0] == ApProbeDsssSample(sequence: 1,
  reason: apProbeDsssMismatch.uint8, length: 1, requested: 11, configured: 6,
  rxTunedMhz: 2462, configuredMhz: 2437)

setup([0'u8, 4, 84, 0, 69, 83, 3, 2, 6, 0])
consume(false)
setup([0'u8, 4, 84, 0, 69, 83, 3, 1, 6])
vifs[1].operChan = nil
consume(false)
setup([0'u8, 4, 84, 0, 69, 83, 3, 1, 6])
channel.prim20Freq = 2438
consume(false)
setup([0'u8, 4, 84, 0, 69, 83, 3, 1, 6])
consume(true)
setup([0'u8, 0, 3, 1, 6])
consume(true)
doAssert apProbeDsssTrace.count == 5 # No named sample for a wildcard request.
doAssert apProbeDsssTrace.samples[1] == ApProbeDsssSample(sequence: 2,
  reason: apProbeDsssBadLength.uint8, length: 2, rxTunedMhz: 2462)
doAssert apProbeDsssTrace.samples[2] == ApProbeDsssSample(sequence: 3,
  reason: apProbeDsssNoOperatingChannel.uint8, length: 1, requested: 6, rxTunedMhz: 2462)
doAssert apProbeDsssTrace.samples[3] == ApProbeDsssSample(sequence: 4,
  reason: apProbeDsssInvalidOperatingChannel.uint8, length: 1, requested: 6,
  rxTunedMhz: 2462, configuredMhz: 2438)
doAssert apProbeDsssTrace.samples[4] == ApProbeDsssSample(sequence: 5,
  reason: apProbeDsssMatched.uint8, length: 1, requested: 6, configured: 6,
  rxTunedMhz: 2462, configuredMhz: 2437)
for _ in 1 .. 28:
  apProbeNoteDsss(apProbeNamed, apProbeDsssMatched, 1, 6, 6, 2437, 2437)
doAssert apProbeDsssTrace.count == 33 and apProbeDsssTrace.samples[0].sequence == 33
doAssert apProbeDsssTrace.samples[1].sequence == 2

# The same tag slot can be reused without attributing an old completion
# to its replacement. Taking a completion is one-shot.
apProbeMarkBuilt(1, apProbeNamed)
apProbeMarkBuilt(33, apProbeWildcard)
apProbeNoteCompletion(1, 0x80800000'u32, 0)
apProbeNoteCompletion(33, 0x80800000'u32, 0)
apProbeNoteCompletion(33, 0x80800000'u32, 0)
doAssert apProbeTrace[apProbeUnknown].acked == 2
doAssert apProbeTrace[apProbeWildcard].acked == 1
apProbeMarkBuilt(2, apProbeNamed)
apProbeNoteCompletion(2, 0x80800000'u32, 0x10000)
apProbeMarkBuilt(3, apProbeNamed)
apProbeNoteCompletion(3, 0x40000000'u32, 0)
apProbeMarkBuilt(4, apProbeNamed)
apProbeNoteCompletion(4, 0x80800000'u32, 0)
doAssert apProbeTrace[apProbeNamed].built == 4
doAssert apProbeTrace[apProbeNamed].done == 2
doAssert apProbeTrace[apProbeNamed].acked == 1
doAssert apProbeTrace[apProbeNamed].unacked == 1
doAssert apProbeTrace[apProbeNamed].aborted == 1
"""


def probe_program(*, trace: bool = False) -> str:
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n"
    for name in ["VifApProbeSsidOverlay", "MacDataFrameHeaderView", "ApmProbeReqView",
                 "RxuMgtDispatchView", "RxuMgtIndMsgView", "MacIeView", "ScanChannelEntry"]:
        types += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    constants = "const\n" + "\n".join(
        line for line in layout.splitlines()
        if line.split("*", 1)[0].strip() in {
            "IE_ID_SSID", "IE_ID_SUPPORTED_RATES", "IE_ID_DS_PARAM", "IE_ID_SSID_LIST",
            "IE_LEN_DS_PARAM"
        }
    ) + "\n"
    scan = (FW / "scan_station_ap_me.nim").read_text()
    handlers = (FW / "task_handlers.nim").read_text()
    functions = procedure((FW / "mac_config_debug.nim").read_text(), "mac_ie_find")
    functions += procedure((FW / "kernel_mac_channel.nim").read_text(),
                           "phy_freq_to_channel").replace("weakExport, ", "")
    if trace:
        functions += "{.pragma: wifiCtrl.}\n" + (FW / "ap_probe_trace.nim").read_text() + "\n"
    functions += procedure(handlers, "apmVifRunning")
    functions += procedure(scan, "apmSessionCurrent")
    functions += procedure(scan, "apm_probe_req_handler")
    functions += procedure(handlers, "rxu_mgt_ind_handler_apm")
    return types + constants + PLATFORM + functions


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_ap_probe_request(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, probe_program() + CHECKS)


@pytest.mark.parametrize("mode", ["checked", "asan"])
def test_ap_probe_observations(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, probe_program(trace=True) + TRACE_CHECKS,
                defines=("bl808WifiApDiscoveryDiag",))
