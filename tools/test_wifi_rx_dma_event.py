"""Check the RX DMA event callback ABI and acknowledgement sequence."""

from pathlib import Path

import pytest

from test_wifi_aes_cmac import procedure as declaration
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rx_upload_owner import source as upload_source


PLATFORM = r'''
var
  logEnabled, interrupts, incomingIrq: bool
  events, dmaPending, nimFwDbgRxlDmaEvt: uint32
  operations: seq[string]
  operationIrqs: seq[bool]
  logCalls: int
  onLog: proc()
  receivedLevel: uint32
  receivedTag, receivedFile, receivedFormat: cstring
  receivedLine: cint
let expectedFile: cstring = "rxl_cntrl.c"
let expectedFormat: cstring = "Nothing TODO with rxl_dma_evt\r\n"
proc logWrite(level: uint32; tag, file: cstring; line: cint;
              format: cstring) {.cdecl, varargs.} =
  operations.add("log")
  operationIrqs.add(interrupts)
  inc logCalls
  receivedLevel = level
  receivedTag = tag
  receivedFile = file
  receivedLine = line
  receivedFormat = format
  if onLog != nil:
    let callback = onLog
    onLog = nil
    callback()
proc irqSave(): uint32 =
  result = interrupts.uint32 * 8
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = (saved and 8) != 0
proc getLogFunc(offset: int): pointer =
  doAssert offset == 204
  if logEnabled: cast[pointer](logWrite) else: nil
proc ke_evt_clear(mask: uint32) =
  doAssert mask == 0x00400000'u32
  operations.add("clear")
  operationIrqs.add(interrupts)
  events = events and not mask
proc regWrite(address: uint; value: uint32) =
  doAssert address == 0x24A00020'u and value == 0x20'u32
  doAssert (events and 0x00400000'u32) == 0
  operations.add("ack")
  operationIrqs.add(interrupts)
  dmaPending = dmaPending and not value
proc setup(enabled: bool; irq = true) =
  logEnabled = enabled
  interrupts = irq
  incomingIrq = irq
  events = 0x00400000'u32 or 0xA5000001'u32
  dmaPending = 0xA5000021'u32
  operations.setLen(0)
  operationIrqs.setLen(0)
  onLog = nil
  logCalls = 0
  receivedLevel = 0
  receivedTag = nil
  receivedFile = nil
  receivedFormat = nil
  receivedLine = 0
  nimFwDbgRxlDmaEvt = 0
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_dma_event_log_arguments(tmp_path: Path, mode: str) -> None:
    body = procedure((FW / "rx_layer.nim").read_text(), "rxl_dma_evt")
    run_program(tmp_path, mode, PLATFORM + body + r'''
for irq in [false, true]:
  setup(true, irq)
  rxl_dma_evt()
  doAssert logCalls == 1 and receivedLevel == 2 and receivedTag == nil
  doAssert receivedLine == 826 and receivedFile == expectedFile
  doAssert receivedFormat == expectedFormat, "missing RX DMA format argument"
  doAssert operations == @["clear", "ack", "log"]
  doAssert operationIrqs == @[false, false, irq] and interrupts == irq
  doAssert events == 0xA5000001'u32 and nimFwDbgRxlDmaEvt == 1
  doAssert dmaPending == 0xA5000001'u32
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_dma_event_without_log_callback(tmp_path: Path, mode: str) -> None:
    body = procedure((FW / "rx_layer.nim").read_text(), "rxl_dma_evt")
    run_program(tmp_path, mode, PLATFORM + body + r'''
for irq in [false, true]:
  setup(false, irq)
  rxl_dma_evt()
  doAssert logCalls == 0 and operations == @["clear", "ack"]
  doAssert operationIrqs == @[false, false] and interrupts == irq
  doAssert events == 0xA5000001'u32 and nimFwDbgRxlDmaEvt == 1
  doAssert dmaPending == 0xA5000001'u32
''')


