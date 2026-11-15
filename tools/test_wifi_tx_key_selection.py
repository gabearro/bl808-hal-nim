"""Reject unusable TX keys without treating them as unprotected traffic."""

from pathlib import Path

import pytest

from test_wifi_aes_cmac import procedure
from test_wifi_message_allocation import run_program
from test_wifi_tx_counter_limit import SETUP
from test_wifi_tx_security import program_source


CASES = {
    "allocation_failure": r'''
for enabled in [false, true]:
  for invalid in 0..<5:
    setup(2, 41, enabled)
    case invalid
    of 0: key.installed = 0
    of 1: key.cipherType = 4
    of 2: key.cipherType = 5
    of 3: key.cipherType = 255
    else: key.staIdx = 4
    let before = key
    let beforeDesc = desc
    doAssert allocate() == high(uint32), "unusable key became an unprotected frame"
    doAssert tail == 0 and key == before and desc == beforeDesc
    doAssert interrupts == enabled
''',
    "append_failure": r'''
for invalid in 0..<5:
  setup(2, 41, true)
  case invalid
  of 0: key.installed = 0
  of 1: key.cipherType = 4
  of 2: key.cipherType = 5
  of 3: key.cipherType = 255
  else: key.staIdx = 4
  let before = frame
  let beforePolicy = primary
  let beforeLink = link
  doAssert txu_cntrl_sec_hdr_append(addr desc, addr frame[48], 1) == nil,
    "unusable key produced a security-header pointer"
  doAssert frame == before and primary == beforePolicy and link == beforeLink
''',
    "tight_wep_header": r'''
proc malloc(size: csize_t): pointer {.importc, header: "<stdlib.h>".}
proc free(p: pointer) {.importc, header: "<stdlib.h>".}
for cipher in [0'u8, 3'u8]:
  setup(cipher, 0x123456, true)
  doAssert allocate() == 4
  let bytes = cast[ptr array[4, uint8]](malloc(4))
  doAssert bytes != nil
  let finish = cast[pointer](cast[uint](bytes) + 4)
  doAssert txu_cntrl_sec_hdr_append(addr desc, finish, 1) == cast[pointer](bytes)
  doAssert bytes[] == [0x57'u8, 0x34, 0x12, 0x80]
  doAssert nimFwDbgDhcpTxSecHdr1 == 0
  free(bytes)
''',
    "control_port_bypass": r'''
setup(2, 41, true)
vifs[1].flags = 2
stations[3].rateWord = 0x0800
key.installed = 0
let before = key
let beforeFrame = frame
doAssert allocate() == 0 and tail == 0 and key == before
doAssert txu_cntrl_sec_hdr_append(addr desc, addr frame[48], 1) == cast[pointer](addr frame[48])
doAssert frame == beforeFrame
''',
    "invalid_descriptor": r'''
setup(2, 41, true)
let beforeFrame = frame
doAssert txu_cntrl_sechdr_len_compute(nil, addr tail) == high(uint32)
doAssert tail == 0
doAssert txu_cntrl_sec_hdr_append(nil, addr frame[48], 1) == nil
for invalid in 0..<2:
  setup(2, 41, true)
  if invalid == 0: desc.staInfoIdx = 7
  else: desc.vifIdx = 2
  doAssert allocate() == high(uint32) and tail == 0
  doAssert txu_cntrl_sec_hdr_append(addr desc, addr frame[48], 1) == nil
doAssert frame == beforeFrame
''',
    "cached_management_key_change": r'''
for removed in [false, true]:
  setup(2, 41, true)
  doAssert allocate() == 8
  desc.hdrLen = 8
  desc.secTailLen = 8
  if removed: keys.pairwiseKey = nil
  else: key.cipherType = 0
  txu_cntrl_protect_mgmt_frame(addr desc, addr frame[16], 24)
  doAssert desc.hdrLen == 0 and desc.secTailLen == 0
  doAssert macFrameControlAt(addr frame[16]).frameControl == 0xD0
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tx_key_selection(tmp_path: Path, case: str, mode: str) -> None:
    code = program_source()
    if mode == "release":
        for name in ["txSecKeyFor", "txu_cntrl_sechdr_len_compute", "txu_cntrl_sec_hdr_append"]:
            body = procedure(code, name)
            code = code.replace(body, "{.push checks:off.}\n" + body + "\n{.pop.}\n", 1)
    run_program(tmp_path, mode, code + SETUP + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("returned", ["nil", "dest"], ids=["failed", "missing-key"])
def test_failed_security_header_not_published(tmp_path: Path, mode: str, returned: str) -> None:
    from test_wifi_lower_preparation import CHECKS, build_program

    code = build_program().split(CHECKS, 1)[0]
    body = procedure(code, "txu_cntrl_sec_hdr_append")
    code = code.replace(body,
        f"proc txu_cntrl_sec_hdr_append(p, dest: pointer; enabled: uint32): pointer = {returned}\n", 1)
    checks = r'''
reset()
invalidated = false
publications = 0
frames = default(typeof(frames))
links = default(typeof(links))
hw = default(typeof(hw))
txEnv = default(TxEnv)
backup = default(typeof(backup))
frames[0] = HostTxDescView(vifIdx: 1, staInfoIdx: 0, staIdx: 0,
  hdrLen: 42, frameLen: 0x0008, seqPassthrough: 100, hwDesc: addr hw[0],
  queueFirst: cast[pointer](1), policy: addr templateBytes)
frames[0].bufferPtrs[0] = 0x20000000
frames[0].bufferLens[0] = 100
backup[3] = Queue(first: addr links[1], last: addr links[1])
txEnv.ac[3].pending = CoList(first: addr frames[1].link, last: addr frames[1].link)
txEnv.packetCounter = 1
discard txl_cntrl_push(addr frames[0], 3)
doAssert publications == 0, "failed header construction reached DMA publication"
doAssert backup[3].first == (addr links[1]) and backup[3].last == (addr links[1])
doAssert links[1].next == nil and frames[0].bufDesc == nil
doAssert droppedStatus == 0xC0020000'u32
doAssert txEnv.ac[3].pending.last == addr frames[1].link
doAssert interrupts
'''
    run_program(tmp_path, mode, code + checks)
