"""The DHCP-only seed uses BL808 entropy, with a device-specific fallback."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import ROOT
from test_wifi_message_allocation import run_program


PLATFORM = r'''
{.define: bl808WifiDiagDhcpTxAttempts.}
var
  entropyOk = true
  entropy: uint32
  tick: uint64
  mac = [2'u8, 1, 2, 3, 4, 5]
  entropyReads, tickReads, macReads: int

proc os_get_random(dest: ptr uint8; count: csize_t): cint =
  inc entropyReads
  doAssert count == 4
  cast[ptr uint32](dest)[] = entropy
  if entropyOk: 0 else: -1

proc readMtimeUs(): uint64 =
  inc tickReads
  tick

proc bl_wifi_mac_addr_get(dest: ptr uint8): cint =
  inc macReads
  copyMem(dest, addr mac[0], mac.len)
  0
'''

CHECKS = r'''
for word in [0'u32, 0x89ABCDEF'u32, high(uint32)]:
  entropy = word
  doAssert bl808_lwip_dhcp_xid_seed() == word and dhcpXidSeedSource == 1
doAssert entropyReads == 3 and tickReads == 0 and macReads == 0

entropyOk = false
let baseline = bl808_lwip_dhcp_xid_seed()
doAssert dhcpXidSeedSource == 2 and baseline != entropy
entropy = 77
doAssert bl808_lwip_dhcp_xid_seed() == baseline
inc tick
let later = bl808_lwip_dhcp_xid_seed()
doAssert later != baseline
tick = 1'u64 shl 40
doAssert bl808_lwip_dhcp_xid_seed() notin [baseline, later]
tick = 0
inc mac[5]
doAssert bl808_lwip_dhcp_xid_seed() != baseline
doAssert entropyReads == 8 and tickReads == 5 and macReads == 5
'''


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_dhcp_xid_seed(tmp_path: Path, mode: str) -> None:
    source = ROOT / "src/bl808/wifi/support/runtime_facade_parts/dhcp_xid.nim"
    run_program(tmp_path, mode, PLATFORM + source.read_text() + CHECKS)
