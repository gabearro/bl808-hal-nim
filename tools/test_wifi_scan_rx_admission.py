"""Check scan RX admission and bounded vendor-IE matching."""

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
  TASK_SCANU = 2'u8
  KeMsgConsumed = 0.cint
  KeMsgNoFree = 1.cint
  IE_ID_SSID = 0'u8
  IE_ID_DS_PARAM = 3'u8
  IE_ID_HT_CAP = 45'u8
  IE_ID_RSN = 48'u8
type
  Header = object
    paramLen: uint32
  Ssid = object
    length: uint8
    bytes: array[32, uint8]
  ScanSsidSlotView = Ssid
  Request = object
    flags: uint32
    vifIdx, scanType: uint8
    ssid: Ssid
  ScanuStartReqPayload = Request
  Env = object
    paramPtr: pointer
    bssidFilterEnabled: uint8
    filterBssid: array[6, uint8]
  WpaParsedInfoView = object
    caps: uint16
  Result = object
    valid: uint8
    cachedRxuMgtInd: pointer
    rssi: int8
  Callbacks = object
    parseSecurityIe: pointer
  Ds = object
    ie: MacIeView
    currentChannel: uint8
var
  WPA_OUI = [0'u8, 0x50, 0xF2, 1]
  header: Header
  request: Request
  scanu_env: Env
  resultEntry: Result
  state: uint16
  parses, lookups, forwards, notifications, logs: int
  nimFwDbgScanFrameSeen: uint32
  callbacks: Callbacks
  wpa_cbs: pointer
  lastLogLine, lastLogValue: uint32
  allocation: pointer
  allocated: uint32
  scanuRequestEpoch: uint32
  cachedSsid: tuple[generation: uint32]
  exposeSecurityIe: bool
  callbackCalls: int
proc rxuMgtIndAt(p: pointer): ptr RxuMgtIndView = cast[ptr RxuMgtIndView](p)
proc rxuMgtIndMsgAt(p: pointer): ptr RxuMgtIndMsgView = cast[ptr RxuMgtIndMsgView](p)
proc rxuMgtIndIeStart(p: pointer): pointer = addr rxuMgtIndAt(p).ieData[0]
proc rxuMgtIndSsidLogPtr(p: ptr RxuMgtIndView): pointer = addr p.ssidDebugLogWindow[8]
proc macIeAt(p: uint): ptr MacIeView = cast[ptr MacIeView](p)
proc totalLen(ie: ptr MacIeView): uint = ie.len.uint + 2
proc macIePayload(ie: ptr MacIeView): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](cast[uint](ie) + 2)
proc blOpsFunc(offset: int): pointer =
  doAssert offset == 8
  nil
proc c_memset(p: pointer; value: cint; length: csize_t): pointer =
  doAssert value == 0
  zeroMem(p, length.int)
  p
proc irqSave(): uint32 = 0
proc irqRestore(saved: uint32) = discard
proc keMsgHdrFromPayload(p: pointer): ptr Header = addr header
proc activeScanuReq(): ptr Request = cast[ptr Request](scanu_env.paramPtr)
proc scanuStartReqView(p: pointer): ptr Request = cast[ptr Request](p)
proc scanuCachedSsidFor(p: ptr Result): ptr typeof(cachedSsid) = addr cachedSsid
proc scanSsidSlot(req: ptr Request; index: int): ptr Ssid =
  doAssert index == 0
  addr req.ssid
proc ke_state_get(task: uint8): uint16 = state
proc ke_msg_forward_and_change_id(p: pointer; id: uint16; dest, source: uint8) =
  doAssert p == allocation and id == 0x804 and dest == 9 and source == 2
  inc forwards
proc ke_msg_send_basic(id: uint16; dest, source: uint8) =
  doAssert id == 76 and dest == 1 and source == 2
  inc notifications
proc find_wpa_rsn_ie(data: pointer; length: uint32; wpa, rsn: ptr pointer) =
  inc parses
  wpa[] = nil
  rsn[] = nil
  if exposeSecurityIe and length >= 2:
    let ie = cast[ptr MacIeView](data)
    if ie.id == 48: rsn[] = data
    elif ie.id == 221: wpa[] = data
proc parseSecurity(data: pointer; length: uint8; output: pointer): pointer {.cdecl.} =
  inc callbackCalls
  nil
proc wpaCallbacks(): ptr Callbacks = addr callbacks
proc scanu_find_result(bssid: pointer; create: uint8): pointer =
  inc lookups
  addr resultEntry
