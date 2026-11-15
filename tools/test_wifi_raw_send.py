"""Execute the production raw-TX request and completion paths on the host."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]

PLATFORM = r'''
{.emit: """
#include <stdarg.h>
#include <stdint.h>
#include <string.h>
static unsigned raw_log_status, raw_log_count, raw_bad_log;
static void raw_log(const char *fmt, ...) {
    if (!fmt) { ++raw_bad_log; return; }
    va_list ap;
    va_start(ap, fmt);
    if (strcmp(fmt, "send complete, status is %08lX\r\n") == 0) {
        raw_log_status = (unsigned)va_arg(ap, unsigned long);
        ++raw_log_count;
    }
    va_end(ap);
}
""".}
proc rawLog(fmt: cstring) {.importc: "raw_log", nodecl, cdecl, varargs.}
var
  logStatus {.importc: "raw_log_status", nodecl.}: cuint
  logCount {.importc: "raw_log_count", nodecl.}: cuint
  badLog {.importc: "raw_bad_log", nodecl.}: cuint
type
  Header = object
    srcId: uint8
  Request = object
    header: Header
    payload: ScanuRawSendReqPayload
  Link = object
    before: uint64
    macHeader: array[512, uint8]
    after: uint64
  Hw = object
    frameLen, payloadStart, payloadEnd: uint32
var
  descs: array[4, TxlFrameDescView]
  links: array[4, Link]
  hardware: array[4, Hw]
  owned: array[4, bool]
  ackCount, allocationCount, pushCount, clockCalls: int
  allocatorFails, loggerAbsent: bool
  expectedSource: uint8

proc clockTrap(p: pointer) {.cdecl.} = inc clockCalls
proc blOpsFunc(offset: int): pointer =
  if offset == 4:
    if not loggerAbsent: return cast[pointer](rawLog)
  elif offset == 200:
    return cast[pointer](clockTrap)
  else:
    doAssert false, "unexpected platform operation"
proc keMsgHdrFromPayload(p: pointer): ptr Header =
  cast[ptr Header](cast[uint](p) - offsetof(Request, payload).uint)
proc scanu_raw_send_cfm(p: pointer; source: uint8) =
  doAssert p == nil and source == expectedSource
  inc ackCount
proc hostTxLinkDescAt(p: pointer): ptr Link = cast[ptr Link](p)
proc hostTxHwDescAt(p: pointer): ptr Hw = cast[ptr Hw](p)
proc c_memcpy(dst, src: pointer; length: csize_t): pointer =
  copyMem(dst, src, length.int)
  dst
proc txl_frame_get(length: uint32): pointer =
  doAssert length == 512 and ackCount == 1
  inc allocationCount
  if allocatorFails: return nil
  for index in 0 ..< 4:
    if not owned[index]:
      owned[index] = true
      descs[index].callback = nil
      descs[index].callbackArg = nil
      return addr descs[index]
proc txl_frame_push_force(p: pointer; ac: uint8) =
  doAssert ac == 3 and ackCount == 1
  inc pushCount
proc reset() =
  descs = default(typeof(descs))
  hardware = default(typeof(hardware))
  owned = default(typeof(owned))
  ackCount = 0
  allocationCount = 0
  pushCount = 0
  clockCalls = 0
  logCount = 0
  badLog = 0
  allocatorFails = false
  loggerAbsent = false
  for index in 0 ..< 4:
    links[index].before = 0x1122334455667788'u64
    links[index].after = 0x8877665544332211'u64
    for b in links[index].macHeader.mitems: b = 0xA5
    descs[index].linkDesc = addr links[index]
    descs[index].thd = addr hardware[index]
    descs[index].vifIdx = 9
    descs[index].staInfoIdx = 9
    descs[index].retryCount = 9
    descs[index].statusByte = 9
    hardware[index].payloadStart = 0x22001000'u32 + index.uint32 * 512
'''

CALLBACK_CHECKS = r'''
type Completion = proc(arg: pointer; status: uint32) {.cdecl.}
let completion = cast[Completion](cfm_raw_send)
for status in [0'u32, 1, 0x00800000, 0x81000000'u32, 0xFFFFFFFF'u32]:
  reset()
  # The callback must not dereference its opaque argument.
  completion(cast[pointer](1), status)
  doAssert clockCalls == 0
  doAssert logCount == 1 and logStatus == status and badLog == 0
  loggerAbsent = true
  completion(nil, status)
  doAssert clockCalls == 0 and logCount == 1
'''

REQUEST_CHECKS = r'''
var bytes: array[512, uint8]
for index in 0 ..< bytes.len: bytes[index] = (index and 255).uint8
var request = Request(header: Header(srcId: 73))
expectedSource = request.header.srcId

for invalidLength in [0'u32, 512, 513, 0xFFFFFFFF'u32]:
  reset()
  request.payload = ScanuRawSendReqPayload(framePtr: addr bytes[0], frameLen: invalidLength)
  for attempt in 0 ..< 8:
    ackCount = 0
    doAssert scanu_raw_send_req_handler(addr request.payload) == 0
    doAssert ackCount == 1 and allocationCount == 0 and pushCount == 0
    doAssert not owned[0] and not owned[1] and not owned[2] and not owned[3]

reset()
request.payload = ScanuRawSendReqPayload(framePtr: nil, frameLen: 24)
doAssert scanu_raw_send_req_handler(addr request.payload) == 0
doAssert ackCount == 1 and allocationCount == 0 and pushCount == 0
reset()
doAssert scanu_raw_send_req_handler(nil) == 0
doAssert ackCount == 0 and allocationCount == 0

for length in 1'u32 .. 511'u32:
  reset()
  request.payload = ScanuRawSendReqPayload(framePtr: addr bytes[0], frameLen: length)
  doAssert scanu_raw_send_req_handler(addr request.payload) == 0
  doAssert ackCount == 1 and allocationCount == 1 and pushCount == 1
  doAssert badLog == 0
  doAssert owned[0] and not owned[1]
  let desc = addr descs[0]
  doAssert desc.vifIdx == 0 and desc.staInfoIdx == 255
  doAssert desc.retryCount == 0 and desc.statusByte == 0
  doAssert desc.callback == cast[pointer](cfm_raw_send)
  doAssert desc.callbackArg == cast[pointer](desc)
  doAssert hardware[0].frameLen == length + 4
  doAssert hardware[0].payloadEnd == hardware[0].payloadStart + length - 1
  doAssert links[0].before == 0x1122334455667788'u64
  doAssert links[0].after == 0x8877665544332211'u64
  for index in 0 ..< 512:
    doAssert links[0].macHeader[index] == (if index.uint32 < length: bytes[index] else: 0xA5'u8)
  type Completion = proc(arg: pointer; status: uint32) {.cdecl.}
  cast[Completion](desc.callback)(desc.callbackArg, 0x81800000'u32)
  doAssert logCount == 1 and logStatus == 0x81800000'u32 and clockCalls == 0
  # Ownership remains with the enclosing frame event, not this callback.
  doAssert owned[0]

reset()
allocatorFails = true
request.payload = ScanuRawSendReqPayload(framePtr: addr bytes[0], frameLen: 24)
scanu_raw_send_req_handler(addr request.payload)
doAssert ackCount == 1 and allocationCount == 1 and pushCount == 0
'''


@pytest.mark.parametrize("mode", ["callback", "requests"])
@pytest.mark.parametrize("build", ["checked", "release", "asan"])
def test_raw_send(tmp_path: Path, mode: str, build: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    base = ROOT / "src/bl808/wifi/fw"
    handlers = (base / "task_handlers.nim").read_text()
    layout = (base / "layout_types.nim").read_text()
    types = "type\n"
    for name in ["ScanuRawSendReqPayload", "TxlFrameDescView"]:
        types += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    procedures = ""
    for name in ["cfm_raw_send", "scanu_raw_send_req_handler"]:
        match = re.search(r"(?ms)^proc " + name + r"\*.*?(?=^proc |\Z)", handlers)
        assert match
        procedures += match.group(0)
    program = tmp_path / "raw_send.nim"
    program.write_text(types + PLATFORM + procedures + (
        CALLBACK_CHECKS if mode == "callback" else REQUEST_CHECKS
    ))
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
               f"--nimcache:{tmp_path / 'nimcache'}", f"-o:{tmp_path / 'test'}"]
    if build == "release":
        command += ["-d:release", "--assertions:on"]
    elif build == "asan":
        command += ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]
    result = subprocess.run(command + [str(program)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
