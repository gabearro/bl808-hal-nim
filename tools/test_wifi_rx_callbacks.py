"""Exercise RX callback bindings, registration, and dispatch using native Nim."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import ROOT, procedure

RX = ROOT / "src/bl808/wifi/rx"

PLATFORM = r"""
type
  BlRxInfo = object
    rssi: int8
  WifiEventSmConnect = object
  WifiEventSmDisconnect = object
  WifiEventBeacon = object
  WifiEvent = object
    kind, value: uint32
var
  enabled = true
  incoming = true
  pending, onPublish, onRead, onClear, onClaim, onPayload: proc()
  basicCalls, advancedCalls, replacementCalls: int
  basicContext, advancedContext: pointer
  onBasic: proc()
  bytes: array[32, uint8]
  info: BlRxInfo
  eventCalls, rssiCalls: int
  eventKind, eventValue: uint32
proc csrReadMstatus(): uint = (if enabled: 8'u else: 0'u)
proc disableInterrupts() = enabled = false
proc enableInterrupts() =
  enabled = true
  if pending != nil:
    let action = pending
    pending = nil
    action()
proc interrupt(action: proc()) =
  if enabled: action()
  else: pending = action
proc publishPoint() =
  if onPublish != nil:
    let action = onPublish
    onPublish = nil
    interrupt(action)
proc readPoint() =
  if onRead != nil:
    let action = onRead
    onRead = nil
    interrupt(action)
proc clearPoint() =
  if onClear != nil:
    let action = onClear
    onClear = nil
    interrupt(action)
proc claimPoint(): bool =
  if onClaim != nil:
    let action = onClaim
    onClaim = nil
    interrupt(action)
  true
proc payloadPoint() =
  if onPayload != nil:
    let action = onPayload
    onPayload = nil
    action()
const
  MmRssiRssiOff = 0'u
  WifiEventChannelSwitch = 1'u32
  WifiEventScanDone = 2'u32
  WifiEventScanDoneOnJoin = 3'u32
proc msgParam(p: pointer): pointer = p
proc loadI8(p: pointer; offset: uint): int8 =
  payloadPoint()
  -71'i8
proc zero(p: pointer; length: uint) =
  payloadPoint()
  zeroMem(p, length.int)
proc storeU32(p: pointer; offset: uint; value: uint32) =
  cast[ptr uint32](cast[uint](p) + offset)[] = value
proc storeI32(p: pointer; offset: uint; value: int32) =
  storeU32(p, offset, cast[uint32](value))
"""

CHECKS = r"""
proc basic(env: pointer; data: ptr uint8; length: cint; metadata: ptr BlRxInfo) {.cdecl.} =
  doAssert enabled == incoming
  doAssert env == basicContext, "basic callback received another registration's context"
  doAssert data == (addr bytes[0]) and length == bytes.len and metadata == (addr info)
  inc basicCalls
  if onBasic != nil:
    let action = onBasic
    onBasic = nil
    action()
proc advanced(env, wrapper: pointer; metadata: ptr BlRxInfo) {.cdecl.} =
  doAssert enabled == incoming
  doAssert env == advancedContext, "advanced callback received another registration's context"
  doAssert wrapper == (addr bytes[0]) and metadata == (addr info)
  inc advancedCalls
proc alternate(env, wrapper: pointer; metadata: ptr BlRxInfo) {.cdecl.} =
  doAssert env == advancedContext and enabled == incoming
  inc replacementCalls
proc dispatch() = bl_rx_pkt_cb(addr bytes[0], bytes.len.cint, addr bytes[0], addr info)
proc connect(env: pointer; event: ptr WifiEventSmConnect) {.cdecl.} = discard
proc disconnect(env: pointer; event: ptr WifiEventSmDisconnect) {.cdecl.} = discard
proc beacon(env: pointer; event: ptr WifiEventBeacon) {.cdecl.} = discard
proc probe(env: pointer; timestamp: int64) {.cdecl.} = discard
proc rssi(env: pointer; value: int8) {.cdecl.} =
  doAssert enabled == incoming and env == basicContext and value == -71
  inc rssiCalls
proc event(env: pointer; value: ptr WifiEvent) {.cdecl.} =
  doAssert enabled == incoming and env == basicContext
  doAssert value.kind == eventKind and value.value == eventValue
  inc eventCalls
proc prepare(state: bool) =
  onBasic = nil
  onPublish = nil
  onRead = nil
  onClear = nil
  onClaim = nil
  onPayload = nil
  pending = nil
  enabled = state
  incoming = state
  basicCalls = 0
  advancedCalls = 0
  replacementCalls = 0
  eventCalls = 0
  rssiCalls = 0
  basicContext = cast[pointer](11)
  advancedContext = cast[pointer](22)
  discard bl_rx_pkt_cb_unregister(nil)
  discard bl_rx_pkt_adv_cb_unregister(nil)

