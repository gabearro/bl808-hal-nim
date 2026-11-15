"""Keep RX scheduler events and copied-frame ownership intact on errors."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rx_drain_lifetime import source as drain_source
from test_wifi_rx_upload_lifetime import PLATFORM, CHECKS


def upload_source(pbuf_input: bool) -> str:
    code = ("{.define: bl808WifiRxPbufInput.}\n" if pbuf_input else "")
    code += "var events: uint32\n" + PLATFORM
    code = code.replace(procedure(code, "ke_evt_clear"), r'''
proc ke_evt_clear(mask: uint32) =
  events = events and not mask
  calls.add("clear")
''', 1)
    code = code.replace(procedure(code, "ke_evt_set"),
                        "proc ke_evt_set(mask: uint32) = events = events or mask\n", 1)
    # Exercise the same exported/imported C boundary used by the firmware.
    host_input = procedure(code, "tcpip_stack_input")
    host_impl = host_input.replace("proc tcpip_stack_input(", "proc hostInputImplementation(", 1)
    host_impl = host_impl.replace("fc: uint32): cint =", "fc: uint32): cint "
                                  '{.exportc: "tcpip_stack_input", cdecl, raises: [Exception].} =', 1)
    host_decl = procedure((FW / "kernel_mac_channel.nim").read_text(), "tcpip_stack_input")
    code = code.replace(host_input, host_impl + host_decl + "\n", 1)
    lower = (FW / "rx_layer.nim").read_text()
    for name in ("rxUploadGeneration", "rxUploadCurrent", "rxInvalidateUpload", "rxReleaseUpload"):
        code += procedure(lower, name)
    code += procedure((FW / "rx_upper.nim").read_text(), "rxu_swdesc_upload_evt")
    code += CHECKS.split("# Generation changes", 1)[0]
    return code + r'''
proc prepare(incoming: bool) =
  when defined(bl808WifiRxPbufInput): setup(false)
  else: setup()
  irq = incoming
  events = 0x801000
  upper.uploadList.nodes.add(addr slots[0])
  upper.uploadList.nodes.add(addr slots[1])
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_lower_rx_error_keeps_pending_event(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, drain_source() + r'''
for incoming in [false, true]:
  for afterRelease in [false, true]:
    setup()
    interrupts = incoming
    if afterRelease:
      onFree = proc() = raise newException(ValueError, "release callback stopped")
    else:
      onEvent = proc() = raise newException(ValueError, "event callback stopped")
    var raised = false
    try: rxl_cntrl_evt()
    except ValueError: raised = true
    doAssert raised and not rxlControlActive and interrupts == incoming
    doAssert (events and 0x100000) != 0, "pending lower RX lost its event"
    let next = if afterRelease: 1 else: 0
    doAssert env.queue.first == addr rxSwTableDescAt(next).link
    while env.queue.first != nil: rxl_cntrl_evt()
    doAssert delivered == @[0, 1, 2, 3, 4, 5] and released == delivered
    doAssert events == 0 and interrupts == incoming
setup()
env.processingFlag = 1
rxl_cntrl_evt()
doAssert events == 0 and not rxlControlActive
''')


@pytest.mark.parametrize("pbuf_input", [False, True])
@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_copy_error_releases_current_and_rearms_next(tmp_path: Path, mode: str, pbuf_input: bool) -> None:
    run_program(tmp_path, mode, upload_source(pbuf_input) + r'''
for incoming in [false, true]:
  prepare(incoming)
  uploadHook = proc() =
    doAssert irq == incoming
    uploadHook = nil
    raise newException(ValueError, "copied input stopped")
  var raised = false
  try: rxu_swdesc_upload_evt()
  except ValueError: raised = true
  doAssert raised and irq == incoming
  doAssert freed == @[cast[pointer](addr slots[0])], "copied frame retained its RX slot"
  doAssert releaseIrqs == @[false] and lower.uploadCount == 0
  doAssert upper.uploadList.nodes == @[cast[pointer](addr slots[1])]
  doAssert events == 0x801000, "pending upload lost its event"
  rxu_swdesc_upload_evt()
  doAssert freed == @[cast[pointer](addr slots[0]), cast[pointer](addr slots[1])]
  doAssert upper.uploadList.nodes.len == 0 and events == 0x1000
  doAssert irq == incoming and lower.uploadCount == 0

# A callback can recycle the slot before reporting an error. Leave its new
# generation and payload state alone while making the remaining queue runnable.
for incoming in [false, true]:
  prepare(incoming)
  uploadHook = proc() =
    uploadHook = nil
    rxInvalidateUpload(addr slots[0])
    headers[0].mpduLengthBytes = 555
    payloads[0].usedFlag = 0xA5A5
    lower.uploadCount = 777
    raise newException(ValueError, "input replaced the slot")
  var raised = false
  try: rxu_swdesc_upload_evt()
  except ValueError: raised = true
  doAssert raised and irq == incoming and freed.len == 0
  doAssert headers[0].mpduLengthBytes == 555 and payloads[0].usedFlag == 0xA5A5
  doAssert lower.uploadCount == 777 and events == 0x801000
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_corrupt_upload_still_stops_without_rescheduling(tmp_path: Path, mode: str) -> None:
    code = upload_source(True)
    code = code.replace(procedure(code, "assert_rec"), r'''
var recoveryCalls: int
proc assert_rec(condition, file: cstring; line: int) = inc recoveryCalls
''', 1)
    run_program(tmp_path, mode, code + r'''
for incoming in [false, true]:
  prepare(incoming)
  recoveryCalls = 0
  headers[0].uploadDone = 1
  rxu_swdesc_upload_evt()
  doAssert recoveryCalls == 1 and freed.len == 0 and irq == incoming
  doAssert upper.uploadList.nodes == @[cast[pointer](addr slots[1])]
  doAssert events == 0x1000, "corrupt chain must wait for recovery"
''')
