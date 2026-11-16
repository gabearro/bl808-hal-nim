"""Exercise management receive counters with real key install/delete paths."""

from pathlib import Path
import re

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_station_keys import harness


SUPPORT = r'''
type
  VifChannelView = object
    bytes: array[1512, uint8]
  RxEnv = object
    secInfo0, secInfo1: uint32
    secFlags: uint8
var
  vifs: array[MAX_VIFS, VifChannelView]
  env: RxEnv
  interrupts = true
  vifKeyPrngState = 1'u32
  rxMgtReplayStates: array[STA_INFO_TAB_ENTRIES + MAX_VIFS * 6, KeyReplayCounterView]
  rxMgtReplayValid: array[STA_INFO_TAB_ENTRIES + MAX_VIFS * 6, bool]
proc irqSave(): uint32 =
  result = interrupts.uint32 * 8
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = (saved and 8) != 0
proc rxKeyChange(key: pointer) = discard
proc vifChannelAt(p: pointer): ptr VifChannelView = cast[ptr VifChannelView](p)
proc vifChannelForIdx(i: uint8): ptr VifChannelView = addr vifs[i]
proc vifMgmtAddKeyParamView(p: pointer): ptr VifMgmtAddKeyParamView =
  cast[ptr VifMgmtAddKeyParamView](p)
proc rxuCntrlEnvView(): ptr RxEnv = addr env
template replayCounterStateView(p: pointer): ptr ReplayCounterStateView =
  cast[ptr ReplayCounterStateView](p)
proc le32(p: pointer): uint32 =
  let bytes = cast[ptr UncheckedArray[uint8]](p)
  for i in 0 ..< 4: result = result or (bytes[i].uint32 shl (8 * i))
'''


def source() -> str:
    rx = (FW / "rx_upper.nim").read_text()
    sta = (FW / "sta_management.nim").read_text()
    vif = (FW / "vif_management.nim").read_text()
    layout = (FW / "layout_types.nim").read_text()
    code = "const MAX_VIFS = 2\nconst STA_INFO_TAB_ENTRIES = 7\nconst RxuMgmtPnTid = 8'u8\n"
    base = harness(replay_stubs=False).replace(
        "proc vifReuseBipKey(param: pointer; hwKeyIdx: uint8): bool = false\n", "")
    code += base + layouts(
        "KeyReplayCounterView", "VifKeySlotView", "VifKeySlotTableOverlay",
        "VifKeyPointersView", "VifMgmtAddKeyParamView",
    ) + "type ReplayCounterStateView = KeyReplayCounterView\n" + SUPPORT
    code += "template vifKeySlotTable(" + layout.split("template vifKeySlotTable(", 1)[1].split(
        "template vifRxProtectedKeySlot(", 1)[0]
    code += "template vifKeyPointersAt(" + layout.split("template vifKeyPointersAt(", 1)[1].split(
        "template txSecurityKeyListAt(", 1)[0]
    code += (FW / "key_install_policy.nim").read_text()
    code += procedure((FW / "mac_config_debug.nim").read_text(), "replay_counter_validate")
    if "proc rxMgtKeyIndex(" in rx:
        for name in ["rxMgtKeyIndex", "rxMgtReplayReset", "rxMgtReplayForget", "rxMgtReplayCounter"]:
            code += procedure(rx, name)
    else:
        code += "proc rxMgtReplayCounter(key: pointer): ptr KeyReplayCounterView = nil\n"
        code += "proc rxMgtReplayReset(key: pointer) = discard\n"
    bodies = procedure(rx, "rxu_cntrl_check_pn")
    for text, names in [(sta, ["sta_mgmt_add_key", "sta_mgmt_del_key"]),
                        (vif, ["vifReuseBipKey", "vif_mgmt_add_key", "vif_mgmt_del_key"])]:
        for name in names:
            bodies += procedure(text, name)
    code += "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", bodies)))
    )
    return code + bodies + r'''
proc keyAt(index: int): ptr VifKeySlotView =
  if index < STA_INFO_TAB_ENTRIES:
    cast[ptr VifKeySlotView](addr sta_info_tab[index].keyArea[0])
  else:
    let offset = index - STA_INFO_TAB_ENTRIES
    vifKeySlot(addr vifs[offset div 6], (offset mod 6).uint)
proc install(index: int; windowed: bool; seed = 0'u64; cipher = 2'u8) =
  if index < STA_INFO_TAB_ENTRIES:
    var request = MachwKeyWriteParamView(keyType: index.uint8,
      cipherType: cipher, keyFlags: windowed.uint8)
    sta_mgmt_add_key(addr request, (index + 8).uint8)
  else:
    let offset = index - STA_INFO_TAB_ENTRIES
    var request = VifMgmtAddKeyParamView(staIdx: (offset mod 6).uint8,
      keySlot: (offset div 6).uint8, cipherType: cipher, hasRxPn: windowed.uint8)
    for i in 0 ..< 4:
      request.pnLowBytes[i] = ((seed shr (8 * i)) and 255).uint8
      request.pnHighBytes[i] = ((seed shr (32 + 8 * i)) and 255).uint8
    vif_mgmt_add_key(addr request, index.uint8)
proc remove(index: int) =
  if index < STA_INFO_TAB_ENTRIES:
    sta_mgmt_del_key(addr sta_info_tab[index])
  else:
    let offset = index - STA_INFO_TAB_ENTRIES
    vif_mgmt_del_key(addr vifs[offset div 6], (offset mod 6).uint8)
proc receive(key: ptr VifKeySlotView; pn: uint64; tid = RxuMgmtPnTid): cint =
  env.secInfo0 = (pn and 0xFFFFFFFF'u64).uint32
  env.secInfo1 = (pn shr 32).uint32
  rxu_cntrl_check_pn(key, tid)
'''


