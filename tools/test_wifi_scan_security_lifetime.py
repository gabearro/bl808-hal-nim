"""Check directed scan security updates across SM, SCANU and cache retirement.

scanu_frame_handler's directed-scan block calls the supplicant's parse and
notify callbacks, the trace, the BSS helpers and the WPS callback; any of
them may run SM code that ends the attempt (smGo: a new SM operation), and a
host prune may replace the cached result. After each such call the block
re-checks frameOwnerCurrent: the result slot's generation, SCANU's request
(scanuRequestCurrent) and, for a directed scan, SM's operation stamp taken
before the block (opCurrent(smOwn.op, directedStamp)). These programs extract
the real templates and the real security section and WPS tail.
"""

from pathlib import Path
import re
import textwrap

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_scan_credentials import PLATFORM, WRAPPER


def owner_templates(scan: str) -> str:
    """The real ownsResult, frameOwnerCurrent and requireFrameOwner."""
    body = procedure(scan, "scanu_frame_handler")
    owns = "  template ownsResult(): bool =" + body.split(
        "  template ownsResult(): bool =", 1)[1].split("\n\n", 1)[0]
    checks = "  template frameOwnerCurrent(): bool =" + body.split(
        "  template frameOwnerCurrent(): bool =", 1)[1].split("\n\n", 1)[0]
    assert "requireFrameOwner" in checks and "opCurrent(smOwn.op, directedStamp)" in checks
    return owns + "\n" + checks + "\n"


def base() -> str:
    layout = (FW / "layout_types.nim").read_text()
    scan = (FW / "scan_station_ap_me.nim").read_text()
    types = "type\n"
    for name in ["ConnectInfoView", "ConnectInfoCredentialOverlay", "VifSecurityOverlay",
                 "ScanuCachedSsid",
                 "ScanuResultEntry", "ScanSsidSlotView", "WpsScanCallbackView",
                 "WpsScanCallbackBuffer"]:
        types += re.search(rf"(?ms)^  {name}[^\n]*\n.*?(?=\n\n)", layout).group(0) + "\n"
    code = types + "var hook: proc(point: string)\nproc fire(point: string) =\n  if hook != nil: hook(point)\n"
    platform = PLATFORM.replace("vifIdx, vifType: uint8", "vifIdx, vifType, staIdx: uint8")
    platform = platform.replace("  Env = object\n", "  Env = object\n    paramPtr: pointer\n")
    code += platform
    code = code.replace("  if parseFails: cast[pointer](1) else: nil", "  fire(\"parse\")\n  if parseFails: cast[pointer](1) else: nil", 1)
    for name, replacement in {
        "notifySecurity": 'proc notifySecurity(data: pointer) {.cdecl.} =\n  inc notifications\n  fire("notify")\n',
        "nimFwTrace2U32": 'proc nimFwTrace2U32(tag: string; a, b: uint32) = fire("trace")\n',
        "me_bw_check": 'proc me_bw_check(p: pointer) =\n  inc finalized\n  fire("bw")\n',
        "me_extract_power_constraint": 'proc me_extract_power_constraint(data: pointer; length: uint32; output: pointer) = fire("power")\n',
        "me_extract_country_reg": 'proc me_extract_country_reg(data: pointer; length: uint32; output: pointer) = fire("country")\n',
    }.items():
        code = code.replace(procedure(code, name), replacement, 1)
    code += (FW / "op.nim").read_text() + r'''
const TASK_SM = 4'u8
const WifiKeyMgmtSae = 1024'u32
const WifiAuthMaskSae = 1024'u32
var
  smOwn: tuple[op: Op]        # SM's operation (station_sm.nim)
  scanuOwn: tuple[op: Op]     # SCANU's operation (scan_machine.nim)
  cached: ScanuCachedSsid
  request: uint32
  replacementConnection: ConnectInfoCredentialOverlay
  forwards, published: int
  wpsFunction, wps_cbs: pointer
  entry: ScanuResultEntry
proc smEnvView(): ptr SmEnvView = addr station
proc vifChannelForIdx(index: uint8): ptr Vif = addr vif
proc ke_state_get(task: uint8): uint16 = station.state.uint16
proc ke_msg_forward_and_change_id(p: pointer; id: uint16; dst, src: uint8) = inc forwards
proc wpsNotify(p: pointer) {.cdecl.} = fire("wps")
proc prepare() =
  hook = nil
  setup(8, true)
  protocol = "rsn"
  selectedAuth = 2
  vif.vifType = VIF_TYPE_STA
  vif.staIdx = 0xFF
  scanu_env.paramPtr = addr request
  discard opGo(scanuOwn.op)
  discard opGo(smOwn.op)
  cached = ScanuCachedSsid(generation: 9)
  replacementConnection = connection
  forwards = 0
  published = 0
  wpsFunction = cast[pointer](wpsNotify)
  wps_cbs = addr wpsFunction
proc replaceOwner(action: int) =
  ## What a callback can do: SM ends the attempt and a new one starts on a
  ## new connection (0), SM moves on (1), the STA VIF is removed (2: SM
  ## abandons the attempt), SM changes state (3) - each an smGo, a new SM
  ## operation; SCANU's request ends (4); a host prune replaces the result
  ## slot (5).
  case action
  of 0:
    discard opGo(smOwn.op)
    station.connectInfo = addr replacementConnection.base
  of 1, 2: discard opGo(smOwn.op)
  of 3:
    discard opGo(smOwn.op)
    station.state = 2
  of 4: discard opGo(scanuOwn.op)
  else: inc cached.generation
  security.cipher = 0x55
  security.keyMgmt = 0x11223344
  vif.capabilityInfo = 0x1234
  ap.securityFlags = 0x12340000
  assoc.rsnIeLen = 99
  connection.base.channelDuration = 0xAABBCC00'u32
  replacementConnection.base.channelDuration = 0xAABBCC00'u32
  scanu_env.directedFound = 77
proc snapshot(): auto =
  (connection, replacementConnection, security, station, vif, ap, assoc,
   assocSecIeStore, scanu_env, notifications, finalized)
'''
    code += procedure((FW / "scan_machine.nim").read_text(), "scanuRequestCurrent")
    code += procedure(scan, "scanuConnectionKeyLength") + procedure(scan, "scanuApplyLegacyCredentialPolicy")
    return code


