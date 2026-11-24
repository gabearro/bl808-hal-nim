"""Keep a reserved TX packet number tied to its hardware key slot."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_tx_counter_limit import SETUP
from test_wifi_tx_security import program_source


CHECKS = r'''
for updateCurrent in [0'u32, 1'u32]:
  setup(2, 41, true)
  doAssert allocate() == 8
  let reservedCounter = counter()
  let beforeFrame = frame
  let beforePrimary = primary
  let beforeLink = link
  key.keyIdx = 13
  doAssert not txSecurityCurrent(addr desc),
    "reserved PN followed a different hardware key slot"
  doAssert txSecurityLengthsCurrent(addr desc) == (-1, -1)
  doAssert txu_cntrl_sec_hdr_append(addr desc, addr frame[48], updateCurrent) == nil
  doAssert frame == beforeFrame and primary == beforePrimary and link == beforeLink
  doAssert counter() == reservedCounter

  txSecurityForget(addr desc)
  doAssert allocate() == 8
  doAssert txu_cntrl_sec_hdr_append(addr desc, addr frame[48], updateCurrent) ==
    cast[pointer](addr frame[40])
  if updateCurrent == 0:
    doAssert link.rateTemplate.pendingCount == 13
  else:
    doAssert primary.pendingCount == 13
'''


@pytest.mark.parametrize("mode", ["checked", "release"])
def test_hardware_key_index_binding(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, program_source() + SETUP + CHECKS)
