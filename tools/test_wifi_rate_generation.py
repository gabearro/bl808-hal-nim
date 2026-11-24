"""Compare BL808 initial/lowest/random rate selection with the vendor object."""

from pathlib import Path
import os
import shutil
import struct
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
const
  RC_PRNG_MULT = 0x41C64E6D'u32
  RC_PRNG_INCR = 0x3039'u32
  RC_RATE_ENTRY_SIZE = 12
  RC_MAX_RATE_ENTRIES = 10
  RCS_FORMAT_MOD = 177
  RCS_RATE_BITMAP = 178
  RCS_RATE_MAP = 182
  RCS_MAX_NSS_MCS = 184
  RCS_LOWEST_IDX = 185
  RCS_HIGHEST_IDX = 186
  RCS_NO_SS = 187
  RCS_GROUP_CNT = 188
  RCS_SHORT_GI = 189
  RCS_PREAMBLE_TYPE = 190
  RCS_N_RATES = 192
  RCS_RATE_MAP_L = 194
proc rcU8(p: pointer; offset: int): var uint8 =
  cast[ptr uint8](cast[uint](p) + offset.uint)[]
proc rcU16(p: pointer; offset: int): var uint16 =
  cast[ptr uint16](cast[uint](p) + offset.uint)[]
"""

HARNESS = r"""
const stride = 204 + 65536 * 2
let data = readFile(vectorPath)
doAssert data.len mod stride == 0
var state: array[200, uint8]
let stats = addr state[0]
doAssert rcPrngState == 1'u32, "incorrect cold-boot PRNG seed"
for start in countup(0, data.len - stride, stride):
  copyMem(stats, unsafeAddr data[start], 200)
  var expected: array[2, uint16]
  copyMem(addr expected[0], unsafeAddr data[start + 200], 4)
  doAssert rc_get_initial_rate_config(stats) == expected[0], "initial rate profile " & $(start div stride)
  doAssert rc_get_lowest_rate_config(stats) == expected[1], "lowest rate profile " & $(start div stride)
  for high in 0 .. 65535:
    let nextState = high.uint32 shl 16
    rcPrngState = (nextState - RC_PRNG_INCR) * prngInverse
    var expectedRandom: uint16
    copyMem(addr expectedRandom, unsafeAddr data[start + 204 + high * 2], 2)
    let before = state
    doAssert rc_new_random_rate(stats) == expectedRandom,
      "random rate profile " & $(start div stride) & " high=" & $high
    doAssert rcPrngState == nextState, "PRNG did not advance exactly once"
    doAssert state == before, "rate selection modified the station"
rcPrngState = 0x12345678
doAssert rc_new_random_rate(nil) == 0xFFFF
doAssert rcPrngState == 0x12345678
doAssert rc_get_initial_rate_config(nil) == 0xFFFF
doAssert rc_get_lowest_rate_config(nil) == 0xFFFF
state = default(typeof(state))
rcU8(stats, RCS_FORMAT_MOD) = 2
rcU8(stats, RCS_LOWEST_IDX) = 4
rcU8(stats, RCS_MAX_NSS_MCS) = 7
doAssert rc_get_initial_rate_config(stats) == 0xFFFF
doAssert rc_new_random_rate(stats) == 0xFFFF
rcU8(stats, RCS_GROUP_CNT) = 4
doAssert rc_get_initial_rate_config(stats) == 0xFFFF
doAssert rc_new_random_rate(stats) == 0xFFFF
rcU8(stats, RCS_GROUP_CNT) = 0
rcU8(stats, RCS_RATE_BITMAP) = 0xFF
rcU8(stats, RCS_NO_SS) = 4
doAssert rc_get_initial_rate_config(stats) == 0xFFFF
doAssert rc_new_random_rate(stats) == 0xFFFF
rcU8(stats, RCS_NO_SS) = 0
rcU8(stats, RCS_SHORT_GI) = 2
doAssert rc_get_initial_rate_config(stats) == 0xFFFF
state = default(typeof(state))
rcU8(stats, RCS_LOWEST_IDX) = 10
rcU8(stats, RCS_HIGHEST_IDX) = 3
doAssert rc_new_random_rate(stats) == 0xFFFF
rcU8(stats, RCS_LOWEST_IDX) = 3
doAssert rc_new_random_rate(stats) == 0xFFFF
rcU8(stats, RCS_LOWEST_IDX) = 16
doAssert rc_get_lowest_rate_config(stats) == 0xFFFF
rcU8(stats, RCS_HIGHEST_IDX) = 16
doAssert rc_get_initial_rate_config(stats) == 0xFFFF
"""

PICKER = r"""
var state: array[200, uint8]
let stats = addr state[0]
doAssert rc_pick_non_duplicate_rate(nil) == 0xFFFF
rcU8(stats, RCS_FORMAT_MOD) = 0
rcU8(stats, RCS_LOWEST_IDX) = 3
rcU8(stats, RCS_HIGHEST_IDX) = 3
rcU16(stats, RCS_RATE_MAP) = 1'u16 shl 3
doAssert rc_pick_non_duplicate_rate(stats) in [3'u16, 0x403'u16]
rcU16(stats, 10) = 3
rcU16(stats, 22) = 0x403
rcU16(stats, RCS_N_RATES) = 2
rcPrngState = 0
var expectedState = 0'u32
for i in 0 ..< RcRandomRateAttemptLimit:
  expectedState = expectedState * RC_PRNG_MULT + RC_PRNG_INCR
