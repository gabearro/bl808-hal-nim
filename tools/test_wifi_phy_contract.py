"""PHY read/write contracts and initial rate-power bytes from named RF data."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_rf_channel_entry import rf_procedure
from test_wifi_rf_power_replay import RF, object_type


def source() -> str:
    rf = RF.read_text()
    code = object_type(rf, "PhyEnvView") + r'''
var
  phy_env {.align: 4.}: array[48, uint8]
  versionWords: seq[uint32]
  versionReads: int
  channelReads: seq[tuple[offset, width: int]]
proc volatileLoad[T](p: ptr T): T =
  channelReads.add((cast[int](p) - cast[int](addr phy_env[0]), sizeof(T)))
  p[]
template phyEnvViewPtr(): ptr PhyEnvView = cast[ptr PhyEnvView](addr phy_env[0])
proc modemVersionReg(): uint32 =
  result = versionWords[min(versionReads, versionWords.len - 1)]
  inc versionReads
'''
    code += rf[rf.index("var trpcTxpwrVsRateTable*"):].split("\nvar trpcEnv", 1)[0] + "\n"
    for name in ("phy_vht_supported", "phy_get_channel_raw", "phy_get_rf_gain_idx",
                 "phy_get_rf_gain_capab", "trpc_get_default_power_idx"):
        code += rf_procedure(rf, name)
    return code


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_phy_vht_uses_conditional_second_version_read(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for firstFlag in [false, true]:
  for firstBw in 0'u32 .. 3:
    for secondFlag in [false, true]:
      for secondBw in 0'u32 .. 3:
        let unrelated = 0xA5A55A5A'u32 and not 0x03400000'u32
        versionWords = @[
          unrelated or (firstFlag.uint32 shl 22) or (firstBw shl 24),
          unrelated or (secondFlag.uint32 shl 22) or (secondBw shl 24)]
        versionReads = 0
        doAssert phy_vht_supported() == (firstFlag or secondBw != 0),
          "VHT bandwidth must come from the conditional second register read"
        doAssert versionReads == (if firstFlag: 1 else: 2)
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_phy_channel_getter_snapshots_both_words_before_output(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for seed in [0, 1, 127, 255]:
  for outputOffset in countup(0, 40, 4):
    for ignoredIndex in [0'u8, 1, 255]:
      for i in 0 ..< phy_env.len: phy_env[i] = ((seed + i * 31) mod 256).uint8
      let before = phy_env
      var expected = before
      for i in 0 ..< 8: expected[outputOffset + i] = before[36 + i]
      channelReads.setLen(0)
      phy_get_channel_raw(addr phy_env[outputOffset], ignoredIndex)
      doAssert channelReads == @[(36, 4), (40, 4)], "channel fields must be sampled as two words"
      doAssert phy_env == expected, "channel output was written before all source fields were sampled"
channelReads.setLen(0)
phy_get_channel_raw(nil, 255)
doAssert channelReads.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_phy_gain_clamp_values_aliases_and_guards(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for raw in 0 .. 255:
  for aliased in [false, true]:
    var bytes = [0xA5'u8, raw.uint8, 0xCC, 0x5A]
    let signed = if raw < 128: raw else: raw - 256
    let wanted = max(-10, min(22, signed))
    let output = if aliased: addr bytes[1] else: addr bytes[2]
    phy_get_rf_gain_idx(addr bytes[1], output)
    doAssert cast[int8](bytes[1]).int == wanted and cast[int8](output[]).int == wanted
    doAssert bytes[0] == 0xA5 and bytes[3] == 0x5A
var shared: int8
phy_get_rf_gain_capab(addr shared, addr shared)
doAssert shared == -10
var a = -77'i8
var b = 99'i8
phy_get_rf_gain_capab(addr a, addr b)
doAssert a == 22 and b == -10
phy_get_rf_gain_idx(nil, addr a)
phy_get_rf_gain_idx(addr b, nil)
doAssert a == 22 and b == -10
phy_get_rf_gain_capab(nil, nil)
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_phy_gain_in_range_input_is_not_written(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
var
  protRead {.importc: "PROT_READ", nodecl, header: "<sys/mman.h>".}: cint
  protWrite {.importc: "PROT_WRITE", nodecl, header: "<sys/mman.h>".}: cint
  mapPrivate {.importc: "MAP_PRIVATE", nodecl, header: "<sys/mman.h>".}: cint
  mapAnon {.importc: "MAP_ANON", nodecl, header: "<sys/mman.h>".}: cint
proc getpagesize(): cint {.importc, header: "<unistd.h>".}
proc mmap(address: pointer; length: csize_t; protection, flags, fd: cint;
          offset: clong): pointer {.importc, header: "<sys/mman.h>".}
proc mprotect(address: pointer; length: csize_t; protection: cint): cint
  {.importc, header: "<sys/mman.h>".}
proc munmap(address: pointer; length: csize_t): cint {.importc, header: "<sys/mman.h>".}
let pageSize = getpagesize().csize_t
for value in -10 .. 22:
  let page = mmap(nil, pageSize, protRead or protWrite, mapPrivate or mapAnon, -1, 0)
  doAssert page != cast[pointer](high(uint))
  cast[ptr int8](page)[] = value.int8
  doAssert mprotect(page, pageSize, protRead) == 0
  var result = 99'u8
  phy_get_rf_gain_idx(page, addr result)
  doAssert cast[int8](result).int == value
  doAssert munmap(page, pageSize) == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_trpc_initial_table_matches_all_fifty_vendor_bytes(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
const expected = [
  21'u8,21,21,21,0,0,0,0,0,0,
  20'u8,20,20,20,20,20,18,18,0,0,
  20'u8,20,20,20,20,19,17,17,0,0,
  18'u8,18,18,18,18,16,16,16,16,16,
  20'u8,20,20,20,20,19,17,17,15,15]
doAssert trpcTxpwrVsRateTable == expected,
  "initial MCS-4 power bytes differ from .data.txpwr_vs_rate_table"
for group in 0'u32 .. 4:
  for index in 0'u8 .. 9:
    doAssert cast[uint8](trpc_get_default_power_idx(group, index)) ==
      ((expected[group.int * 10 + index.int].uint32 * 4) and 252).uint8
doAssert trpcTxpwrVsRateTable == expected
''')
