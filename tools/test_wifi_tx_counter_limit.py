"""Exercise TKIP/CCMP exhaustion and the two security-length consumers."""

from pathlib import Path

import pytest

from test_wifi_aes_cmac import procedure
from test_wifi_message_allocation import run_program
from test_wifi_tx_security import program_source
from test_wifi_tx_tid import source as tx_source


SETUP = r'''
const MaxPn = 0xFFFFFFFFFFFF'u64
var
  key: VifKeySlotView
  keys: KeyList
  desc: HostTxDescView
  primary: HostTxRateTemplateView
  link: HostTxLinkDescView
  frame: array[64, uint8]
  tail: uint32
proc setup(cipher: uint8; pn: uint64; enabled: bool) =
  txSecurityReset()
  rxKeyRevision = 1
  rxKeyLastChanged = default(typeof(rxKeyLastChanged))
  stations = default(typeof(stations))
  vifs = default(typeof(vifs))
  key = VifKeySlotView(cipherType: cipher, staIdx: 2, keyIdx: 11,
    installed: 1, pnLow: (pn and 0xFFFFFFFF'u64).uint32, pnHigh: (pn shr 32).uint32)
  keys.pairwiseKey = addr key
  stations[3].keyMat = addr keys
  desc = HostTxDescView(staInfoIdx: 3, vifIdx: 1, frameLen: 0x0008,
    pnScratch: [0x5A'u8, 0x5A, 0x5A, 0x5A, 0x5A, 0x5A],
    policy: addr primary, bufDesc: addr link)
  primary = default(typeof(primary))
  link = default(typeof(link))
  for b in frame.mitems: b = 0xA5
  macFrameControlAt(addr frame[16]).frameControl = 0x00D0
  interrupts = enabled
  irqSaves = 0
  irqRestores = 0
  onRestore = nil
  tail = 0xDEADBEEF'u32
proc counter(): uint64 = key.pnLow.uint64 or (key.pnHigh.uint64 shl 32)
proc scratch(d: var HostTxDescView): uint64 =
  for i in 0..<6: result = result or (d.pnScratch[i].uint64 shl (i * 8))
proc allocate(): uint32 = txu_cntrl_sechdr_len_compute(addr desc, addr tail)
'''

