"""Check RX initialization diagnostics and callback boundaries against the blob."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rx_init_owner import source as owner_source


PREFIX = r'''
type Diagnostic = tuple[format, message: string, irq: uint32,
                        headerHead, payloadHead: uint32]
var
  diagnostics: seq[Diagnostic]
  diagnosticEvents: seq[string]
  logEnabled = true
  logTrigger = -1
{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
'''

PRINTER = r'''
proc log(format: cstring) {.cdecl, varargs.} =
  var output: array[512, char]
  var size: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", size,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert size >= 0 and size < output.len.cint
  let index = diagnostics.len
  diagnostics.add(($format, $cast[cstring](addr output[0]), irqLevel,
                   hdSubmitted, pdSubmitted))
  diagnosticEvents.add("log")
  if index == logTrigger: runHook(onLog)
'''

SUPPORT = r'''
proc snprintf(output: cstring; size: csize_t; format: cstring): cint
  {.importc, header: "<stdio.h>", varargs.}
proc ptrText(p: pointer): string =
  var output: array[64, char]
  discard snprintf(cast[cstring](addr output[0]), output.len.csize_t, "%p", p)
  $cast[cstring](addr output[0])
proc setupDiagnostic(hdAvailable, pdAvailable: int; incoming = 8'u32) =
  setup()
  irqLevel = incoming
  diagnostics.setLen(0)
  diagnosticEvents.setLen(0)
  logEnabled = true
  logTrigger = -1
  for i in 0 ..< 41:
    headers[i].usedFlag = (i >= hdAvailable).uint32
    payloads[i].usedFlag = (i >= pdAvailable).uint32
proc expectedMessages(hdCount, pdCount: int): seq[string] =
  if hdCount <= 3: result.add("No enough DESC " & $hdCount & "(41)\r\n")
  if pdCount <= 3: result.add("No enough PBD DESC, " & $pdCount & "(41)\r\n")
  if hdCount < 2 or pdCount < 2:
    let hdCurrent = if hdCount > 0: cast[pointer](addr headers[0]) else: nil
    let hdHead = if hdCount > 1: cast[pointer](addr headers[1]) else: nil
    let hdTail = if hdCount > 0: cast[pointer](addr headers[hdCount - 1]) else: nil
    let pdCurrent = if pdCount > 0: cast[pointer](addr payloads[0]) else: nil
    let pdHead = if pdCount > 1: cast[pointer](addr payloads[1]) else: nil
    let pdTail = if pdCount > 0: cast[pointer](addr payloads[pdCount - 1]) else: nil
    result.add(ptrText(hdCurrent) & ":" & ptrText(hdHead) & ptrText(hdTail) &
               " vs " & ptrText(pdCurrent) & ":" & ptrText(pdHead) & ":" &
               ptrText(pdTail) & "\r\n")
proc expectedEvents(hdCount, pdCount: int): seq[string] =
  if hdCount <= 3: result.add("log")
  result.add(@["hd-head", "hd-dma"])
  if pdCount <= 3: result.add("log")
  result.add(@["pd-head", "pd-dma", "probe"])
  if hdCount < 2 or pdCount < 2: result.add("log")
  result.add("trace")
'''


def source() -> str:
    code = PREFIX + owner_source()
    replacements = {
        "log": PRINTER,
        "machwRxSetHdSubmittedHead": r'''
proc machwRxSetHdSubmittedHead(value: uint32) =
  diagnosticEvents.add("hd-head")
  hdSubmitted = value
''',
        "machwRxSetPdSubmittedHead": r'''
proc machwRxSetPdSubmittedHead(value: uint32) =
  diagnosticEvents.add("pd-head")
  pdSubmitted = value
''',
        "machwRxDmaTrigger": r'''
proc machwRxDmaTrigger(bits: uint32) =
  diagnosticEvents.add(if bits == 0x04000000'u32: "hd-dma" else: "pd-dma")
  triggers.add(bits)
''',
        "nimFwRxDmaAfterInitProbe": r'''
proc nimFwRxDmaAfterInitProbe() =
  diagnosticEvents.add("probe")
  runHook(onProbe)
''',
        "rfPhyTraceCheckpoint": r'''
proc rfPhyTraceCheckpoint(stage: uint32) =
  doAssert stage == 0x10 and irqLevel == 0
  diagnosticEvents.add("trace")
  runHook(onTrace)
''',
    }
    for name, replacement in replacements.items():
        code = code.replace(procedure(code, name), replacement, 1)
    code = code.replace(
        "of 4: result = cast[pointer](log)",
        "of 4:\n    if logEnabled: result = cast[pointer](log)",
        1,
    )
    return code + SUPPORT


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_counts_pointer_arguments_and_warning_order(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for full in [0'u32, 1]:
  for hdAvailable in [0, 1, 2, 3, 4, 41]:
    for pdAvailable in [0, 1, 2, 3, 4, 41]:
      for incoming in [0'u32, 8]:
        setupDiagnostic(hdAvailable, pdAvailable, incoming)
        let hdCount = if full != 0: 41 else: hdAvailable
        let pdCount = if full != 0: 41 else: pdAvailable
        let ok = rxl_hwdesc_init(full)
        if hdCount >= 2 and pdCount >= 2: doAssert ok
        let expected = expectedMessages(hdCount, pdCount)
        doAssert diagnostics.len == expected.len, "missing descriptor-capacity diagnostic"
        for index, record in diagnostics:
          doAssert record.message == expected[index]
          doAssert record.irq == 0
          if record.format == "No enough DESC %d(%d)\r\n":
            doAssert record.headerHead == 0 and record.payloadHead == 0
          elif record.format == "No enough PBD DESC, %d(%d)\r\n":
            doAssert record.payloadHead == 0
          else:
            doAssert record.format == "%p:%p%p vs %p:%p:%p\r\n"
        doAssert diagnosticEvents == expectedEvents(hdCount, pdCount)
        doAssert irqLevel == incoming and enters == 1 and exits == 1
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_missing_or_replaced_printer_keeps_initialization_order(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [0'u32, 8]:
  setupDiagnostic(3, 3, incoming)
  logEnabled = false
  doAssert rxl_hwdesc_init(0)
  doAssert diagnostics.len == 0
  doAssert diagnosticEvents == @["hd-head", "hd-dma", "pd-head", "pd-dma", "probe", "trace"]
  doAssert lower.submittedHead == addr headers[1]
  doAssert hardware.pdCurrent == (addr payloads[0]) and irqLevel == incoming

  setupDiagnostic(3, 3, incoming)
  logTrigger = 0
  onLog = proc() = logEnabled = false
  doAssert rxl_hwdesc_init(0)
  doAssert diagnostics.len == 1
  doAssert diagnostics[0].message == "No enough DESC 3(41)\r\n"
  doAssert diagnosticEvents == @["log", "hd-head", "hd-dma", "pd-head", "pd-dma", "probe", "trace"]
  doAssert lower.submittedHead == (addr headers[1]) and irqLevel == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_warning_callback_reset_stops_old_publication(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for useReset in [false, true]:
  for phase in 0 .. 2:
    for incoming in [0'u32, 8]:
      setupDiagnostic(1, 1, incoming)
      logTrigger = phase
      onLog = proc() =
        doAssert rxl_hwdesc_init(1)
        markReplacement()
      let ok = if useReset: rxl_reset() else: rxl_hwdesc_init(0)
      doAssert not ok
      doAssert diagnostics.len == phase + 1 and triggers.len == phase + 2
      doAssert enters == 2 and exits == 2 and irqLevel == incoming
      doAssert listClears == 0 and upperInitializations == 0
      doAssert txControlState.resetInProgress == 1 and resetEvents == 0x80000000'u32
      checkReplacement()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_warning_exception_restores_critical_callback_pair(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for useReset in [false, true]:
  for phase in 0 .. 2:
    for incoming in [0'u32, 8]:
      setupDiagnostic(1, 1, incoming)
      logTrigger = phase
      onLog = proc() = raise newException(ValueError, "diagnostic callback stopped")
      var raised = false
      try:
        if useReset: discard rxl_reset()
        else: discard rxl_hwdesc_init(0)
      except ValueError:
        raised = true
      doAssert raised and enters == 1 and exits == 1 and irqLevel == incoming
      doAssert diagnostics.len == phase + 1 and triggers.len == phase
      doAssert lower.currentHd == nil and hardware.pdCurrent == nil
      doAssert listClears == 0 and upperInitializations == 0
''')
