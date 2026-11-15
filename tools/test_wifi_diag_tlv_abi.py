"""Check the no-op diagnostic callback against the vendor's parameter types."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_diagnostic_tlv_callback_abi(tmp_path: Path, mode: str) -> None:
    body = procedure((FW / "scan_station_ap_me.nim").read_text(), "sm_connect_wap_tlv_pack_cb")
    checks = r'''
type TlvCallback = proc(id: uint8; data: pointer; length: uint16) {.cdecl.}
let callback: TlvCallback = sm_connect_wap_tlv_pack_cb
var bytes = [1'u8, 2, 3, 4]
for id in [0'u8, 1, 2, 3, 4, 5, 255]:
  for length in [0'u16, 1, 4, high(uint16)]:
    callback(id, nil, length)
    callback(id, addr bytes[0], length)
doAssert bytes == [1'u8, 2, 3, 4]
'''
    run_program(tmp_path, mode, body + checks)