CASES = {
    "rearm_from_log": r'''
for irq in [false, true]:
  setup(true, irq)
  onLog = proc() =
    doAssert interrupts == incomingIrq
    events = 0xC0400100'u32
    dmaPending = 0xC0000020'u32
  rxl_dma_evt()
  doAssert events == 0xC0400100'u32 and dmaPending == 0xC0000020'u32,
    "old handler acknowledged the completion queued by its log callback"
  doAssert operations == @["clear", "ack", "log"] and logCalls == 1
  doAssert operationIrqs == @[false, false, irq] and interrupts == irq
''',
    "nested_from_log": r'''
for irq in [false, true]:
  setup(true, irq)
  onLog = proc() =
    events = events or 0x00400000'u32
    dmaPending = dmaPending or 0x20'u32
    rxl_dma_evt()
    events = events or 0x00400000'u32
    dmaPending = dmaPending or 0x20'u32
  rxl_dma_evt()
  doAssert events == (0x00400000'u32 or 0xA5000001'u32)
  doAssert dmaPending == 0xA5000021'u32
  doAssert operations == @["clear", "ack", "log", "clear", "ack", "log"]
  doAssert nimFwDbgRxlDmaEvt == 2 and logCalls == 2 and interrupts == irq
''',
    "log_exception": r'''
for irq in [false, true]:
  setup(true, irq)
  onLog = proc() = raise newException(ValueError, "RX diagnostic")
  var raised = false
  try: rxl_dma_evt()
  except ValueError: raised = true
  doAssert raised and interrupts == irq
  doAssert events == 0xA5000001'u32 and dmaPending == 0xA5000001'u32
  doAssert operations == @["clear", "ack", "log"] and nimFwDbgRxlDmaEvt == 1
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_dma_event_retirement(tmp_path: Path, mode: str, case: str) -> None:
    body = procedure((FW / "rx_layer.nim").read_text(), "rxl_dma_evt")
    run_program(tmp_path, mode, PLATFORM + body + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_scheduler_retains_next_dma_event(tmp_path: Path, mode: str) -> None:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    code = PLATFORM + procedure((FW / "rx_layer.nim").read_text(), "rxl_dma_evt")
    code += r'''
const KE_EVT_MAX = 26
var keEvtHandlers: array[KE_EVT_MAX, tuple[handler, param: pointer]]
template keEvtField: uint32 = events
template keEnvEventField(): ptr uint32 = addr events
proc nimFwTrace2U32(tag: cstring; first, second: uint32) = discard
proc assert_err(condition, file: cstring; line: cint) = doAssert false
'''
    code += "".join(procedure(kernel, name) for name in (
        "eventIndex32", "keDispatchEvent", "ke_evt_schedule"))
    run_program(tmp_path, mode, code + r'''
for irq in [false, true]:
  setup(true, irq)
  events = 0x00400000'u32
  dmaPending = 0x20
  keEvtHandlers[9] = (cast[pointer](rxl_dma_evt), nil)
  onLog = proc() =
    events = events or 0x00400000'u32
    dmaPending = dmaPending or 0x20'u32
  ke_evt_schedule()
  doAssert events == 0x00400000'u32 and dmaPending == 0x20
  doAssert logCalls == 1 and nimFwDbgRxlDmaEvt == 1
  ke_evt_schedule()
  doAssert events == 0 and dmaPending == 0
  doAssert logCalls == 2 and nimFwDbgRxlDmaEvt == 2 and interrupts == irq
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_upload_full_log_arguments_and_release(tmp_path: Path, mode: str) -> None:
    code = upload_source()
    log = r'''
{.emit: "#include <stdarg.h>".}
proc logMessage(level: uint32; tag, file: cstring; line: cint;
                format: cstring) {.cdecl, varargs.} =
  var capacity: cint
  var used: clong
  {.emit: ["va_list args; va_start(args, ", format, "); ",
           capacity, " = va_arg(args, int); ",
           used, " = va_arg(args, long); va_end(args);"].}
  receivedLevel = level
  receivedTag = tag
  receivedFile = file
  receivedLine = line
  receivedFormat = format
  receivedCapacity = capacity
  receivedUsed = used
  inc logCalls
  if onLog != nil: onLog()
'''
    code = code.replace(declaration(code, "logMessage"), log, 1)
    state = r'''
var
  receivedLevel: uint32
  receivedTag, receivedFile, receivedFormat: cstring
  receivedLine, receivedCapacity: cint
  receivedUsed: clong
  logCalls: int
'''
    run_program(tmp_path, mode, state + code + r'''
for incoming in [false, true]:
  for used in [39'u32, 40, 41, 42, 0x80000000'u32, 0xFFFFFFFF'u32]:
    setup()
    logCalls = 0
    irq = incoming
    lower.uploadCount = used
    onLog = proc() = doAssert irq == incoming
    rxu_swdesc_upload_evt()
    doAssert logCalls == 1 and receivedLevel == 2 and receivedTag == nil
    doAssert receivedFile == cstring("rxu_cntrl.c") and receivedLine == 2002
    doAssert receivedFormat == cstring("---->>> Drop before too late %d:%ld\r\n")
    doAssert receivedCapacity == 41 and receivedUsed == cast[int32](used).clong
    doAssert freed == @[cast[pointer](addr descriptors[0])]
    doAssert lower.uploadCount == used and irq == incoming
    doAssert "input" notin calls
''')
