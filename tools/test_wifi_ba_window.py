"""Keep successful ADDBA responses within the receiver's nonzero window."""

from pathlib import Path

import pytest

from test_wifi_ba_response_owner import source
from test_wifi_message_allocation import run_program


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_unspecified_and_explicit_receive_windows(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incomingIrq in [false, true]:
  for station in 0'u8 .. 6'u8:
    for requested in [0'u16, 1, 2, 11, 12, 13, 64, 1023]:
      for lowerBits in 0'u16 .. 31'u16:
        setupOwner(incomingIrq)
        logging = false
        let params = (requested shl 6) or lowerBits
        var message: Message
        let p = request(message, station, params)
        let before = message
        doAssert rxu_mgt_ind_handler_bam(p) == 0
        doAssert interrupts == incomingIrq
        doAssert allocations == 1 and pushes == 1 and powerUpdates == 1
        doAssert message == before, "ADDBA negotiation rewrote its request"
        let body = addBaRspActionBodyAt(addr link.macHeader[24])
        let expectedWindow = if requested == 0: 12'u16 else: min(requested, 12'u16)
        doAssert body.statusCode == 0 and body.timeout == 0 and body.dialogToken == 0xEF
        doAssert (body.baParams shr 6) in 1'u16 .. 12'u16,
          "successful ADDBA response advertised a zero receive window"
        doAssert body.baParams == ((expectedWindow shl 6) or (params and 0x3E) or 2)
        doAssert mmio == 0xABCD0090'u32
''')
