"""Run the scan-frame admission prefix across request replacement callbacks."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const MAX_VIFS = 2
const TASK_SCANU = 2'u8
const IE_ID_DS_PARAM = 3'u8
type
  WpaParsedInfoView = object
    caps: uint16
    keyMgmtMaskLow: uint8
  Callbacks = object
    parseSecurityIe: pointer
  DsParameter = object
    channel: uint8
var
  scanu_env: tuple[paramPtr: pointer, bssidFilterEnabled: uint8]
  scanuRequestEpoch: uint32
  frame: array[96, uint8]
  ie: array[6, uint8]
  entry: ScanuResultEntry
  cached: ScanuCachedSsid
  original: ptr ScanuStartReqPayload
  replacement: ScanuStartReqPayload
  callbacks: Callbacks
  wpa_cbs: pointer
  hook: proc(point: string)
  protocol, forwards, finds, indications: int
  released, reachedCommit, enabled: bool
  nimFwDbgScanFrameSeen: uint32
proc malloc(n: csize_t): pointer {.importc, header: "<stdlib.h>".}
proc free(p: pointer) {.importc, header: "<stdlib.h>".}
proc c_memset(p: pointer; value: cint; n: csize_t): pointer =
  zeroMem(p, n.int)
  p
proc fire(point: string) =
  if hook != nil: hook(point)
proc irqSave(): uint32 =
  fire("snapshot-enter")
  result = enabled.uint32 * 8
  enabled = false
proc irqRestore(saved: uint32) =
  enabled = (saved and 8) != 0
  fire("snapshot-exit")
proc rxuMgtIndAt(p: pointer): ptr RxuMgtIndView = cast[ptr RxuMgtIndView](p)
proc rxuMgtIndIeStart(p: pointer): pointer = addr rxuMgtIndAt(p).ieData[0]
proc scanuRxFrameValid(p: pointer; n: uint32): bool = p == addr frame[0]
proc scanuStartReqView(p: pointer): ptr ScanuStartReqPayload =
  doAssert not enabled
  cast[ptr ScanuStartReqPayload](p)
proc activeScanuReq(): ptr ScanuStartReqPayload = scanuStartReqView(scanu_env.paramPtr)
proc scanSsidSlot(p: ptr ScanuStartReqPayload; index: int): ptr ScanSsidSlotView =
  cast[ptr ScanSsidSlotView](addr p.ssidFilter[0])
proc scanuFrameMatchesBssid(p: ptr RxuMgtIndView): bool = true
proc ke_state_get(task: uint8): uint8 =
  fire("state")
  1
proc ke_msg_forward_and_change_id(p: pointer; id: uint16; dst, src: uint8) =
  doAssert p == (addr frame[0]) and id == 0x804 and dst == 9 and src == 2
  inc forwards
proc mac_ie_find(p: pointer; n: uint32; id: uint8): pointer = nil
proc dsParamSetIeAt(p: pointer): ptr DsParameter = cast[ptr DsParameter](p)
proc dsParamFreq(band: uint8; p: ptr DsParameter): uint16 = 2412
proc find_wpa_rsn_ie(p: pointer; n: uint32; wpa, rsn: ptr pointer) =
  wpa[] = if protocol == 0: addr ie[0] else: nil
  rsn[] = if protocol == 1: addr ie[0] else: nil
proc totalLen(p: ptr MacIeView): uint = p.len.uint + 2
proc parseSecurity(p: pointer; n: uint8; output: pointer): pointer {.cdecl.} =
  doAssert n == 6
  fire("parser")
  nil
proc wpaCallbacks(): ptr Callbacks = addr callbacks
proc scanu_find_result(p: pointer; allocate: uint8): pointer =
  inc finds
  addr entry
proc scanuResultAt(p: pointer): ptr ScanuResultEntry = cast[ptr ScanuResultEntry](p)
proc scanuCachedSsidFor(p: ptr ScanuResultEntry): ptr ScanuCachedSsid = addr cached
proc ke_msg_send_basic(id: uint16; dst, src: uint8) =
  doAssert id == 76 and dst == 1 and src == 2
  inc indications
  fire("indication")
proc setup(family: int) =
  hook = nil
  original = cast[ptr ScanuStartReqPayload](malloc(sizeof(ScanuStartReqPayload).csize_t))
  doAssert original != nil
  original[] = default(ScanuStartReqPayload)
  original.scanType = 1
  original.flags = 0x100
  original.ssidFilter[0] = 1
  original.ssidFilter[1] = 65
  scanu_env.paramPtr = original
  scanu_env.bssidFilterEnabled = 0
  scanuRequestEpoch = 7
  frame = default(typeof(frame))
  rxuMgtIndAt(addr frame[0]).frameLen = 36
  ie[0] = 48
  ie[1] = 4
  callbacks.parseSecurityIe = cast[pointer](parseSecurity)
  wpa_cbs = addr callbacks
  entry = ScanuResultEntry(valid: 1, rssi: -40)
  cached = ScanuCachedSsid(generation: 9)
  protocol = family
  forwards = 0
  finds = 0
  indications = 0
  released = false
  reachedCommit = false
  enabled = true
proc finish() =
  if not released: free(original)
'''


def source() -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    layout = (FW / "layout_types.nim").read_text()
    declaration = "  ScanuStartReqPayload" + layout.split("  ScanuStartReqPayload", 1)[1]
    lines = declaration.splitlines()
    request_type = "type\n" + lines[0] + "\n"
    for line in lines[1:]:
        if line and not line.startswith("    "):
            break
        request_type += line + "\n"
    prefix = procedure(scan, "scanu_frame_handler").split("  # Security info\n", 1)[0]
    return layouts("ScanChannelEntry", "ScanSsidSlotView", "ScanuResultEntry",
                   "ScanuCachedSsid", "RxuMgtIndView", "MacIeView") + request_type + \
        PLATFORM + procedure(scan, "scanuRequestCurrent") + prefix + "  reachedCommit = true\n"


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_retired_request_stops_admission(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for family in [0, 1]:
  for point in ["state", "parser", "indication"]:
    for action in 0 .. 1:
      setup(family)
      var fired = false
      hook = proc(at: string) =
        if at != point or fired: return
        fired = true
        if action == 0:
          scanu_env.paramPtr = addr replacement
          free(original)
          released = true
        else:
          inc scanuRequestEpoch
      scanu_frame_handler(addr frame[0], frame.len.uint32)
      doAssert fired and not reachedCommit and forwards == 1
      doAssert finds == (if point == "indication": 1 else: 0)
      finish()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reused_result_slot_stops_admission(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup(1)
hook = proc(point: string) =
  if point == "indication": inc cached.generation
scanu_frame_handler(addr frame[0], frame.len.uint32)
doAssert not reachedCommit and forwards == 1 and finds == 1
finish()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_current_request_reaches_result_processing(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for family in [0, 1]:
  for irq in [false, true]:
    for count in [0'u8, 1'u8]:
      setup(family)
      enabled = irq
      original.scanType = count
      scanu_frame_handler(addr frame[0], frame.len.uint32)
      doAssert reachedCommit and forwards == 0 and finds == 1 and indications == 1
      doAssert enabled == irq
      finish()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_retired_request_at_snapshot_boundary(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for point in ["snapshot-enter", "snapshot-exit"]:
  for irq in [false, true]:
    setup(1)
    enabled = irq
    var fired = false
    hook = proc(at: string) =
      if at != point or fired: return
      fired = true
      scanu_env.paramPtr = addr replacement
      free(original)
      released = true
    scanu_frame_handler(addr frame[0], frame.len.uint32)
    doAssert fired and not reachedCommit and forwards == 1
    doAssert finds == 0 and indications == 0 and enabled == irq
    finish()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_snapshot_preserves_consumed_request_fields(tmp_path: Path, mode: str) -> None:
    from test_wifi_scan_result_updates import source as result_source

    run_program(tmp_path, mode, result_source() + r'''
for irq in [false, true]:
  prepareUpdate(true, -20)
  enabled = irq
  var fired = false
  hook = proc(at: string) =
    if at != "snapshot-exit" or fired: return
    fired = true
    original.flags = 0x100
    original.vifIdx = 0xFF
    original.scanType = 2
    original.ssidFilter[1] = 66
  scanu_frame_handler(addr frame[0], frame.len.uint32)
  doAssert fired and reachedCommit and forwards == 1 and enabled == irq
  doAssert indications == 0 and allocations == 1 and frees == 1
  doAssert cached.ssidBytes[0] == 65 and entry.rssi == -20
  finish()
''')
