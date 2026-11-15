"""Check PHY descriptor caching and initialization against the RF object ABI."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_sta_tx_channel import source as sta_source


def source() -> str:
    rf = (FW / "global_state/rf_bl808_core.nim").read_text()
    code = sta_source() + "\nvar nimFwDbgPhyInitPhase: uint32\n"
    for name in ["phy_get_channel_raw", "copyPhyInitCfg", "phyInitProgramInitialChannel"]:
        code += procedure(rf, name)
    return code + r'''
proc readback(): array[2, uint32] =
  var guarded = [0x12345678'u32, 0, 0, 0x87654321'u32]
  phy_get_channel_raw(addr guarded[1], 0)
  doAssert guarded[0] == 0x12345678'u32 and guarded[3] == 0x87654321'u32
  [guarded[1], guarded[2]]
proc descriptorWords(channel: ChanCtxtDefView): array[2, uint32] =
  [channel.band.uint32 or (channel.chanType.uint32 shl 8) or
    (channel.primFreq.uint32 shl 16),
   channel.centerFreq1.uint32 or (channel.centerFreq2.uint32 shl 16)]
'''


CASES = {
    "secondary_frequency": r'''
for secondary in [0'u16, 1, 2437, 65535]:
  for power in [0'u8, 1, 17, 127, 255]:
    setup()
    var channel = ChanCtxtDefView(band: 1, chanType: 2, primFreq: 5180,
      centerFreq1: 5210, centerFreq2: secondary, txPower: power, phyEnvFlags: 3)
    phy_set_channel(addr channel, 0)
    doAssert readback() == descriptorWords(channel), "secondary frequency changed in readback"
    doAssert phy.txPowerAndFlags == (power.uint16 or 0x300'u16)
    let before = phy
    clearCalls()
    phy_set_channel(addr channel, 0)
    doAssert calls.len == 0 and phy == before
''',
    "flag_only_update": r'''
setup()
var channel = ChanCtxtDefView(band: 1, chanType: 2, primFreq: 5180,
  centerFreq1: 5210, centerFreq2: 5530, txPower: 17)
phy_set_channel(addr channel, 0)
for flags in 1 .. 255:
  clearCalls()
  channel.phyEnvFlags = flags.uint8
  phy_set_channel(addr channel, 0)
  doAssert programmed == @[5210'u32], "flag change incorrectly treated as unchanged"
  doAssert "rate-power" notin calls
  doAssert phy.txPowerAndFlags == (17'u16 or (flags.uint16 shl 8))
  doAssert readback() == descriptorWords(channel)
  clearCalls()
  phy_set_channel(addr channel, 0)
  doAssert calls.len == 0
''',
    "power_only_noop": r'''
for secondary in [0'u16, 5530]:
  setup()
  var channel = ChanCtxtDefView(band: 1, chanType: 2, primFreq: 5180,
    centerFreq1: 5210, centerFreq2: secondary, txPower: 17, phyEnvFlags: 3)
  phy_set_channel(addr channel, 0)
  let before = phy
  clearCalls()
  channel.txPower = 31
  phy_set_channel(addr channel, 0)
  doAssert calls.len == 0 and phy == before, "power byte alone must not retune"
  channel.phyEnvFlags = 4
  phy_set_channel(addr channel, 0)
  doAssert programmed == @[5210'u32] and phy.txPowerAndFlags == 0x41F
''',
    "initial_channel_publication": r'''
setup()
let bytes = cast[ptr UncheckedArray[uint8]](addr phy)
for i in 0 ..< sizeof(phy): bytes[i] = 0xA5
let before = phy
phyInitProgramInitialChannel()
doAssert phy == before, "RF setup published a channel descriptor before config copy"
doAssert programmed == @[2412'u32]
doAssert nimFwDbgPhyInitPhase == 5
''',
    "configuration_sentinels": r'''
for nilConfig in [false, true]:
  setup()
  let bytes = cast[ptr UncheckedArray[uint8]](addr phy)
  for i in 0 ..< sizeof(phy): bytes[i] = 0xA5
  var config: array[9, uint32]
  for i in 0 ..< config.len: config[i] = 0x87650000'u32 + i.uint32
  copyPhyInitCfg(if nilConfig: nil else: addr config[0])
  for i in 0 ..< config.len:
    doAssert phy.initCfgWords[i] == (if nilConfig: 0'u32 else: config[i])
  doAssert readback() == [0x00FF0501'u32, 0x00FF00FF'u32]
  for i in 44 ..< sizeof(phy):
    doAssert bytes[i] == 0xA5, "configuration copy changed descriptor flags/power"
''',
    "setter_transition_matrix": r'''
setup()
var channel = ChanCtxtDefView(band: 0, chanType: 0, primFreq: 2412,
  centerFreq1: 2412, centerFreq2: 0, txPower: 7, phyEnvFlags: 0)
for step in 0 .. 11:
  let before = phy
  let oldWords = readback()
  let oldType = ((oldWords[0] shr 8) and 255).uint8
  case step
  of 0: discard
  of 1: channel.band = 1
  of 2: channel.chanType = 2
  of 3: channel.primFreq = 5180
  of 4: channel.centerFreq1 = 5210
  of 5: channel.centerFreq2 = 5530
  of 6: channel.phyEnvFlags = 0x80
  of 7: channel.txPower = 255
  of 8: channel.centerFreq2 = 0
  of 9: channel.phyEnvFlags = 0
  of 10: channel.chanType = 0
  else: discard
  let expectedWords = descriptorWords(channel)
  let changed = oldWords != expectedWords or
    ((before.txPowerAndFlags shr 8).uint8 != channel.phyEnvFlags)
  clearCalls()
  let descriptorBefore = channel
  phy_set_channel(addr channel, 0)
  doAssert channel == descriptorBefore
  if changed:
    doAssert programmed == @[channel.centerFreq1.uint32]
    doAssert readback() == expectedWords
    doAssert phy.txPowerAndFlags == (channel.txPower.uint16 or
      (channel.phyEnvFlags.uint16 shl 8))
    doAssert ("rate-power" in calls) == (oldType != channel.chanType)
  else:
    doAssert phy == before and calls.len == 0
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_phy_descriptor(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