proc scanuResultAt(p: pointer): ptr Result = cast[ptr Result](p)
proc dsParamSetIeAt(p: pointer): ptr Ds = cast[ptr Ds](p)
proc dsParamFreq(band: uint8; ds: ptr Ds): uint16 = 2412
proc logHook(a, b: uint32; fmt: pointer; line, value: uint32) {.cdecl, varargs.} =
  doAssert a == 2 and b == 0 and fmt == nil
  inc logs
  lastLogLine = line
  lastLogValue = value
proc getLogFunc(offset: int): typeof(logHook) =
  doAssert offset == 204
  logHook
proc setup(length: uint32 = 68; subtype: uint16 = 0x80) =
  if allocation != nil: dealloc(allocation)
  allocated = length
  allocation = alloc0(max(length.int, 1))
  header.paramLen = length
  state = 1
  request = Request(vifIdx: 0, scanType: 1)
  request.ssid.length = 1
  scanu_env = Env(paramPtr: addr request,
    filterBssid: [2'u8, 3, 4, 5, 6, 7])
  resultEntry = default(Result)
  parses = 0
  lookups = 0
  forwards = 0
  notifications = 0
  logs = 0
  exposeSecurityIe = false
  callbackCalls = 0
  wpa_cbs = nil
  callbacks.parseSecurityIe = cast[pointer](parseSecurity)
  if length >= 68:
    rxuMgtIndAt(allocation).frameLen = (length - 32).uint16
    rxuMgtIndAt(allocation).bssid = scanu_env.filterBssid
    rxuMgtIndMsgAt(allocation).frameCtrl = subtype
proc putIes(ies: openArray[uint8]) =
  setup((68 + ies.len).uint32)
  let dest = cast[ptr UncheckedArray[uint8]](rxuMgtIndIeStart(allocation))
  for i, value in ies: dest[i] = value
"""

CHECKS = r"""
for length in 0'u32 .. 67:
  setup(length)
  doAssert not scanuRxFrameValid(allocation, length)
  doAssert rxu_mgt_ind_handler_scanu(allocation) == KeMsgConsumed
  doAssert parses == 0 and forwards == 0 and lookups == 0
doAssert rxu_mgt_ind_handler_scanu(nil) == KeMsgConsumed

# The physical buffer has slack, but it is outside the message's owned extent.
# Its zero-length IE would parse successfully if the declared bound were lost.
setup(70)
header.paramLen = 69
doAssert not scanuRxFrameValid(allocation, header.paramLen)
doAssert rxu_mgt_ind_handler_scanu(allocation) == KeMsgConsumed
doAssert parses == 0 and lookups == 0 and forwards == 0

for frameLength in [0, 1, 35, 36, 37, 65535]:
  setup()
  rxuMgtIndAt(allocation).frameLen = frameLength.uint16
  let valid = frameLength == 36
  doAssert scanuRxFrameValid(allocation, allocated) == valid
  doAssert rxu_mgt_ind_handler_scanu(allocation) == (if valid: KeMsgNoFree else: KeMsgConsumed)
  doAssert parses == valid.int

for subtype in [0x00, 0x10, 0x50, 0x51, 0x80, 0x84, 0xB0, 0xD0, 0x2080]:
  setup(68, subtype.uint16)
  doAssert scanuRxFrameValid(allocation, allocated) == (subtype in [0x50, 0x80, 0x2080])

for join in [0'u8, 1]:
  for byteIndex in 0 ..< 6:
    setup()
    scanu_env.bssidFilterEnabled = join
    rxuMgtIndAt(allocation).bssid[byteIndex] = rxuMgtIndAt(allocation).bssid[byteIndex] xor 2
    doAssert rxu_mgt_ind_handler_scanu(allocation) == KeMsgNoFree
    doAssert forwards == 1 and parses == 0 and lookups == 0,
      "a directed scan admitted the wrong BSSID before parsing"
  setup()
  scanu_env.bssidFilterEnabled = join
  doAssert rxu_mgt_ind_handler_scanu(allocation) == KeMsgNoFree
  doAssert parses == 1 and lookups == 1
  setup()
  scanu_env.filterBssid = [0xFF'u8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
  scanu_env.bssidFilterEnabled = join
  discard rxu_mgt_ind_handler_scanu(allocation)
  doAssert parses == 1 and lookups == 1

for badField in 0 .. 2:
  setup()
  if badField == 0: request.vifIdx = 2
  elif badField == 1: request.scanType = 2
  else: request.ssid.length = 33
  discard rxu_mgt_ind_handler_scanu(allocation)
  doAssert forwards == 1 and parses == 0 and lookups == 0

for id in [0'u8, 3, 32, 42, 45, 221]:
  for length in 0 .. 33:
    var ie = @[id, length.uint8]
    for i in 0 ..< length: ie.add(0)
    if id == 221 and length >= 5:
      ie[2] = 0; ie[3] = 0x50; ie[4] = 0xF2; ie[5] = 2; ie[6] = 1
      if length >= 24:
        for aci in 0 ..< 4: ie[10 + aci * 4] = (aci shl 5).uint8
    putIes(ie)
    let valid = case id
      of 0: length <= 32
      of 3, 32, 42: length == 1
      of 45: length >= 26
      else: length < 5 or length >= 24
    doAssert scanuRxFrameValid(allocation, allocated) == valid
    doAssert rxu_mgt_ind_handler_scanu(allocation) == (if valid: KeMsgNoFree else: KeMsgConsumed)
    if not valid: doAssert parses == 0 and lookups == 0 and forwards == 0
    if ie.len > 2:
      # Remove the last byte without changing the advertised TLV size.
      putIes(ie[0 ..< ie.high])
      doAssert not scanuRxFrameValid(allocation, allocated)

var wmm = newSeq[uint8](26)
wmm[0..8] = [221'u8, 24, 0, 0x50, 0xF2, 2, 1, 1, 0]
for aci in 0 ..< 4:
  wmm[10 + aci * 4] = (aci shl 5).uint8
putIes(wmm)
doAssert scanuRxFrameValid(allocation, allocated)
wmm[14] = wmm[10] # duplicate BE, no BK
putIes(wmm)
doAssert not scanuRxFrameValid(allocation, allocated)

putIes([1'u8])
doAssert not scanuRxFrameValid(allocation, allocated)
putIes([99'u8, 0, 100, 2, 1, 2])
doAssert scanuRxFrameValid(allocation, allocated)
putIes(@[0'u8, 0, 3, 1, 1, 45, 26] & newSeq[uint8](26))
doAssert scanuRxFrameValid(allocation, allocated)
for ies in [@[0'u8, 0, 0, 1, 120],
            @[0'u8, 1, 120, 0, 0],
            @[3'u8, 1, 1, 3, 1, 6]]:
  putIes(ies)
  doAssert not scanuRxFrameValid(allocation, allocated)
  doAssert rxu_mgt_ind_handler_scanu(allocation) == KeMsgConsumed
  doAssert parses == 0 and lookups == 0 and forwards == 0

for ies in [@[48'u8, 0, 48, 0],
            @[221'u8, 4, 0, 0x50, 0xF2, 1,
              221, 4, 0, 0x50, 0xF2, 1]]:
  putIes(ies)
  doAssert not scanuRxFrameValid(allocation, allocated)
  doAssert rxu_mgt_ind_handler_scanu(allocation) == KeMsgConsumed
  doAssert parses == 0 and lookups == 0 and forwards == 0
putIes([221'u8, 4, 0, 0x50, 0xF2, 1, 48, 0])
doAssert scanuRxFrameValid(allocation, allocated)
putIes([221'u8, 4, 1, 2, 3, 4, 221, 4, 1, 2, 3, 4])
doAssert scanuRxFrameValid(allocation, allocated)

# The security parser callback length is uint8; payloads 254 and 255 would wrap.
for id in [48'u8, 221'u8]:
  for claimed in [253, 254, 255]:
    var ie = newSeq[uint8](claimed + 2)
    ie[0] = id
    ie[1] = claimed.uint8
    putIes(ie)
    exposeSecurityIe = true
    wpa_cbs = addr callbacks
    doAssert scanuRxFrameValid(allocation, allocated)
    discard rxu_mgt_ind_handler_scanu(allocation)
    doAssert parses == 1
    doAssert callbackCalls == (if claimed == 253: 1 else: 0)
    doAssert lookups == (if claimed == 253: 1 else: 0)
    doAssert forwards == (if claimed == 253: 0 else: 1)

# The Nim finder only returns a complete IE with enough declared OUI bytes.
var oui = [0'u8, 0x50, 0xF2, 2, 1]
doAssert mac_vsie_find(nil, 99, addr oui[0], 5) == nil
for available in 0 .. 35:
  let data = cast[ptr UncheckedArray[uint8]](alloc0(max(available, 1)))
  for claimed in 0 .. 255:
    if available >= 1: data[0] = 221
    if available >= 2: data[1] = claimed.uint8
    for i in 0 ..< min(available - 2, 5): data[i + 2] = oui[i]
    let found = mac_vsie_find(data, available.uint32, addr oui[0], 5)
    doAssert (found != nil) == (claimed >= 5 and claimed + 2 <= available)
  dealloc(data)
var vendor = [221'u8, 0, 221, 5, 0, 0x50, 0xF2, 2, 1]
doAssert mac_vsie_find(addr vendor[0], vendor.len.uint32, addr oui[0], 5) == addr vendor[2]
doAssert mac_vsie_find(addr vendor[0], vendor.len.uint32, nil, 1) == nil
doAssert mac_vsie_find(addr vendor[0], vendor.len.uint32, nil, 0) == addr vendor[0]
let wrapped = cast[pointer](high(uint) - 1'u)
doAssert mac_ie_find(wrapped, 4, 221) == nil
doAssert mac_vsie_find(wrapped, 4, addr oui[0], 5) == nil
dealloc(allocation)
allocation = nil
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "capacity", "bssid", "ssid", "ds",
                                      "ssid_duplicate", "ds_duplicate",
                                      "rsn_duplicate", "wpa_duplicate", "ht",
                                      "wmm", "dispatch"])
def test_scan_rx_admission(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    scan = (FW / "scan_station_ap_me.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    mac = (FW / "mac_config_debug.nim").read_text()
    names = ["scanuRxFrameValid", "scanuFrameMatchesBssid"]
    parts = {name: procedure(scan, name).split("\n{.emit:", 1)[0] for name in names}
    if mutation == "capacity":
        parts[names[0]] = parts[names[0]].replace(" or frameLength > payloadLength - headerLength", "")
    elif mutation == "bssid":
        parts[names[1]] = "proc scanuFrameMatchesBssid(rx: ptr RxuMgtIndView): bool = true\n"
    elif mutation in ["ssid", "ds", "ht"]:
        condition = {"ssid": "ie.len > 32", "ds": "ie.len != 1", "ht": "ie.len < 26"}[mutation]
        parts[names[0]] = parts[names[0]].replace(condition, "false")
    elif mutation == "ssid_duplicate":
        parts[names[0]] = parts[names[0]].replace("seenSsid or ie.len > 32", "ie.len > 32")
    elif mutation == "ds_duplicate":
        parts[names[0]] = parts[names[0]].replace("seenDsParam or ie.len != 1", "ie.len != 1")
    elif mutation == "rsn_duplicate":
        parts[names[0]] = parts[names[0]].replace("if seenRsn: return false", "if false: return false")
    elif mutation == "wpa_duplicate":
        parts[names[0]] = parts[names[0]].replace("if seenWpa: return false", "if false: return false")
    elif mutation == "wmm":
        parts[names[0]] = parts[names[0]].replace("body[4] == 1 and ie.len < 24", "false")
        parts[names[0]] = parts[names[0]].replace(
            "body[3] == 2 and body[4] == 1:\n          var seenAccessCategories",
            "false:\n          var seenAccessCategories")
    dispatch = procedure(tasks, "rxu_mgt_ind_handler_scanu")
    if mutation == "dispatch":
        dispatch = dispatch.replace("scanu_frame_handler(param, payloadLength)", "scanu_frame_handler(param, 0)")
    vsie = procedure(mac, "mac_vsie_find")
    # Compile the real entry path through cache lookup/notification. The later
    # directed-VIF/security/WPS population is intentionally not modeled here.
    full_entry = procedure(scan, "scanu_frame_handler")
    assert "c_strlen" not in full_entry and "rxuMgtIndSsidLogPtr" not in full_entry
    entry = full_entry.split("  # Security info\n", 1)[0]
    layout = (FW / "layout_types.nim").read_text()
    types = ""
    for name in ["MacIeView", "RxuMgtIndView", "RxuMgtIndMsgView"]:
        types += re.search(rf"(?ms)^  {name}[^\n]*\n.*?(?=\n\n)", layout).group(0) + "\n"
    program = tmp_path / "admission.nim"
    program.write_text("type\n" + types + PLATFORM + procedure(mac, "mac_ie_find") + vsie
                       + procedure(scan, "readLegacyRateIe") + "\n".join(parts.values())
                       + procedure(scan, "scanuRequestCurrent")
                       + "\nproc scanEarlyEndRequest() = ke_msg_send_basic(0x4C, 1, 2)\n"
                       + entry + dispatch + CHECKS)
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}", *flags[mode], str(program)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and any(reason in result.stdout for reason in
            ["AssertionDefect", "IndexDefect", "AddressSanitizer", "SIGSEGV", "SIGBUS"]), result.stdout