CASES = {
    "strict": r'''
for index in 0 ..< rxMgtReplayStates.len:
  install(index, false)
  let key = keyAt(index)
  key.pnLow = 0xAABBCCDD'u32
  key.pnHigh = 0x12345678
  for counter in key.replayCounters.mitems: counter.pnLow = 10000
  let before = key[]
  doAssert receive(key, 1) == 1
  doAssert receive(key, 1) == 0
  doAssert receive(key, 2) == 1
  doAssert key[] == before, "management RX changed data or TX state"
''',
    "windowed": r'''
for index in 0 ..< rxMgtReplayStates.len:
  install(index, true)
  let key = keyAt(index)
  key.replayCounters[0].pnLow = 10000
  key.pnLow = 12345
  let before = key[]
  doAssert receive(key, 70) == 1
  doAssert receive(key, 69) == 1
  doAssert receive(key, 70) == 0
  doAssert receive(key, 1) == 0
  doAssert key[] == before
''',
    "windowed_wide_jumps": r'''
for index in 0 ..< rxMgtReplayStates.len:
  for extra in [0'u64, 32]:
    install(index, true)
    let key = keyAt(index)
    key.replayCounters[0].pnLow = 10000
    key.pnLow = 12345
    let before = key[]
    doAssert receive(key, 1) == 1
    let high = (1'u64 shl 37) + 1 + extra
    doAssert receive(key, high) == 1
    if extra != 0: doAssert receive(key, high - 32) == 1
    doAssert receive(key, high) == 0
    doAssert key[] == before, "management jump modified data counters or TX PN"
''',
    "lifecycle": r'''
for index in 0 ..< rxMgtReplayStates.len:
  for windowed in [false, true]:
    for enabled in [false, true]:
      interrupts = enabled
      install(index, windowed)
      let key = keyAt(index)
      doAssert receive(key, 100) == 1
      remove(index)
      doAssert receive(key, 101) == 0
      doAssert not rxMgtReplayValid[index]
      install(index, windowed)
      doAssert receive(key, 1) == 1
      doAssert interrupts == enabled
''',
    "seed": r'''
for index in STA_INFO_TAB_ENTRIES ..< rxMgtReplayStates.len:
  for windowed in [false, true]:
    for seed in [1'u64, 31, 32, 0xFFFFFFFF'u64, 0x100000000'u64]:
      install(index, windowed, seed)
      let key = keyAt(index)
      doAssert receive(key, seed) == 0
      doAssert receive(key, seed + 1) == 1
      doAssert receive(key, seed + 1) == 0
''',
    "isolation": r'''
for windowed in [false, true]:
  for index in 0 ..< rxMgtReplayStates.len: install(index, windowed)
  for index in 0 ..< rxMgtReplayStates.len:
    let key = keyAt(index)
    let others = rxMgtReplayStates
    doAssert receive(key, 200, 0) == 1
    doAssert receive(key, 1) == 1
    for other in 0 ..< rxMgtReplayStates.len:
      if other != index: doAssert rxMgtReplayStates[other] == others[other]
    doAssert receive(key, 2) == 1
    doAssert receive(key, 201, 0) == 1
''',
    "invalid": r'''
var detached: VifKeySlotView
for tid in [0'u8, 8, 9, 255]: doAssert receive(nil, 1, tid) == 0
doAssert receive(addr detached, 1) == 0
for index in 0 ..< rxMgtReplayStates.len:
  install(index, false)
  let key = keyAt(index)
  let before = key[]
  for tid in 9'u16 .. 255'u16:
    doAssert receive(key, 1, tid.uint8) == 0
  doAssert key[] == before
  remove(index)
  doAssert rxMgtReplayCounter(key) == nil
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_management_receive_counter(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


@pytest.mark.parametrize("case", ["strict", "invalid"])
def test_management_receive_counter_unchecked(tmp_path: Path, case: str) -> None:
    code = source()
    body = procedure((FW / "rx_upper.nim").read_text(), "rxu_cntrl_check_pn")
    assert code.count(body) == 1
    code = code.replace(body, "{.push checks:off.}\n" + body + "{.pop.}\n", 1)
    run_program(tmp_path, "release", code + CASES[case])
