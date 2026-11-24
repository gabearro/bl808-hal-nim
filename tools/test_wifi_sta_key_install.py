"""Exercise the full station-add/key handoff with bounded owned snapshots."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
const
  MAX_VIFS = 2
  STA_MGMT_FREE_STAS = 5
  VIF_TYPE_STA = 0'u8
type
  VifChannelView = object
    vifIdx, vifType, staIdx: uint8
    security: VifSecurityOverlay
    supportedRatesLong: array[34, uint8]
  Sta = object
    valid, instNbr, marker: uint8
  StaQueueIdentity = object
    entry: pointer
    stationEpoch, vifEpoch: uint32
    station, vif: uint8
  Header = object
    paramLen: uint32
  Sm = object
    state: uint8
    connectInfo: pointer
  WpaCallbacks = object
    keyWrite: pointer
  WpsCallbacks = object
    staConnected: pointer
var
  vifs: array[MAX_VIFS, VifChannelView]
  stations: array[STA_MGMT_FREE_STAS, Sta]
  rxVifEpochs: array[MAX_VIFS, uint32]
  stationEpochs: array[STA_MGMT_FREE_STAS, uint32]
  mmStaAddInProgress: array[MAX_VIFS, bool]
  mmStaAddVifEpoch: array[MAX_VIFS, uint32]
  connection, replacementConnection: ConnectInfoCredentialOverlay
  header: Header
  request: MmStaAddReqPayload
  sm: Sm
  wpa: WpaCallbacks
  wpsTable: WpsCallbacks
  wpa_cbs, wps_cbs: pointer
  wpaSent: WpaKeyWriteParamView
  wepSent: WepKeyWriteParamView
  irq: bool
  registrations, addresses, addressDeletes, wpaCalls, wepCalls, wpsCalls, rollbacks, unregisters, abortCleanups: int
  registerStatus, keyIndex: uint8
  wpaSetupResult: cint
  addressFails, addressCleanupFails: bool
  registrationAdmitted: bool
  hook: proc(point: string)
  nimFwDbgPreauthStaAddEntry, nimFwDbgPreauthStaAddMeta: uint32
  nimFwDbgPreauthStaAddResult, nimFwDbgPreauthStaAddExit: uint32
proc fire(point: string) =
  doAssert not irq
  if hook != nil: hook(point)
proc irqSave(): uint32 =
  result = if irq: 8'u32 else: 0'u32
  irq = false
proc irqRestore(saved: uint32) = irq = (saved and 8) != 0
proc vifChannelForIdx(index: uint8): ptr VifChannelView =
  doAssert index < MAX_VIFS
  addr vifs[index]
proc vifSecurity(vif: ptr VifChannelView): ptr VifSecurityOverlay = addr vif.security
proc smEnvView(): ptr Sm = addr sm
proc smRegistrationAdmitRequest(p: pointer): bool = registrationAdmitted
proc connectInfoCredentials(p: pointer): ptr ConnectInfoCredentialOverlay = cast[ptr ConnectInfoCredentialOverlay](p)
proc keMsgHdrFromPayload(p: pointer): ptr Header =
  doAssert p == (addr connection) or p == (addr replacementConnection)
  addr header
proc mmStaAddReqView(p: pointer): ptr MmStaAddReqPayload = cast[ptr MmStaAddReqPayload](p)
proc staDeleteEpoch(index: uint8): uint32 =
  if index < STA_MGMT_FREE_STAS: stationEpochs[index] else: 0
proc staDeleteIsCurrent(index: uint8; epoch: uint32): bool =
  index < STA_MGMT_FREE_STAS and stations[index].valid != 0 and stationEpochs[index] == epoch
proc staInfoForIdx(index: uint8): ptr Sta =
  doAssert index < STA_MGMT_FREE_STAS
  addr stations[index]
proc sta_mgmt_register(p: pointer; index: ptr uint8): uint8 =
  inc registrations
  if registerStatus != 0: return registerStatus
  let req = mmStaAddReqView(p)
  doAssert req.vifIdx < MAX_VIFS and req.bssid == [2'u8, 3, 4, 5, 6, 7]
  for i in 0 ..< stations.len:
    if stations[i].valid == 0:
      stations[i] = Sta(valid: 1, instNbr: req.vifIdx, marker: 7)
      index[] = i.uint8
      fire("register")
      return 0
  1
proc mm_sec_machwaddr_wr(index: uint8; slot: pointer; unused: uint8): uint8 =
  doAssert cast[uint](slot) == stations[index].instNbr.uint and unused == 0
  inc addresses
  result = if addressFails: 0xFF'u8 else: index + 8
  fire("address")
proc mm_sec_machwkey_wr(p: pointer): uint8 =
  wepSent = cast[ptr WepKeyWriteParamView](p)[]
  inc wepCalls
  result = keyIndex
  fire("wep")
proc mm_sta_del(index: uint8) =
  inc rollbacks
  doAssert stations[index].valid != 0 and stations[index].marker == 7
  stations[index].valid = 0
  inc stationEpochs[index]
  fire("rollback")
proc sta_mgmt_unregister(index: uint8) =
  inc unregisters
  doAssert stations[index].valid != 0 and stations[index].marker == 7
  stations[index].valid = 0
  inc stationEpochs[index]
  fire("unregister")
proc staMgmtBeginRemoval(index: uint8; owner: var StaQueueIdentity): pointer =
  doAssert stations[index].valid != 0 and stations[index].marker == 7
  owner = StaQueueIdentity(entry: addr stations[index], station: index,
    stationEpoch: stationEpochs[index] + 1, vif: stations[index].instNbr,
    vifEpoch: rxVifEpochs[stations[index].instNbr])
  stations[index].valid = 0
  inc stationEpochs[index]
  addr stations[index]
proc staRemovalCurrent(owner: StaQueueIdentity): bool =
  owner.entry == cast[pointer](addr stations[owner.station]) and
    stations[owner.station].valid == 0 and
    stations[owner.station].instNbr == owner.vif and
    stationEpochs[owner.station] == owner.stationEpoch and
    rxVifEpochs[owner.vif] == owner.vifEpoch
proc mmDeleteSecurityAddress(index: uint8): bool =
  inc addressDeletes
  fire("address-delete")
  not addressCleanupFails
proc staMgmtFinishRemoval(owner: StaQueueIdentity) =
  doAssert staRemovalCurrent(owner)
  inc unregisters
  fire("unregister")
proc mmStaDelTrackUnpublished(owner: StaQueueIdentity) =
  inc abortCleanups
  if mmDeleteSecurityAddress(owner.station) and staRemovalCurrent(owner):
    staMgmtFinishRemoval(owner)
proc wpaWrite(p: pointer) {.cdecl.} =
  wpaSent = cast[ptr WpaKeyWriteParamView](p)[]
  inc wpaCalls
  fire("wpa")
proc bl808WpaStaConnectResult(callback, params: pointer): cint =
  cast[proc(p: pointer) {.cdecl.}](callback)(params)
  wpaSetupResult
proc wpsConnected(vif, station: uint8) {.cdecl.} =
  doAssert vif < MAX_VIFS and station < STA_MGMT_FREE_STAS
  inc wpsCalls
  fire("wps")
proc wpaCallbacks(): ptr WpaCallbacks = addr wpa
proc wpsCallbacks(): ptr WpsCallbacks = addr wpsTable
proc setup(mode: string; incomingIrq = true) =
  hook = nil
  registrationAdmitted = true
  irq = incomingIrq
  vifs = default(typeof(vifs))
  stations = default(typeof(stations))
  rxVifEpochs = [1'u32, 2]
  stationEpochs = [1'u32, 2, 3, 4, 5]
  mmStaAddInProgress = default(typeof(mmStaAddInProgress))
  mmStaAddVifEpoch = default(typeof(mmStaAddVifEpoch))
  connection = default(ConnectInfoCredentialOverlay)
  replacementConnection = default(ConnectInfoCredentialOverlay)
  header.paramLen = sizeof(connection).uint32
  for i in 0 ..< 8: connection.keyString[i] = 65
  request = MmStaAddReqPayload(vifIdx: 0, quickConn: 1, bssid: [2'u8, 3, 4, 5, 6, 7])
  for i in 0 ..< MAX_VIFS:
    vifs[i].vifIdx = i.uint8
    vifs[i].staIdx = 0xFF
    vifs[i].security.connected = 1
    vifs[i].supportedRatesLong[0] = 3
    vifs[i].supportedRatesLong[1] = 120
    vifs[i].supportedRatesLong[2] = 121
    vifs[i].supportedRatesLong[3] = 122
  sm = Sm(state: 1, connectInfo: addr connection)
  wpa = WpaCallbacks(keyWrite: cast[pointer](wpaWrite))
  wpsTable = WpsCallbacks(staConnected: cast[pointer](wpsConnected))
  wpa_cbs = addr wpa
  wps_cbs = addr wpsTable
  case mode
  of "ap": vifs[0].vifType = 2
  of "wps": sm.state = 2
  of "wpa": vifs[0].security.cipher = 3
  of "wep":
    vifs[0].security.cipher = 1
    connection.keyString[5] = 0
  else: discard
  registrations = 0
  addresses = 0
  addressDeletes = 0
  wpaCalls = 0
  wepCalls = 0
  wpsCalls = 0
  rollbacks = 0
  abortCleanups = 0
  unregisters = 0
  registerStatus = 0
  wpaSetupResult = 0
  addressFails = false
  addressCleanupFails = false
  keyIndex = 4
  wpaSent = default(WpaKeyWriteParamView)
  wepSent = default(WepKeyWriteParamView)
proc mm_sta_add*(param: pointer; staIdxOut, hwStaIdxOut: ptr uint8): uint8 {.exportc, cdecl.}
proc invoke(): uint8 =
  var index = 0x91'u8
  var hardware = 0x92'u8
  result = mm_sta_add(addr request, addr index, addr hardware)
  if result == 0:
    doAssert index < STA_MGMT_FREE_STAS and hardware == index + 8
  else:
    doAssert index == 0xFF and hardware == 0xFF
"""

