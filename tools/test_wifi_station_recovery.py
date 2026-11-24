"""Exercise station preparation without resetting unrelated MAC state."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import ROOT, procedure

SUPPORT = ROOT / "src/bl808/wifi/support"
PLATFORM = r"""
const
  Scale = sizeof(pointer).uint div 4
  CfgVirtDevMax = 2'u8
  BlVifSta = 0'u
  BlVifDevOff = 8'u
  BlVifUpOff = 12'u
  BlVifVifIdxOff = 13'u
  BlVifLinksNumOff = 14'u
  SmDisconnectingState = 10'u16
  WifiConnectDefault = 1'u32 shl 31
  WifiConnectPmfCapable = 1'u32 shl 9
  ScanActive = 1'u8
type
  BlHw = object
  Netif = object
  MacAddr = object
  MacSsid = object
  RxHostSession = object
    epoch: uint32
var
  wifi_hw: BlHw
  wifiStarted = true
  staEnabled = true
  apEnabled = true
  apRegistered = true
  connectDone = 8'i32
  disconnectDone = 0'i32
  sm_state = 6'u16
  lastStatusCode = 8'i32
  lastReasonCode = 4'i32
  hostVif: array[80, uint8]
  netif, alternateNetif: array[16, uint8]
  mac = [2'u8, 3, 4, 5, 6, 7]
  epoch = 1'u32
  fwStatus = 1.cint
  cmdReady = true
  canRecover: bool
  abortResult, disconnectResult, connectResult, scanResult: cint
  abortStatus: uint8
  automatic = true
  polls: int
  calls: seq[string]
  onPoll, onAbort: proc()
  enabled = true
proc ptrAt(base: pointer; offset: uint): pointer = cast[pointer](cast[uint](base) + offset * Scale)
proc loadPtr(base: pointer; offset: uint): pointer = cast[ptr pointer](ptrAt(base, offset))[]
proc storePtr(base: pointer; offset: uint; value: pointer) = cast[ptr pointer](ptrAt(base, offset))[] = value
proc loadU8(base: pointer; offset: uint): uint8 = cast[ptr uint8](ptrAt(base, offset))[]
proc storeU8(base: pointer; offset: uint; value: uint8) = cast[ptr uint8](ptrAt(base, offset))[] = value
proc loadU16(base: pointer; offset: uint): uint16 = 0
proc loadU32(base: pointer; offset: uint): uint32 = 0
proc vifAt(index: uint): pointer = addr hostVif[0]
proc staIface(): pointer = addr netif[0]
proc ifaceNetif(iface: pointer): pointer = addr netif[0]
proc netifHwaddr(iface: pointer): ptr uint8 = addr mac[0]
proc osEnterCritical(): uint32 =
  result = if enabled: 8'u32 else: 0'u32
  enabled = false
proc osExitCritical(saved: uint32) = enabled = (saved and 8) != 0
proc captureRxHostSession(vif, station: uint8): RxHostSession = RxHostSession(epoch: epoch)
proc rxHostSessionCurrent(session: RxHostSession): bool = session.epoch == epoch
proc vif_mgmt_sta_status(vif: uint8; address: pointer): cint = fwStatus
proc wifiCmdMgrRecoverIfCrashed(hw: pointer): bool =
  calls.add("recover")
  if canRecover: cmdReady = true
  canRecover
proc wifiCmdMgrReady(hw: pointer): bool = cmdReady
proc bl_main_connect_abort(status: ptr uint8): cint =
  calls.add("abort")
  status[] = abortStatus
  if onAbort != nil: onAbort()
  abortResult
proc bl_main_disconnect(): cint =
  calls.add("disconnect")
  if onAbort != nil: onAbort()
  disconnectResult
proc vendorPollFor(count: uint32) =
  calls.add("poll")
  inc polls
  if onPoll != nil:
    let action = onPoll
    onPoll = nil
    action()
  if automatic and polls >= 2:
    sm_state = 0
    fwStatus = 0
    connectDone = 25
proc sm_delete_resources(value: pointer) =
  calls.add("delete")
  sm_state = 0
  fwStatus = 0
proc smDrainStaleSentMessages() = calls.add("prune")
proc bl_send_reset(hw: ptr BlHw): cint =
  calls.add("reset")
  apEnabled = false
  0
proc bl_main_phy_up(): cint =
  calls.add("start")
  0
proc wifi_mgmr_sta_readd_firmware_if(): bool =
  calls.add("add")
  true
proc wifiChannelToFreq(channel: uint8): uint16 =
  if channel != 0: 2407'u16 + 5'u16 * channel.uint16 else: 0'u16
proc c_strlen(value: cstring): csize_t = value.len.csize_t
proc vendorPutsRaw(value: cstring) = discard
proc vendorPrintU32(value, base: uint32) = discard
proc scanDiagReset() = discard
var scanDoneCount, scanItemCount, scanConfirmationStatus: uint32
var lastStaFrequency: uint16
proc bl_main_connect(ssid: ptr uint8; ssidLen: cint; psk: ptr uint8; pskLen: cint;
                     pmk: ptr uint8; pmkLen: cint; address: ptr uint8; band: uint8;
                     freq: uint16; flags: uint32): cint =
  calls.add("connect")
  lastStaFrequency = freq
  connectResult
proc bl_main_scan(nif: ptr Netif; channels: ptr uint16; count: uint16;
                  address: ptr MacAddr; ssid: ptr MacSsid; mode: uint8; duration: uint32): cint =
  calls.add("scan")
  scanResult
proc mgmrRaw(): pointer = nil
proc bl_msg_get_channel_nums(): cint = 11
var lastApChannel: cint
proc bl_main_apm_start(ssid, password: cstring; channel: cint; hidden: uint8; interval: uint16): cint =
  calls.add("ap_start")
  lastApChannel = channel
  connectResult
proc bl_main_apm_stop(): cint =
  calls.add("ap_stop")
  disconnectResult
const MgmrApBcnIntOff = 0'u
"""

CHECKS = {
    "normal": """
doAssert recover() == 0
doAssert "abort" in calls and polls >= 2
doAssert connectDone == -1 and disconnectDone == 1
""",
    "async_status": """
abortStatus = 1
doAssert recover() == 0
doAssert polls >= 2
""",
    "transport_failure": """
abortResult = -110
doAssert recover() == -110
doAssert polls == 0 and connectDone == 8
""",
    "busy_mailbox": """
cmdReady = false
doAssert recover() < 0
doAssert "abort" notin calls and polls == 0
""",
    "mailbox_recovered": """
cmdReady = false
canRecover = true
doAssert recover() == 0
""",
    "idle_queue_failed": """
sm_state = 0
fwStatus = 0
connectDone = -1
cmdReady = false
doAssert recover() < 0
doAssert polls == 0
""",
    "timeout": """
automatic = false
doAssert recover() == -110
doAssert polls > 0 and polls <= 4
doAssert sm_state == 6 and connectDone == 8
""",
    "inactive_ap": """
doAssert recover() == 0
doAssert apEnabled
""",
    "healthy_scan": """
sm_state = 0
connectDone = 0
doAssert recover() == 0
doAssert "abort" notin calls and "disconnect" notin calls and polls == 0
doAssert connectDone == 0 and fwStatus == 1
""",
    "replace_connection": """
sm_state = 0
connectDone = 0
doAssert recover(true) == 0
doAssert "disconnect" in calls and "abort" notin calls
""",
    "disconnect_owns_recovery": """
sm_state = SmDisconnectingState
connectDone = 0
storeU8(vifAt(0), BlVifLinksNumOff, 1)
var iface: pointer
doAssert wifi_mgmr_scan(nil, nil) == -16
doAssert wifi_mgmr_sta_connect(addr iface, "ssid", "password", nil, nil, 0, 1) == -16
doAssert calls == @["recover", "recover"] and polls == 0
doAssert connectDone == 0 and disconnectDone == 0
doAssert loadU8(vifAt(0), BlVifLinksNumOff) == 1 and sm_state == SmDisconnectingState
sm_state = 0
fwStatus = 0
connectDone = -1
disconnectDone = 1
storeU8(vifAt(0), BlVifLinksNumOff, 0)
doAssert wifi_mgmr_scan(nil, nil) == 0
doAssert wifi_mgmr_sta_connect(addr iface, "ssid", "password", nil, nil, 0, 1) == 0
doAssert calls == @["recover", "recover", "recover", "scan", "recover", "connect"]
""",
    "disconnect_failure": """
sm_state = 0
connectDone = 0
disconnectResult = -5
doAssert recover(true) == -5
doAssert connectDone == 0 and polls == 0
""",
    "rebind": """
onPoll = proc() = inc epoch
doAssert recover() < 0
doAssert connectDone != -1
""",
    "netif_rebind": """
onPoll = proc() = storePtr(vifAt(0), BlVifDevOff, addr alternateNetif[0])
doAssert recover() < 0
""",
    "missing_interface": """
fwStatus = -1
doAssert recover() < 0
doAssert "abort" notin calls
""",
    "queue_fails_during_poll": """
onPoll = proc() = cmdReady = false
doAssert recover() < 0
doAssert connectDone != -1
""",
    "nested_admission": """
onAbort = proc() =
  doAssert not beginStationControl(), "nested operation entered recovery"
doAssert recover() == 0
doAssert beginStationControl()
endStationControl()
""",
    "connect_recovery_failure": """
cmdReady = false
sm_state = 0
fwStatus = 0
var iface: pointer
doAssert wifi_mgmr_sta_connect(addr iface, "ssid", "password", nil, nil, 0, 1) < 0
doAssert "connect" notin calls
doAssert connectDone != 0, "failed preparation reported a connected station"
""",
    "connect_dispatch_failure": """
sm_state = 0
fwStatus = 0
connectDone = -1
connectResult = -5
var iface: pointer
doAssert wifi_mgmr_sta_connect(addr iface, "ssid", "password", nil, nil, 0, 1) == -5
doAssert connectDone > 0
""",
    "nested_connect": """
onAbort = proc() =
  var iface: pointer
  let before = connectDone
  doAssert wifi_mgmr_sta_connect(addr iface, "ssid", "password", nil, nil, 0, 1) == -16
  doAssert connectDone == before
doAssert recover() == 0
""",
    "scan_failure": """
abortResult = -5
doAssert wifi_mgmr_scan(nil, nil) == -5
doAssert "scan" notin calls
""",
    "active_after_idle": """
automatic = false
onPoll = proc() = sm_state = 0
doAssert recover() == -110
doAssert fwStatus == 1 and connectDone == 8
""",
    "host_link_pending": """
storeU8(vifAt(0), BlVifLinksNumOff, 1)
doAssert recover() == -110
doAssert loadU8(vifAt(0), BlVifLinksNumOff) == 1
""",
    "host_result_pending": """
connectDone = 0
automatic = false
onPoll = proc() =
  fwStatus = 0
  sm_state = 0
doAssert recover() == -110
doAssert connectDone == 0
""",
    "nested_ap_start": """
onAbort = proc() =
  doAssert wifi_mgmr_ap_start(nil, "ap", 0, "password", 1) == -16
  doAssert apEnabled
doAssert recover() == 0
doAssert "ap_start" notin calls
""",
    "nested_ap_stop": """
onAbort = proc() =
  doAssert wifi_mgmr_ap_stop(nil) == -16
  doAssert apEnabled
doAssert recover() == 0
doAssert "ap_stop" notin calls
""",
    "ap_stop_failure": """
disconnectResult = -5
doAssert wifi_mgmr_ap_stop(nil) == -5
doAssert apEnabled
""",
    "ap_start_failure": """
apEnabled = false
apRegistered = false
connectResult = -5
doAssert wifi_mgmr_ap_start(nil, "ap", 0, "password", 1) == -5
doAssert not apEnabled and not apRegistered
""",
    "ap_channel_plan": """
apEnabled = false
apRegistered = false
for channel in [0.cint, 12, 13, 14, 255]:
  doAssert wifi_mgmr_ap_start(nil, "ap", 0, nil, channel) == -1
  doAssert not apEnabled and not apRegistered and calls.len == 0
for channel in 1.cint .. 11.cint:
  apEnabled = false
  apRegistered = false
  doAssert wifi_mgmr_ap_start(nil, "ap", 0, nil, channel) == 0
  doAssert apEnabled and apRegistered and lastApChannel == channel
doAssert calls.len == 11
for call in calls: doAssert call == "ap_start"
""",
    "sta_channel_plan": """
var iface: pointer
let before = connectDone
for channel in [12'u8, 13, 14, 15, 255]:
  doAssert wifi_mgmr_sta_connect(addr iface, "ssid", nil, nil, nil, 0, channel) == -1
doAssert wifi_mgmr_sta_connect(addr iface, "ssid", nil, nil, nil, 1, 6) == -1
doAssert calls.len == 0 and connectDone == before
sm_state = 0
fwStatus = 0
connectDone = -1
for channel in 0'u8 .. 11'u8:
  doAssert wifi_mgmr_sta_connect(addr iface, "ssid", nil, nil, nil, 0, channel) == 0
  doAssert lastStaFrequency == (if channel == 0: 0'u16 else: 2407'u16 + 5'u16 * channel.uint16)
  doAssert calls == @["recover", "connect"]
  calls.setLen(0)
""",
    "disconnect_admission": """
doAssert wifi_mgmr_sta_disconnect() == 0
doAssert "disconnect" in calls and polls == 0 and disconnectDone == 0
""",
    "abort_admission": """
doAssert wifi_mgmr_sta_connect_abort() == 0
doAssert "abort" in calls and polls == 0 and disconnectDone == 0
""",
    "disconnect_rejected": """
disconnectResult = -5
doAssert wifi_mgmr_sta_disconnect() == -5
doAssert polls == 0 and connectDone == 8
""",
    "abort_rejected": """
abortResult = -110
doAssert wifi_mgmr_sta_connect_abort() == -110
doAssert polls == 0 and connectDone == 8
""",
}


def program(case: str, mutation: str | None = None) -> str:
    scan = (SUPPORT / "mgmr_facade_parts/scan_connect.nim").read_text()
    helper = SUPPORT / "mgmr_facade_parts/station_recovery.nim"
    source = PLATFORM
    names = sorted(set(re.findall(r"\bnimfwDbg\w+", scan)))
    source += "\nvar\n" + "".join(f"  {name}: uint32\n" for name in names)
    source += "\ntype ScanCompleteCb = proc(env: pointer) {.cdecl.}\n"
    if helper.exists():
        body = helper.read_text()
        if mutation:
            before, after = {
                "ready": ("  if not wifiCmdMgrReady(cast[pointer](addr wifi_hw)): return -32\n", ""),
                "abort": ("  if result != 0: return\n", ""),
                "epoch": (" or\n      not rxHostSessionCurrent(identity.session)", ""),
                "busy": ("  if stationControlBusy: return false\n", ""),
                "idle": ("sm_state == 0 and bindingStatus == 0 and ", ""),
                "host_link": (" and\n        loadU8(identity.hostVif, BlVifLinksNumOff) == 0", ""),
                "host_result": (" and connectDone != 0", ""),
                "identity": ("      loadPtr(identity.hostVif, BlVifDevOff) != identity.netif or\n", ""),
            }[mutation]
            assert before in body, mutation
            body = body.replace(before, after)
        source += body
        source += """
proc recover(join = false): cint =
  doAssert beginStationControl()
  defer: endStationControl()
  wifi_mgmr_recover_terminal_connect_failure(join)
"""
    else:
        source += """
var busy = false
proc beginStationControl(): bool =
  if busy: return false
  busy = true
  true
proc endStationControl() = busy = false
"""
        source += procedure(scan, "wifi_mgmr_recover_terminal_connect_failure")
        source += "\nproc recover(join = false): cint =\n  if wifi_mgmr_recover_terminal_connect_failure(): 0 else: -1\n"
    for name in ["wifi_mgmr_prepare_join_after_scan", "wifi_mgmr_scan", "wifi_mgmr_sta_connect",
                 "wifi_mgmr_sta_disconnect", "wifi_mgmr_sta_connect_abort"]:
        source += procedure(scan, name)
    source += """
proc wifiApReleaseInterface(): cint =
  apRegistered = false
  0
proc wifiApRegisterInterface(): cint =
  apRegistered = true
  0
proc apIface(): pointer = staIface()
proc netif_set_up(netif: ptr Netif) = discard
proc netif_set_link_up(netif: ptr Netif) = discard
proc netif_set_link_down(netif: ptr Netif) = discard
"""
    ap = (SUPPORT / "mgmr_facade_parts/ap_control.nim").read_text()
    for name in ["wifi_mgmr_ap_start", "wifi_mgmr_ap_stop"]:
        source += procedure(ap, name)
    source += """
storePtr(vifAt(0), BlVifDevOff, addr netif[0])
storeU8(vifAt(0), BlVifUpOff, 1)
storeU8(vifAt(0), BlVifVifIdxOff, 0)
""" + CHECKS[case] + """
doAssert "reset" notin calls and "delete" notin calls and "prune" notin calls and "add" notin calls,
  "station recovery reset or removed live firmware state"
doAssert enabled
"""
    return source


def run_program(tmp_path: Path, source: str, mode: str, fails: bool = False) -> None:
    nim = shutil.which("nim")
    if nim is None: pytest.skip("Nim is required")
    path = tmp_path / "station_recovery.nim"
    path.write_text(source)
    flags = {"checked": [], "release": ["-d:release"],
             "asan": ["--passC:-fsanitize=address", "--passL:-fsanitize=address"]}[mode]
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
                             "-d:WifiStaRecoveryPollLimit=4", *flags, "--checks:on",
                             f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}", str(path)],
                            cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    if fails: assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
    else: assert result.returncode == 0, result.stdout


@pytest.mark.parametrize("case", CHECKS)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_station_recovery(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, program(case), mode)


MUTANTS = {"ready": "idle_queue_failed", "abort": "transport_failure", "epoch": "rebind",
           "busy": "nested_admission", "idle": "active_after_idle", "host_link": "host_link_pending",
           "host_result": "host_result_pending", "identity": "netif_rebind"}


@pytest.mark.parametrize("mutation", MUTANTS)
def test_station_recovery_guards(tmp_path: Path, mutation: str) -> None:
    run_program(tmp_path, program(MUTANTS[mutation], mutation), "checked", True)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_station_binding_status(tmp_path: Path, mode: str) -> None:
    source = r"""
const MAX_VIFS = 2
const VIF_TYPE_STA = 0'u8
type
  CoListHdr = object
  Vif = object
    macAddr: array[6, uint8]
    vifType, vifIdx, state, staIdx: uint8
    chanCtxt: pointer
  Env = object
    activeList: int
var
  vifs: array[2, Vif]
  env: Env
  active = [true, true]
  enabled: bool
proc irqSave(): uint32 =
  result = if enabled: 8'u32 else: 0'u32
  enabled = false
proc irqRestore(value: uint32) = enabled = value != 0
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc vifMgmtEnvView(): ptr Env = addr env
proc co_list_find(list: ptr int; node: ptr CoListHdr): bool =
  for index in 0 ..< vifs.len:
    if node == cast[ptr CoListHdr](addr vifs[index]): return active[index]
proc c_memcmp(a, b: pointer; length: csize_t): cint {.importc: "memcmp", header: "<string.h>", cdecl.}
"""
    source += procedure((ROOT / "src/bl808/wifi/fw/vif_management.nim").read_text(), "vif_mgmt_sta_status")
    source += r"""
for state in [false, true]:
  enabled = state
  var mac = [2'u8, 3, 4, 5, 6, 7]
  vifs[0] = Vif(macAddr: mac, vifType: 0, vifIdx: 0, staIdx: 255)
  active[0] = true
  doAssert vif_mgmt_sta_status(2, addr mac[0]) == -1
  doAssert vif_mgmt_sta_status(0, nil) == -1
  doAssert vif_mgmt_sta_status(0, addr mac[0]) == 0
  vifs[0].state = 1
  doAssert vif_mgmt_sta_status(0, addr mac[0]) == 1
  vifs[0].state = 0
  vifs[0].staIdx = 0
  doAssert vif_mgmt_sta_status(0, addr mac[0]) == 1
  vifs[0].staIdx = 255
  vifs[0].chanCtxt = cast[pointer](1)
  doAssert vif_mgmt_sta_status(0, addr mac[0]) == 1
  vifs[0].chanCtxt = nil
  vifs[0].vifType = 2
  doAssert vif_mgmt_sta_status(0, addr mac[0]) == -1
  vifs[0].vifType = 0
  vifs[0].vifIdx = 1
  doAssert vif_mgmt_sta_status(0, addr mac[0]) == -1
  vifs[0].vifIdx = 0
  vifs[0].macAddr[0] = 4
  doAssert vif_mgmt_sta_status(0, addr mac[0]) == -1
  vifs[0].macAddr = mac
  active[0] = false
  doAssert vif_mgmt_sta_status(0, addr mac[0]) == -1
  doAssert enabled == state
"""
    run_program(tmp_path, source, mode)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_command_manager_readiness(tmp_path: Path, mode: str) -> None:
    from test_wifi_cmd_lifecycle import program as command_program
    source = command_program("unused").split('\nconst TestCase = "', 1)[0]
    source += procedure((ROOT / "src/bl808/wifi/cmds.nim").read_text(), "wifiCmdMgrReady")
    source += r"""
for state in [false, true]:
  install(state)
  doAssert not wifiCmdMgrReady(nil)
  doAssert wifiCmdMgrReady(H())
  storePtr(E(), EnvMsgA2eHostidOff, cast[pointer](1))
  doAssert wifiCmdMgrReady(H())
  storeU32(H(), MgrStateOff, RwnxCmdMgrStateCrashed)
  doAssert not wifiCmdMgrReady(H())
  storeU32(H(), MgrStateOff, RwnxCmdMgrStateDraining)
  doAssert not wifiCmdMgrReady(H())
  storeU32(H(), MgrStateOff, 0)
  storePtr(E(), EnvSharedOff, nil)
  doAssert not wifiCmdMgrReady(H())
  storePtr(E(), EnvSharedOff, S())
  storePtr(H(), BlHwIpcEnvOff, nil)
  doAssert not wifiCmdMgrReady(H())
  doAssert enabled == state
"""
    run_program(tmp_path, source, mode)
