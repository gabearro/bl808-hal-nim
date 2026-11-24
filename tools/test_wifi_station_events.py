"""Exercise host station notifications across callbacks and interface reuse."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import ROOT

RX = ROOT / "src/bl808/wifi/rx"
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
{.pragma: wifiCtrl.}
{.define: bl808WifiRealLwip.}
type
  BlSta = object
  Netif = object
    linked: bool
    dhcpActive: bool
    address: uint32
  BlRxInfo = object
  WifiEventSmConnect = object
  WifiEventSmDisconnect = object
  WifiEventBeacon = object
  WifiEvent = object
var
  wifi_hw: array[WifiHostModParamsOffset.int, uint8]
  message: array[900, uint8]
  netifs: array[2, Netif]
  enabled, incoming: bool
  actions, savedActions: seq[string]
  onStage: proc(stage: string)
  pending, onCopy: proc()
  savedHw: typeof(wifi_hw)
  savedNetifs: typeof(netifs)
  rxVifEpochs: array[2, uint32]
  stationEpochs: array[5, uint32]
  lastStatus: uint16
  sendConnect: bool
  beforeHostDelivery: proc()
proc ke_msg_send(payload: pointer)
const MAX_VIFS = 2
const STA_MGMT_FREE_STAS = 5
proc csrReadMstatus(): uint = (if enabled: 8'u else: 0'u)
proc disableInterrupts() = enabled = false
proc enableInterrupts() =
  enabled = true
  if pending != nil:
    let action = pending
    pending = nil
    action()
proc irqSave(): uint32 =
  result = csrReadMstatus().uint32
  disableInterrupts()
proc irqRestore(saved: uint32) =
  if (saved and 8) != 0: enableInterrupts()
proc smActivationAcceptPeer(payload: pointer; vif, station: uint8; linked = false): bool = true
proc smActivationTrackPeer(p, hw: pointer; token: uint32;
    check: proc(host: pointer; station: uint8; token: uint32; retire: bool): bool {.nimcall.}) = discard
proc staDeleteEpoch(index: uint8): uint32 =
  doAssert index < 5
  stationEpochs[index]
template rxHostIrqSave(): uint32 = irqSave()
template rxHostIrqRestore(saved: uint32) = irqRestore(saved)
proc stage(name: string) =
  if name != "log": actions.add(name)
  if onStage != nil: onStage(name)
template bl_os_printf(args: varargs[untyped]) = stage("log")
template ptrAt(base: pointer; offset: uint): pointer =
  cast[pointer](cast[uint](base) + offset)
proc netifapi_netif_set_link_up(netif: ptr Netif) =
  doAssert enabled == incoming
  if not netif.linked and netif.dhcpActive: stage("pre-wpa-dhcp")
  netif.linked = true
  stage("up")
proc netifapi_netif_set_link_down(netif: ptr Netif) =
  doAssert enabled == incoming
  netif.linked = false
  stage("down")
proc netifapi_netif_set_addr(netif: ptr Netif; address, mask, gateway: pointer): cint =
  doAssert enabled == incoming
  netif.address = cast[ptr uint32](address)[]
  stage("address")
  0
proc wifi_netif_dhcp_stop(netif: ptr Netif): cint =
  doAssert enabled == incoming
  if netif.dhcpActive: netif.address = 0
  netif.dhcpActive = false
  stage("dhcp-stop")
  0
proc bl_tx_cntrl_link_up(station: ptr BlSta) = stage("tx-up")
proc bl_tx_cntrl_link_down(station: ptr BlSta) = stage("tx-down")
proc c_memcpy(dest, source: pointer; size: csize_t): pointer =
  system.copyMem(dest, source, size.int)
  if onCopy != nil:
    let action = onCopy
    onCopy = nil
    if enabled: action()
    else: pending = action
  dest
proc c_memset(dest: pointer; value: cint; size: csize_t): pointer =
  doAssert value == 0
  zeroMem(dest, size.int)
  dest
"""

