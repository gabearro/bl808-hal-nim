"""Execute directed scan credential selection and publication decisions."""

from pathlib import Path
import re
import shutil
import subprocess
import textwrap

import pytest

from test_wifi_disconnect_tx import procedure

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
const MAX_VIFS = 2
const VIF_TYPE_STA = 0'u8
type
  SmEnvView = object
    connectInfo: pointer
    state, connectModeFlags: uint8
  Vif = object
    vifIdx, vifType: uint8
    capabilityInfo: uint16
    macAddr, bssid: array[6, uint8]
  Ap = object
    securityFlags: uint32
  Assoc = object
    rsnIePtr: uint32
    rsnIeLen: uint8
  WpaParsedInfoView = object
    keyMgmtLe: uint32
    caps: uint16
    groupCipher, pairwiseCipher, keyMgmtMaskLow, scanNotifyVendorByte: uint8
  WpaParsedInfoBuffer = object
    view: WpaParsedInfoView
  WpaScanSecurityNotifyView = object
    vifIdx: uint8
    macAddr, bssid: array[6, uint8]
    cipher, scanNotifyVendorByte: uint8
    keyMgmt, cipherPair: uint16
  MacIeView = object
    id, len: uint8
  Callbacks = object
    parseSecurityIe, scanSecurityNotify: pointer
  Header = object
    paramLen: uint32
  Env = object
    directedFound: uint8
var
  connection: ConnectInfoCredentialOverlay
  security: VifSecurityOverlay
  station: SmEnvView
  vif: Vif
  ap: Ap
  assoc: Assoc
  header: Header
  scanu_env: Env
  callbacks: Callbacks
  wpa_cbs: pointer
  protocol: string
  parseFails: bool
  selectedAuth: uint32
  parserCalls, notifications, finalized: int
  irq = true
  informationElement: array[8, uint8]
  assocSecIeStore: array[MAX_VIFS, array[128, uint8]]
  nimFwDbgScanKeyMgmt, nimFwDbgScanSmF, nimFwDbgScanCaps, nimFwDbgScanAT: uint32
proc irqSave(): uint32 =
  result = if irq: 8'u32 else: 0'u32
  irq = false
proc irqRestore(saved: uint32) = irq = (saved and 8) != 0
proc connectInfoCredentials(p: pointer): ptr ConnectInfoCredentialOverlay = cast[ptr ConnectInfoCredentialOverlay](p)
proc connectInfoView(p: pointer): ptr ConnectInfoView = cast[ptr ConnectInfoView](p)
proc keMsgHdrFromPayload(p: pointer): ptr Header =
  doAssert p == addr connection.base
  addr header
proc c_memset(p: pointer; value: cint; length: csize_t): pointer =
  doAssert value == 0
  zeroMem(p, length.int)
  p
proc c_memcpy(dest, source: pointer; length: csize_t): pointer =
  copyMem(dest, source, length.int)
  dest
proc totalLen(ie: ptr MacIeView): uint = ie.len.uint + 2
proc find_wpa_rsn_ie(data: pointer; length: uint32; wpa, rsn: ptr pointer) =
  wpa[] = if protocol == "wpa": addr informationElement[0] else: nil
  rsn[] = if protocol == "rsn": addr informationElement[0] else: nil
proc parseSecurity(data: pointer; length: uint8; output: pointer): pointer {.cdecl.} =
  doAssert data == (addr informationElement[0]) and length == 6
  inc parserCalls
  cast[ptr WpaParsedInfoView](output)[] = WpaParsedInfoView(keyMgmtLe: 2,
    groupCipher: 3, pairwiseCipher: 3, keyMgmtMaskLow: 2)
  if parseFails: cast[pointer](1) else: nil
