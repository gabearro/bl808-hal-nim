"""Verify association-response completion message ownership and callback ABI."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure

ROOT = Path(__file__).resolve().parents[1]

PLATFORM = r"""
type
  ApmAssocStaAddIndPayload = object
    prefix: array[68, uint8]
    aid: uint16
  Completion = proc(param: pointer; status: uint32) {.cdecl.}
var
  storage: array[96, uint8]
  events: seq[string]
  loggerPresent = true
  logStatus, logAid: uint32
  logText: string
  pendingSlot: int
  message: ptr ApmAssocStaAddIndPayload
  apmPendingAssociations: array[1, tuple[meQueued: bool]]
proc apmPendingRequestSlot(p: pointer; queued: bool): int = pendingSlot
proc keMsgHdrFromPayload(p: pointer): pointer = cast[pointer](cast[uint](p) - 12)
proc ke_msg_send(p: pointer) =
  doAssert p == cast[pointer](message)
  events.add("send")
proc ke_msg_free(p: pointer) =
  doAssert p == cast[pointer](addr storage[0]), "freed the payload instead of its message header"
  events.add("free")
proc aidListDelete(p: pointer) =
  doAssert p == cast[pointer](message)
  events.add("delete")
  message.aid = 19 # a reentrant disconnect hook may change message state
{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc logger(format: cstring) {.cdecl, varargs.} =
  doAssert $format == "apm mlme assoc rsp send failed:%d,aid:%d\n"
  var status, aid, length: cint
  var output: array[128, char]
  {.emit: ["va_list args, display; va_start(args, ", format, "); ",
           "va_copy(display, args); ", status, " = va_arg(args, int); ",
           aid, " = va_arg(args, int); ", length,
           " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
           format, ", display); va_end(display); va_end(args);"].}
  doAssert length > 0 and length < output.len.cint
  logStatus = cast[uint32](status)
  logAid = aid.uint32
  logText = $cast[cstring](addr output[0])
  events.add("log")
proc blOpsFunc(offset: int): pointer =
  doAssert offset == 4
  if loggerPresent: cast[pointer](logger) else: nil
"""

CHECKS = r"""
let completion: Completion = apm_tx_cfm_handler
for status in [0'u32, 0x10000, 0x40000000, 0x80000000'u32, 0xFF000000'u32,
               0x800000, 0x800001, 0x810000, 0xFFFFFFFF'u32]:
  for aid in [0'u16, 1, 5, 65535]:
    for hasLogger in [false, true]:
      storage = default(typeof(storage))
      message = cast[ptr ApmAssocStaAddIndPayload](addr storage[12])
      message.aid = aid
      loggerPresent = hasLogger
      pendingSlot = 0
      apmPendingAssociations[0].meQueued = false
      events.setLen(0)
      completion(message, status)
      if (status and 0x800000) != 0:
        doAssert events == (if aid != 0: @["send"] else: @["free"])
        doAssert apmPendingAssociations[0].meQueued == (aid != 0)
      else:
        var expected: seq[string]
        if aid != 0: expected.add("delete")
        if hasLogger: expected.add("log")
        expected.add("free")
        doAssert events == expected
        if hasLogger:
          doAssert logStatus == status
          doAssert logAid == (if aid != 0: 19'u32 else: 0'u32)
          doAssert logText == "apm mlme assoc rsp send failed:" &
            $cast[int32](status) & ",aid:" & $logAid & "\n"
for status in [0'u32, 0x800000]:
  storage = default(typeof(storage))
  message = cast[ptr ApmAssocStaAddIndPayload](addr storage[12])
  message.aid = 1
  pendingSlot = -1
  events.setLen(0)
  completion(message, status)
  doAssert events == @["free"]
events.setLen(0)
completion(nil, 0)
doAssert events.len == 0
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_apm_confirmation_ownership(mode: str, tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    source = (ROOT / "src/bl808/wifi/fw/scan_station_ap_me.nim").read_text()
    path = tmp_path / "apm_confirmation.nim"
    path.write_text(PLATFORM + procedure(source, "apm_tx_cfm_handler") + CHECKS)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
               "--skipUserCfg:on", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}"]
    command += ["--checks:on"]
    if mode == "release":
        command += ["-d:release", "--assertions:on"]
    elif mode == "asan":
        command += ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]
    result = subprocess.run(command + [str(path)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
