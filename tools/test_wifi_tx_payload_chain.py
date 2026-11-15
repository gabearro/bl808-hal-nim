"""Validate TX payload ranges before linking them into hardware descriptors."""

from pathlib import Path
import re

import pytest

from test_wifi_aes_cmac import procedure
from test_wifi_disconnect_tx import FW
from test_wifi_message_allocation import run_program
from test_wifi_tx_backup import PLATFORM


def source() -> str:
    tx = (FW / "tx_layer.nim").read_text()
    body = procedure(tx, "txlBuildBufferThd") + procedure(tx, "txl_buffer_update_thd")
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", body)))
    )
    return PLATFORM + debug + body + r'''
proc setup() =
  links = default(typeof(links))
  descs = default(typeof(descs))
  hw = default(typeof(hw))
  descs[0] = HostTxDescView(bufDesc: addr links[0], hwDesc: addr hw[0],
    hdrLen: 34, seqPassthrough: 16)
  descs[0].bufferPtrs[0] = 0x20000000
  descs[0].bufferLens[0] = 16
  links[0].headerLen = 34
  hw[0].status = 0x12345678
  hw[0].controlFlags = 0xA5A5
'''


CASES = {
    "invalid": r'''
for failure in 0..11:
  setup()
  case failure
  of 0: descs[0].bufferLens[0] = 0
  of 1:
    descs[0].bufferPtrs[0] = high(uint32)
    descs[0].bufferLens[0] = 2
    descs[0].seqPassthrough = 2
  of 2: descs[0].bufferLens[0] = 15
  of 3: descs[0].bufferLens[0] = 17
  of 4:
    descs[0].bufferPtrs[0] = 0
    descs[0].bufferLens[0] = 0
  of 5:
    descs[0].bufferPtrs[1] = 0
    descs[0].bufferLens[1] = 1
  of 6:
    descs[0].bufferPtrs[2] = 0x21000000
    descs[0].bufferLens[2] = 1
  of 7: descs[0].seqPassthrough = 0
  of 8: links[0].headerLen = 0
  of 9: links[0].headerLen = high(uint32)
  of 10:
    descs[0].bufferPtrs[1] = 0x21000000
    descs[0].bufferLens[1] = 0
  else:
    descs[0].bufferPtrs[0] = 1
    descs[0].bufferLens[0] = high(uint32)
    descs[0].seqPassthrough = high(uint16)
  let before = links[0]
  doAssert not txlBuildBufferThd(addr descs[0]), "invalid chain accepted: " & $failure
  doAssert links[0] == before, "failed build changed descriptor chain"
  doAssert hw[0].status == 0 and hw[0].controlFlags == 0

setup()
descs[0].bufferLens[0] = 0
let before = links[0]
txl_buffer_update_thd(addr descs[0])
doAssert links[0] == before and hw[0].status == 0 and hw[0].controlFlags == 0
''',
    "valid": r'''
for count in 1..4:
  setup()
  var total = 0'u32
  for i in 0..<count:
    descs[0].bufferPtrs[i] = 0x20000000'u32 + i.uint32 * 0x10000
    descs[0].bufferLens[i] = 3 + i.uint32
    total += 3 + i.uint32
  descs[0].seqPassthrough = total.uint16
  doAssert txlBuildBufferThd(addr descs[0])
  doAssert links[0].headerThd.next == cast[pointer](addr links[0].payloadThd[0])
  doAssert hw[0].status == pointerAddrU32(addr links[0].headerThd) and hw[0].controlFlags == 256
  for i in 0..<count:
    let thd = links[0].payloadThd[i]
    doAssert thd.payloadStart == descs[0].bufferPtrs[i]
    doAssert thd.payloadEnd == descs[0].bufferPtrs[i] + descs[0].bufferLens[i] - 1
    doAssert thd.next == (if i + 1 < count: cast[pointer](addr links[0].payloadThd[i + 1]) else: nil)

setup()
descs[0].bufferPtrs[0] = high(uint32)
descs[0].bufferLens[0] = 1
descs[0].seqPassthrough = 1
doAssert txlBuildBufferThd(addr descs[0])
doAssert links[0].payloadThd[0].payloadEnd == high(uint32)

setup()
descs[0].bufferLens[0] = high(uint16).uint32
descs[0].seqPassthrough = high(uint16)
txl_buffer_update_thd(addr descs[0])
doAssert hw[0].status != 0 and links[0].payloadThd[0].payloadEnd == 0x2000FFFE'u32
''',
    "null": r'''
setup()
doAssert not txlBuildBufferThd(nil)
descs[0].bufDesc = nil
doAssert not txlBuildBufferThd(addr descs[0])
descs[0].bufDesc = addr links[0]
descs[0].hwDesc = nil
doAssert not txlBuildBufferThd(addr descs[0])
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tx_payload_chain(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_bad_chain_stops_submission(tmp_path: Path, mode: str) -> None:
    from test_wifi_lower_preparation import CHECKS, build_program

    code = build_program().split(CHECKS, 1)[0]
    checks = r'''
for failure in 0..4:
  reset()
  invalidated = false
  publications = 0
  frames = default(typeof(frames))
  links = default(typeof(links))
  hw = default(typeof(hw))
  txEnv = default(TxEnv)
  backup = default(typeof(backup))
  frames[0] = HostTxDescView(vifIdx: 1, staInfoIdx: 0, staIdx: 0,
    hdrLen: 34, frameLen: 0x8E88, seqPassthrough: 16,
    hwDesc: addr hw[0], queueFirst: cast[pointer](1), policy: addr templateBytes)
  frames[0].bufferPtrs[0] = 0x20000000
  frames[0].bufferLens[0] = 16
  case failure
  of 0: frames[0].bufferLens[0] = 0
  of 1: frames[0].bufferPtrs[0] = high(uint32)
  of 2: frames[0].bufferLens[0] = 15
  of 3: frames[0].bufferPtrs[0] = 0
  else:
    frames[0].bufferPtrs[2] = 0x21000000
    frames[0].bufferLens[2] = 1
  backup[3] = Queue(first: addr links[1], last: addr links[1])
  txEnv.ac[3].pending = CoList(first: addr frames[1].link, last: addr frames[1].link)
  txEnv.packetCounter = 1
  discard txl_cntrl_push(addr frames[0], 3)
  doAssert publications == 0, "invalid payload chain reached DMA publication"
  doAssert backup[3].first == (addr links[1]) and links[1].next == nil
  doAssert txEnv.ac[3].pending.last == addr frames[1].link
  doAssert frames[0].bufDesc == nil and interrupts
'''
    run_program(tmp_path, mode, code + checks)
