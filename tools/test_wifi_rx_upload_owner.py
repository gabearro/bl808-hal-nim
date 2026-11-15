"""Exercise atomic RX upload dequeue and frame identity across host callbacks."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rx_upload import PLATFORM
from test_wifi_rx_chain import PLATFORM as CHAIN_PLATFORM, CHECKS as CHAIN_CHECKS


def source() -> str:
    code = r'''
var irq = true
var requirePopLock, differentExit: bool
var onUpload, onEnter, onLog: proc()
var exits, wrongExits, recovered: int
proc irqSave(): uint32 =
  result = irq.uint32 * 8
  irq = false
proc irqRestore(saved: uint32) = irq = (saved and 8) != 0
proc logMessage(level: uint32; tag, file: cstring; line: cint;
                format: cstring) {.cdecl, varargs.} =
  if onLog != nil: onLog()
''' + PLATFORM
    code = code.replace(procedure(code, "rxMpduHeader"), "", 1)
    code = code.replace(procedure(code, "getLogFunc"),
                        "proc getLogFunc(offset: int): pointer = cast[pointer](logMessage)\n", 1)
    code = code.replace(procedure(code, "assert_rec"),
                        "proc assert_rec(file, condition: cstring; line: int) = inc recovered\n", 1)
    code = code.replace(procedure(code, "co_list_pop_front"), r'''
proc co_list_pop_front(list: ptr CoList): pointer =
  if requirePopLock: doAssert not irq
  if list.nodes.len == 0: return nil
  result = list.nodes[0]
  list.nodes.delete(0)
''', 1)
    code = code.replace("  inputResult\n", "  if onUpload != nil: onUpload()\n  inputResult\n", 1)
    code = code.replace(procedure(code, "enter"), r'''
proc enter(): uint32 {.cdecl.} =
  calls.add("enter")
  result = irqSave()
  if onEnter != nil: onEnter()
''', 1)
    code = code.replace(procedure(code, "leave"), r'''
proc leave(saved: uint32) {.cdecl.} =
  inc exits
  irqRestore(saved)
proc otherLeave(saved: uint32) {.cdecl.} =
  inc wrongExits
  irqRestore(saved)
''', 1)
    code = code.replace(procedure(code, "blOpsFunc"), r'''
proc blOpsFunc(slot: int): pointer =
  case slot
  of 20: cast[pointer](enter)
  of 24:
    if differentExit: cast[pointer](otherLeave) else: cast[pointer](leave)
  else: nil
''', 1)
    code += r'''
var descriptors: array[2, RxMpduDescView]
var headers: array[2, RxSwDescView]
var payloads: array[2, RxPayloadHwDescView]
proc rxMpduHeader(p: pointer): ptr RxSwDescView =
  for i in 0 .. 1:
    if p == (addr descriptors[i]) and descriptors[i].swDesc == (addr headers[i]):
      return addr headers[i]
'''
    code += procedure((FW / "rx_upper.nim").read_text(), "rxu_swdesc_upload_evt")
    return code + r'''
proc setup() =
  descriptors = default(typeof(descriptors))
  headers = default(typeof(headers))
  payloads = default(typeof(payloads))
  upper = default(RxuEnv)
  lower = default(RxlEnv)
  onUpload = nil
  onEnter = nil
  onLog = nil
  differentExit = false
  requirePopLock = false
  exits = 0
  wrongExits = 0
  recovered = 0
  irq = true
  inputResult = 0
  calls.setLen(0)
  freed.setLen(0)
  nimFwDbgRxuUploadTcpipOk = 0
  nimFwDbgRxuUploadTcpipFail = 0
  for i in 0 .. 1:
    payloads[i].bufferAddr = (0x20000000 + i * 0x800).uint32
    headers[i].mpduLengthBytes = 20
    headers[i].bufferChain = addr payloads[i]
    descriptors[i].swDesc = addr headers[i]
    descriptors[i].descFlag = 3
  upper.uploadList.nodes.add(addr descriptors[0])
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_upload_dequeues_with_interrupts_masked(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [false, true]:
  setup()
  requirePopLock = true
  irq = incoming
  onUpload = proc() = doAssert irq == incoming
  rxu_swdesc_upload_evt()
  doAssert upper.uploadList.nodes.len == 0 and irq == incoming
  doAssert nimFwDbgRxuUploadTcpipOk == 1
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_host_rebinding_does_not_update_replacement(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for variant in 0 .. 4:
  setup()
  onUpload = proc() =
    case variant
    of 0: descriptors[0].swDesc = addr headers[1]
    of 1: headers[0].bufferChain = addr payloads[1]
    of 2: headers[0].mpduLengthBytes = 99
    of 3: headers[0].bufferOffset = 2
    else: descriptors[0].descCount = 77
    lower.uploadCount = 999
    nimFwDbgRxuUploadTcpipOk = 777
    nimFwDbgRxuUploadTcpipFail = 888
  rxu_swdesc_upload_evt()
  doAssert freed.len == 0 and lower.uploadCount == 999
  doAssert nimFwDbgRxuUploadTcpipOk == 777 and nimFwDbgRxuUploadTcpipFail == 888
  doAssert irq
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_upload_credit_keeps_original_callback_pair(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
onEnter = proc() = differentExit = true
rxu_swdesc_upload_evt()
doAssert lower.uploadCount == 1 and exits == 1 and wrongExits == 0
doAssert irq
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_full_pool_log_rebinding_is_not_released(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [false, true]:
  setup()
  irq = incoming
  lower.uploadCount = 39
  onLog = proc() =
    doAssert irq == incoming
    descriptors[0].swDesc = addr headers[1]
    lower.uploadCount = 777
  rxu_swdesc_upload_evt()
  doAssert freed.len == 0 and lower.uploadCount == 777 and irq == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_credit_rebinding_does_not_change_count(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
onEnter = proc() =
  descriptors[0].swDesc = addr headers[1]
  lower.uploadCount = 777
rxu_swdesc_upload_evt()
doAssert lower.uploadCount == 777 and exits == 1 and irq
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_invalid_header_does_not_reach_host(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for invalid in [nil, cast[pointer](1), cast[pointer](addr headers[1])]:
  setup()
  descriptors[0].swDesc = invalid
  rxu_swdesc_upload_evt()
  doAssert recovered == 1 and capturedNode != cast[pointer](addr descriptors[0])
  doAssert descriptors[0].descCount == 0 and payloads[0].usedFlag == 0
  doAssert freed.len == 0 and irq
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_bounded_upload_release_pipeline(tmp_path: Path, mode: str) -> None:
    code = CHAIN_PLATFORM
    lower = (FW / "rx_layer.nim").read_text()
    for name in ("rxPayloadDescIndex", "rxPayloadBufferValid", "rxPayloadChainBounds", "rxl_mpdu_free"):
        code += procedure(lower, name)
    code += r'''
proc rxHostForward(desc: pointer; generation, status: uint32; header: pointer;
                   offset: uint32; data: pointer; extra: uint32): cint =
  tcpip_stack_input(desc, status, header, offset, data, extra)
'''
    code += procedure((FW / "rx_upper.nim").read_text(), "rxu_swdesc_upload_evt")
    code += procedure((FW / "mac_config_debug.nim").read_text(), "bl60x_firmwre_mpdu_free")
    code += CHAIN_CHECKS.split("\nfor count in 1 .. 41:", 1)[0]
    run_program(tmp_path, mode, code + r'''
for count in [1, 2, 4]:
  reset(count)
  sw.mpduLengthBytes = (count * 1736).uint16
  for i in 0 ..< count: rxPayloadHwDescAt(i).usedFlag = 0
  upper.uploadList.nodes.add(addr desc)
  rxu_swdesc_upload_evt()
  doAssert inputCalls == 1 and released == 0 and lower.uploadCount == count.uint32
  doAssert level == 8 and entered == exited
  bl60x_firmwre_mpdu_free(addr desc)
  doAssert released == 1 and lower.uploadCount == 0
  doAssert level == 8 and entered == exited
  for i in 0 ..< count: doAssert rxPayloadHwDescAt(i).usedFlag == 0
''')