CHECKS = r"""
proc vif(): pointer = vifAt(addr wifi_hw[0], BlVifSta)
proc peer(index: uint): pointer = staAt(addr wifi_hw[0], index)
proc param(): pointer = msgParam(addr message[0])
proc ke_msg_send(payload: pointer) =
  doAssert payload == param()
  if beforeHostDelivery != nil: beforeHostDelivery()
  if sendConnect:
    discard blRxSmConnectInd(addr wifi_hw[0], nil, addr message[0])
  else:
    discard blRxSmDisconnectInd(addr wifi_hw[0], nil, addr message[0])
proc connected(env: pointer; event: ptr WifiEventSmConnect) {.cdecl.} =
  doAssert env == cast[pointer](19) and enabled == incoming
  lastStatus = loadU16(event, WifiConnStatusOff)
  doAssert loadU8(event, WifiConnVifOff) == 0
  when TestCase in ["source_copy_change", "source_log_change"]:
    doAssert loadU16(event, WifiConnAidOff) == 42
  when TestCase == "callback_payload_change":
    storeU16(event, WifiConnStatusOff, 1)
  stage("connect")
proc disconnected(env: pointer; event: ptr WifiEventSmDisconnect) {.cdecl.} =
  doAssert env == cast[pointer](23) and enabled == incoming
  doAssert loadU16(event, WifiDiscReasonOff) == 7
  stage("disconnect")
proc setupMessage(status: uint16) =
  message = default(typeof(message))
  storeU16(param(), SmConnStatusOff, status)
  storeU16(param(), SmConnReasonOff, 7)
proc prepare(state: bool) =
  wifi_hw = default(typeof(wifi_hw))
  netifs = default(typeof(netifs))
  rxVifEpochs = default(typeof(rxVifEpochs))
  stationEpochs = default(typeof(stationEpochs))
  enabled = state
  incoming = state
  actions.setLen(0)
  onStage = nil
  onCopy = nil
  pending = nil
  storeU32(vif(), BlVifDevOff, 1)
  storeU8(vif(), 12, 1)
  storeU8(vif(), 13, 0)
  storeU8(vif(), BlVifLinksNumOff, 1)
  storeU8(vif(), BlVifFixedStaIdxOff, 0)
  storeU8(peer(0), BlStaIsUsedOff, 1)
  netifs[0] = Netif(linked: true, dhcpActive: true, address: 0x01020304)
  discard bl_rx_sm_connect_ind_cb_register(cast[pointer](19), connected)
  discard bl_rx_sm_disconnect_ind_cb_register(cast[pointer](23), disconnected)
proc remember() =
  savedHw = wifi_hw
  savedNetifs = netifs
  savedActions = @[]
  for action in actions: savedActions.add(action)
proc unchanged() =
  doAssert wifi_hw == savedHw, "obsolete event changed host state"
  doAssert netifs == savedNetifs, "obsolete event changed the replacement interface"
  doAssert actions == savedActions, "obsolete event invoked another callback"
proc replaceConnection(station: uint8 = 1) =
  let previousIncoming = incoming
  incoming = enabled
  defer: incoming = previousIncoming
  var nested: array[900, uint8]
  let payload = msgParam(addr nested[0])
  storeU16(payload, SmDiscReasonOff, 7)
  if loadU8(vif(), BlVifLinksNumOff) != 0:
    discard blRxSmDisconnectInd(addr wifi_hw[0], nil, addr nested[0])
  storeU8(payload, SmStaAddApIdxOff, station)
  storeU8(payload, SmStaAddQosOff, 1)
  doAssert blRxSmStaAddInd(addr wifi_hw[0], nil, addr nested[0]) == 0
  storeU16(payload, SmConnStatusOff, 0)
  discard blRxSmConnectInd(addr wifi_hw[0], nil, addr nested[0])
  netifs[0].address = 0xAABBCCDD'u32
  netifs[0].dhcpActive = true

for state in [false, true]:
  prepare(state)
  setupMessage(if TestCase in ["connect_failed_replace", "failed_normal", "failed_dhcp"]: 1 else: 0)
  when TestCase == "normal":
    doAssert blRxSmConnectInd(addr wifi_hw[0], nil, addr message[0]) == 0
    doAssert actions == @["connect", "up"]
    actions.setLen(0)
    storeU16(param(), SmDiscReasonOff, 7)
    doAssert blRxSmDisconnectInd(addr wifi_hw[0], nil, addr message[0]) == 0
    doAssert actions == @["tx-down", "dhcp-stop", "disconnect", "down", "address"]
    doAssert loadU8(vif(), BlVifLinksNumOff) == 0 and netifs[0].address == 0 and
      not netifs[0].dhcpActive
  elif TestCase in ["source_change", "source_log_change", "source_copy_change", "callback_payload_change"]:
    storeU16(param(), SmConnAidOff, 42)
    onStage = proc(name: string) =
      let wanted = when TestCase == "source_log_change": "log" else: "connect"
      if name == wanted:
        onStage = nil
        storeU16(param(), SmConnStatusOff, 1)
        storeU16(param(), SmConnAidOff, 0)
    when TestCase == "source_copy_change":
      onStage = nil
      onCopy = proc() =
        storeU16(param(), SmConnStatusOff, 1)
        storeU16(param(), SmConnAidOff, 0)
    discard blRxSmConnectInd(addr wifi_hw[0], nil, addr message[0])
    doAssert lastStatus == 0 and actions == @["connect", "up"]
    doAssert loadU8(vif(), BlVifLinksNumOff) == 1
  elif TestCase in ["connect_replace", "connect_failed_replace", "disconnect_replace", "down_replace", "dhcp_stop_replace",
                    "log_replace", "tx_replace", "same_slot"]:
    onStage = proc(name: string) =
      let wanted = when TestCase == "down_replace": "down"
                   elif TestCase == "disconnect_replace": "disconnect"
                   elif TestCase == "dhcp_stop_replace": "dhcp-stop"
                   elif TestCase == "log_replace": "log"
                   elif TestCase == "tx_replace": "tx-down"
                   else: "connect"
      if name == wanted:
        when TestCase == "disconnect_replace": doAssert not netifs[0].dhcpActive
        onStage = nil
        replaceConnection(when TestCase == "same_slot": 0'u8 else: 1'u8)
        remember()
    when TestCase in ["disconnect_replace", "down_replace", "dhcp_stop_replace", "tx_replace"]:
      storeU16(param(), SmDiscReasonOff, 7)
      discard blRxSmDisconnectInd(addr wifi_hw[0], nil, addr message[0])
    else:
      discard blRxSmConnectInd(addr wifi_hw[0], nil, addr message[0])
    unchanged()
  elif TestCase in ["firmware_retire", "station_retire", "unrelated_vif", "netif_replace",
                    "interface_down", "vif_rebind", "fixed_replace"]:
    onStage = proc(name: string) =
      if name == "connect":
        onStage = nil
        when TestCase == "station_retire": inc stationEpochs[0]
        elif TestCase == "unrelated_vif": inc rxVifEpochs[1]
        elif TestCase == "netif_replace": storeU32(vif(), BlVifDevOff, 2)
        elif TestCase == "interface_down": storeU8(vif(), BlVifUpOff, 0)
        elif TestCase == "vif_rebind": storeU8(vif(), BlVifVifIdxOff, 1)
        elif TestCase == "fixed_replace": storeU8(vif(), BlVifFixedStaIdxOff, 1)
        else: inc rxVifEpochs[0]
        remember()
    discard blRxSmConnectInd(addr wifi_hw[0], nil, addr message[0])
    when TestCase == "unrelated_vif":
      doAssert actions == savedActions & @["up"]
    else: unchanged()
  elif TestCase in ["failed_normal", "failed_dhcp"]:
    netifs[0].dhcpActive = TestCase == "failed_dhcp"
    discard blRxSmConnectInd(addr wifi_hw[0], nil, addr message[0])
    doAssert actions == @["connect", "tx-down", "dhcp-stop", "down"]
    doAssert loadU8(vif(), BlVifLinksNumOff) == 0 and not netifs[0].linked
    doAssert not netifs[0].dhcpActive
    doAssert netifs[0].address == (if TestCase == "failed_dhcp": 0'u32 else: 0x01020304'u32)
  elif TestCase == "without_callbacks":
    discard bl_rx_sm_connect_ind_cb_unregister(nil, nil)
    discard bl_rx_sm_disconnect_ind_cb_unregister(nil, nil)
    discard blRxSmConnectInd(addr wifi_hw[0], nil, addr message[0])
    storeU16(param(), SmDiscReasonOff, 7)
    discard blRxSmDisconnectInd(addr wifi_hw[0], nil, addr message[0])
    doAssert actions == @["up", "tx-down", "dhcp-stop", "down", "address"]
  elif TestCase == "no_link":
    storeU8(vif(), BlVifLinksNumOff, 0)
    storeU8(vif(), BlVifFixedStaIdxOff, 255)
    doAssert blRxSmConnectInd(addr wifi_hw[0], nil, addr message[0]) == 0
    doAssert actions == @["connect", "up"]
    remember()
    doAssert blRxSmDisconnectInd(addr wifi_hw[0], nil, addr message[0]) == -1
    unchanged()
  elif TestCase == "nil_input":
    remember()
    for handler in [blRxSmConnectInd, blRxSmDisconnectInd, blRxSmStaAddInd]:
      doAssert handler(nil, nil, addr message[0]) == -1
      doAssert handler(addr wifi_hw[0], nil, nil) == -1
    unchanged()
  elif TestCase == "session_bounds":
    doAssert not rxHostSessionCurrent(default(RxHostSession))
    for vifIndex in 0 .. 255:
      for stationIndex in 0 .. 255:
        let session = captureRxHostSession(vifIndex.uint8, stationIndex.uint8)
        doAssert rxHostSessionCurrent(session) ==
          (vifIndex < 2 and (stationIndex < 5 or stationIndex == 255))
  elif TestCase == "scoped_indication":
    for connectionFailure in [false, true]:
      for change in 0 .. 4:
        prepare(state)
        setupMessage(connectionFailure.uint16)
        sendConnect = connectionFailure
        let owner = captureRxHostSession(0, 0xFF)
        beforeHostDelivery = proc() =
          case change
          of 1: inc rxVifEpochs[0] # Same host slot now belongs to a new association.
          of 2: storeU8(vif(), BlVifVifIdxOff, 1)
          of 3: inc rxVifEpochs[1]
          of 4: inc stationEpochs[0] # Cleanup may finish removing its own station.
          else: discard
          remember()
        rxHostSendStationIndication(param(), owner)
        if change in [1, 2]:
          unchanged()
        else:
          if connectionFailure:
            doAssert actions == @["connect", "tx-down", "dhcp-stop", "down"]
          else:
            doAssert actions == @["tx-down", "dhcp-stop", "disconnect", "down", "address"]
          doAssert not netifs[0].linked
        doAssert rxHostStationIndicationTop == nil
        beforeHostDelivery = nil
  elif TestCase == "disconnect_station_retired_in_callback":
    onStage = proc(name: string) =
      if name == "disconnect": inc stationEpochs[0]
    discard blRxSmDisconnectInd(addr wifi_hw[0], nil, addr message[0])
    doAssert actions == @["tx-down", "dhcp-stop", "disconnect", "down", "address"]
    doAssert not netifs[0].linked and netifs[0].address == 0
  elif TestCase == "reconnect_each_peer_slot":
    for index in [0'u8, 1, 2, 3, 4, 0]:
      storeU16(param(), SmDiscReasonOff, 7)
      doAssert blRxSmDisconnectInd(addr wifi_hw[0], nil, addr message[0]) == 0
      doAssert not netifs[0].dhcpActive
      setupMessage(0)
      storeU8(param(), SmStaAddApIdxOff, index)
      doAssert blRxSmStaAddInd(addr wifi_hw[0], nil, addr message[0]) == 0
      doAssert loadU8(vif(), BlVifFixedStaIdxOff) == index
      doAssert loadU8(peer(index.uint), BlStaIsUsedOff) == 1
      setupMessage(0)
      doAssert blRxSmConnectInd(addr wifi_hw[0], nil, addr message[0]) == 0
      doAssert netifs[0].linked and "pre-wpa-dhcp" notin actions
      netifs[0].dhcpActive = true
  elif TestCase == "station_bounds":
    for index in 5 .. 255:
      storeU8(vif(), BlVifLinksNumOff, 0)
      storeU8(param(), SmStaAddApIdxOff, index.uint8)
      remember()
      doAssert blRxSmStaAddInd(addr wifi_hw[0], nil, addr message[0]) == -1
      unchanged()
  elif TestCase == "fixed_bounds":
    for index in 5 .. 255:
      storeU8(vif(), BlVifFixedStaIdxOff, index.uint8)
      remember()
      doAssert blRxSmDisconnectInd(addr wifi_hw[0], nil, addr message[0]) == -1
      doAssert blRxSmConnectInd(addr wifi_hw[0], nil, addr message[0]) == -1
      unchanged()
  doAssert enabled == state
"""


