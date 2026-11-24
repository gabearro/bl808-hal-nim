"""TX key/cipher branches from the pinned libwifi_fw.a txu_cntrl.o.

The reference selects sta[244]->pairwise at 0x0800014c-0x08000156,
skips the control-port EtherType at 0x08000168-0x0800018a, and maps
cipher 0/3, 1, 2 at 0x08000192-0x08000216. Frame construction uses the
same key/gate test before setting FC Protected at 0x0800038a-0x080003c8.
"""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_tx_counter_limit import SETUP
from test_wifi_tx_security import program_source


SELECTION_CHECKS = r'''
for cipher in 0'u8 .. 3'u8:
  let expected =
    case cipher
    of 0'u8, 3'u8: (4, 4)
    of 1'u8: (8, 12)
    else: (8, 8)
  for gate in 0 .. 2:
    setup(cipher, 41, true)
    desc.frameLen = 0x8E88'u16  # EAPOL in the descriptor's wire byte order.
    if gate != 0:
      vifs[1].flags = 2
      stations[3].rateWord = (if gate == 1: 0x888E'u16 else: 0x0800'u16)
    let bypass = gate == 1
    doAssert (txSecuritySelectedKey(addr desc, false) == nil) == bypass
    let before = counter()
    doAssert allocate() == (if bypass: 0'u32 else: expected[0].uint32)
    doAssert tail == (if bypass: 0'u32 else: expected[1].uint32)
    doAssert counter() == before + (if bypass: 0'u64 else: 1'u64)
    doAssert txSecurityLengthsCurrent(addr desc) ==
      (if bypass: (0, 0) else: expected)

  setup(cipher, 41, true)
  keys.pairwiseKey = nil
  doAssert txSecuritySelectedKey(addr desc, false) == nil
  doAssert allocate() == 0 and tail == 0 and counter() == 41
  doAssert txSecurityLengthsCurrent(addr desc) == (0, 0)
'''


PROTECTION_CHECKS = r'''
for cipher in 0'u8 .. 3'u8:
  setup(cipher, 41, true)
  desc.frameLen = 0
  txu_cntrl_protect_mgmt_frame(addr desc, addr frame[16], 24)
  doAssert macFrameControlAt(addr frame[16]).frameControl == 0x40D0'u16
  doAssert desc.hdrLen == (if cipher in [0'u8, 3'u8]: 4'u8 else: 8'u8)
  doAssert desc.secTailLen ==
    (case cipher
     of 0'u8, 3'u8: 4'u8
     of 1'u8: 12'u8
     else: 8'u8)
  doAssert counter() == 42
'''


@pytest.mark.parametrize("mode", ["checked", "release"])
def test_vendor_key_selection_and_cipher_lengths(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, program_source() + SETUP + SELECTION_CHECKS)


@pytest.mark.parametrize("mode", ["checked", "release"])
def test_protected_management_frame_setup(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, program_source() + SETUP + PROTECTION_CHECKS)
