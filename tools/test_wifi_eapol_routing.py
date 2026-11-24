"""Exercise the vendor EAPOL callback routes, including the real RX handoff."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
import test_wifi_rx_decapsulation as rx


SUPPORT = r'''
const
  TASK_SM = 4'u8
  SM_ACTIVATING_STATE = 9'u16
  SmIdleState = 0'u16
var
  sm: tuple[state: uint8]
  smState: uint16
  wpa: WpaCallbacksView
  wpsTable: WpsCallbacksView
  wpa_cbs, wps_cbs: pointer
  callbackRecords: seq[tuple[route: int, source, data: pointer, length: uint32]]
  capturePayload: bool
  capturedBytes: seq[uint8]
  capturedSource: array[6, uint8]
  nimFwDbgEapolIn, nimFwDbgEapolDropped, nimFwDbgEapolForwarded: uint32
  nimFwDbgVifWpaState, nimFwDbgSmStateAtEapol: uint32
  nimFwDbgEapolCbInv, nimFwDbgEapolCbNull: uint32
proc smEnvView(): ptr typeof(sm) = addr sm
proc wpaCallbacks(): ptr WpaCallbacksView = cast[ptr WpaCallbacksView](wpa_cbs)
proc wpsCallbacks(): ptr WpsCallbacksView = cast[ptr WpsCallbacksView](wps_cbs)
proc vifSecurityAt(p: uint): ptr Security = addr cast[ptr Vif](p).security
proc ke_state_get(task: uint8): uint16 =
  doAssert task == TASK_SM
  smState
proc recordInput(route: int; source, data: pointer; length: uint32): cint =
  callbackRecords.add((route, source, data, length))
  if capturePayload:
    capturedBytes = newSeq[uint8](length.int)
    copyMem(addr capturedBytes[0], data, length.int)
    copyMem(addr capturedSource[0], source, 6)
  if route == 1: -17.cint else: 29.cint
proc wpaInput(source, data: pointer; length: uint32): cint {.cdecl.} =
  recordInput(1, source, data, length)
proc wpsInput(source, data: pointer; length: uint32): cint {.cdecl.} =
  recordInput(2, source, data, length)
proc resetRouting(state = 0'u16; mode = 0'u8) =
  smState = state
  sm.state = mode
  wpa = default(WpaCallbacksView)
  wpsTable = default(WpsCallbacksView)
  wpa.eapolHandler = cast[pointer](wpaInput)
  wpsTable.eapolHandler = cast[pointer](wpsInput)
  wpa_cbs = addr wpa
  wps_cbs = addr wpsTable
  callbackRecords.setLen(0)
  capturePayload = false
  capturedBytes.setLen(0)
  capturedSource = default(typeof(capturedSource))
  nimFwDbgEapolIn = 0
  nimFwDbgEapolDropped = 0
  nimFwDbgEapolForwarded = 0
  nimFwDbgVifWpaState = 0
  nimFwDbgSmStateAtEapol = 0
  nimFwDbgEapolCbInv = 0
  nimFwDbgEapolCbNull = 0
'''


def callback_types() -> str:
    layout = (FW / "layout_types.nim").read_text()
    result = "type\n"
    for name in ["WpaCallbacksView", "WpsCallbacksView"]:
        result += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    return result


def handler() -> str:
    return procedure((FW / "scan_station_ap_me.nim").read_text(), "sm_handle_eapol_input")


def source() -> str:
    return r'''
const MAX_VIFS = 2
const STA_INFO_TAB_ENTRIES = 7
type
  Station = object
    instNbr: uint8
  Security = object
    connected: uint8
  Vif = object
    security: Security
var
  stations: array[7, Station]
  vifs: array[2, Vif]
  stationReads, vifReads: int
  sourceBytes: array[6, uint8]
  dataBytes: array[8, uint8]
proc staInfoForIdx(index: uint8): ptr Station =
  inc stationReads
  doAssert index < 7
  addr stations[index]
proc vifChannelForIdx(index: uint8): ptr Vif =
  inc vifReads
  doAssert index < 2
  addr vifs[index]
''' + callback_types() + SUPPORT + procedure(
    (FW / "platform_bl.nim").read_text(), "bl_wifi_set_wps_status_internal"
) + handler() + r'''
{.emit: """
extern void sm_handle_eapol_input(unsigned char, void*, void*, NU16);
static void call_eapol_input(unsigned char station, void *source, void *data, NU16 length) {
  sm_handle_eapol_input(station, source, data, length);
}
""".}
proc callInput(station: uint8; source, data: pointer; length: uint16) {.
  importc: "call_eapol_input", cdecl, nodecl.}
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_wpa_routes_idle_and_activating(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for vif in 0'u8 .. 1:
  for station in [0'u8, 4, 6]:
    stations[station].instNbr = vif
    vifs[vif].security.connected = 1
    for state in [0'u16, 1, 8, 9, 10, 255]:
      for availability in [2, 1, 0]:
        resetRouting(state)
        if availability == 0: wpa_cbs = nil
        elif availability == 1: wpa.eapolHandler = nil
        callInput(station, addr sourceBytes[0], addr dataBytes[0], high(uint16))
        let routed = state in [0'u16, 9] and availability == 2
        doAssert callbackRecords.len == routed.int
        if routed:
          doAssert callbackRecords[0] == (1, cast[pointer](addr sourceBytes[0]),
            cast[pointer](addr dataBytes[0]), high(uint16).uint32)
        doAssert nimFwDbgEapolCbInv == routed.uint32
        doAssert nimFwDbgEapolCbNull ==
          (state in [0'u16, 9] and availability != 2).uint32
        doAssert smState == state and nimFwDbgSmStateAtEapol == state.uint32
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_wps_route_and_input_indices(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
stations[4].instNbr = 1
vifs[1].security.connected = 1
for state in [0'u16, 9, 10]:
  for availability in 0 .. 2:
    resetRouting(state, 2)
    if availability == 0: wps_cbs = nil
    elif availability == 1: wpsTable.eapolHandler = nil
    callInput(4, addr sourceBytes[0], addr dataBytes[0], 8)
    doAssert callbackRecords.len == (availability == 2).int
    if availability == 2:
      doAssert callbackRecords[0].route == 2 and callbackRecords[0].length == 8
    doAssert nimFwDbgEapolCbInv == 0
    doAssert smState == state and nimFwDbgSmStateAtEapol == 0

for mode in [0'u8, 2]:
  resetRouting(0, mode)
  vifs[1].security.connected = 0
  callInput(4, addr sourceBytes[0], addr dataBytes[0], 8)
  doAssert callbackRecords.len == 0 and nimFwDbgEapolDropped == 1
vifs[1].security.connected = 1

for station in [7'u8, 255]:
  resetRouting()
  stationReads = 0
  vifReads = 0
  callInput(station, addr sourceBytes[0], addr dataBytes[0], 8)
  doAssert stationReads == 0 and vifReads == 0 and callbackRecords.len == 0
  doAssert nimFwDbgEapolDropped == 1
for vif in [2'u8, 255]:
  resetRouting()
  stations[4].instNbr = vif
  vifReads = 0
  callInput(4, addr sourceBytes[0], addr dataBytes[0], 8)
  doAssert vifReads == 0 and callbackRecords.len == 0
  doAssert nimFwDbgEapolDropped == 1
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_exported_wps_status_controls_eapol_route(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
stations[4].instNbr = 1
vifs[1].security.connected = 1
resetRouting(0)
bl_wifi_set_wps_status_internal(2)
doAssert sm.state == 2
callInput(4, addr sourceBytes[0], addr dataBytes[0], 8)
doAssert callbackRecords.len == 1 and callbackRecords[0].route == 2
resetRouting(0)
bl_wifi_set_wps_status_internal(0)
callInput(4, addr sourceBytes[0], addr dataBytes[0], 8)
doAssert callbackRecords.len == 1 and callbackRecords[0].route == 1
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_rx_dispatch_reaches_station_callback(tmp_path: Path, mode: str) -> None:
    code = rx.dispatch_source()
    stub = rx.procedure(code, "sm_handle_eapol_input")
    code = code.replace(stub,
        "proc sm_handle_eapol_input*(staIdx: uint8; srcAddr, eapolBuf: pointer; eapolLen: uint16) {.cdecl, exportc.}\n", 1)
    assert "    cipher: uint8" in code
    code = code.replace("    cipher: uint8", "    cipher, connected: uint8", 1)
    code += callback_types() + SUPPORT + handler()
    code += rx.CHECKS.split("# Unprotected IP", 1)[0]
    run_program(tmp_path, mode, code + r'''
for state in [0'u16, 9, 10]:
  for split in [false, true]:
    let payloadSize = if split: 1800 else: 40
    setup(0x0208, 24, payloadSize)
    resetRouting(state)
    capturePayload = true
    vifs[0].security.connected = 1
    snapAt(24, 0x888E)
    var tailBytes: array[1736, uint8]
    var tail = Chain(frameData: addr tailBytes[0])
    var expected = newSeq[uint8](payloadSize - 8)
    if split:
      for i in 0 ..< 88: tailBytes[i] = ((i * 7) and 255).uint8
      copyMem(addr expected[0], addr bytes[32], 1704)
      copyMem(addr expected[1704], addr tailBytes[0], 88)
      chain.next = addr tail
      for i in 1736 ..< bytes.len: bytes[i] = 0xEE
    else:
      copyMem(addr expected[0], addr bytes[32], expected.len)
    let expectedSource = macDataFrameAt(addr bytes[0]).addr3
    doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
    doAssert transferred == 0
    if state in [0'u16, 9]:
      doAssert callbackRecords.len == 1 and callbackRecords[0].route == 1
      doAssert capturedBytes == expected and capturedSource == expectedSource
    else:
      doAssert callbackRecords.len == 0
    doAssert allocations == split.int and frees == split.int
''')