# ALL_BINDINGS

for state in [false, true]:
  prepare(state)
  when TestCase == "independent":
    discard bl_rx_pkt_cb_register(basicContext, basic)
    discard bl_rx_pkt_adv_cb_register(advancedContext, advanced)
    dispatch()
    doAssert basicCalls == 1 and advancedCalls == 1
  elif TestCase == "unregister":
    discard bl_rx_pkt_cb_register(basicContext, basic)
    discard bl_rx_pkt_adv_cb_register(advancedContext, advanced)
    discard bl_rx_pkt_adv_cb_unregister(nil)
    dispatch()
    doAssert basicCalls == 1 and advancedCalls == 0
    discard bl_rx_pkt_adv_cb_register(advancedContext, advanced)
    discard bl_rx_pkt_cb_unregister(nil)
    dispatch()
    doAssert basicCalls == 1 and advancedCalls == 1
  elif TestCase == "replace_during_callback":
    discard bl_rx_pkt_cb_register(basicContext, basic)
    discard bl_rx_pkt_adv_cb_register(advancedContext, advanced)
    onBasic = proc() = discard bl_rx_pkt_adv_cb_register(advancedContext, alternate)
    dispatch()
    doAssert basicCalls == 1 and advancedCalls == 0 and replacementCalls == 0,
      "a new registration received the old packet"
    dispatch()
    doAssert replacementCalls == 1
  elif TestCase == "aba":
    discard bl_rx_pkt_cb_register(basicContext, basic)
    discard bl_rx_pkt_adv_cb_register(advancedContext, advanced)
    onBasic = proc() =
      discard bl_rx_pkt_adv_cb_unregister(nil)
      discard bl_rx_pkt_adv_cb_register(advancedContext, advanced)
    dispatch()
    doAssert advancedCalls == 0, "registration reuse revived a pending callback"
  elif TestCase == "nested":
    discard bl_rx_pkt_cb_register(basicContext, basic)
    discard bl_rx_pkt_adv_cb_register(advancedContext, advanced)
    onBasic = proc() = dispatch()
    dispatch()
    doAssert basicCalls == 2 and advancedCalls == 2
  elif TestCase == "publish":
    if not state: continue
    discard bl_rx_pkt_cb_register(cast[pointer](99), basic)
    onPublish = proc() = dispatch()
    discard bl_rx_pkt_cb_register(basicContext, basic)
    doAssert basicCalls == 1
  elif TestCase == "register_late":
    discard bl_rx_pkt_cb_register(basicContext, basic)
    onBasic = proc() = discard bl_rx_pkt_adv_cb_register(advancedContext, advanced)
    dispatch()
    doAssert advancedCalls == 0
    dispatch()
    doAssert advancedCalls == 1
  elif TestCase == "cancel_advanced":
    discard bl_rx_pkt_cb_register(basicContext, basic)
    discard bl_rx_pkt_adv_cb_register(advancedContext, advanced)
    onBasic = proc() = discard bl_rx_pkt_adv_cb_unregister(nil)
    dispatch()
    doAssert basicCalls == 1 and advancedCalls == 0
  elif TestCase == "basic_change":
    discard bl_rx_pkt_cb_register(basicContext, basic)
    discard bl_rx_pkt_adv_cb_register(advancedContext, advanced)
    onBasic = proc() = discard bl_rx_pkt_cb_unregister(nil)
    dispatch()
    doAssert basicCalls == 1 and advancedCalls == 1
  elif TestCase == "nested_replacement":
    discard bl_rx_pkt_cb_register(basicContext, basic)
    discard bl_rx_pkt_adv_cb_register(advancedContext, advanced)
    onBasic = proc() =
      discard bl_rx_pkt_adv_cb_register(advancedContext, alternate)
      dispatch()
    dispatch()
    doAssert basicCalls == 2 and advancedCalls == 0 and replacementCalls == 1
  elif TestCase == "wrap":
    discard bl_rx_pkt_cb_register(basicContext, basic)
    discard bl_rx_pkt_adv_cb_register(advancedContext, advanced)
    cbPktAdv.generation = high(uint32)
    onBasic = proc() = discard bl_rx_pkt_adv_cb_register(advancedContext, advanced)
    dispatch()
    doAssert cbPktAdv.generation == 0 and advancedCalls == 0
    dispatch()
    doAssert advancedCalls == 1
  elif TestCase == "nil":
    discard bl_rx_pkt_cb_register(basicContext, nil)
    discard bl_rx_pkt_adv_cb_register(advancedContext, nil)
    dispatch()
    doAssert basicCalls == 0 and advancedCalls == 0
  elif TestCase == "batch_snapshot":
    if not state: continue
    discard bl_rx_pkt_cb_register(basicContext, basic)
    discard bl_rx_pkt_adv_cb_register(advancedContext, advanced)
    onRead = proc() = discard bl_rx_pkt_adv_cb_register(advancedContext, alternate)
    dispatch()
    doAssert basicCalls == 1 and advancedCalls == 0 and replacementCalls == 0
  elif TestCase == "claim":
    if not state: continue
    discard bl_rx_pkt_cb_register(basicContext, basic)
    let saved = snapshotCallback(cbPkt)
    onClaim = proc() = discard bl_rx_pkt_cb_unregister(nil)
    doAssert claimCallback(cbPkt, saved), "an admitted invocation must remain coherent"
    doAssert cbPkt.handler == nil
    saved.handler(saved.context, addr bytes[0], bytes.len.cint, addr info)
    doAssert basicCalls == 1 and not claimCallback(cbPkt, saved)
  elif TestCase == "all_bindings":
    verifyAllBindings()
  elif TestCase == "events":
    discard bl_rx_rssi_cb_register(basicContext, rssi)
    discard blRxRssiStatusInd(nil, nil, nil)
    doAssert rssiCalls == 1
    discard bl_rx_event_register(basicContext, event)
    eventKind = WifiEventChannelSwitch
    eventValue = 6
    notifyEventChannelSwitch(6)
    eventKind = WifiEventScanDone
    eventValue = 272
    notifyEventScanDone(false)
    eventKind = WifiEventScanDoneOnJoin
    notifyEventScanDone(true)
    doAssert eventCalls == 3
  elif TestCase == "events_unregistered":
    discard bl_rx_rssi_cb_unregister(nil, nil)
    onPayload = proc() = doAssert false, "unregistered RSSI callback must not inspect payload"
    discard blRxRssiStatusInd(nil, nil, nil)
    onPayload = nil
    doAssert rssiCalls == 0
  elif TestCase == "event_replacement":
    for kind in 0 .. 3:
      discard bl_rx_rssi_cb_register(basicContext, rssi)
      discard bl_rx_event_register(basicContext, event)
      onPayload = proc() =
        discard bl_rx_rssi_cb_register(basicContext, rssi)
        discard bl_rx_event_register(basicContext, event)
      case kind
      of 0: discard blRxRssiStatusInd(nil, nil, nil)
      of 1: notifyEventChannelSwitch(6)
      of 2: notifyEventScanDone(false)
      else: notifyEventScanDone(true)
    doAssert rssiCalls == 0 and eventCalls == 0
  doAssert enabled == state
