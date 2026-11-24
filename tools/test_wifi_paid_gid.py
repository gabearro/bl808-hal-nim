"""Check the MAC Partial AID/GID encoders against mac.o bit operations."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    mac = (FW / "mac_config_debug.nim").read_text()
    return (procedure(mac, "mac_paid_gid_sta_compute")
            + procedure(mac, "mac_paid_gid_ap_compute"))


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_paid_gid_encoding(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
var bssid: array[6, uint8]
for octet4 in [0'u8, 1, 0x7F, 0x80, 0xFF]:
  for octet5 in 0'u16 .. 255'u16:
    bssid[4] = octet4
    bssid[5] = octet5.uint8
    let staBits = (octet5.uint32 shl 1) or (octet4.uint32 and 0x80)
    doAssert mac_paid_gid_sta_compute(addr bssid[0]) == staBits shl 22
    for aid in [0'u16, 1, 31, 255, 511, 512, 1023, high(uint16)]:
      let bssidMix = ((octet5.uint32 xor (octet5.uint32 shr 4)) and 0xF) shl 5
      let paid = ((aid.uint32 and 511) + bssidMix) and 511
      let expected = (paid shl 22) or 0x003F0000'u32
      doAssert mac_paid_gid_ap_compute(addr bssid[0], aid) == expected
''')
