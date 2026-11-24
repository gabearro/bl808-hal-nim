"""Compare packed-rate neighbors with the decoded BL808 rc.o branches."""

from pathlib import Path
import random
import shutil
import struct
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src/bl808/wifi/fw/rate_control.nim"

PLATFORM = r"""
const
  RCS_LOWEST_IDX = 185
  RCS_HIGHEST_IDX = 186
  RCS_MAX_NSS_MCS = 184
  RCS_RATE_MAP = 182
  RCS_SHORT_GI = 189
  RCS_RATE_BITMAP = 178
proc rcU8(p: pointer; offset: int): var uint8 =
  cast[ptr uint8](cast[uint](p) + offset.uint)[]
proc rcU16(p: pointer; offset: int): var uint16 =
  cast[ptr uint16](cast[uint](p) + offset.uint)[]
"""

HARNESS = r"""
let data = readFile(vectorPath)
const stride = 200 + 65536 * 6
doAssert data.len mod stride == 0
var state: array[200, uint8]
let stats = addr state[0]
for start in countup(0, data.len - stride, stride):
  copyMem(stats, unsafeAddr data[start], 200)
  for raw in 0 .. 65535:
    var expected: array[3, uint16]
    copyMem(addr expected[0], unsafeAddr data[start + 200 + raw * 6], 6)
    doAssert rc_set_next_mcs_index(stats, raw.uint16) == expected[0],
      "next rate differs: " & $raw & " profile " & $(start div stride)
    doAssert rc_set_previous_mcs_index(stats, raw.uint16) == expected[1],
      "previous rate differs: " & $raw & " profile " & $(start div stride)
    doAssert rc_check_valid_rate(stats, raw.uint16) == expected[2],
      "rate validation differs: " & $raw & " profile " & $(start div stride)
for raw in 0 .. 65535:
  doAssert rc_set_next_mcs_index(nil, raw.uint16) == raw.uint16
  doAssert rc_set_previous_mcs_index(nil, raw.uint16) == raw.uint16
  doAssert rc_check_valid_rate(nil, raw.uint16) == 0
state = default(typeof(state))
rcU8(stats, RCS_MAX_NSS_MCS) = 7
rcU8(stats, RCS_RATE_BITMAP) = 0b00000010'u8
doAssert rc_set_next_mcs_index(stats, 0x1000'u16) == 0x1001'u16
rcU8(stats, RCS_RATE_BITMAP) = 0b00000100'u8
doAssert rc_set_next_mcs_index(stats, 0x1000'u16) == 0x1000'u16
"""


def neighbor(rate: int, state: bytes, higher: bool) -> int:
    fmt = (rate >> 11) & 7
    if fmt < 2:
        mcs = rate & 127
        if higher:
            rates = struct.unpack_from("<H", state, 182)[0]
            if mcs >= state[186] or not (rates >> (mcs + 1)) & 1:
                return rate
            return (rate & 0xFF80) | (mcs + 1)
        if mcs <= state[185]:
            return rate
        return (rate & 0xFF80) | (mcs - 1)
    if fmt not in (2, 3):
        return rate
    mcs = rate & 7
    if higher:
        nss = (rate >> 3) & 3
        if mcs >= state[184] or not (state[178 + nss] >> (mcs + 1)) & 1:
            return rate
        mcs += 1
    else:
        if mcs == 0:
            return rate
        mcs -= 1
    return (rate & 0xFFF8) | mcs | (0x200 if state[189] else 0)


def vectors() -> bytes:
    rng = random.Random(0x808AD)
    data = bytearray()
    for profile in range(12):
        state = bytearray(200)
        state[178:182] = bytes(rng.getrandbits(8) for _ in range(4))
        if profile == 0:
            state[178:182] = b"\xff" * 4
        if profile == 1:
            state[178:182] = b"\x00" * 4
        struct.pack_into("<H", state, 182, rng.getrandbits(16))
        state[184] = profile % 8
        state[185] = profile % 4
        state[186] = 4 + profile % 8
        state[189] = profile % 3
        data += state
        for rate in range(65536):
            fmt = (rate >> 11) & 7
            valid = 0
            if fmt < 2 and rate & 127 < 16:
                valid = (struct.unpack_from("<H", state, 182)[0] >> (rate & 127)) & 1
            elif fmt in (2, 3):
                valid = (state[178 + ((rate >> 3) & 3)] >> (rate & 7)) & 1
            elif fmt > 3:
                valid = 1
            data += struct.pack("<HHH", neighbor(rate, state, True), neighbor(rate, state, False), valid)
    return bytes(data)


@pytest.mark.parametrize("release_mode", [False, True])
def test_rate_neighbors(release_mode: bool, tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    source = SOURCE.read_text()
    code = PLATFORM
    for name in ["rc_get_mcs_index", "rc_get_nss", "rc_check_valid_rate",
                 "rc_set_next_mcs_index", "rc_set_previous_mcs_index"]:
        code += procedure(source, name)
    path = tmp_path / "rate_neighbors.nim"
    vector_path = tmp_path / "vectors.bin"
    vector_path.write_bytes(vectors())
    path.write_text(code + f'\nconst vectorPath = "{vector_path}"\n' + HARNESS)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
               f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}"]
    command += ["-d:release", "--checks:off"] if release_mode else ["--checks:on"]
    result = subprocess.run(command + [str(path)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