"""


def all_bindings_source() -> str:
    slots = [
        ("cbPkt", "basic", "bl_rx_pkt_cb_register", "bl_rx_pkt_cb_unregister(nil)"),
        ("cbPktAdv", "advanced", "bl_rx_pkt_adv_cb_register", "bl_rx_pkt_adv_cb_unregister(nil)"),
        ("cbSmConnect", "connect", "bl_rx_sm_connect_ind_cb_register", "bl_rx_sm_connect_ind_cb_unregister(nil, nil)"),
        ("cbSmDisconnect", "disconnect", "bl_rx_sm_disconnect_ind_cb_register", "bl_rx_sm_disconnect_ind_cb_unregister(nil, nil)"),
        ("cbBeacon", "beacon", "bl_rx_beacon_ind_cb_register", "bl_rx_beacon_ind_cb_unregister(nil, nil)"),
        ("cbProbeResp", "probe", "bl_rx_probe_resp_ind_cb_register", "bl_rx_probe_resp_ind_cb_unregister(nil, nil)"),
        ("cbRssi", "rssi", "bl_rx_rssi_cb_register", "bl_rx_rssi_cb_unregister(nil, nil)"),
        ("cbEvent", "event", "bl_rx_event_register", "bl_rx_event_unregister(nil)"),
    ]
    result = "proc verifyAllBindings() =\n"
    for slot, callback, install, clear in slots:
        result += f"""
  block:
    discard {install}(cast[pointer](11), {callback})
    let before = snapshotCallback({slot})
    if incoming:
      onPublish = proc() =
        let published = snapshotCallback({slot})
        doAssert published.handler == {callback} and published.context == cast[pointer](22)
        doAssert published.generation == before.generation + 1
    discard {install}(cast[pointer](22), {callback})
    let published = snapshotCallback({slot})
    doAssert published.handler == {callback} and published.context == cast[pointer](22)
    doAssert not claimCallback({slot}, before)
    if incoming:
      onClear = proc() =
        let cleared = snapshotCallback({slot})
        doAssert cleared.handler == nil and cleared.context == nil
        doAssert cleared.generation == published.generation + 1
    discard {clear}
    doAssert not claimCallback({slot}, published)
    if incoming:
      discard {install}(cast[pointer](11), {callback})
      let old = snapshotCallback({slot})
      onRead = proc() = discard {install}(cast[pointer](22), {callback})
      let observed = snapshotCallback({slot})
      doAssert observed == old, "snapshot mixed two registrations"
      doAssert not claimCallback({slot}, observed)
      discard {clear}
