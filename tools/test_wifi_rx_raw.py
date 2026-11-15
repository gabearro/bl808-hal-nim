"""Exercise raw unassociated RX routing and the actual MPDU upload helper."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_rx_decapsulation import CHECKS, FW, dispatch_source, procedure


def source(real_upload: bool) -> str:
    code = dispatch_source()
    body = procedure(code, "rxu_cntrl_frame_handle")
    code = code.replace(body, "", 1)
    code = code.replace(procedure(code, "rxu_mpdu_upload_and_indicate"), "", 1)
    code = code.replace(procedure(code, "irqSave"), "", 1)
    code = code.replace(procedure(code, "irqRestore"), "", 1)
    code = code.replace(procedure(code, "rxu_cntrl_desc_prepare"), "", 1)
    code = code.replace(procedure(code, "vif_mgmt_get_first_ap_inf"), "", 1)
    code = code.replace(procedure(code, "apm_send_mlme"), "", 1)
    code = code.replace(procedure(code, "rxu_mgt_frame_check"), "", 1)
    code = code.replace(procedure(code, "ke_evt_set"), "", 1)
    code += r'''
var
  interrupts = true
  apPresent = false
  mgtResult: uint32
  mlmeCalls, mgtCalls, wakeups: int
proc irqSave(): uint32 =
  result = if interrupts: 8'u32 else: 0'u32
  interrupts = false
proc irqRestore(value: uint32) = interrupts = (value and 8) != 0
proc rxu_cntrl_desc_prepare(p: pointer) =
  doAssert not interrupts
  doAssert p == addr mpdu
  inc prepared
  envState.uploadList.first = p
proc vif_mgmt_get_first_ap_inf(): pointer =
  if apPresent: addr vifs[1] else: nil
proc apm_send_mlme(vif: pointer; fc: uint16; dest, callback, arg, extra: pointer) =
  doAssert vif == cast[pointer](addr vifs[1]) and fc == 192
  doAssert equalMem(dest, addr macDataFrameAt(chain.frameData).addr2, 6)
  doAssert callback == nil and arg == nil and extra == cast[pointer](1)
  inc mlmeCalls
proc rxu_mgt_frame_check(p: pointer; sta: uint8): uint32 =
  doAssert p == cast[pointer](addr mpdu) and sta == 255
  inc mgtCalls
  mgtResult
proc ke_evt_set(mask: uint32) =
  doAssert mask == 0x00800000'u32
  inc wakeups
'''
    if real_upload:
        code += r'''
type RxPayloadHwDescView = Chain
template bufferStart(p: ptr Chain): uint = cast[uint](p.frameData)
proc c_memmove(dst, src: pointer; size: csize_t): pointer
  {.importc: "memmove", header: "<string.h>".}
proc assert_warn(condition, file: cstring; line: int) = doAssert false
'''
        production = FW.read_text()
        code += procedure(production, "rxuStripPayloadPrefix")
        code += procedure(production, "rxu_mpdu_upload_and_indicate")
    else:
        code += r'''
proc rxu_mpdu_upload_and_indicate(p: pointer) =
  inc transferred
  mpdu.curDesc = cast[pointer](1)
  let saved = irqSave()
  rxu_cntrl_desc_prepare(p)
  irqRestore(saved)
'''
    code += body + procedure(CHECKS, "setup")
    return code + r'''
proc reset(fc: uint16; length: int) =
  setup(fc, length, 0)
  sw.hwFlags = 0x201C
  interrupts = true
  apPresent = false
  mgtResult = 0
  mlmeCalls = 0
  mgtCalls = 0
  wakeups = 0
'''


CASES = {
    "data": r'''
for fc in [0x0008'u16, 0x0048, 0x0088, 0x8088, 0x0388, 0x8388]:
  let length = rxu_cntrl_machdr_len_get(fc).int + 16
  reset(fc, length)
  let original = bytes
  doAssert rxu_cntrl_frame_handle(addr mpdu) == 1
  doAssert transferred == 1 and prepared == 1 and wakeups == 1
  doAssert mgtCalls == 0 and mlmeCalls == 0 and eapolCalls == 0
  doAssert bytes == original and sw.mpduLengthBytes == length.uint16
  doAssert envState.staIdx == 255 and envState.vifIdx == 255
  doAssert interrupts
''',
    "control": r'''
for fc in [0x00C4'u16, 0x00D4, 0x00A4, 0x00B4]:
  let length = rxu_cntrl_machdr_len_get(fc).int
  for enabled in [false, true]:
    reset(fc, length)
    let buffer = alloc(length)
    defer: dealloc(buffer)
    copyMem(buffer, addr bytes[0], length)
    chain.frameData = buffer
    interrupts = enabled
    doAssert rxu_cntrl_frame_handle(addr mpdu) == 1
    doAssert transferred == 1 and prepared == 1 and wakeups == 1
    doAssert sw.mpduLengthBytes == length.uint16
    doAssert envState.seqCtrl == 0 and envState.seqNum == 0 and envState.fragNum == 0
    doAssert envState.staIdx == 255 and envState.vifIdx == 255 and envState.tid == 0
    doAssert equalMem(buffer, addr bytes[0], length)
    doAssert interrupts == enabled
''',
    "ap_routing": r'''
for differentByte in -1..5:
  reset(0x0008, 40)
  apPresent = true
  vifs[1].macAddr = macDataFrameAt(chain.frameData).addr1
  if differentByte >= 0: vifs[1].macAddr[differentByte] = vifs[1].macAddr[differentByte] xor 1
  let result = rxu_cntrl_frame_handle(addr mpdu)
  doAssert result == (differentByte >= 0).uint32
  doAssert transferred == (differentByte >= 0).int and prepared == transferred
  doAssert mlmeCalls == (differentByte == -1).int and mgtCalls == 0
  doAssert wakeups == transferred
''',
    "management": r'''
for accepted in [0'u32, 1]:
  reset(0x00B0, 30)
  mgtResult = accepted
  doAssert rxu_cntrl_frame_handle(addr mpdu) == accepted
  doAssert mgtCalls == 1 and mlmeCalls == 0
  doAssert transferred == 0 and prepared == 0
''',
    "invalid": r'''
for fc in [0x0008'u16, 0x00C4, 0x00D4, 0x00A4, 0x00B4]:
  for length in 0..<rxu_cntrl_machdr_len_get(fc).int:
    reset(fc, length)
    doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
    doAssert transferred == 0 and prepared == 0 and mlmeCalls == 0 and mgtCalls == 0
  reset(fc, rxu_cntrl_machdr_len_get(fc).int)
  sessionCurrent = false
  doAssert rxu_cntrl_frame_handle(addr mpdu) == 0 and prepared == 0
  reset(fc, rxu_cntrl_machdr_len_get(fc).int)
  sw.hwFlags = sw.hwFlags and not 0x2000'u32
  doAssert rxu_cntrl_frame_handle(addr mpdu) == 0 and prepared == 0
for fc in [0x00C4'u16, 0x00D4, 0x00A4, 0x00B4]:
  reset(fc, rxu_cntrl_machdr_len_get(fc).int)
  sw.hwFlags = sw.hwFlags or 0x02000000'u32
  doAssert rxu_cntrl_frame_handle(addr mpdu) == 0 and prepared == 0
''',
    "wake_existing_queue": r'''
reset(0x0008, 24)
sw.hwFlags = 0
envState.uploadList.first = addr mpdu
doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
doAssert wakeups == 1 and prepared == 0
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("real_upload", [False, True], ids=["routing", "integrated"])
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_raw_rx(tmp_path: Path, case: str, real_upload: bool, mode: str) -> None:
    checks = CASES[case]
    if real_upload and case in {"data", "control"}:
        checks += "\ndoAssert (sw.frameControlFlags and 0x00FFFF02'u32) == 0x00FFFF02'u32\n"
    run_program(tmp_path, mode, source(real_upload) + checks)
