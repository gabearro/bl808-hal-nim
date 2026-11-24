"""Execute directed scan credential selection and publication decisions."""

from pathlib import Path
import re
import shutil
import subprocess
import textwrap

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"


def test_sdk_wpa_parser_cipher_offsets() -> None:
    clang = shutil.which("clang")
    if clang is None:
        pytest.skip("clang is required")
    source = r'''
#include "build/bl_iot_sdk_b773b3f/components/network/wifi/include/supplicant_api.h"
_Static_assert(offsetof(wifi_wpa_ie_t, pairwise_cipher) == 4, "pairwise cipher ABI");
_Static_assert(offsetof(wifi_wpa_ie_t, group_cipher) == 8, "group cipher ABI");
_Static_assert(offsetof(wifi_connect_parm_t, pairwise_cipher) == 56, "connect pairwise ABI");
_Static_assert(offsetof(wifi_connect_parm_t, group_cipher) == 57, "connect group ABI");
_Static_assert(offsetof(wifi_connect_parm_t, pmf_required) == 123, "PMF required ABI");
_Static_assert(offsetof(wifi_connect_parm_t, mgmt_group_cipher) == 124, "mgmt group ABI");
'''
    result = subprocess.run([clang, "-std=c11", "-fshort-enums", "-fsyntax-only", "-x", "c", "-"],
                            input=source, cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout


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
  WifiRsnAkmInfo = object
    bipCmac128: bool
  WpaScanSecurityNotifyView = object
    vifIdx: uint8
    macAddr, bssid: array[6, uint8]
    cipher, scanNotifyVendorByte: uint8
    keyMgmt: uint16
    pairwiseCipher, groupCipher: uint8
    pmfRequired, mgmtGroupCipher: uint8
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
  parsedCaps: uint16
  parsedMgmtSupported: bool
  preferencePmfCapable, preferencePmfRequired: bool
  parserCalls, notifications, finalized: int
  notifiedPairwise, notifiedGroup, notifiedPmfRequired, notifiedMgmtGroup: uint8
  irq = true
  informationElement: array[257, uint8]
  assocSecIeStore: array[MAX_VIFS, array[255, uint8]]
  parserLength: uint8
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
  doAssert data == (addr informationElement[0]) and length == parserLength
  inc parserCalls
  cast[ptr WpaParsedInfoView](output)[] = WpaParsedInfoView(keyMgmtLe: 2,
    caps: parsedCaps, groupCipher: 3, pairwiseCipher: 3, keyMgmtMaskLow: 2)
  if parseFails: cast[pointer](1) else: nil
proc wifiRsnAkmInfoFromIe(data: pointer; length: uint32): WifiRsnAkmInfo =
  WifiRsnAkmInfo(bipCmac128: parsedMgmtSupported)
proc notifySecurity(data: pointer) {.cdecl.} =
  inc notifications
  let notify = cast[ptr WpaScanSecurityNotifyView](data)
  notifiedPairwise = notify.pairwiseCipher
  notifiedGroup = notify.groupCipher
  notifiedPmfRequired = notify.pmfRequired
  notifiedMgmtGroup = notify.mgmtGroupCipher
proc wpaCallbacks(): ptr Callbacks = addr callbacks
proc wifiPreferredKeyMgmtFromMask(mask: uint32; pmf, required: bool): uint32 =
  preferencePmfCapable = pmf
  preferencePmfRequired = required
  selectedAuth
proc nimFwTrace2U32(tag: string; a, b: uint32) = discard
proc me_bw_check(p: pointer) = inc finalized
proc me_extract_power_constraint(data: pointer; length: uint32; output: pointer) = discard
proc me_extract_country_reg(data: pointer; length: uint32; output: pointer) = discard
proc setup(keyLength: int; privacy: bool) =
  connection = default(ConnectInfoCredentialOverlay)
  connection.base.authType = 7
  connection.base.authRetryGate = 5
  connection.base.channelDuration = 0x12345278
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
  parsedCaps = 0
  parsedMgmtSupported = true
  preferencePmfCapable = false
  preferencePmfRequired = false
  parserCalls = 0
  notifications = 0
  finalized = 0
  notifiedPairwise = 0
  notifiedGroup = 0
  notifiedPmfRequired = 0
  notifiedMgmtGroup = 0
  irq = true
  informationElement = default(typeof(informationElement))
  informationElement[0..5] = [48'u8, 4, 1, 2, 3, 4]
  parserLength = 6
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

FORWARD_STUB = r"""
var frame: pointer
proc ke_msg_forward_and_change_id(p: pointer; id: uint16; dst, src: uint8) =
  doAssert p == frame and id == 0x804'u16 and dst == 9 and src == 2
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
      if auth == 1024: parsedCaps = 0x80
      exercise()
      let accepted = not fail and auth != 0 and
        (auth != WifiKeyMgmtSae or family == "rsn")
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

# A new BSS must not inherit security fields or PMF policy from the previous one.
setup(8, true)
protocol = "rsn"
selectedAuth = 2
security.groupCipher = 4
security.pairwiseCipher = 4
security.keyMgmtMaskLow = 6
security.keyMgmt = 1024
security.pmfCapable = 1
security.pmfRequired = 1
exercise()
doAssert scanu_env.directedFound == 1
doAssert security.groupCipher == 3 and security.pairwiseCipher == 3
doAssert security.keyMgmtMaskLow == 2 and security.keyMgmt == 2
doAssert security.pmfCapable == 0 and security.pmfRequired == 0

for caps in [0'u16, 0x40'u16]:
  setup(8, true)
  protocol = "rsn"
  selectedAuth = 1024
  parsedCaps = caps
  exercise()
  doAssert scanu_env.directedFound == 0 and finalized == 0
  doAssert security.keyMgmt == 0 and security.pmfCapable == 0

for family in ["wpa", "rsn"]:
  for claimed in [254'u8, 255'u8]:
    setup(8, true)
    protocol = family
    selectedAuth = 2
    informationElement[1] = claimed
    exercise()
    doAssert parserCalls == 0 and scanu_env.directedFound == 0
    doAssert finalized == 0 and notifications == 0

setup(8, true)
protocol = "rsn"
selectedAuth = 1024
parsedCaps = 0x80
connection.base.channelDuration = connection.base.channelDuration and not 0x600'u32
exercise()
doAssert scanu_env.directedFound == 0 and finalized == 0
doAssert security.keyMgmt == 0 and security.pmfCapable == 0

setup(8, true)
protocol = "rsn"
selectedAuth = 2
parsedCaps = 0xC0
connection.base.channelDuration = connection.base.channelDuration and not 0x600'u32
exercise()
doAssert scanu_env.directedFound == 0 and finalized == 0
doAssert security.keyMgmt == 0 and security.pmfRequired == 0

setup(8, true)
protocol = "rsn"
selectedAuth = 2
parsedCaps = 0x40
exercise()
doAssert scanu_env.directedFound == 0 and finalized == 0
doAssert security.keyMgmt == 0 and security.pmfRequired == 0

setup(8, true)
protocol = "rsn"
selectedAuth = 2
connection.base.channelDuration = connection.base.channelDuration or 0x400'u32
exercise()
doAssert scanu_env.directedFound == 0 and finalized == 0
doAssert security.keyMgmt == 0 and security.pmfRequired == 0
doAssert not preferencePmfCapable and preferencePmfRequired

setup(8, true)
protocol = "rsn"
selectedAuth = 2
exercise()
doAssert scanu_env.directedFound == 1 and not preferencePmfCapable
doAssert not preferencePmfRequired

setup(8, true)
protocol = "rsn"
selectedAuth = 1024
parsedCaps = 0x80
exercise()
doAssert scanu_env.directedFound == 1 and preferencePmfCapable
doAssert not preferencePmfRequired

# Existing joining state and already prepared BSS state retain vendor bypasses.
for prepared in [false, true]:
  setup(64, true)
  if prepared: ap.securityFlags = 0x80000000'u32
  else: station.state = 2
  exercise()
  doAssert finalized == 1 and scanu_env.directedFound == 1
  doAssert station.connectModeFlags == 0x80 and parserCalls == 0
  doAssert connection.base.channelDuration == (if prepared: 0x12345278'u32 else: 0x12345279'u32)
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
        section = section.replace("if securityParsed and selectedAuth != 0 and pmfCompatible:",
                                  "if selectedAuth != 0 and pmfCompatible:")
    elif mutation == "reset_acceptance":
        section = section.replace("        securityAccepted = false\n", "")
    layout = (FW / "layout_types.nim").read_text()
    types = ""
    for name in ["ConnectInfoView", "ConnectInfoCredentialOverlay", "VifSecurityOverlay"]:
        types += re.search(rf"(?ms)^  {name}[^\n]*\n.*?(?=\n\n)", layout).group(0) + "\n"
    program = tmp_path / "credentials.nim"
    program.write_text("const WifiKeyMgmtSae = 1024'u32\nconst WifiAuthMaskSae = 1024'u32\n" + "type\n" + types + PLATFORM + FORWARD_STUB + reader + legacy + WRAPPER
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


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("force_pmf_capable", [False, True])
def test_scan_akm_selection_with_real_preference(tmp_path: Path, mode: str,
                                                force_pmf_capable: bool) -> None:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    layout = (FW / "layout_types.nim").read_text()
    rsn = (FW / "rsn_parse.nim").read_text()
    body = procedure(scan, "scanu_frame_handler")
    section = "      securityState.connected = connectInfo.authRetryGate\n" + body.split(
        "      securityState.connected = connectInfo.authRetryGate\n", 1)[1].split(
            "\n  # WPS callback", 1)[0]
    types = "".join(re.search(
        rf"(?ms)^  {name}[^\n]*\n.*?(?=\n\n)", layout).group(0) + "\n"
        for name in ["ConnectInfoView", "ConnectInfoCredentialOverlay", "VifSecurityOverlay",
                     "WpaParsedInfoView", "WpaParsedInfoBuffer",
                     "WpaScanSecurityNotifyView"])
    platform = PLATFORM.replace(procedure(PLATFORM, "wifiPreferredKeyMgmtFromMask"), "")
    platform = platform.replace("  WifiRsnAkmInfo = object\n    bipCmac128: bool\n", "")
    platform = platform.replace(procedure(platform, "wifiRsnAkmInfoFromIe"), "")
    platform = re.sub(r"  WpaParsedInfoView = object\n.*?  WpaParsedInfoBuffer = object\n"
                      r"    view: WpaParsedInfoView\n", "", platform, count=1, flags=re.S)
    platform = re.sub(r"  WpaScanSecurityNotifyView = object\n.*?(?=  MacIeView = object\n)",
                      "", platform, count=1, flags=re.S)
    platform = platform.replace(
        "  parsedCaps: uint16\n",
        "  parsedCaps: uint16\n  parsedMask: uint32\n"
        "  parsedGroupCipher, parsedPairwiseCipher: uint8\n")
    platform = platform.replace(
        "  cast[ptr WpaParsedInfoView](output)[] = WpaParsedInfoView(keyMgmtLe: 2,\n"
        "    caps: parsedCaps, groupCipher: 3, pairwiseCipher: 3, keyMgmtMaskLow: 2)",
        "  let bytes = cast[ptr UncheckedArray[uint8]](output)\n"
        "  zeroMem(output, sizeof(WpaParsedInfoView))\n"
        "  bytes[4] = parsedPairwiseCipher\n"
        "  bytes[8] = parsedGroupCipher\n"
        "  bytes[12] = parsedMask.uint8\n"
        "  bytes[13] = (parsedMask shr 8).uint8\n"
        "  bytes[16] = parsedCaps.uint8")
    platform = platform.replace(
        "  parsedCaps = 0\n",
        "  parsedCaps = 0\n  parsedMask = 2\n"
        "  parsedGroupCipher = 3\n  parsedPairwiseCipher = 3\n")
    code = (rsn + "\ntype\n" + types + platform + FORWARD_STUB +
            procedure(layout, "keyMgmtLe") +
            procedure(scan, "scanuConnectionKeyLength") +
            procedure(scan, "scanuApplyLegacyCredentialPolicy").split("\n{.emit:", 1)[0] +
            WRAPPER + textwrap.indent(textwrap.dedent(section), "  ") + "\n")
    if force_pmf_capable:
        code = "{.define: bl808WifiForcePmfCapable.}\n" + code
    run_program(tmp_path, mode, code + r'''
const realRsnIe = [48'u8, 26, 1, 0, 0, 15, 172, 4, 1, 0,
  0, 15, 172, 4, 1, 0, 0, 15, 172, 2, 0x80, 0, 0, 0,
  0, 15, 172, 6]
proc setupRealRsn() =
  setup(8, true)
  informationElement[0..27] = realRsnIe
  parserLength = 28
const forceCapable = defined(bl808WifiForcePmfCapable)
for sample in [
    (0x200'u32, 0'u16, WifiKeyMgmtPsk, 1, 3'u8, 3'u8),
    (0x200'u32, 0x80'u16, WifiKeyMgmtSae, 1, 4'u8, 4'u8),
    (0x200'u32, 0x80'u16, WifiKeyMgmtSae, 1, 4'u8, 5'u8),
    (0x400'u32, 0x80'u16, WifiKeyMgmtSae, 1, 4'u8, 4'u8),
    (0x200'u32, 0x80'u16, WifiKeyMgmtPsk, 1, 3'u8, 4'u8),
    (0x200'u32, 0x80'u16, WifiKeyMgmtPsk, 1, 4'u8, 3'u8),
    (0'u32, 0x80'u16, WifiKeyMgmtPsk, 1, 3'u8, 4'u8),
    (0x400'u32, 0'u16, WifiKeyMgmtNone, 0, 4'u8, 4'u8),
    (0x200'u32, 0x40'u16, WifiKeyMgmtNone, 0, 4'u8, 4'u8),
    (0'u32, 0xC0'u16, (if forceCapable: WifiKeyMgmtSae else: WifiKeyMgmtNone),
      forceCapable.int, 4'u8, 4'u8)]:
  setupRealRsn()
  protocol = "rsn"
  parsedMask = WifiAuthMaskPsk or WifiAuthMaskSae
  connection.base.channelDuration = sample[0]
  parsedCaps = sample[1]
  parsedGroupCipher = sample[4]
  parsedPairwiseCipher = sample[5]
  exercise()
  doAssert security.keyMgmt == sample[2],
    "sample=" & $sample & " selected=" & $security.keyMgmt &
    " parsed=" & $parserCalls & " choice=" & $nimFwDbgScanAT &
    " raw=" & $wifiRsnAkmInfoFromIe(addr informationElement[0], 28)
  doAssert scanu_env.directedFound == sample[3].uint8
  doAssert notifications == sample[3] and finalized == sample[3]
  if sample[3] != 0:
    doAssert security.groupCipher == sample[4]
    doAssert security.pairwiseCipher == sample[5]
    doAssert notifiedGroup == sample[4]
    doAssert notifiedPairwise == sample[5]
    let negotiatedPmf = (forceCapable or (sample[0] and 0x600'u32) != 0) and
      (sample[1] and 0x80'u16) != 0
    doAssert notifiedMgmtGroup == (if negotiatedPmf: 6'u8 else: 0'u8)
    doAssert notifiedPmfRequired == (if negotiatedPmf and
      ((sample[0] and 0x400'u32) != 0 or (sample[1] and 0x40'u16) != 0 or
       sample[2] == WifiKeyMgmtSae): 1'u8 else: 0'u8)
setupRealRsn()
protocol = "rsn"
connection.base.channelDuration = 0x200
parsedMask = WifiAuthMaskPsk or WifiAuthMaskSae
parsedCaps = 0x80
parsedGroupCipher = 4
parsedPairwiseCipher = 4
informationElement[27] = 11 # BIP-GMAC-128 is unsupported by this firmware.
exercise()
doAssert security.keyMgmt == 0 and scanu_env.directedFound == 0
''')


def test_scan_security_trace_handles_unaligned_short_ie(tmp_path: Path) -> None:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    layout = (FW / "layout_types.nim").read_text()
    rsn = (FW / "rsn_parse.nim").read_text()
    body = procedure(scan, "scanu_frame_handler")
    section = "      securityState.connected = connectInfo.authRetryGate\n" + body.split(
        "      securityState.connected = connectInfo.authRetryGate\n", 1)[1].split(
            "\n  # WPS callback", 1)[0]
    types = "".join(re.search(
        rf"(?ms)^  {name}[^\n]*\n.*?(?=\n\n)", layout).group(0) + "\n"
        for name in ["ConnectInfoView", "ConnectInfoCredentialOverlay", "VifSecurityOverlay"])
    unaligned = "cast[pointer](cast[uint](addr unalignedStorage[0]) + 1'u)"
    platform = PLATFORM.replace(
        "  informationElement: array[257, uint8]\n",
        "  informationElement: array[257, uint8]\n"
        "  unalignedStorage: array[3, uint32]\n  traceWord: uint32\n")
    platform = platform.replace("addr informationElement[0] else: nil",
                                f"{unaligned} else: nil")
    platform = platform.replace(
        "data == (addr informationElement[0]) and length == parserLength",
        f"data == {unaligned} and length == parserLength")
    platform = platform.replace(
        "proc nimFwTrace2U32(tag: string; a, b: uint32) = discard",
        "proc nimFwTrace2U32(tag: string; a, b: uint32) = traceWord = b")
    platform = platform.replace(procedure(platform, "wifiPreferredKeyMgmtFromMask"), "")
    platform = platform.replace("  WifiRsnAkmInfo = object\n    bipCmac128: bool\n", "")
    platform = platform.replace(procedure(platform, "wifiRsnAkmInfoFromIe"), "")
    code = (rsn + "\ntype\n" + types + platform + FORWARD_STUB +
            procedure(scan, "scanuConnectionKeyLength") +
            procedure(scan, "scanuApplyLegacyCredentialPolicy").split("\n{.emit:", 1)[0] +
            WRAPPER + textwrap.indent(textwrap.dedent(section), "  ") + "\n")
    run_program(tmp_path, "checked",
                '{.passC: "-fsanitize=alignment -fno-sanitize-recover=alignment".}\n'
                '{.passL: "-fsanitize=alignment".}\n' + code + r'''
for sample in [(4'u8, 0x02010430'u32), (0'u8, 0x30'u32)]:
  setup(8, true)
  protocol = "rsn"
  selectedAuth = 2
  informationElement[1] = sample[0]
  parserLength = sample[0] + 2'u8
  copyMem(cast[pointer](cast[uint](addr unalignedStorage[0]) + 1'u),
          addr informationElement[0], parserLength.int)
  traceWord = 0
  exercise()
  doAssert scanu_env.directedFound == 1
  doAssert traceWord == sample[1]
''')
