"""Check PHY capability fields, TX policy propagation, and byte arithmetic."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rate_init import CASES as RATE_CASES, source as rate_source
from test_wifi_sta_tx_channel import object_type


def source() -> str:
    rf = (FW / "global_state/rf_bl808_core.nim").read_text()
    table = rf[rf.index("var phyRxGainTable*"):].split("\nvar phyRxGainOffsetVsTemperature", 1)[0]
    code = object_type(rf, "WifiModemBlock") + table
    code += r'''
var
  modem: WifiModemBlock
  version: uint32
  versionReads: int
  writes: seq[int]
  phyRxGainOffsetVsTemperature = -128'i8
proc volatileLoad[T](p: ptr T): T = p[]
proc volatileStore(p: ptr int8; value: int8) = p[] = value
proc modemVersionReg(): uint32 =
  inc versionReads
  version
proc wifiModemRegs(): ptr WifiModemBlock = addr modem
proc updateReg32(p: ptr uint32; mask, value: uint32) =
  writes.add(cast[int](p) - cast[int](addr modem))
  p[] = (p[] and mask) or value
'''
    for name in ["phyRxGainByte", "rc2_config_rxgain", "phy_get_ntx",
                 "phy_get_nss", "phy_get_nrx", "phy_get_bw",
                 "phy_vht_supported", "phy_he_supported", "phy_ldpc_tx_supported",
                 "phy_ldpc_rx_supported", "phy_bfmee_supported", "phy_bfmer_supported",
                 "phy_mu_mimo_rx_supported", "phy_mu_mimo_tx_supported"]:
        code += procedure(rf, name)
    return code


CASES = {
    "capability_flags": r'''
proc checkVersion(word: uint32) =
  version = word
  doAssert phy_get_bw() == ((word shr 24) and 3).uint8
  doAssert phy_vht_supported() == ((word and 0x03400000'u32) != 0),
    "VHT support must use bit 22 or the bandwidth field"
  doAssert phy_he_supported() == ((word and (1'u32 shl 21)) != 0)
  doAssert phy_ldpc_tx_supported() == ((word and (1'u32 shl 26)) != 0)
  doAssert phy_ldpc_rx_supported() == ((word and (1'u32 shl 27)) != 0)
  doAssert phy_bfmee_supported() == ((word and (1'u32 shl 28)) != 0)
  doAssert phy_bfmer_supported() == ((word and (1'u32 shl 29)) != 0)
  doAssert phy_mu_mimo_rx_supported() == ((word and (1'u32 shl 30)) != 0)
  doAssert phy_mu_mimo_tx_supported() == ((word and (1'u32 shl 31)) != 0)
checkVersion(0)
checkVersion(0xFFFFFFFF'u32)
for bit in 0..31:
  checkVersion(1'u32 shl bit)
  checkVersion(not (1'u32 shl bit))
for features in 0'u32..2047:
  checkVersion(features shl 21)
''',
    "capability_counts": r'''
for nibble in 0'u32..15:
  for unrelated in [0'u32, 0xFFFFFFFF'u32, 0xA5A55A5A'u32]:
    let expected = (if nibble == 0: 255'u8 else: (nibble - 1).uint8)
    versionReads = 0
    version = (unrelated and not 0xF0'u32) or (nibble shl 4)
    doAssert phy_get_ntx() == expected
    version = (unrelated and not 0xF00'u32) or (nibble shl 8)
    doAssert phy_get_nss() == expected
    version = (unrelated and not 0xF'u32) or nibble
    doAssert phy_get_nrx() == expected
    doAssert versionReads == 3
''',
    "gain_byte": r'''
const base = [14, 19, 26, 32, 38, 45, 50, 57, 63]
for offset in -128..127:
  for index in 0..<base.len:
    let expected = ((base[index] + offset + 256) mod 256).uint32
    doAssert phyRxGainByte(index, offset.int8) == expected,
      "gain addition did not preserve the low byte"
''',
    "gain_registers_and_cache": r'''
const base = [14, 19, 26, 32, 38, 45, 50, 57, 63]
for offset in -128..127:
  let bytes = cast[ptr UncheckedArray[uint8]](addr modem)
  for i in 0..<sizeof(modem): bytes[i] = (i and 255).uint8
  var expected = modem
  var packed: array[3, uint32]
  for index in 0..<base.len:
    packed[index div 4] = packed[index div 4] or
      (((base[index] + offset + 256) mod 256).uint32 shl ((index mod 4)*8))
  expected.rxGainTable0C080 = packed[0]
  expected.rxGainTable1C084 = packed[1]
  expected.rxGainTable2C088 = (expected.rxGainTable2C088 and 0xFFFFFF00'u32) or packed[2]
  phyRxGainOffsetVsTemperature = (if offset == 0: 1'i8 else: 0'i8)
  writes.setLen(0)
  rc2_config_rxgain(offset.int8)
  doAssert modem == expected
  doAssert phyRxGainOffsetVsTemperature == offset.int8
  doAssert writes == @[0xC080, 0xC080, 0xC080, 0xC080,
                      0xC084, 0xC084, 0xC084, 0xC084, 0xC088]
  writes.setLen(0)
  rc2_config_rxgain(offset.int8)
  doAssert modem == expected and writes.len == 0
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_phy_byte_fields(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_phy_ldpc_tx_policy(tmp_path: Path, mode: str) -> None:
    rf = (FW / "global_state/rf_bl808_core.nim").read_text()
    stub = "proc phy_ldpc_tx_supported(): bool = true"
    code = rate_source()
    assert code.count(stub) == 1
    code = code.replace(stub, "var version: uint32\n"
                        "proc modemVersionReg(): uint32 = version\n"
                        + procedure(rf, "phy_ldpc_tx_supported"))
    code += RATE_CASES.split("proc expectedCount", 1)[0]
    code += r'''
proc checkPolicy(word: uint32; ht, peerLdpc: bool) =
  version = word
  setup(ht, 0xFFF, 0, 0, (if peerLdpc: 1'u16 else: 0'u16))
  doAssert rcTryInitStation(addr sta)
  doAssert errors == 0
  let ldpc = ht and peerLdpc and (word and (1'u32 shl 26)) != 0
  doAssert policy.bufferAddr == ((1'u32 shl 14) or (if ldpc: 64'u32 else: 0'u32)),
    "station TX policy must require both local and peer LDPC support"
for ht in [false, true]:
  for peer in [false, true]:
    checkPolicy(0, ht, peer)
    checkPolicy(0xFFFFFFFF'u32, ht, peer)
    for bit in 0..31:
      checkPolicy(1'u32 shl bit, ht, peer)
      checkPolicy(not (1'u32 shl bit), ht, peer)
    for bw in 0'u32..3:
      checkPolicy(bw shl 24, ht, peer)
      checkPolicy((bw shl 24) or (1'u32 shl 26), ht, peer)
'''
    run_program(tmp_path, mode, code)