CASES = {
    "boundaries": r'''
for cipher in [1'u8, 2'u8]:
  for enabled in [false, true]:
    for pn in [0'u64, 0xFFFFFFFE'u64, 0xFFFFFFFF'u64, 0x100000000'u64,
               MaxPn - 1, MaxPn, MaxPn + 1, high(uint64)]:
      setup(cipher, pn, enabled)
      let beforeKey = key
      let beforeDesc = desc
      if pn < MaxPn:
        doAssert allocate() == 8
        doAssert counter() == pn + 1 and scratch(desc) == pn + 1
        doAssert tail == (if cipher == 1: 12'u32 else: 8'u32)
      else:
        doAssert allocate() == high(uint32), "exhausted TX counter was accepted"
        doAssert key == beforeKey and desc == beforeDesc and tail == 0
      doAssert irqSaves >= 1 and irqSaves == irqRestores and interrupts == enabled
''',
    "last_value_once": r'''
for cipher in [1'u8, 2'u8]:
  for enabled in [false, true]:
    setup(cipher, MaxPn - 1, enabled)
    doAssert allocate() == 8 and scratch(desc) == MaxPn
    let beforeKey = key
    let beforeDesc = desc
    for retry in 0..<3:
      tail = 0xFFFFFFFF'u32
      doAssert allocate() == high(uint32), "TX counter wrapped at exhaustion"
      doAssert key == beforeKey and desc == beforeDesc and tail == 0
    doAssert irqSaves >= 4 and irqSaves == irqRestores and interrupts == enabled
''',
    "pending_interrupt": r'''
for cipher in [1'u8, 2'u8]:
  setup(cipher, MaxPn - 2, true)
  var other = desc
  var otherTail: uint32
  var nestedResult: uint32
  var fired = false
  onRestore = proc() =
    fired = true
    doAssert counter() == MaxPn - 1 and scratch(desc) == MaxPn - 1
    nestedResult = txu_cntrl_sechdr_len_compute(addr other, addr otherTail)
  doAssert allocate() == 8
  doAssert fired and nestedResult == 8
  doAssert scratch(desc) == MaxPn - 1 and scratch(other) == MaxPn
  doAssert counter() == MaxPn and interrupts and irqSaves >= 2 and irqSaves == irqRestores
''',
    "management_failure": r'''
for enabled in [false, true]:
  for absent in [false, true]:
    setup(2, MaxPn, enabled)
    if absent: keys.pairwiseKey = nil
    let beforeFrame = frame
    let beforeKey = key
    txu_cntrl_protect_mgmt_frame(addr desc, addr frame[16], 24)
    doAssert frame == beforeFrame, "failed protection changed the MAC header"
    doAssert desc.hdrLen == 0 and desc.secTailLen == 0
    doAssert key == beforeKey and interrupts == enabled
  for invalid in [1'u8, 7, 9, 255]:
    setup(2, 41, enabled)
    desc.hdrLen = invalid
    desc.secTailLen = 8
    let beforeFrame = frame
    txu_cntrl_protect_mgmt_frame(addr desc, addr frame[16], 24)
    doAssert frame == beforeFrame and counter() == 41
    doAssert desc.hdrLen == 0 and desc.secTailLen == 0
''',
    "management_cached_last": r'''
for cipher in [1'u8, 2'u8]:
  for enabled in [false, true]:
    setup(cipher, MaxPn - 1, enabled)
    txu_cntrl_protect_mgmt_frame(addr desc, addr frame[16], 24)
    doAssert desc.hdrLen == 8 and desc.secTailLen == (if cipher == 1: 12 else: 8)
    doAssert counter() == MaxPn and scratch(desc) == MaxPn
    doAssert macFrameControlAt(addr frame[16]).frameControl == 0x40D0
    let beforeFrame = frame
    let beforeKey = key
    txu_cntrl_protect_mgmt_frame(addr desc, addr frame[16], 24)
    doAssert frame == beforeFrame and key == beforeKey
    doAssert interrupts == enabled
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tx_counter_limit(tmp_path: Path, case: str, mode: str) -> None:
    code = program_source()
    if mode == "release":
        for name in ["txSecBumpPn", "txu_cntrl_sechdr_len_compute", "txu_cntrl_protect_mgmt_frame"]:
            body = procedure(code, name)
            code = code.replace(body, "{.push checks:off.}\n" + body + "\n{.pop.}\n", 1)
    run_program(tmp_path, mode, code + SETUP + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tx_allocation_failure_not_narrowed(tmp_path: Path, mode: str) -> None:
    checks = r'''
for invalid in [1'u32, 2, 7, 9, 256, 264, high(uint32)]:
  for enabled in [false, true]:
    reset()
    interrupts = enabled
    securityHeaderLen = invalid
    securityTailLen = 8
    var desc = HostTxDescView(staInfoIdx: 0, staIdx: 0xFF, vifIdx: 0,
                             frameLen: 0x0008, hdrLen: 0x66, secTailLen: 0x55)
    calls.setLen(0)
    pushedDesc = nil
    doAssert not txu_cntrl_push(addr desc, 2), "invalid length reached the TX queue"
    doAssert pushedDesc == nil and interrupts == enabled
    doAssert desc.hdrLen == 0x66 and desc.secTailLen == 0x55
    doAssert calls == @["irq-save", "security", "drop-count", "confirm", "irq-restore"]
    doAssert droppedStatus == 0xC0020000'u32
'''
    run_program(tmp_path, mode, tx_source(mode == "release") + checks)
