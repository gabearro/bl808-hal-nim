"""Native TPC tests against the pinned BL808 tpc.o control flow and ABI."""

import os
from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import FW, ROOT, procedure


PLATFORM = r"""
const
  MACHW_TX_POWER_REG = 0x24B000A0'u
  StaTxPolicyUpdateTxPower = 16'u8
type
  CoListHdr = object
    next: ptr CoListHdr
  Sta = object
    link: CoListHdr
    txPolicyUpdateFlags: array[1, uint8]
  Channel = object
    txPower: uint8
  Context = object
    linkCount: uint8
    channel: Channel
  Vif = object
    txPower, maxTxPower: int8
    postponedStaHead, chanCtxt: pointer
  Rate = object
    rateWord: uint32
    txPower: int32
  Hw = object
    chainedThd: pointer
  Frame = object
    hwDesc: pointer
var
  vifs: array[2, Vif]
  contexts: array[2, Context]
  stations: array[2, Sta]
  onChannel: bool
  powerRegister: uint32
  registerWrites: seq[uint32]
  rfCalls: seq[tuple[group: uint32, index: uint8]]
  ratePowers: array[24, int8]
  phyCalls: int
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc staInfoAt(p: pointer): ptr Sta = cast[ptr Sta](p)
proc chanCtxtAt(p: pointer): ptr Context = cast[ptr Context](p)
proc hostTxDescAt(p: pointer): ptr Frame = cast[ptr Frame](p)
proc hostTxHwDescAt(p: pointer): ptr Hw = cast[ptr Hw](p)
proc hostTxRateTemplateAt(p: pointer): ptr Rate = cast[ptr Rate](p)
proc chan_is_on_channel(p: pointer): bool {.cdecl.} =
  doAssert p == addr vifs[0]
  onChannel
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_TX_POWER_REG
  powerRegister
proc regWrite(address: uint; value: uint32) =
  doAssert address == MACHW_TX_POWER_REG
  powerRegister = value
  registerWrites.add(value)
proc c_memset(p: pointer; value: cint; n: csize_t): pointer =
  doAssert value == 0
  zeroMem(p, n.int)
  p
proc c_memcpy(dst, src: pointer; n: csize_t): pointer =
  copyMem(dst, src, n.int)
  dst
proc bl_tpc_power_table_get(p: ptr array[38, int8]) =
  for i in 0 ..< ratePowers.len:
    p[i] = ratePowers[i]
  for i in 24 ..< 38:
    p[i] = 127
proc trpc_get_default_power_idx(group: uint32; index: uint8): int8 =
  rfCalls.add((group, index))
  cast[int8]((group * 73 + index.uint32 * 13 + 128) and 255)
"""


def source() -> str:
    tpc = (FW / "tx_power_control.nim").read_text()
    phy = procedure(
        (FW / "global_state/rf_bl808_core.nim").read_text(), "phy_get_rf_gain_idx"
    ).replace("  var power =", "  inc phyCalls\n  var power =", 1)
    result = PLATFORM + procedure((FW / "power_save.nim").read_text(), "bl_pwr_find")
    result += phy
    result += procedure((FW / "kernel_mac_channel.nim").read_text(), "chan_update_tx_power")
    for name in ["tpc_update_tx_power", "tpc_get_vif_tx_power", "tpc_update_vif_tx_power",
                 "tpc_get_vif_tx_power_vs_rate", "tpc_update_frame_tx_power"]:
        result += procedure(tpc, name)
    return result


