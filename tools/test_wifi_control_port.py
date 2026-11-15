"""Run the real activation transaction before accepting a supplicant result."""

from pathlib import Path

import pytest

from test_wifi_activation_exchange import source
from test_wifi_message_allocation import run_program


CHECKS = r'''
for vifIndex in 0'u8 .. 1'u8:
  for staIndex in 0'u8 .. 6'u8:
    for cipher in 0'u8 .. 4'u8:
      for flags in 0'u32 .. 3'u32:
        begin(vifIndex, staIndex, cipher, flags)
        drain()
        let expected = if cipher >= 2: 1'u8 else: 2'u8 - (flags and 1).uint8
        doAssert stations[staIndex].controlPortState == expected
        doAssert stations[staIndex].rateWord == 0x888E
        doAssert stationReady == 1 and calls == 7
        doAssert connected == (if cipher <= 1: 1 else: 0)
        if cipher >= 2:
          sm_handle_supplicant_result(staIndex, 0)
          doAssert stations[staIndex].controlPortState == 2 and connected == 1
          sm_handle_supplicant_result(staIndex, 0)
          doAssert connected == 1
        finish()
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_association_keeps_wpa_port_restricted(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + CHECKS)
