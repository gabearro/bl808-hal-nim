"""Check TX event logging ABI and its immediate dispatch integration."""

from pathlib import Path
import re

import pytest

import test_wifi_host_publication as host
from test_wifi_message_allocation import run_program


LOGGER = r'''
var
  loggerEnabled = true
  logLookups: int
  logMessages: seq[string]
  logAction: proc()
{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc logger(level: uint32; tag, file: cstring; line: cint; format: cstring)
    {.cdecl, varargs.} =
  doAssert level == 2 and tag == nil
  doAssert file != nil and format != nil, "missing TX log file or format"
  doAssert file == cstring("ipc_emb.c") and line == 290
  doAssert format == cstring("queue_idx is %d\r\n")
  doAssert ipcTxDispatchActive and queueReads == 0 and submitted.len == 0
  var output: array[64, char]
  var size: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", size,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert size >= 0 and size < output.len.cint
  logMessages.add($cast[cstring](addr output[0]))
  if logAction != nil: logAction()
proc getLogFunc(offset: int): pointer =
  doAssert offset == 204
  inc logLookups
  if loggerEnabled: cast[pointer](logger) else: nil
'''


def source() -> str:
    platform = host.PLATFORM.replace(
        "proc getLogFunc(offset: int): pointer = nil\n", LOGGER
    )
    assert platform != host.PLATFORM
    ipc = (host.FW / "ipc_embedded.nim").read_text()
    body = host.procedure(ipc, "ipc_emb_tx_evt")
    body += host.procedure(ipc, "ipc_emb_txcfm")
    body += host.procedure((host.FW / "tx_layer.nim").read_text(), "txl_cntrl_push")
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n"
        for name in sorted(set(re.findall(r"\bnimFwDbg\w+", body)))
    )
    reset = host.CHECKS.split("\nfor ac in ", 1)[0]
    return platform + debug + body + reset + r'''
proc setup(count: int; irq: bool) =
  reset(count, true)
  interrupts = irq
  nestedStage = ""
  immediate = false
  recycle = false
  loggerEnabled = true
  logLookups = 0
  logMessages.setLen(0)
  logAction = nil
  keEvtField = 0x40
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tx_event_logging_and_dispatch(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for irq in [false, true]:
  for ac in 0'u32 .. 4:
    for enabled in [false, true]:
      for count in [0, 1]:
        setup(count, irq)
        loggerEnabled = enabled
        keEvtField = keEvtField or (0x200'u32 shl ac)
        ipc_emb_tx_evt(ac)
        doAssert interrupts == irq and not ipcTxDispatchActive
        doAssert logLookups == (ac != 0).int
        if enabled and ac != 0:
          doAssert logMessages == @["queue_idx is " & $ac & "\r\n"]
        else:
          doAssert logMessages.len == 0
        doAssert hostList.first == nil and keEvtField == 0x40
        doAssert submitted.len == count and allocated.len == count
        doAssert txEnv.packetCounter == count.uint32
        doAssert writes.len == count + 1
        doAssert writes[^1] == (0x2480010C'u, 256'u32)
        if count == 1:
          doAssert submitted == @[0] and wrappers[0].active == 1
          doAssert txEnv.ac[0].pending.first == addr wrappers[0].txDesc.link
          doAssert writes[0] == (0x24800108'u, 256'u32)
  for ac in [5'u32, high(uint32)]:
    setup(1, irq)
    ipc_emb_tx_evt(ac)
    doAssert interrupts == irq and not ipcTxDispatchActive
    doAssert logLookups == 0 and logMessages.len == 0
    doAssert queueReads == 0 and submitted.len == 0 and writes.len == 0
    doAssert hostList.first == (addr wrappers[0].link) and keEvtField == 0x40
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tx_event_logger_reentry(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for irq in [false, true]:
  setup(1, irq)
  immediate = true
  recycle = true
  keEvtField = keEvtField or 0x2000'u32
  logAction = proc() =
    doAssert interrupts == irq
    ipc_emb_tx_evt(0)
    doAssert interrupts == irq and ipcTxDispatchActive
    doAssert queueReads == 0 and submitted.len == 0
    doAssert wrappers[0].active == 0
  ipc_emb_tx_evt(4)
  doAssert interrupts == irq and not ipcTxDispatchActive
  doAssert logLookups == 1 and logMessages == @["queue_idx is 4\r\n"]
  doAssert submitted == @[0] and completed == @[0]
  doAssert txEnv.packetCounter == 0 and txEnv.ac[0].pending.first == nil
  doAssert hostList.first == nil and confirmList.first == nil
  doAssert wrappers[0].active == 0xAABBCCDD'u32
  doAssert keEvtField == 0x240'u32
''')