def run(tmp_path: Path, mode: str, body: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim compiler is unavailable")
    path = tmp_path / "tx_power.nim"
    path.write_text(source() + body)
    flags = ["--checks:on"] if mode == "checked" else ["-d:release", "--checks:off"]
    if mode == "asan":
        flags += ["--passC:-fsanitize=address", "--passC:-fno-omit-frame-pointer",
                  "--passL:-fsanitize=address"]
    result = subprocess.run(
        [nim, "c", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}", *flags, str(path)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90,
    )
    assert result.returncode == 0, result.stdout
    result = subprocess.run(
        [str(tmp_path / "test")], cwd=ROOT, text=True,
        env={**os.environ, "ASAN_OPTIONS": "detect_leaks=0"},
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30,
    )
    assert result.returncode == 0, result.stdout


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_power_indices_and_table_scan(mode, tmp_path):
    run(tmp_path, mode, r"""
# Compile-check the exported ABI, not just the returned low byte.
let getter: proc(vif: pointer): uint8 {.cdecl.} = tpc_get_vif_tx_power
for value in 0'u32 .. 255:
  powerRegister = 0xD391A700'u32 or value
  doAssert getter(nil).uint32 == value
  doAssert getter(addr vifs[0]).uint32 == value
doAssert registerWrites.len == 0
doAssert bl_pwr_find(nil, 0) == 0
doAssert bl_pwr_find(nil, 4) == 0
var levels: array[513, int8]
for count in [1, 2, 8, 255, 256, 257, 513]:
  for maximum in 0 ..< count:
    for i in 0 ..< count: levels[i] = -128
    levels[maximum] = 127
    doAssert bl_pwr_find(addr levels[0], count.uint32) == maximum.uint32
  for i in 0 ..< count: levels[i] = -1
  doAssert bl_pwr_find(addr levels[0], count.uint32) == 0
for first in -128 .. 127:
  for second in -128 .. 127:
    levels[0] = first.int8
    levels[1] = second.int8
    let expected = if second > first: 1'u32 else: 0'u32
    doAssert bl_pwr_find(addr levels[0], 2) == expected

var rate = Rate(rateWord: 0x80000807'u32, txPower: 0x12345678)
var hw = Hw(chainedThd: addr rate)
var frame = Frame(hwDesc: addr hw)
tpc_update_frame_tx_power(addr vifs[0], nil)
frame.hwDesc = nil
tpc_update_frame_tx_power(addr vifs[0], addr frame)
frame.hwDesc = addr hw
hw.chainedThd = nil
tpc_update_frame_tx_power(addr vifs[0], addr frame)
doAssert rfCalls.len == 0 and rate.txPower == 0x12345678
hw.chainedThd = addr rate
for group in 0'u32 .. 2:
  for index in 0'u32 .. 7:
    if group == 0 and index > 3: continue
    rate.rateWord = 0x80000000'u32 or
      (if group == 2: 0x800'u32 or index
       elif group == 1: index + 4 else: index)
    let original = rate.rateWord
    tpc_update_frame_tx_power(addr vifs[0], addr frame)
    doAssert rate.rateWord == original
    doAssert rate.txPower == ((group * 73 + index * 13 + 128) and 255).int32
    doAssert rfCalls[^1] == (group, index.uint8)
""")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_power_table_selection_and_register_masks(mode, tmp_path):
    run(tmp_path, mode, r"""
for group in 0 .. 2:
  for maximum in 0 .. 7:
    for i in 0 ..< ratePowers.len: ratePowers[i] = 1
    ratePowers[group * 8 + maximum] = 22
    for requested in [0'u8, 1, 127, 255]:
      powerRegister = 0xDEADBEEF'u32
      registerWrites.setLen(0)
      rfCalls.setLen(0)
      tpc_update_tx_power(requested)
      let selectedGroup = if group == 2: 2'u32 else: 1'u32
      let selectedIndex = if group == 0: 0'u8 else: maximum.uint8
      let selected11b = if group == 0: maximum.uint8 else: 0'u8
      doAssert rfCalls == @[(selectedGroup, selectedIndex), (0'u32, selected11b)]
      doAssert registerWrites == @[0xDEADBE40'u32, 0xDEAD4840'u32]
      doAssert powerRegister == 0xDEAD4840'u32
# Equal positive maxima prefer the first rate and 11g over 11n.
for i in 0 ..< ratePowers.len: ratePowers[i] = 10
rfCalls.setLen(0)
tpc_update_tx_power(0)
doAssert rfCalls == @[(1'u32, 0'u8), (0'u32, 0'u8)]
# The vendor seeds the cross-family winner at zero, even for negative tables.
for ofdm in [-128, -10, 0, 1, 22, 127]:
  for ht in [-128, -10, 0, 1, 22, 127]:
    for i in 0 ..< ratePowers.len: ratePowers[i] = -128
    ratePowers[6] = 7
    ratePowers[8 + 3] = ofdm.int8
    ratePowers[16 + 5] = ht.int8
    var selected = (0'u32, 0'u8)
    var best = 0
    if ofdm > best:
      best = ofdm
      selected = (1'u32, 3'u8)
    if ht > best:
      selected = (2'u32, 5'u8)
    rfCalls.setLen(0)
    tpc_update_tx_power(0)
    doAssert rfCalls == @[selected, (0'u32, 6'u8)]
""")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_vif_power_limits_and_channel_updates(mode, tmp_path):
    run(tmp_path, mode, r"""
proc clampPhy(power: int): int = min(22, max(-10, power))
for oldPower in [-10, 0, 8, 22, 127]:
  for userLimit in [-128, -10, 0, 8, 22, 127]:
    for requested in -128 .. 127:
      for sameChannel in [false, true]:
        for isOnChannel in [false, true]:
          vifs = default(typeof(vifs))
          contexts = default(typeof(contexts))
          stations = default(typeof(stations))
          contexts[0].linkCount = 2
          contexts[0].channel.txPower = 75
          vifs[0] = Vif(txPower: oldPower.int8, maxTxPower: userLimit.int8,
            chanCtxt: addr contexts[0], postponedStaHead: addr stations[0])
          vifs[1] = Vif(txPower: 3, maxTxPower: 1,
            chanCtxt: (if sameChannel: addr contexts[0] else: addr contexts[1]))
          stations[0].link.next = addr stations[1].link
          stations[0].txPolicyUpdateFlags[0] = 0x82
          stations[1].txPolicyUpdateFlags[0] = 1
          onChannel = isOnChannel
          phyCalls = 0
          rfCalls.setLen(0)
          registerWrites.setLen(0)
          var power = requested.int8
          var index = 0xA5'u8
          tpc_update_vif_tx_power(addr vifs[0], addr power, addr index)
          if requested == 127:
            doAssert phyCalls == 0 and power == 127 and index == 0xA5
            doAssert vifs[0].txPower == oldPower.int8
            doAssert contexts[0].channel.txPower == 75
            doAssert rfCalls.len == 0 and registerWrites.len == 0
            continue
          let phyPower = clampPhy(requested)
          let limited = phyPower > userLimit
          let returned = if limited: clampPhy(userLimit) else: phyPower
          doAssert phyCalls == (if limited: 2 else: 1)
          doAssert power.int == returned and index == cast[uint8](power)
          # Match the vendor's two separate stored-power and user-limit fields.
          doAssert vifs[0].txPower.int == phyPower
          doAssert vifs[0].maxTxPower.int == userLimit
          let changed = returned != oldPower
          doAssert stations[0].txPolicyUpdateFlags[0] == (if changed: 0x92 else: 0x82)
          doAssert stations[1].txPolicyUpdateFlags[0] == (if changed: 0x11 else: 1)
          let effective = min(phyPower, userLimit)
          let expected = if sameChannel: min(effective, 1) else: effective
          doAssert contexts[0].channel.txPower ==
            (if changed: cast[uint8](expected.int8) else: 75'u8)
          doAssert rfCalls.len == (if changed and isOnChannel: 2 else: 0)
          doAssert registerWrites.len == rfCalls.len

# No channel: mark attached stations but do not program MAC power.
vifs[0] = Vif(txPower: 0, maxTxPower: 127, postponedStaHead: addr stations[0])
stations[0] = default(Sta)
rfCalls.setLen(0)
var power = 15'i8
var index: uint8
tpc_update_vif_tx_power(addr vifs[0], addr power, addr index)
doAssert vifs[0].txPower == 15 and stations[0].txPolicyUpdateFlags[0] == 16
doAssert rfCalls.len == 0
""")
