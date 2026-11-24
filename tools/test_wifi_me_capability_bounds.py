"""Check the local VIF bounds on the vendor-compatible capability builder."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_capability_builder_rejects_unowned_vif_indices(tmp_path: Path, mode: str) -> None:
    management = (FW / "scan_station_ap_me.nim").read_text()
    code = r'''
const
  MAX_VIFS = 2
  VIF_TYPE_STA = 0'u8
type Vif = object
  vifType: uint8
  capabilityInfo: uint16
var
  vifs: array[MAX_VIFS, Vif]
  accesses: int
proc encodedArgU8(p: pointer): uint8 = cast[uint](p).uint8
proc vifChannelForIdx(index: uint8): ptr Vif =
  inc accesses
  doAssert index < MAX_VIFS.uint8
  addr vifs[index]
'''
    code += procedure(management, "me_build_capability")
    run_program(tmp_path, mode, code + r'''
vifs[0] = Vif(vifType: VIF_TYPE_STA, capabilityInfo: 0x30)
vifs[1] = Vif(vifType: 2, capabilityInfo: 0x30)
doAssert me_build_capability(nil) == 0x431'u16
doAssert me_build_capability(cast[pointer](1)) == 0x401'u16
doAssert accesses == 2
for rawIndex in [2'u, 255'u, 256'u, 257'u, high(uint)]:
  doAssert me_build_capability(cast[pointer](rawIndex)) == 0'u16
doAssert accesses == 2
''')