proc notifySecurity(data: pointer) {.cdecl.} = inc notifications
proc wpaCallbacks(): ptr Callbacks = addr callbacks
proc wifiPreferredKeyMgmtFromMask(mask: uint32; pmf: bool): uint32 = selectedAuth
proc nimFwTrace2U32(tag: string; a, b: uint32) = discard
proc me_bw_check(p: pointer) = inc finalized
proc me_extract_power_constraint(data: pointer; length: uint32; output: pointer) = discard
proc me_extract_country_reg(data: pointer; length: uint32; output: pointer) = discard
proc setup(keyLength: int; privacy: bool) =
  connection = default(ConnectInfoCredentialOverlay)
  connection.base.authType = 7
  connection.base.authRetryGate = 5
  connection.base.channelDuration = 0x12345678
  for i in 0 ..< min(keyLength, 64): connection.keyString[i] = 65
  security = default(VifSecurityOverlay)
  security.cipher = 9
  station = SmEnvView(connectInfo: addr connection.base, state: 1, connectModeFlags: 0x80)
  vif = Vif(vifType: 9, capabilityInfo: (if privacy: 0x10'u16 else: 0))
  ap = default(Ap)
  assoc = default(Assoc)
  header.paramLen = sizeof(connection).uint32
  scanu_env = default(Env)
  protocol = "legacy"
  parseFails = false
  selectedAuth = 0
  parserCalls = 0
  notifications = 0
  finalized = 0
  irq = true
  informationElement = [48'u8, 4, 1, 2, 3, 4, 0, 0]
  callbacks = Callbacks(parseSecurityIe: cast[pointer](parseSecurity),
    scanSecurityNotify: cast[pointer](notifySecurity))
  wpa_cbs = addr callbacks
"""

WRAPPER = r"""
proc exercise() =
  let securityState = addr security
  let stationManager = addr station
  let connectInfoPtr = station.connectInfo
  let connectInfo = connectInfoView(connectInfoPtr)
  let savedChannelDurationFlags = connectInfo.channelDuration
  let apConfig = addr ap
  let vifView = addr vif
  let assocState = addr assoc
  let bssInfoOut = cast[pointer](addr ap)
  let ieStart = cast[pointer](addr informationElement[0])
  let ieLen = informationElement.len.uint32
  let directedOwner = (connection: connectInfoPtr)
  template requireFrameOwner() = discard
"""

CHECKS = r"""
const keyOffset = offsetof(ConnectInfoCredentialOverlay, keyString).uint32
# The reader cannot use a terminator outside the owned extent or key field.
for length in 0'u32 .. keyOffset + 64:
  let bytes = cast[ptr UncheckedArray[uint8]](alloc0(max(length.int, 1)))
  if length > keyOffset:
    for i in keyOffset ..< length: bytes[i] = 65
  doAssert scanuConnectionKeyLength(bytes, length) == -1
  if length > keyOffset:
    bytes[length - 1] = 0
    doAssert scanuConnectionKeyLength(bytes, length) == (length - keyOffset - 1).int
  dealloc(bytes)
doAssert scanuConnectionKeyLength(nil, 999) == -1
setup(64, true)
connection.altSsid[0] = 0
doAssert scanuConnectionKeyLength(addr connection, sizeof(connection).uint32) == -1

for privacy in [false, true]:
  for keyLength in 0 .. 64:
    for incomingIrq in [false, true]:
      setup(keyLength, privacy)
      irq = incomingIrq
      let accepted = if privacy: keyLength in [5, 10, 13, 26] else: keyLength == 0
      exercise()
      doAssert irq == incomingIrq
      doAssert scanu_env.directedFound == accepted.uint8
      doAssert finalized == accepted.int and notifications == 0 and parserCalls == 0
      doAssert (ap.securityFlags shr 31) == accepted.uint32
      doAssert vif.vifType == (if accepted: VIF_TYPE_STA else: 9'u8)
      doAssert security.cipher == (if privacy and accepted: 1'u8 else: 0'u8)
      doAssert connection.base.authType == (if privacy and accepted: 1'u8 else: 7'u8)
      doAssert connection.base.channelDuration == (if privacy: 0'u32 else: 2'u32)
      doAssert station.connectModeFlags == (0x80'u8 or
        (if accepted: 0'u8 elif privacy: 2'u8 else: 1'u8))

for keyLength in [10, 26]:
  for position in 0 ..< keyLength:
    for ch in 1 .. 255:
      setup(keyLength, true)
      connection.keyString[position] = ch.uint8
      exercise()
      let validHex = ch in ord('0') .. ord('9') or ch in ord('A') .. ord('F') or
                     ch in ord('a') .. ord('f')
      doAssert scanu_env.directedFound == validHex.uint8
      doAssert finalized == validHex.int
      doAssert station.connectModeFlags == (if validHex: 0x80'u8 else: 0x82'u8)

# Tight message bounds reject even when a terminator exists in allocation slack.
for privacy in [false, true]:
  for length in [0'u32, 61, 62, 66, 67]:
    setup(5, privacy)
    header.paramLen = length
    exercise()
    doAssert scanu_env.directedFound == 0 and finalized == 0
    doAssert (station.connectModeFlags and (if privacy: 2'u8 else: 1'u8)) != 0
  setup(5, privacy)
  header.paramLen = 68
  exercise()
  doAssert scanu_env.directedFound == privacy.uint8

for family in ["wpa", "rsn"]:
  for fail in [false, true]:
    for auth in [0'u32, 2, 1024]:
      setup(8, true)
      protocol = family
      parseFails = fail
      selectedAuth = auth
      exercise()
      let accepted = not fail and auth != 0
      doAssert parserCalls == 1
      doAssert notifications == accepted.int and finalized == accepted.int
      doAssert scanu_env.directedFound == accepted.uint8
      doAssert (ap.securityFlags shr 31) == accepted.uint32
      doAssert station.connectModeFlags == 0x80
      doAssert security.cipher == (if accepted and auth == 1024: 4'u8 elif family == "wpa": 2'u8 else: 3'u8)
  for absent in ["table", "parser"]:
    setup(8, true)
    protocol = family
    selectedAuth = 2
    if absent == "table": wpa_cbs = nil
    else: callbacks.parseSecurityIe = nil
    exercise()
    doAssert parserCalls == 0 and finalized == 0 and notifications == 0
    doAssert scanu_env.directedFound == 0

# Existing joining state and already prepared BSS state retain vendor bypasses.
for prepared in [false, true]:
  setup(64, true)
  if prepared: ap.securityFlags = 0x80000000'u32
  else: station.state = 2
  exercise()
  doAssert finalized == 1 and scanu_env.directedFound == 1
  doAssert station.connectModeFlags == 0x80 and parserCalls == 0
  doAssert connection.base.channelDuration == (if prepared: 0x12345678'u32 else: 0x12345679'u32)
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "extent", "key_capacity", "wep", "open",
                                      "auth", "publish", "parse", "reset_acceptance", "hex"])
def test_scan_credentials(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    scan = (FW / "scan_station_ap_me.nim").read_text()
    reader = procedure(scan, "scanuConnectionKeyLength")
    legacy = procedure(scan, "scanuApplyLegacyCredentialPolicy").split("\n{.emit:", 1)[0]
    body = procedure(scan, "scanu_frame_handler")
    section = "      securityState.connected = connectInfo.authRetryGate\n" + body.split(
        "      securityState.connected = connectInfo.authRetryGate\n", 1)[1].split("\n  # WPS callback", 1)[0]
    if mutation == "extent":
        reader = reader.replace("min(payloadLength - keyOffset, credentials.keyString.len.uint32)", "credentials.keyString.len.uint32")
    elif mutation == "key_capacity":
        reader = reader.replace("min(payloadLength - keyOffset, credentials.keyString.len.uint32)", "payloadLength - keyOffset")
    elif mutation == "wep":
        legacy = legacy.replace("keyLength in [5, 10, 13, 26]", "keyLength > 0")
    elif mutation == "open":
        legacy = legacy.replace("if keyLength != 0:", "if false:")
    elif mutation == "auth":
        legacy = legacy.replace("connection.authType = 1", "connection.authType = 0")
    elif mutation == "hex":
        legacy = legacy.replace("if keyLength == 10 or keyLength == 26:", "if false:")
    elif mutation == "publish":
        section = section.replace("      if securityAccepted:", "      if true:")
    elif mutation == "parse":
        section = section.replace("if securityParsed and selectedAuth != 0:", "if selectedAuth != 0:")
    elif mutation == "reset_acceptance":
        section = section.replace("        securityAccepted = false\n", "")
    layout = (FW / "layout_types.nim").read_text()
    types = ""
    for name in ["ConnectInfoView", "ConnectInfoCredentialOverlay", "VifSecurityOverlay"]:
        types += re.search(rf"(?ms)^  {name}[^\n]*\n.*?(?=\n\n)", layout).group(0) + "\n"
    program = tmp_path / "credentials.nim"
    program.write_text("type\n" + types + PLATFORM + reader + legacy + WRAPPER
                       + textwrap.indent(textwrap.dedent(section), "  ") + "\n" + CHECKS)
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
