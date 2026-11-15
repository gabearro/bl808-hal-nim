"""Keep a completed frame's channel metadata across deferred RX processing."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rx_admission import admission_source


def source() -> str:
    code = admission_source()
    code = "var radio: array[8, uint8]\nvar channelReads: int\nvar onChannel: proc()\n" + code
    code = code.replace(procedure(code, "phy_get_channel_raw"), r'''
proc phy_get_channel_raw(info: pointer; index: uint8) =
  doAssert index == 0
  inc channelReads
  copyMem(info, addr radio[0], 8)
  if onChannel != nil:
    let callback = onChannel
    onChannel = nil
    callback()
''', 1)
    lower = (FW / "rx_layer.nim").read_text()
    if "proc rxTransferFrame(" in lower:
        code += procedure(lower, "rxTransferFrame")
    code += procedure(lower, "rxl_mpdu_transfer")
    for name in ["rxInvalidateUpload", "rx_swdesc_init"]:
        body = procedure(lower, name)
        if name == "rx_swdesc_init":
            body = body.replace(".firstHeaderDesc =", ".swDesc =")
        code += body
    return code + r'''
proc setup() =
  reset(0x0208, 24)
  radio = [0'u8, 1, 0x6C, 9, 0x6C, 9, 0, 0]
  channelReads = 0
  onChannel = nil
proc harvest() =
  env.submittedHead = rxHeaderHwDescAt(0)
  rxHeaderHwDescAt(0).next = nil
  rxl_timer_int_handler()
'''


CASES = {
    "deferred_retune": r'''
setup()
let received = radio
harvest()
let descriptor = cast[pointer](rxSwTableDescAt(0))
radio = [1'u8, 2, 0x3C, 20, 0x3C, 20, 0, 0]
rxlControlActive = true
rxl_cntrl_evt()
rxlControlActive = false
doAssert env.queue.first == addr rxSwTableDescAt(0).link
rxl_mpdu_transfer(descriptor)
doAssert rxHeaderHwDescAt(0).channelInfo == received
doAssert channelReads == 1, "upload must use the receive-channel snapshot"
''',
    "independent_frames": r'''
setup()
let first = radio
harvest()
radio = [1'u8, 0, 0x3C, 20, 0x3C, 20, 0, 0]
let second = radio
rxHeaderHwDescAt(1)[] = rxHeaderHwDescAt(0)[]
rxHeaderHwDescAt(1).swDesc = pointerAddrU32(rxSwTableDescAt(1))
rxPayloadHwDescAt(1)[] = rxPayloadHwDescAt(0)[]
rxPayloadHwDescAt(1).bufferAddr = pointerAddrU32(addr buffers[1].payloadBytes[0])
rxPayloadHwDescAt(1).bufferStart = rxPayloadHwDescAt(1).bufferAddr
rxPayloadHwDescAt(1).frameData = addr buffers[1].payloadBytes[0]
buffers[1] = buffers[0]
rxHeaderHwDescAt(1).bufferChain = rxPayloadHwDescAt(1)
rxHeaderHwDescAt(1).bufferAddr = pointerAddrU32(rxPayloadHwDescAt(1))
env.submittedHead = rxHeaderHwDescAt(1)
rxl_timer_int_handler()
radio = [0'u8, 0, 0x85, 9, 0x85, 9, 0, 0]
rxl_mpdu_transfer(rxSwTableDescAt(1))
rxl_mpdu_transfer(rxSwTableDescAt(0))
doAssert rxHeaderHwDescAt(0).channelInfo == first
doAssert rxHeaderHwDescAt(1).channelInfo == second
doAssert channelReads == 2
''',
    "slot_reuse": r'''
setup()
harvest()
rxInvalidateUpload(rxSwTableDescAt(0))
radio = [1'u8, 0, 0x3C, 20, 0x3C, 20, 0, 0]
let replacement = radio
harvest()
radio = default(typeof(radio))
rxl_mpdu_transfer(rxSwTableDescAt(0))
doAssert rxHeaderHwDescAt(0).channelInfo == replacement
doAssert channelReads == 2
''',
    "fallback": r'''
setup()
let current = radio
rxl_mpdu_transfer(rxSwTableDescAt(0))
doAssert rxHeaderHwDescAt(0).channelInfo == current and channelReads == 1
radio[2] = 0x85
rxl_mpdu_transfer(rxSwTableDescAt(0))
doAssert rxHeaderHwDescAt(0).channelInfo == radio and channelReads == 2
''',
    "reset_and_wrap": r'''
setup()
harvest()
rx_swdesc_init()
rxCaptureStation(rxSwTableDescAt(0), rxHeaderHwDescAt(0).hwFlags)
radio[2] = 0x85
rxl_mpdu_transfer(rxSwTableDescAt(0))
doAssert rxHeaderHwDescAt(0).channelInfo == radio and channelReads == 2
rxUploadEpochs[0] = high(uint32)
radio[2] = 0x76
harvest()
doAssert rxUploadEpochs[0] == 0
let latest = radio
radio = default(typeof(radio))
rxl_mpdu_transfer(rxSwTableDescAt(0))
doAssert rxHeaderHwDescAt(0).channelInfo == latest and channelReads == 3
''',
    "cancel_capture": r'''
setup()
rxHeaderHwDescAt(0).channelInfo = [9'u8, 8, 7, 6, 5, 4, 3, 2]
let before = rxHeaderHwDescAt(0).channelInfo
onChannel = proc() = rxInvalidateUpload(rxSwTableDescAt(0))
harvest()
doAssert rxHeaderHwDescAt(0).channelInfo == before
''',
    "read_snapshot": r'''
setup()
harvest()
var expected, observed: array[2, uint32]
copyMem(addr expected[0], addr radio[0], sizeof(expected))
radio = default(typeof(radio))
for initiallyEnabled in [false, true]:
  interrupts = initiallyEnabled
  doAssert rxReadCapturedChannel(rxSwTableDescAt(0), observed)
  doAssert observed == expected and interrupts == initiallyEnabled
interrupts = true
rxInvalidateUpload(rxSwTableDescAt(0))
observed = [0x12345678'u32, 0x90ABCDEF'u32]
let unchanged = observed
doAssert not rxReadCapturedChannel(rxSwTableDescAt(0), observed)
doAssert observed == unchanged
doAssert not rxReadCapturedChannel(nil, observed)
doAssert observed == unchanged
harvest()
rxSwTableDescAt(0).swDesc = rxHeaderHwDescAt(1)
doAssert not rxReadCapturedChannel(rxSwTableDescAt(0), observed)
doAssert observed == unchanged and interrupts
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_rx_channel_capture(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