doAssert rc_pick_non_duplicate_rate(stats) == 0xFFFF
doAssert rcPrngState == expectedState, "exhaustion was not bounded"

# Simulate repeated empty-group results with one supported MCS in NSS group 2.
# The fallback must enumerate all of its allowed bandwidth/GI combinations.
state = default(typeof(state))
rcU8(stats, RCS_FORMAT_MOD) = 2
rcU8(stats, RCS_LOWEST_IDX) = 4
rcU8(stats, RCS_HIGHEST_IDX) = 11
rcU8(stats, RCS_NO_SS) = 2
rcU8(stats, RCS_GROUP_CNT) = 3
rcU8(stats, RCS_MAX_NSS_MCS) = 7
rcU8(stats, RCS_SHORT_GI) = 1
rcU8(stats, RCS_RATE_BITMAP + 2) = 1'u8 shl 5
forceEmptyGroup = true
randomCalls = 0
doAssert rc_pick_non_duplicate_rate(stats) == 0x1295'u16
doAssert randomCalls == RcRandomRateAttemptLimit
doAssert rc_check_rate_duplicated(stats, 0x1295) == 0
rcU16(stats, 10) = 0x1295
rcU16(stats, RCS_N_RATES) = 1
doAssert rc_pick_non_duplicate_rate(stats) == 0x1095
rcU16(stats, 22) = 0x1095
rcU16(stats, RCS_N_RATES) = 2
doAssert rc_pick_non_duplicate_rate(stats) == 0x1315
rcU16(stats, 34) = 0x1315
rcU16(stats, RCS_N_RATES) = 3
doAssert rc_pick_non_duplicate_rate(stats) == 0x1115
rcU16(stats, 46) = 0x1115
rcU16(stats, RCS_N_RATES) = 4
doAssert rc_pick_non_duplicate_rate(stats) == 0xFFFF
rcU16(stats, RCS_N_RATES) = 11
doAssert rc_pick_non_duplicate_rate(stats) == 0xFFFF
rcU16(stats, 130) = 0xBEEF # Outside the ten-entry rate table.
doAssert rc_check_rate_duplicated(stats, 0xBEEF) == 0
doAssert rc_check_rate_duplicated(nil, 0xBEEF) == 0

