"""Keep RX post-processing and release attached to the captured frame."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rx_admission import admission_source


def source() -> str:
    code = """
var onBoundary: proc(name: string)
var steps: seq[string]
proc boundary(name: string) =
  steps.add(name)
  if onBoundary != nil: onBoundary(name)
""" + admission_source()
    replacements = {
        "nimFwTrace2U32": '''
proc nimFwTrace2U32(label: string; a, b: uint32) = boundary("trace")
''',
        "tick": '''
proc tick(): uint32 {.cdecl.} =
  boundary("clock")
  0x12345678
''',
        "rxlHandleApPowerSave": '''
proc rxlHandleApPowerSave(vif: ptr VifChannelView; sta: ptr StaInfoView;
                         index: uint8; frame: pointer) = boundary("power")
''',
        "td_pck_ind": '''
proc td_pck_ind(vif, sta, count: uint8) = boundary("traffic")
''',
        "mm_check_beacon": '''
proc mm_check_beacon(p, vif, sta: pointer; tim: ptr uint32): uint32 =
  tim[] = 0x1234
  boundary("beacon")
  1
''',
        "ps_check_beacon": '''
proc ps_check_beacon(tim: pointer; length: uint32; vif: pointer) = boundary("ps")
''',
        "vif_mgmt_bcn_recv": '''
proc vif_mgmt_bcn_recv(vif: pointer) = boundary("received")
''',
        "chan_tbtt_switch_update": '''
proc chan_tbtt_switch_update(vif: pointer; expiry: uint32) = boundary("channel")
''',
        "ps_check_frame": '''
proc ps_check_frame(p: pointer; flags: uint32; vif: pointer) = boundary("frame")
''',
        "rxu_cntrl_frame_handle": '''
proc rxu_cntrl_frame_handle(p: pointer): uint32 =
  boundary("upper")
  0
''',
    }
    for name, replacement in replacements.items():
        code = code.replace(procedure(code, name), replacement, 1)
    return code + r'''
proc setup(beacon = true; associated = true) =
  onBoundary = nil
  steps.setLen(0)
  reset(if beacon: 0x0080'u16 else: 0x0208'u16, 36)
  vifs[0].vifType = 0
  vifs[0].state = 1
  vifs[0].chanCtxt = cast[pointer](1)
  if not associated:
    rxHeaderHwDescAt(0).hwFlags = 0x6000
    rxCaptureStation(rxSwTableDescAt(0), 0x6000)
proc invalidate(kind: int) =
  case kind
  of 0:
    let header = rxHeaderHwDescAt(0)
    rxCaptureStation(rxSwTableDescAt(0), header.hwFlags)
    header.mpduLengthBytes = 53
    header.frameLen = 53
    header.uploadDone = 777
    stas[4].connectionStart = 0xFEED
  of 1:
    inc stationEpochs[4]
    stas[4].connectionStart = 0xFEED
  else:
    inc rxVifEpochs[0]
    stas[4].connectionStart = 0xFEED
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("kind", [0, 1, 2], ids=["slot-reuse", "station", "vif"])
def test_beacon_pipeline_stops_after_owner_change(tmp_path: Path, mode: str, kind: int) -> None:
    run_program(tmp_path, mode, source() + f'''
let order = @["trace", "clock", "power", "traffic", "beacon", "ps",
              "received", "channel", "upper"]
for index, phase in order:
  setup()
  onBoundary = proc(name: string) =
    if name == phase: invalidate({kind})
  dispatch()
  doAssert steps == order[0 .. index], "post-processing continued after " & phase
  doAssert freed == {0 if kind == 0 else 1}
  doAssert interrupts and not rxlControlActive
  if phase == "trace" or phase == "clock":
    doAssert stas[4].connectionStart == 0xFEED
  if {kind} == 0:
    doAssert rxHeaderHwDescAt(0).uploadDone == 777
    doAssert rxHeaderHwDescAt(0).mpduLengthBytes == 53
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_data_and_unassociated_reuse_are_not_released(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup(false)
onBoundary = proc(name: string) =
  if name == "frame": invalidate(0)
dispatch()
doAssert steps == @["trace", "clock", "power", "traffic", "frame"]
doAssert freed == 0 and interrupts

setup(false, false)
onBoundary = proc(name: string) =
  if name == "trace": invalidate(0)
dispatch()
doAssert steps == @["trace"] and freed == 0 and interrupts
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_current_beacon_keeps_postprocessing_order(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
dispatch()
doAssert steps == @["trace", "clock", "power", "traffic", "beacon", "ps",
                    "received", "channel", "upper"]
doAssert freed == 1 and interrupts and not rxlControlActive
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_frame_identity_checks_header_binding_and_span(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
let header = rxHeaderHwDescAt(0)
let token = rxCaptureFrameHeader(header, addr vifs[0], addr stas[4])
doAssert rxFrameCurrent(token)
doAssert not rxFrameCurrent(rxCaptureFrameHeader(header, addr vifs[1], addr stas[4]))
doAssert not rxFrameCurrent(rxCaptureFrameHeader(header, addr vifs[0], addr stas[3]))
doAssert not rxFrameCurrent(rxCaptureFrameHeader(nil, addr vifs[0], addr stas[4]))
header.mpduLengthBytes = 35
doAssert not rxFrameCurrent(token)
header.mpduLengthBytes = 36
let payload = header.bufferChain
header.bufferChain = rxPayloadHwDescAt(1)
doAssert not rxFrameCurrent(token)
header.bufferChain = payload
rxPayloadHwDescAt(0).frameData = addr buffers[1].payloadBytes[0]
doAssert not rxFrameCurrent(token)
rxPayloadHwDescAt(0).frameData = addr buffers[0].payloadBytes[0]
doAssert rxFrameCurrent(token)
rxCaptureStation(rxSwTableDescAt(0), header.hwFlags)
doAssert not rxFrameCurrent(token)
doAssert interrupts
''')
