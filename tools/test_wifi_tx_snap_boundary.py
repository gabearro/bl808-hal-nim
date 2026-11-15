"""Keep TX header reservation consistent with its SNAP encoding boundary."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_tx_sequence import CHECKS, program_source


def source(unchecked: bool) -> str:
    code = program_source()
    if unchecked:
        for name in ["txu_cntrl_push", "txuBuildFrame", "txu_cntrl_frame_build"]:
            body = procedure(code, name)
            code = code.replace(body, "{.push checks:off.}\n" + body + "\n{.pop.}\n", 1)
    checks = CHECKS.split("\nreset()\n", 1)[0]
    assert "let snapLength = if etherType >= 1536: 8 else: 0" in checks
    return code + checks


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("unchecked", [False, True], ids=["bounds", "unchecked"])
def test_tx_snap_boundary(tmp_path: Path, mode: str, unchecked: bool) -> None:
    checks = r'''
for etherType in [0'u16, 1500, 1535, 1536, 1537, 0x0800, 0xFFFF]:
  for tid in [0'u8, 7, 8, 0xFF]:
    for vifIndex in [0'u8, 1]:
      for securityLength in [0'u32, 4, 8]:
        for enabled in [false, true]:
          reset()
          interrupts = enabled
          securityHeaderLen = securityLength
          securityTailLen = securityLength
          pushResult = 1
          checkTx(0, tid, vifIndex, etherType)
          doAssert interrupts == enabled
'''
    run_program(tmp_path, mode, source(unchecked) + checks)