# Match the range of bit 10 in the HT-to-legacy random generator, including
# nonzero OFDM indices in the deterministic exhaustion path.
state = default(typeof(state))
rcU8(stats, RCS_FORMAT_MOD) = 2
rcU8(stats, RCS_LOWEST_IDX) = 3
rcU8(stats, RCS_HIGHEST_IDX) = 4
rcU8(stats, RCS_PREAMBLE_TYPE) = 1
rcU8(stats, RCS_RATE_BITMAP) = 1
rcU16(stats, RCS_RATE_MAP) = (1'u16 shl 3) or (1'u16 shl 4)
rcU16(stats, RCS_N_RATES) = 2
rcU16(stats, 10) = 0x403
rcU16(stats, 22) = 0x1000
doAssert rc_pick_non_duplicate_rate(stats) == 0x404
rcU16(stats, 34) = 0x404
rcU16(stats, RCS_N_RATES) = 3
doAssert rc_pick_non_duplicate_rate(stats) == 0xFFFF
"""


def capabilities(fmt: int, lo: int, hi: int, rates: int, bitmaps: list[int],
                 bandwidth: int = 0, nss: int = 0, mcs: int = 7,
                 gi: int = 0, preamble: int = 0) -> bytearray:
    state = bytearray(200)
    state[177] = fmt
    state[178:182] = bytes(bitmaps)
    struct.pack_into("<H", state, 182, rates)
    state[184:191] = bytes([mcs, lo, hi, bandwidth, nss, gi, preamble])
    struct.pack_into("<H", state, 194, 0xBEEF)  # Must never be a rate bitmap.
    return state


def initial_rate(state: bytes) -> int:
    fmt = state[177]
    if fmt < 2:
        return (fmt << 11) | (state[190] << 10) | state[186]
    if fmt > 3:
        return 0
    bitmap = state[178 + state[188]]
    return ((fmt << 11) | (state[189] << 9) | (state[187] << 7) |
            (state[188] << 3) | (bitmap.bit_length() - 1))


def lowest_rate(state: bytes) -> int:
    fmt, lo = state[177], state[185]
    if fmt > 3:
        return 0
    if lo == 0:
        return 0x400
    return lo if fmt < 2 else fmt << 11


def random_rate(state: bytes, high: int) -> int:
    fmt = state[177]
    if fmt > 3:
        return (fmt << 11) & 65535
    legacy = fmt < 2 or (state[185] <= 3 and high & 0x800)
    if legacy:
        low, top = state[185:187]
        index = low + (high & 127) % (top - low + 1)
        bitmap = struct.unpack_from("<H", state, 182)[0]
        if not (bitmap >> index) & 1:
            index = top
        result = (fmt << 11) if fmt < 2 else 0
        result |= index
        if index == 0:
            return result | 0x400
        if fmt >= 2 or index <= 3:
            result |= (state[190] << 10) | (high & 0x400)
        return result
    nss = ((high >> 3) & 3) % (state[188] + 1)
    mcs = (high & 7) % (state[184] + 1)
    bitmap = state[178 + nss]
    if not (bitmap >> mcs) & 1:
        mcs = bitmap.bit_length() - 1
    gi = ((high >> 9) & 1) % (state[189] + 1)
    minimum_bandwidth = max(state[187] - 1, 0)
    bandwidth = minimum_bandwidth + ((high >> 7) & 3) % (state[187] - minimum_bandwidth + 1)
    return (fmt << 11) | (nss << 3) | mcs | (gi << 9) | (bandwidth << 7)


def vectors() -> bytes:
    profiles = [
        capabilities(0, 0, 11, 0xFFF, [0, 0, 0, 0]),
        capabilities(1, 1, 3, 0xA, [0, 0, 0, 0], preamble=1),
        capabilities(0, 3, 3, 8, [0, 0, 0, 0]),
        capabilities(1, 0, 0, 1, [0, 0, 0, 0]),
        capabilities(0, 4, 11, 0xA50, [0, 0, 0, 0]),
        capabilities(2, 0, 11, 0xFFF, [0xFF, 0x0F, 0, 0], bandwidth=1, nss=1, gi=1, preamble=1),
        capabilities(3, 4, 11, 0xFF0, [0x55, 0xAA, 0x81, 0x42], bandwidth=3, nss=3),
        capabilities(2, 0, 3, 0xB, [0xFF, 0, 0, 0]),
        capabilities(3, 3, 11, 0xF88, [0x5, 0xA, 0x9, 0], bandwidth=2, nss=2, mcs=3, gi=1),
        capabilities(2, 4, 11, 0xFF0, [0xFF, 0, 0, 0], mcs=255),
        capabilities(2, 4, 11, 0xFF0, [1, 0, 0, 0], mcs=0),
        capabilities(4, 4, 11, 0xFF0, [0xFF, 0, 0, 0]),
    ]
    data = bytearray()
    for state in profiles:
        data += state + struct.pack("<HH", initial_rate(state), lowest_rate(state))
        for high in range(65536):
            data += struct.pack("<H", random_rate(state, high))
    return bytes(data)


def prelude() -> tuple[str, str, str]:
    helpers = (FW / "runtime_helpers.nim").read_text()
    source = (FW / "rate_control.nim").read_text()
    layout = (FW / "layout_types.nim").read_text()
    code = PLATFORM
    storage = (FW / "global_state/storage.nim").read_text()
    seed = next(line.strip() for line in storage.splitlines() if line.lstrip().startswith("rcPrngState* "))
    code += f"\nvar {seed}\n"
    if "  RcRateCapabilitiesView" in layout:
        code += "\ntype\n  RcRateCapabilitiesView" + layout.split("  RcRateCapabilitiesView", 1)[1].split(
            "  RcRetrySlotView", 1)[0]
        code += "\ntemplate rcRateCapabilities" + helpers.split("template rcRateCapabilities", 1)[1].split(
            "template rcThroughputArray", 1)[0]
    code += "\ntemplate rcPrngNext" + helpers.split("template rcPrngNext", 1)[1].split(
        "proc rcRateEntryPtr", 1)[0]
    code += procedure(helpers, "rcHighestBit")
    return code, source, helpers


def test_rate_init_capability_seeding() -> None:
    init = procedure((FW / "rate_control.nim").read_text(), "rcTryInitStation")
    ht = init.split("if isHT:", 1)[1].split("  else:", 1)[0]
    assert "caps.mcsBitmaps[0] = 0xFF" in ht
    assert "caps.maxMcs = 7" in ht
    assert "caps.preambleType = ((sta.supportedRatesBitmap shr 10) and 1).uint8" in init
    assert "shr 10) and 0x3" not in init


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("scenario", ["generation", "picker"])
def test_rate_generation(mode: str, scenario: str, tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    code, source, helpers = prelude()
    for name in ["rc_get_initial_rate_config", "rc_get_lowest_rate_config"]:
        code += procedure(source, name)
    if scenario == "generation":
        code += procedure(source, "rc_new_random_rate")
        path = tmp_path / "vectors.bin"
        path.write_bytes(vectors())
        code += f'\nconst vectorPath = "{path}"\n'
        code += f"const prngInverse = {pow(0x41C64E6D, -1, 1 << 32)}'u32\n" + HARNESS
    else:
        code += "\nvar forceEmptyGroup: bool\nvar randomCalls: int\n"
        code += procedure(source, "rc_new_random_rate").replace("rc_new_random_rate*", "real_random_rate")
        code += "\nproc rc_new_random_rate(stats: pointer): uint16 =\n"
        code += "  inc randomCalls\n  if forceEmptyGroup: return 0xFFFF\n  real_random_rate(stats)\n"
        code += procedure(helpers, "rcRateConfig")
        code += procedure(source, "rc_check_rate_duplicated")
        code += "\nconst RcRandomRateAttemptLimit = 64\n" + procedure(helpers, "rc_pick_non_duplicate_rate")
        code += PICKER
    file = tmp_path / "rate_generation.nim"
    file.write_text(code)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
               f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}"]
    command += ["--checks:on"] if mode == "checked" else ["-d:release", "--checks:off"]
    if mode == "asan":
        command += ["--passC:-fsanitize=address", "--passC:-fno-omit-frame-pointer", "--passL:-fsanitize=address"]
    result = subprocess.run(command + [str(file)], cwd=ROOT, text=True,
                            env={**os.environ, "ASAN_OPTIONS": "detect_leaks=0"},
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
