"""Exercise the compact WiFi power-table contract against the RF row layout."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import FW, ROOT, procedure


PLATFORM = r'''
var
  trpcTxpwrVsRateTable: array[50, uint8]
  config: array[544, uint8]
  wlCfgGlobal: pointer = addr config[0]
  tpcChannelOffsetTable: array[14, int8]
  tpcPowerTable: array[38, int8]
  scaledOffsets: array[14, int8]
  offsetUpdates: int
proc phy_powroffset_set(p: ptr int8) {.exportc, cdecl.} =
  copyMem(addr scaledOffsets[0], p, 14)
  inc offsetUpdates
proc setup() =
  for i in 0..<trpcTxpwrVsRateTable.len:
    trpcTxpwrVsRateTable[i] = (i * 3 + 17).uint8
  for i in 0..<config.len: config[i] = ((i * 7 + 19) and 255).uint8
  for i in 0..<14:
    tpcChannelOffsetTable[i] = (i - 7).int8
    tpcPowerTable[24 + i] = tpcChannelOffsetTable[i]
  scaledOffsets = default(typeof(scaledOffsets))
  offsetUpdates = 0
proc assertRateLookup(table: array[24, int8]) =
  for group in 0..2:
    for index in 0..7:
      if group == 0 and index > 3: continue
      let packedRate =
        if group == 2: 0x800'u32 or index.uint32
        elif group == 1: (index + 4).uint32
        else: index.uint32
      let expected = (cast[uint8](table[group * 8 + index]).uint32 shl 2) and 0xFC'u32
      doAssert tpc_get_vif_tx_power_vs_rate(packedRate).uint32 == expected
'''


def source() -> str:
    rf = (FW / "global_state/rf_bl808_core.nim").read_text()
    tpc = (FW / "tx_power_control.nim").read_text()
    declarations, checks = PLATFORM.split("proc assertRateLookup", 1)
    code = declarations
    for name in ["trpcCopyTable", "trpcCopyFromWlCfg", "trpcCopyTableOut", "trpc_power_get",
                 "trpc_update_power_11b", "trpc_update_power_11g", "trpc_update_power_11n",
                 "trpc_update_power", "trpc_get_default_power_idx"]:
        code += procedure(rf, name)
    if "proc trpcLoadPowerFromConfig(" in rf:
        code += procedure(rf, "trpcLoadPowerFromConfig")
        code += "proc loadConfig(kind: uint8) = trpcLoadPowerFromConfig(kind)\n"
    else:
        code += "proc loadConfig(kind: uint8) = trpc_update_power(cast[pointer](kind.uint))\n"
    for name in ["tpc_get_vif_tx_power_vs_rate", "bl_tpc_update_power_table",
                 "bl_tpc_update_power_table_rate", "bl_tpc_update_power_rate_11b",
                 "bl_tpc_update_power_rate_11g", "bl_tpc_update_power_rate_11n",
                 "bl_tpc_power_table_get"]:
        code += procedure(tpc, name)
    return code + "proc assertRateLookup" + checks


CASES = {
    "readback": r'''
setup()
let original = trpcTxpwrVsRateTable
var guarded: array[56, uint8]
for b in guarded.mitems: b = 0xA5
trpc_power_get(addr guarded[16])
for group in 0..2:
  for index in 0..7:
    doAssert guarded[16 + group * 8 + index] == original[group * 10 + index],
      "readback did not pack the RF rows"
for i in 0..<16: doAssert guarded[i] == 0xA5
for i in 40..<56: doAssert guarded[i] == 0xA5, "24-byte getter changed its suffix"
doAssert trpcTxpwrVsRateTable == original
''',
    "full_update": r'''
for seed in 0..3:
  setup()
  let oldTable = trpcTxpwrVsRateTable
  let oldConfig = config
  var rates: array[24, int8]
  for i in 0..<rates.len: rates[i] = cast[int8](((seed * 67 + i * 11) and 255).uint8)
  let input = rates
  trpc_update_power(addr rates[0])
  for group in 0..2:
    for index in 0..7:
      doAssert trpcTxpwrVsRateTable[group * 10 + index] == cast[uint8](rates[group * 8 + index]),
        "full update ignored or misplaced a supplied rate"
    for index in 8..9:
      doAssert trpcTxpwrVsRateTable[group * 10 + index] == oldTable[group * 10 + index]
  for i in 30..<50: doAssert trpcTxpwrVsRateTable[i] == oldTable[i]
  var output: array[24, int8]
  trpc_power_get(addr output[0])
  doAssert output == input and rates == input and config == oldConfig
  assertRateLookup(rates)
''',
    "wrappers": r'''
for rateOnly in [false, true]:
  setup()
  var full: array[38, int8]
  for i in 0..<full.len: full[i] = (i - 20).int8
  let original = full
  let oldOffsets = tpcChannelOffsetTable
  var rates: array[24, int8]
  copyMem(addr rates[0], addr full[0], 24)
  if rateOnly: bl_tpc_update_power_table_rate(addr rates)
  else: bl_tpc_update_power_table(addr full)
  var output: array[38, int8]
  bl_tpc_power_table_get(addr output)
  for i in 0..<24: doAssert output[i] == original[i], "WiFi wrapper lost a rate update"
  for i in 0..<14:
    let expected = if rateOnly: oldOffsets[i] else: original[24 + i]
    doAssert output[24 + i] == expected and tpcChannelOffsetTable[i] == expected
    if not rateOnly:
      doAssert tpcPowerTable[24 + i] == expected
      doAssert scaledOffsets[i] == cast[int8](expected.int32 * 4)
  doAssert offsetUpdates == (if rateOnly: 0 else: 1)
  doAssert full == original
  assertRateLookup(rates)
''',
    "partial_updates": r'''
setup()
let original = trpcTxpwrVsRateTable
var b = [1'i8, 2, 3, 4]
var g = [5'i8, 6, 7, 8, 9, 10, 11, 12]
var n = [13'i8, 14, 15, 16, 17, 18, 19, 20]
bl_tpc_update_power_rate_11b(addr b)
bl_tpc_update_power_rate_11g(addr g)
bl_tpc_update_power_rate_11n(addr n)
var rates: array[24, int8]
trpc_power_get(addr rates[0])
for i in 0..<4: doAssert rates[i] == b[i]
for i in 4..<8: doAssert rates[i] == cast[int8](original[i])
for i in 0..<8:
  doAssert rates[8 + i] == g[i] and rates[16 + i] == n[i]
for i in [8, 9, 18, 19, 28, 29]: doAssert trpcTxpwrVsRateTable[i] == original[i]
for i in 30..<50: doAssert trpcTxpwrVsRateTable[i] == original[i]
assertRateLookup(rates)
''',
    "config_reload": r'''
for kind in [0'u8, 1, 2, 255]:
  setup()
  let original = trpcTxpwrVsRateTable
  let oldConfig = config
  loadConfig(kind)
  for i in 0..<4: doAssert trpcTxpwrVsRateTable[i] == config[0x32 + i]
  for i in 0..<8:
    doAssert trpcTxpwrVsRateTable[10 + i] == config[0x36 + i]
    doAssert trpcTxpwrVsRateTable[20 + i] == config[(if kind == 0: 0x3E else: 0x46) + i]
  for i in 0..<10:
    let expected = config[(if kind == 0: 0x6C else: 0x78) + i]
    doAssert trpcTxpwrVsRateTable[30 + i] == expected
    doAssert trpcTxpwrVsRateTable[40 + i] == expected
  for i in [4, 5, 6, 7, 8, 9, 18, 19, 28, 29]:
    doAssert trpcTxpwrVsRateTable[i] == original[i]
  doAssert config == oldConfig
''',
    "empty_inputs": r'''
setup()
let original = trpcTxpwrVsRateTable
trpc_power_get(nil)
trpc_update_power(nil)
trpc_update_power_11b(nil)
trpc_update_power_11g(nil)
trpc_update_power_11n(nil)
doAssert trpcTxpwrVsRateTable == original
wlCfgGlobal = nil
loadConfig(0)
loadConfig(1)
doAssert trpcTxpwrVsRateTable == original
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_tpc_adapter(tmp_path: Path, case: str, mode: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    path = tmp_path / "tpc_adapter.nim"
    path.write_text(source() + CASES[case])
    flags = {
        "checked": [],
        "release": ["-d:release", "--assertions:on"],
        "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"],
    }[mode]
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", "--checks:on", *flags, f"--nimcache:{tmp_path / 'cache'}",
        f"-o:{tmp_path / 'check'}", str(path)], cwd=ROOT, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    assert result.returncode == 0, result.stdout
