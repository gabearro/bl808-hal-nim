"""Accept fresh 48-bit PNs even when the old 32-bit block index aliases."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    start = layout.index("template replayCounterStateView(")
    return (layouts("KeyReplayCounterView", "ReplayCounterStateView")
            + layout[start:layout.index("\n\n", start)] + "\n"
            + procedure((FW / "mac_config_debug.nim").read_text(), "replay_counter_validate"))


CASES = {
    "same_bank_alias": r'''
const period = 1'u64 shl 37
for first in [1'u64, 30, 31, 32, 63, 0xFFFFFFFF'u64, 0x100000000'u64]:
  for multiple in [1'u64, 2, 1023]:
    var state: ReplayCounterStateView
    doAssert replay_counter_validate(addr state, first)
    let high = first + multiple * period
    doAssert high < (1'u64 shl 48)
    doAssert replay_counter_validate(addr state, high),
      "fresh forward PN collided with an old bitmap bit"
    doAssert state.pnLow == (high + 1).uint32
    doAssert state.pnHigh == ((high + 1) shr 32).uint32
    var bitmap: array[2, uint32]
    bitmap[(((high + 1) shr 5) and 1).int] = 1'u32 shl ((high + 1) and 31).int
    doAssert state.bitmap == bitmap
    let before = state
    doAssert not replay_counter_validate(addr state, high)
    doAssert state == before
''',
    "previous_bank_alias": r'''
const period = 1'u64 shl 37
for first in [1'u64, 30, 31, 32, 63, 0xFFFFFFFF'u64, 0x100000000'u64]:
  for multiple in [1'u64, 2, 1023]:
    var state: ReplayCounterStateView
    doAssert replay_counter_validate(addr state, first)
    let high = first + multiple * period + 32
    doAssert high < (1'u64 shl 48)
    doAssert replay_counter_validate(addr state, high)
    doAssert replay_counter_validate(addr state, high - 32),
      "unseen in-window PN collided with stale previous-bank history"
    let before = state
    doAssert not replay_counter_validate(addr state, high - 32)
    doAssert not replay_counter_validate(addr state, high)
    doAssert not replay_counter_validate(addr state, high - 33)
    doAssert state == before
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_large_forward_jumps(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
def test_valid_stream_against_seen_set(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, "import std/sets\n" + source() + r'''
var state: ReplayCounterStateView
var seen = initHashSet[uint64]()
var highest = 0'u64
proc observe(pn: uint64) =
  doAssert pn < (1'u64 shl 48)
  let expected = pn + 32 >= highest and pn notin seen
  let before = state
  doAssert replay_counter_validate(addr state, pn) == expected,
    "replay decision disagreed with the seen-set model at PN " & $pn
  if expected:
    highest = max(highest, pn)
    seen.incl(pn)
  else:
    doAssert state == before, "rejected valid-stream PN modified replay state"
observe(1)
for step in 0'u64 ..< 128:
  let previous = highest
  observe(highest + (1'u64 shl 37) * (1 + step mod 3) + (step and 63))
  let high = highest
  for pn in [high - 32, high - 31, high - 1, high, previous, high - 33]: observe(pn)
  observe(high + 1)
  observe(high + 1)
''')