CHECKS = r"""
for mode in ["open", "wps", "wpa", "wep"]:
  for point in ["register", "address"]:
    setup(mode)
    hook = proc(stage: string) =
      if stage == point: registrationAdmitted = false
    doAssert invoke() != 0
    doAssert registrations == 1 and abortCleanups == 1 and rollbacks == 0
    doAssert addressDeletes == 1 and unregisters == 1
    doAssert stations[0].valid == 0

for mode in ["ap", "open", "wps", "wpa", "wep"]:
  for incomingIrq in [false, true]:
    setup(mode, incomingIrq)
    doAssert invoke() == 0 and irq == incomingIrq
    doAssert registrations == 1 and addresses == 1 and rollbacks == 0
    doAssert wpaCalls == (mode == "wpa").int
    doAssert wepCalls == (mode == "wep").int
    doAssert wpsCalls == (mode == "wps").int
    doAssert vifs[0].staIdx == (if mode == "ap": 0xFF'u8 else: 0)
    doAssert not mmStaAddInProgress[0]
    if mode == "wpa":
      doAssert wpaSent.keyDataLen == 3 and wpaSent.keyMaterial[0] == 120
      doAssert wpaSent.ssid[0] == 65 and wpaSent.ssid[8] == 0 and wpaSent.quickConn == 1
      doAssert wpaSent.ssidTailPadding == [0'u8, 0, 0]
    if mode == "wep":
      doAssert wepSent.keyLen == 5 and wepSent.cipherMode == 0
      doAssert wepSent.keyData[0] == 65 and wepSent.selector == 0xFF00

for length in 0 .. 255:
  setup("wpa")
  vifs[0].supportedRatesLong[0] = length.uint8
  doAssert (invoke() == 0) == (length <= 32)
  doAssert registrations == (length <= 32).int
for length in 0 .. 64:
  setup("wpa")
  connection.keyString = default(typeof(connection.keyString))
  for i in 0 ..< length: connection.keyString[i] = 65
  doAssert invoke() == 0
  if length == 64: doAssert wpaSent.ssidTailPadding[0] == 0
setup("wpa")
for ch in connection.keyString.mitems: ch = 71
doAssert invoke() != 0 and registrations == 0

for length in 0'u32 .. 190:
  setup("wpa")
  header.paramLen = length
  doAssert (invoke() == 0) == (length >= 71)
  setup("wpa")
  for ch in connection.altSsid.mitems: ch = 66
  header.paramLen = length
  let expected = if length <= 126: length >= 71 else: length >= 190
  doAssert (invoke() == 0) == expected
  if expected and length >= 190: doAssert wpaSent.ssid[63] == 66

for length in [5, 10, 13, 26]:
  setup("wep")
  connection.keyString = default(typeof(connection.keyString))
  for i in 0 ..< length: connection.keyString[i] = 65
  doAssert invoke() == 0
  doAssert wepSent.keyLen == (if length in [10, 26]: length div 2 else: length).uint8
  doAssert wepSent.cipherMode == (if length in [13, 26]: 3'u8 else: 0)
  doAssert wepSent.keyData[0] == (if length in [10, 26]: 0xAA'u8 else: 65)
for length in [0, 4, 6, 12, 14, 63, 64]:
  setup("wep")
  connection.keyString = default(typeof(connection.keyString))
  for i in 0 ..< length: connection.keyString[i] = 65
  doAssert invoke() != 0 and registrations == 0
setup("wep")
for i in 0 ..< 10: connection.keyString[i] = 71
connection.keyString[10] = 0
doAssert invoke() != 0 and registrations == 0

for index in [2'u8, 255]:
  setup("open")
  request.vifIdx = index
  doAssert invoke() != 0 and registrations == 0
setup("wpa")
wpa_cbs = nil
doAssert invoke() != 0 and registrations == 0
setup("open")
registerStatus = 7
doAssert invoke() == 7 and addresses == 0
setup("wep")
keyIndex = 0xFF
doAssert invoke() != 0 and abortCleanups == 1 and addressDeletes == 1

setup("wpa")
wpaSetupResult = -1
doAssert invoke() != 0 and wpaCalls == 1 and irq
doAssert vifs[0].staIdx == 0xFF and stations[0].valid == 0
doAssert abortCleanups == 1 and addressDeletes == 1 and unregisters == 1
wpaSetupResult = 0
doAssert invoke() == 0 and wpaCalls == 2
doAssert vifs[0].staIdx == 0 and stations[0].valid != 0
doAssert abortCleanups == 1 and addressDeletes == 1 and unregisters == 1

for mode in ["ap", "open", "wps", "wpa", "wep"]:
  for incomingIrq in [false, true]:
    setup(mode, incomingIrq)
    addressFails = true
    doAssert invoke() != 0 and rollbacks == 0 and abortCleanups == 1 and
      unregisters == 1 and irq == incomingIrq
    doAssert addresses == 1 and addressDeletes == 1 and
      wpsCalls == 0 and wpaCalls == 0 and wepCalls == 0
    doAssert stations[0].valid == 0 and not mmStaAddInProgress[0]

for mode in ["ap", "open", "wps", "wpa", "wep"]:
  setup(mode)
  addressFails = true
  addressCleanupFails = true
  doAssert invoke() != 0 and addresses == 1 and addressDeletes == 1
  doAssert stations[0].valid == 0 and unregisters == 0,
    "uncleared hardware address returned the station slot to the free pool"

for replaceVif in [false, true]:
  setup("open")
  addressFails = true
  hook = proc(stage: string) =
    if stage != "address": return
    if replaceVif: inc rxVifEpochs[0]
    else: inc stationEpochs[0]
    stations[0] = Sta(valid: 1, instNbr: 0, marker: 99)
  doAssert invoke() != 0 and stations[0].marker == 99
  doAssert rollbacks == 0 and unregisters == 0

for mode in ["wpa", "wep"]:
  for point in ["register", "address", mode]:
    setup(mode)
    var fired = false
    hook = proc(stage: string) =
      if fired or stage != point: return
      fired = true
      request.vifIdx = 99
      request.quickConn = 99
      for ch in connection.keyString.mitems: ch = 0xE7
      for ch in vifs[0].supportedRatesLong.mitems: ch = 0xE8
    doAssert invoke() == 0 and fired
    if mode == "wpa": doAssert wpaSent.quickConn == 1 and wpaSent.ssid[0] == 65
    else: doAssert wepSent.keyData[0] == 65

for mode in ["open", "wps", "wpa", "wep"]:
  let points = if mode == "open": @["register", "address"] else: @["register", "address", mode]
  for point in points:
    for action in 0 .. 2:
      setup(mode)
      var fired = false
      var replacementVif: VifChannelView
      var replacementSta: Sta
      hook = proc(stage: string) =
        if fired or stage != point: return
        fired = true
        if action == 0:
          inc rxVifEpochs[0]
          vifs[0].staIdx = 4
          vifs[0].security.staKeySlots = [9'u8, 10, 11, 12]
        elif action == 1:
          inc stationEpochs[0]
          stations[0] = Sta(valid: 1, instNbr: 0, marker: 99)
        else:
          sm.connectInfo = addr replacementConnection
        replacementVif = vifs[0]
        replacementSta = stations[0]
      doAssert invoke() != 0
      doAssert fired
      if action != 2:
        doAssert rollbacks == 0 and vifs[0] == replacementVif and stations[0] == replacementSta
      else:
        doAssert abortCleanups == 1 and addressDeletes == 1 and stations[0].valid == 0

for point in ["register", "address", "wpa"]:
  setup("wpa")
  var fired = false
  hook = proc(stage: string) =
    if fired or stage != point: return
    fired = true
    doAssert invoke() != 0
  doAssert invoke() == 0 and fired and registrations == 1

setup("wpa")
var replaced = false
hook = proc(stage: string) =
  if replaced or stage != "wpa": return
  replaced = true
  inc rxVifEpochs[0]
  inc stationEpochs[0]
  stations[0].valid = 0
  doAssert invoke() == 0
doAssert invoke() != 0 and replaced
doAssert registrations == 2 and wpaCalls == 2 and rollbacks == 0
doAssert vifs[0].staIdx == 0 and stations[0].valid == 1

# Independent AP clients may still register through a synchronous callback.
setup("ap")
var nestedAp = false
hook = proc(stage: string) =
  if nestedAp or stage != "address": return
  nestedAp = true
  doAssert invoke() == 0
doAssert invoke() == 0 and nestedAp and registrations == 2
doAssert vifs[0].staIdx == 0xFF

setup("open")
var logical, hardware: uint8
doAssert mm_sta_add(nil, addr logical, addr hardware) != 0
doAssert mm_sta_add(addr request, nil, addr hardware) != 0
doAssert mm_sta_add(addr request, addr logical, nil) != 0
doAssert registrations == 0
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "ssid", "extent", "hex", "generation", "connection", "reentry", "outputs", "address", "address_cleanup", "key_setup_result"])
def test_sta_key_install(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    source = (FW / "kernel_mac_channel.nim").read_text()
    plan_type = re.search(r"(?ms)^type\n  MmStaKeyPlan = object.*?(?=^  MmStaDeletion = object)", source).group(0)
    parts = {name: procedure(source, name) for name in
             ["mmKeyHexDigit", "mmPrepareStaKeys", "mmStaAddCurrent", "mm_sta_add"]}
    if mutation == "ssid":
        parts["mmPrepareStaKeys"] = parts["mmPrepareStaKeys"].replace("if ssidLength > 32:", "if false:")
    elif mutation == "extent":
        parts["mmPrepareStaKeys"] = parts["mmPrepareStaKeys"].replace("min(payloadLength - keyOffset, credentials.keyString.len.uint32)", "credentials.keyString.len.uint32")
    elif mutation == "hex":
        parts["mmKeyHexDigit"] = parts["mmKeyHexDigit"].replace("else: -1", "else: 0")
    elif mutation == "generation":
        parts["mmStaAddCurrent"] = "proc mmStaAddCurrent(v: uint8; e: uint32; s: uint8; g: uint32): bool = true\n"
    elif mutation == "connection":
        parts["mm_sta_add"] = parts["mm_sta_add"].replace("(not keys.boundToConnection or smEnvView().connectInfo == keys.connection)", "true")
    elif mutation == "reentry":
        parts["mm_sta_add"] = parts["mm_sta_add"].replace("if guarded and mmStaAddInProgress[instNbr] and mmStaAddVifEpoch[instNbr] == vifEpoch:", "if false:")
    elif mutation == "outputs":
        parts["mm_sta_add"] = parts["mm_sta_add"].replace("  let stationEpoch = stationEpochs[staIdx.int]\n", "  staIdxOut[] = staIdx\n  let stationEpoch = stationEpochs[staIdx.int]\n")
    elif mutation == "address":
        parts["mm_sta_add"] = parts["mm_sta_add"].replace("if hwIdx == 0xFF:", "if false:")
    elif mutation == "address_cleanup":
        parts["mm_sta_add"] = parts["mm_sta_add"].replace(
            "mmStaDelTrackUnpublished(removal)",
            "staMgmtFinishRemoval(removal)")
    elif mutation == "key_setup_result":
        parts["mm_sta_add"] = parts["mm_sta_add"].replace(
            "if bl808WpaStaConnectResult(keys.callback, addr keys.wpa) != 0:\n      return abortOwned()",
            "discard bl808WpaStaConnectResult(keys.callback, addr keys.wpa)")
    layout = (FW / "layout_types.nim").read_text()
    types = ""
    for name in ["ConnectInfoView", "ConnectInfoCredentialOverlay", "VifSecurityOverlay",
                 "WpaKeyWriteParamView", "WepKeyWriteParamView", "MmStaAddReqPayload"]:
        types += re.search(rf"(?ms)^  {name}[^\n]*\n.*?(?=\n\n)", layout).group(0) + "\n"
    program = tmp_path / "keys.nim"
    program.write_text("type\n" + types + plan_type + PLATFORM + "\n".join(parts.values()) + CHECKS)
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}", *flags[mode], str(program)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and any(reason in result.stdout for reason in
            ["AssertionDefect", "IndexDefect", "AddressSanitizer", "SIGSEGV"]), result.stdout