"""
    return result


def program(case: str, mutation: str = "") -> str:
    types = (RX / "types.nim").read_text()
    callback_types = "type\n  MsgCbProc" + types.split("  MsgCbProc", 1)[1].split("  WifiWpaIe", 1)[0]
    helpers = (RX / "callback_runtime.nim").read_text()
    helpers = helpers.replace("  slot.handler = callback\n", "  slot.handler = callback\n  publishPoint()\n")
    helpers = helpers.replace("  let handler = slot.handler\n", "  let handler = slot.handler\n  readPoint()\n")
    helpers = helpers.replace("  slot.handler = nil\n", "  slot.handler = nil\n  clearPoint()\n")
    helpers = helpers.replace("slot.generation == pending.generation and\n",
                              "slot.generation == pending.generation and claimPoint() and\n")
    if mutation in {"setCallback", "clearCallback", "snapshotCallback", "claimCallback"}:
        start = helpers.index(f"proc {mutation}[")
        end = helpers.find("\nproc ", start + 1)
        if end < 0: end = len(helpers)
        part = helpers[start:end].replace("  let saved = callbackIrqSave()\n", "")
        part = part.replace("  defer: callbackIrqRestore(saved)\n", "")
        helpers = helpers[:start] + part + helpers[end:]
    if mutation == "generation":
        helpers = helpers.replace("slot.generation == pending.generation and ", "")
    state = (RX / "callback_state.nim").read_text().split("var nimFwDbg", 1)[0]
    state = "\n".join(line for line in state.splitlines() if "wifi_hw" not in line) + "\n"
    registrations = "".join((RX / "callback_registers_parts" / name).read_text()
                            for name in ["packet.nim", "station.nim", "scan.nim", "misc.nim"])
    if mutation == "batch":
        registrations = registrations.replace("    let saved = callbackIrqSave()\n", "")
        registrations = registrations.replace("    defer: callbackIrqRestore(saved)\n", "")
    events = (RX / "scan_events_parts/event_notify.nim").read_text()
    events += procedure((RX / "control_events.nim").read_text(), "blRxRssiStatusInd")
    return (PLATFORM + callback_types + helpers + state + registrations + events
            + f'\nconst TestCase = "{case}"\n' + CHECKS.replace("# ALL_BINDINGS", all_bindings_source()))


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", ["independent", "unregister", "replace_during_callback", "aba", "nested", "publish",
                                  "register_late", "cancel_advanced", "basic_change", "nested_replacement",
                                  "wrap", "nil", "batch_snapshot", "claim", "all_bindings", "events",
                                  "events_unregistered", "event_replacement"])
def test_rx_callbacks(tmp_path: Path, mode: str, case: str) -> None:
    result = run_program(tmp_path, program(case), mode)
    assert result.returncode == 0, result.stdout


def run_program(tmp_path: Path, source: str, mode: str = "checked") -> subprocess.CompletedProcess:
    nim = shutil.which("nim")
    if nim is None: pytest.skip("Nim is required")
    path = tmp_path / "callbacks.nim"
    path.write_text(source)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on"]
    if mode == "release": command += ["-d:release"]
    if mode == "asan": command += ["--passC:-fsanitize=address", "--passL:-fsanitize=address"]
    command += ["--checks:on", "--assertions:on", f"--nimcache:{tmp_path / 'cache'}",
                f"-o:{tmp_path / 'test'}", str(path)]
    return subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, timeout=90)


@pytest.mark.parametrize(("mutation", "case"), [
    ("setCallback", "all_bindings"), ("clearCallback", "all_bindings"),
    ("snapshotCallback", "all_bindings"), ("claimCallback", "claim"),
    ("batch", "batch_snapshot"), ("generation", "aba"),
])
def test_rx_callbacks_guard_regressions(tmp_path: Path, mutation: str, case: str) -> None:
    result = run_program(tmp_path, program(case, mutation))
    assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
