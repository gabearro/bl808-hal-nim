"""Exercise real kernel allocation with returning assertions and heap failures."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_ap_teardown import procedure

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r'''
type
  KeMsgHdr {.packed.} = object
    next: pointer
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
const
  KeMsgHdrSize = sizeof(KeMsgHdr).uint
  KeMsgTailSlack = 4'u32
var
  allocated: seq[pointer]
  allocationCalls, assertions: int
  lastSize: uint32
  failAllocation, missingAllocator: bool
proc malloc(size: csize_t): pointer {.importc, header: "<stdlib.h>".}
proc free(p: pointer) {.importc, header: "<stdlib.h>".}
proc heapAlloc(size: uint32): pointer {.cdecl.} =
  inc allocationCalls
  lastSize = size
  if failAllocation: return nil
  doAssert size < 16384
  result = malloc(size.csize_t)
  doAssert result != nil
  allocated.add(result)
  let bytes = cast[ptr UncheckedArray[uint8]](result)
  for i in 0 ..< size.int: bytes[i] = 0xA5
proc blOpsFunc(offset: int): pointer =
  doAssert offset == 0xB8
  if missingAllocator: nil else: cast[pointer](heapAlloc)
proc keMsgPayload(header: ptr KeMsgHdr): pointer =
  cast[pointer](cast[uint](header) + KeMsgHdrSize)
proc keMsgHdrFromPayload(payload: pointer): ptr KeMsgHdr =
  cast[ptr KeMsgHdr](cast[uint](payload) - KeMsgHdrSize)
proc c_memset(p: pointer; value: cint; size: csize_t): pointer =
  doAssert value == 0 and p != nil
  zeroMem(p, size.int)
  p
proc assert_err(condition, file: cstring; line: cint) =
  inc assertions # The real Nim assertion schedules reset and returns.
proc reset() =
  for p in allocated: free(p)
  allocated.setLen(0)
  allocationCalls = 0
  assertions = 0
  lastSize = 0
  failAllocation = false
  missingAllocator = false
'''

TIM_METADATA_STUBS = r'''
# Non-TIM fixtures exercise their own allocation/lifetime contracts.
proc mmTimAllocationSize(id: uint16; destination: uint8; length: uint32): uint32 = length
proc mmTimRegisterAllocation(header: ptr KeMsgHdr) = discard
proc mmTimCaptureMessage(header: ptr KeMsgHdr) = discard
proc mmTimForget(header: pointer) = discard
proc chanSwitchForget(header: pointer): bool = false
proc smRspTimerForget(header: pointer) = discard
proc smDisconnectStorageLength(id: uint16; destination: uint8; length: uint32): uint32 = length
proc smDisconnectRegister(header: ptr KeMsgHdr) = discard
proc smDisconnectForget(header: pointer) = discard
proc mmEdcaForget(header: pointer) = discard
proc mmConfigForgetIdleOwner(header: pointer): bool = false
proc mmConfigResumeAbandonedIdle() = discard
proc smDisconnectStamp(header: ptr KeMsgHdr) = discard
proc chanUpdateStorageLength(id: uint16; destination: uint8; length: uint32): uint32 = length
proc chanUpdateRegister(header: ptr KeMsgHdr) = discard
proc chanUpdateCaptureMessage(header: ptr KeMsgHdr) = discard
proc chanUpdateForget(header: pointer) = discard
proc chanBcnRequestForget(header: pointer) = discard
proc chanUpdateAdmit(request: pointer): bool = true
'''
PLATFORM += TIM_METADATA_STUBS

CHECKS = r'''
for size in [0'u32, 1, 2, 3, 4, 15, 16, 255, 860]:
  for fatal in [false, true]:
    reset()
    let p = if fatal: ke_msg_alloc(0x1234, 5, 3, size)
            else: ke_msg_try_alloc(0x1234, 5, 3, size)
    doAssert p != nil and allocationCalls == 1 and assertions == 0
    doAssert lastSize == size + KeMsgHdrSize.uint32 + KeMsgTailSlack
    let header = keMsgHdrFromPayload(p)
    doAssert header.id == 0x1234 and header.srcId == 3 and header.destId == 5
    doAssert header.paramLen == size and header.next == nil
    let bytes = cast[ptr UncheckedArray[uint8]](p)
    for i in 0 ..< size.int: doAssert bytes[i] == 0
    for i in size.int ..< size.int + 4: doAssert bytes[i] == 0xA5

for missing in [false, true]:
  for fatal in [false, true]:
    reset()
    missingAllocator = missing
    failAllocation = true
    let p = if fatal: ke_msg_alloc(1, 2, 3, 10)
            else: ke_msg_try_alloc(1, 2, 3, 10)
    doAssert p == nil and allocated.len == 0
    doAssert allocationCalls == (not missing).int
    doAssert assertions == fatal.int

let overhead = KeMsgHdrSize.uint32 + KeMsgTailSlack
for fatal in [false, true]:
  for size in [high(uint32) - overhead + 1, high(uint32)]:
    reset()
    let p = if fatal: ke_msg_alloc(1, 2, 3, size)
            else: ke_msg_try_alloc(1, 2, 3, size)
    doAssert p == nil and allocationCalls == 0 and assertions == fatal.int
  reset()
  failAllocation = true
  let p = if fatal: ke_msg_alloc(1, 2, 3, high(uint32) - overhead)
          else: ke_msg_try_alloc(1, 2, 3, high(uint32) - overhead)
  doAssert p == nil and allocationCalls == 1 and lastSize == high(uint32)
  doAssert assertions == fatal.int
reset()
'''


def run_program(tmp_path: Path, mode: str, code: str, *, defines: tuple[str, ...] = ()) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    path = tmp_path / "allocation.nim"
    path.write_text(code)
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "goto": ["--mm:arc", "--exceptions:goto"],
             "firmware": ["--mm:arc", "--exceptions:goto", "-d:release",
                          "--panics:on", "--checks:off", "--assertions:on",
                          "--threads:off", "--stackTrace:off", "--lineTrace:off",
                          "--opt:size"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}",
        *flags[mode], *(f"-d:{define}" for define in defines), str(path)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, timeout=90)
    assert result.returncode == 0, result.stdout


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_kernel_allocation_failures(tmp_path: Path, mode: str) -> None:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    code = PLATFORM + procedure(kernel, "ke_msg_try_alloc") + procedure(kernel, "ke_msg_alloc")
    run_program(tmp_path, mode, code + CHECKS)