def source(case: str, mutation: str = "") -> str:
    types = (RX / "types.nim").read_text()
    callbacks = "type\n  MsgCbProc" + types.split("  MsgCbProc", 1)[1].split("  WifiWpaIe", 1)[0]
    state = (RX / "callback_state.nim").read_text()
    state = "\n".join(line for line in state.splitlines() if "wifi_hw" not in line) + "\n"
    accessors = (RX / "accessors.nim").read_text().split("proc hwRaw", 1)[1]
    accessors = "proc hwRaw" + accessors
    accessors = re.sub(r"proc loadPtr[^\n]+\n", "", accessors)
    accessors = accessors.replace(
        "  ptrAt(ptrAt(hw, BlHwStaTableOff), stationIndex * BlStaSize)",
        '  doAssert stationIndex < NxRemoteStaStoreMax.uint, "host station index out of bounds"\n'
        "  ptrAt(ptrAt(hw, BlHwStaTableOff), stationIndex * BlStaSize)")
    raw_pointer = """
proc loadPtr(base: pointer; offset: uint): pointer =
  let value = loadU32(base, offset)
  if value == 1: return addr netifs[0]
  if value == 2: return addr netifs[1]
  cast[pointer](value)
"""
    constants = "".join((RX / "layout_parts" / name).read_text() for name in
                        ["host_tables.nim", "firmware_indications.nim", "wifi_events.nim"])
    helpers = ""
    fw_source = (FW / "rx_host_delivery.nim").read_text()
    if "type RxHostSession" in fw_source:
        helpers += "type RxHostSession" + fw_source.split("type RxHostSession", 1)[1]
    runtime = RX / "station_lifecycle.nim"
    if runtime.exists(): helpers += runtime.read_text().replace("firmware.", "")
    handlers = "".join((RX / "station_events_parts" / name).read_text()
                       for name in ["connect.nim", "disconnect.nim", "sta_add.nim"])
    registrations = (RX / "callback_registers_parts/station.nim").read_text()
    host_layout = f'import "{FW.parent / "host_table_layout.nim"}"\n'
    result = (host_layout + PLATFORM + constants + callbacks + (RX / "callback_runtime.nim").read_text()
            + state + accessors + raw_pointer + helpers + handlers.replace("firmware.", "") + registrations
            + f'\nconst TestCase = "{case}"\n' + CHECKS)
    if mutation == "serial":
        result = result.replace("transition.serial != stationRxSerial or\n", "")
    elif mutation == "session":
        result = result.replace("not rxHostSessionCurrent(transition.session)", "false")
    elif mutation == "binding":
        start = result.index("  loadPtr(vif, BlVifDevOff) == transition.netif and")
        end = result.index("\n\nproc stationRxNetifCurrent", start)
        result = result[:start] + "  true\n" + result[end:]
    elif mutation == "continuation":
        result = result.replace("if not stationRxTransitionCurrent(transition): return 0", "discard")
    elif mutation == "netif":
        result = result.replace("if stationRxNetifCurrent(transition):", "if true:")
    elif mutation == "dhcp_retire":
        result = result.replace("  retireStationDhcp(transition)\n", "  discard\n")
    elif mutation == "bounds":
        result = result.replace("station >= NxRemoteStaMax", "station == 254")
    elif mutation == "legacy_peer_limit":
        result = result.replace("NxRemoteStaMax = WifiHostPeerCount.uint8", "NxRemoteStaMax = 3'u8")
    elif mutation == "irq":
        result = result.replace("    disableInterrupts()\n", "    discard\n")
    elif mutation == "source":
        result = result.replace("if status != 0 and loadU8", "if loadU16(msgParam(msg), SmConnStatusOff) != 0 and loadU8")
    elif mutation == "indication_owner":
        guard = ("    if not rxHostClaimStationIndication(ind, loadU8(vif, BlVifVifIdxOff)):\n"
                 "      return 0\n")
        assert result.count(guard) == 2
        result = result.replace(guard, "")
    return result


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", ["normal", "source_change", "source_log_change", "source_copy_change",
    "callback_payload_change", "connect_replace", "connect_failed_replace", "disconnect_replace",
    "down_replace", "dhcp_stop_replace", "log_replace", "tx_replace", "same_slot", "firmware_retire", "station_retire", "unrelated_vif",
    "netif_replace", "interface_down", "vif_rebind", "fixed_replace", "failed_normal", "failed_dhcp", "without_callbacks",
    "scoped_indication",
    "disconnect_station_retired_in_callback",
    "no_link", "nil_input", "session_bounds", "station_bounds", "fixed_bounds",
    "reconnect_each_peer_slot"])
def test_host_station_events(tmp_path: Path, mode: str, case: str) -> None:
    result = run_case(tmp_path, source(case), mode)
    assert result.returncode == 0, result.stdout


def run_case(tmp_path: Path, body: str, mode: str = "checked") -> subprocess.CompletedProcess:
    nim = shutil.which("nim")
    if nim is None: pytest.skip("Nim is required")
    path = tmp_path / "station_events.nim"
    path.write_text(body)
    options = {"checked": [], "release": ["-d:release"],
               "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    return subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", "--assertions:on", "--checks:on", *options[mode],
        f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}", str(path)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)


@pytest.mark.parametrize(("mutation", "case"), [
    ("serial", "same_slot"), ("session", "firmware_retire"), ("binding", "netif_replace"),
    ("continuation", "connect_failed_replace"), ("netif", "down_replace"),
    ("dhcp_retire", "disconnect_replace"),
    ("bounds", "station_bounds"), ("legacy_peer_limit", "reconnect_each_peer_slot"),
    ("irq", "source_copy_change"), ("source", "source_change"),
    ("indication_owner", "scoped_indication"),
])
def test_station_event_guards(tmp_path: Path, mutation: str, case: str) -> None:
    result = run_case(tmp_path, source(case, mutation))
    assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
