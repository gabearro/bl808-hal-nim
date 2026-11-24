"""Exercise bounded RSN parsing with valid and inconsistent PMF fields."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import FW, run_program


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_rsn_akm_and_pmf_validation(tmp_path: Path, mode: str) -> None:
    source = (FW / "rsn_parse.nim").read_text()
    run_program(tmp_path, mode, source + r'''
var rsn = [48'u8, 20, 1, 0, 0, 15, 172, 4,
           1, 0, 0, 15, 172, 4, 1, 0, 0, 15, 172, 2, 0, 0]
let fullLength = rsn.len.uint32
for available in 0'u32 ..< fullLength:
  let info = wifiRsnAkmInfoFromIe(addr rsn[0], available)
  doAssert info.authMask == 0 and not info.pmfCapable and not info.pmfRequired
let base = wifiRsnAkmInfoFromIe(addr rsn[0], fullLength)
doAssert base.authMask == WifiAuthMaskPsk
doAssert base.ccmpGroup and base.ccmpPairwise
doAssert not base.pmfCapable and not base.pmfRequired
doAssert base.bipCmac128

rsn[7] = 2
let tkipGroup = wifiRsnAkmInfoFromIe(addr rsn[0], fullLength)
doAssert tkipGroup.authMask == WifiAuthMaskPsk
doAssert not tkipGroup.ccmpGroup and tkipGroup.ccmpPairwise
rsn[7] = 4
rsn[13] = 2
let tkipPairwise = wifiRsnAkmInfoFromIe(addr rsn[0], fullLength)
doAssert tkipPairwise.authMask == WifiAuthMaskPsk
doAssert tkipPairwise.ccmpGroup and not tkipPairwise.ccmpPairwise
rsn[13] = 4

rsn[20] = 0xC0
let required = wifiRsnAkmInfoFromIe(addr rsn[0], fullLength)
doAssert required.authMask == WifiAuthMaskPsk
doAssert required.pmfCapable and required.pmfRequired

# MFPR without MFPC advertises a requirement that the peer cannot satisfy.
rsn[20] = 0x40
let inconsistent = wifiRsnAkmInfoFromIe(addr rsn[0], fullLength)
doAssert inconsistent.authMask == 0
doAssert not inconsistent.pmfCapable and not inconsistent.pmfRequired
doAssert wifiRsnAuthMaskFromIe(addr rsn[0], fullLength) == 0

rsn[20] = 0
rsn[1] = 18
doAssert wifiRsnAkmInfoFromIe(addr rsn[0], 20).authMask == WifiAuthMaskPsk
rsn[1] = 20
rsn[2] = 2
doAssert wifiRsnAkmInfoFromIe(addr rsn[0], fullLength).authMask == 0

# The management group cipher defaults to BIP-CMAC-128 when omitted. An
# explicit unsupported suite must not be accepted for a PMF connection.
var mgmt = [48'u8, 26, 1, 0, 0, 15, 172, 4, 1, 0,
            0, 15, 172, 4, 1, 0, 0, 15, 172, 2,
            0xC0, 0, 0, 0, 0, 15, 172, 6]
let cmac = wifiRsnAkmInfoFromIe(addr mgmt[0], mgmt.len.uint32)
doAssert cmac.authMask == WifiAuthMaskPsk and cmac.bipCmac128
mgmt[27] = 11
let unsupportedMgmt = wifiRsnAkmInfoFromIe(addr mgmt[0], mgmt.len.uint32)
doAssert unsupportedMgmt.authMask == WifiAuthMaskPsk
doAssert unsupportedMgmt.pmfCapable and unsupportedMgmt.pmfRequired
doAssert not unsupportedMgmt.bipCmac128
mgmt[1] = 25
doAssert wifiRsnAkmInfoFromIe(addr mgmt[0], 27).authMask == 0

# Mixed WPA/WPA2 AP mode emits TKIP+CCMP pairwise suites with PSK AKM.
let mixed = [48'u8, 24, 1, 0, 0, 15, 172, 2, 2, 0,
             0, 15, 172, 2, 0, 15, 172, 4, 1, 0,
             0, 15, 172, 2, 0, 0]
doAssert wifiRsnAkmInfoFromIe(addr mixed[0], mixed.len.uint32).authMask == WifiAuthMaskPsk
doAssert not wifiRsnAkmInfoFromIe(addr mixed[0], mixed.len.uint32).ccmpGroup
doAssert wifiRsnAkmInfoFromIe(addr mixed[0], mixed.len.uint32).ccmpPairwise
var ies: array[29, uint8]
ies[0] = 0
ies[1] = 1
ies[2] = 65
copyMem(addr ies[3], unsafeAddr mixed[0], mixed.len)
doAssert wifiRsnAkmInfoFromIeBuffer(addr ies[0], ies.len.uint32).authMask == WifiAuthMaskPsk
ies[1] = 30
doAssert wifiRsnAkmInfoFromIeBuffer(addr ies[0], ies.len.uint32).authMask == 0
''')
