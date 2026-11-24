"""Check WLAN rate-power class dispatch against wl_api.c.o."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_power_replay import RF


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_rate_class_byte_aliases_and_index_bounds(tmp_path: Path, mode: str) -> None:
    rf = RF.read_text()
    code = r'''
var
  calls: seq[tuple[group: uint32, index: uint8]]
  invalidCalls: int
proc wlInvalidPowerCfgIndex(): int8 =
  inc invalidCalls
  -127'i8
proc trpc_get_default_power_idx(group: uint32; index: uint8): int8 =
  calls.add((group, index))
  42'i8
'''
    code += procedure(rf, "wl_wlan_power_cfg_get")
    run_program(tmp_path, mode, code + r'''
type ClassCase = tuple[value, group, maxIndex: uint32]
const cases: array[24, ClassCase] = [
  (0'u32, 0'u32, 11'u32), (1'u32, 0'u32, 11'u32),
  (2'u32, 2'u32, 7'u32), (3'u32, 2'u32, 7'u32),
  (4'u32, 3'u32, 9'u32),
  (5'u32, 4'u32, 9'u32), (6'u32, 4'u32, 9'u32),
  (7'u32, 4'u32, 9'u32),
  (258'u32, 2'u32, 7'u32), (259'u32, 2'u32, 7'u32),
  (514'u32, 2'u32, 7'u32), (515'u32, 2'u32, 7'u32),
  (0xFFFF_FF02'u32, 2'u32, 7'u32),
  (261'u32, 4'u32, 9'u32), (262'u32, 4'u32, 9'u32),
  (263'u32, 4'u32, 9'u32), (0xFFFF_FF05'u32, 4'u32, 9'u32),
  (256'u32, 99'u32, 0'u32), (257'u32, 99'u32, 0'u32),
  (260'u32, 99'u32, 0'u32), (264'u32, 99'u32, 0'u32),
  (0xFFFF_FF00'u32, 99'u32, 0'u32),
  (0xFFFF_FF04'u32, 99'u32, 0'u32),
  (0xFFFF_FF08'u32, 99'u32, 0'u32),
]
for item in cases:
  for index in [0'u32, 3, 4, 7, 8, 9, 10, 11, 12, high(uint32)]:
    calls.setLen(0)
    invalidCalls = 0
    let valid = item.group != 99 and index <= item.maxIndex
    let returned = wl_wlan_power_cfg_get(item.value, index)
    doAssert returned == (if valid: 42'i8 else: -127'i8)
    doAssert invalidCalls == (if valid: 0 else: 1)
    if valid:
      let group = if item.group == 0 and index > 3: 1'u32 else: item.group
      let adjusted = if item.group == 0 and index > 3: (index - 4).uint8 else: index.uint8
      doAssert calls == @[(group, adjusted)]
    else:
      doAssert calls.len == 0
''')