def context(scan: str, directed: str = "1'u8") -> str:
    return f'''
  let scanParam = scanu_env.paramPtr
  let scanEpoch = scanuOwn.op.serial
  let cachedSsid = addr cached
  let resultGeneration = cached.generation
  let frame = cast[pointer](addr request)
  let bfOn = {directed}
  let directedStamp = smOwn.op.serial
''' + owner_templates(scan)


def security_source() -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    body = procedure(scan, "scanu_frame_handler")
    section = "      securityState.connected = connectInfo.authRetryGate\n" + body.split(
        "      securityState.connected = connectInfo.authRetryGate\n", 1)[1].split("\n  # WPS callback", 1)[0]
    wrapper = WRAPPER.replace("  template requireFrameOwner() = discard\n", "")
    wrapper = wrapper.replace("proc exercise() =\n", "proc exercise() =\n" + context(scan), 1)
    return base() + wrapper + textwrap.indent(textwrap.dedent(section), "  ") + "\n"


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_security_callbacks_stop_retired_updates(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, security_source() + r'''
for point in ["parse", "trace", "notify", "bw", "power", "country"]:
  for action in 0 .. 5:
    prepare()
    var fired = false
    var expected: typeof(snapshot())
    hook = proc(at: string) =
      if at != point or fired: return
      fired = true
      replaceOwner(action)
      expected = snapshot()
    exercise()
    doAssert fired and snapshot() == expected, "retired update after " & point
    doAssert forwards == 1
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_current_security_owner_completes(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, security_source() + r'''
for family in ["wpa", "rsn"]:
  for failure in [false, true]:
    prepare()
    protocol = family
    parseFails = failure
    exercise()
    doAssert forwards == 0
    doAssert notifications == (not failure).int
    doAssert finalized == (not failure).int
    doAssert scanu_env.directedFound == (not failure).uint8
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_security_ie_copy_preserves_complete_length(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, security_source() + r'''
for size in [6, 128, 129, 255, 256, 257]:
  prepare()
  protocol = "rsn"
  informationElement[0] = 48
  informationElement[1] = (size - 2).uint8
  for i in 2 ..< size: informationElement[i] = (i mod 251).uint8
  parserLength = size.uint8
  assocSecIeStore = default(typeof(assocSecIeStore))
  exercise()
  if size <= 255:
    doAssert forwards == 0 and parserCalls == 1 and notifications == 1
    doAssert assoc.rsnIeLen == size.uint8
    for i in 0 ..< size:
      doAssert assocSecIeStore[0][i] == informationElement[i]
    for i in size ..< assocSecIeStore[0].len:
      doAssert assocSecIeStore[0][i] == 0
  else:
    # The parser callback takes a uint8 total length, so these IEs are
    # rejected before the copy branch and never forwarded as accepted BSSes.
    doAssert forwards == 0 and parserCalls == 0 and notifications == 0
    doAssert assoc.rsnIeLen == 0
    for byte in assocSecIeStore[0]: doAssert byte == 0
''')


def test_directed_owner_is_bound_before_use() -> None:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    body = procedure(scan, "scanu_frame_handler")
    assert body.index("directedConnection = smEnvView().connectInfo") < \
        body.index("directedStamp = smOwn.op.serial") < \
        body.index("let connectInfoPtr = directedConnection")
    assert "connectInfoView(directedConnection).vifIdx != scanVifIdx" in body
    assert "if bfOn == 0: 0'u32 else: directedStamp" in body
    publisher = procedure(scan, "scanuPublishFrameResult")
    assert "smStamp == 0 or opCurrent(smOwn.op, smStamp)" in publisher
    checks = owner_templates(scan)
    assert "bfOn == 0 or opCurrent(smOwn.op, directedStamp)" in checks


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_callback_releases_connection(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, security_source() + r'''
proc malloc(n: csize_t): pointer {.importc, header: "<stdlib.h>".}
proc free(p: pointer) {.importc, header: "<stdlib.h>".}
for point in ["parse", "notify"]:
  prepare()
  let retired = cast[ptr ConnectInfoCredentialOverlay](malloc(sizeof(ConnectInfoCredentialOverlay).csize_t))
  retired[] = connection
  station.connectInfo = addr retired.base
  var fired = false
  var expected: typeof(snapshot())
  hook = proc(at: string) =
    if at != point or fired: return
    fired = true
    replaceOwner(0)
    free(retired)
    expected = snapshot()
  exercise()
  doAssert fired and snapshot() == expected and forwards == 1
''')


def wps_source() -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    body = procedure(scan, "scanu_frame_handler").split("  # WPS callback\n", 1)[1]
    support = r'''
const WPS_OUI = [0'u8, 0x50, 0xF2, 4]
proc mac_vsie_find(p: pointer; n: uint32; oui: pointer; size: uint32): pointer = addr informationElement[0]
proc scanuPublishFrameResult(frame: pointer; frameLen: uint16; payloadLen: uint32;
    item: ptr ScanuResultEntry;
    request: pointer; epoch, generation: uint32; count, bfOn: uint8;
    smStamp = 0'u32) =
  if bfOn != 0: doAssert smStamp != 0 and opCurrent(smOwn.op, smStamp)
  else: doAssert smStamp == 0
  inc published
proc exerciseWps(directed: bool) =
'''
    wrapper = context(scan, "directed.uint8") + r'''
  let result = cast[pointer](addr entry)
  let scanResultEntry = addr entry
  var ssidScratch = ScanSsidSlotView(length: 4)
  let ieStart = cast[pointer](addr informationElement[0])
  let ieLen = informationElement.len.uint32
  let numSsids = 1'u8
  let totalLen = 36'u16
  let len = 68'u32
'''
    return base() + support + wrapper + body


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_wps_callback_respects_owners(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, wps_source() + r'''
for directed in [false, true]:
  for action in 0 .. 5:
    prepare()
    var fired = false
    hook = proc(point: string) =
      if point == "wps":
        fired = true
        replaceOwner(action)
    exerciseWps(directed)
    let retired = directed or action >= 4
    doAssert fired
    doAssert published == (not retired).int and forwards == retired.int
''')


SM_CHECK = "(bfOn == 0 or opCurrent(smOwn.op, directedStamp))"
MUTANTS = {
    # The directed scan no longer checks SM's operation after the callbacks.
    "sm_stamp": (SM_CHECK, "true"),
    # Nor SCANU's request or the result slot.
    "owns_result": ("  template frameOwnerCurrent(): bool =\n    ownsResult() and",
                    "  template frameOwnerCurrent(): bool =\n    true and"),
}


@pytest.mark.parametrize("mutant", MUTANTS)
@pytest.mark.parametrize("program", ["security", "wps"])
def test_owner_rechecks_are_load_bearing(tmp_path: Path, mutant: str, program: str) -> None:
    """Each part of frameOwnerCurrent is what stops a retired update: drop it
    and the callback tests fail."""
    old, new = MUTANTS[mutant]
    if program == "security":
        code = security_source() + r'''
for point in ["parse", "notify"]:
  for action in 0 .. 5:
    prepare()
    var fired = false
    var expected: typeof(snapshot())
    hook = proc(at: string) =
      if at != point or fired: return
      fired = true
      replaceOwner(action)
      expected = snapshot()
    exercise()
    doAssert fired and snapshot() == expected, "retired update after " & point
'''
    else:
        code = wps_source() + r'''
for action in 0 .. 5:
  prepare()
  hook = proc(point: string) =
    if point == "wps": replaceOwner(action)
  exerciseWps(true)
  doAssert published == 0 and forwards == 1, "retired directed result published"
'''
    assert code.count(old) == 1, mutant
    with pytest.raises(AssertionError, match="AssertionDefect"):
        run_program(tmp_path, "checked", code.replace(old, new, 1))
