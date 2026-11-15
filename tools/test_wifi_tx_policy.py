"""Exercise TX policy serialization against the BL808 me_utils.o/tpc.o blocks."""

from itertools import product
from pathlib import Path
import os
import random
import shutil
import struct
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
const
  RCS_ANOTHER_FLAG = 176
  RCS_RATE_BITMAP = 178
  RCS_MAX_NSS_MCS = 184
  RCS_FLAGS = 175
  StaTxPolicyUpdateRateControl = 1'u8
  StaTxPolicyUpdateAggregationLength = 2'u8
  StaTxPolicyUpdateTxPower = 16'u8
proc rcU8(p: pointer; offset: int): var uint8 = cast[ptr uint8](cast[uint](p) + offset.uint)[]
proc rcU16(p: pointer; offset: int): var uint16 = cast[ptr uint16](cast[uint](p) + offset.uint)[]
proc rcRateConfig(p: pointer; index: int): uint16 = rcU16(p, 10 + index * 12)
type
  Sta = object
    txPolicy, rcStats: pointer
    txPolicyUpdateFlags: array[1, uint8]
    instNbr, htVhtConfig: uint8
    aggregationLength: uint32
  Vif = object
    mcsSet: array[16, uint8]
var
  sta: Sta
  vif: Vif
  powerCalls, irqCalls: int
  calledRates: array[4, uint32]
  originalPolicy: array[60, uint8]
  irqActive: bool
proc staInfoAt(p: pointer): ptr Sta = cast[ptr Sta](p)
proc vifChannelForIdx(index: uint8): ptr Vif =
  doAssert index == sta.instNbr
  addr vif
proc vifHtCapabilities(p: ptr Vif): ptr Vif = p
proc trpc_get_default_power_idx(group: uint32; index: uint8): int8 =
  doAssert not irqActive
  cast[int8]((group * 73 + index.uint32 * 13 + 128) and 255)
proc irqSave(): uint32 =
  doAssert not irqActive and irqCalls == 0
  doAssert equalMem(sta.txPolicy, addr originalPolicy[0], 60), "policy published before IRQ lock"
  irqActive = true
  inc irqCalls
  8
proc irqRestore(state: uint32) =
  doAssert state == 8 and irqActive
  irqActive = false
  inc irqCalls
"""

HARNESS = r"""
let vectors = readFile(vectorPath)
const stride = 564
doAssert vectors.len mod stride == 0
var statsStore: array[216, uint8]
var policyStore: array[76, uint8]
sta.rcStats = addr statsStore[8]
sta.txPolicy = addr policyStore[8]
for offset in countup(0, vectors.len - stride, stride):
  for b in statsStore.mitems: b = 0xA5
  for b in policyStore.mitems: b = 0xA5
  copyMem(sta.rcStats, unsafeAddr vectors[offset], 200)
  copyMem(sta.txPolicy, unsafeAddr vectors[offset + 200], 60)
  copyMem(addr originalPolicy[0], sta.txPolicy, 60)
  copyMem(addr vif.mcsSet[0], unsafeAddr vectors[offset + 260], 16)
  sta.htVhtConfig = vectors[offset + 276].uint8
  sta.txPolicyUpdateFlags[0] = vectors[offset + 277].uint8
  copyMem(addr sta.aggregationLength, unsafeAddr vectors[offset + 278], 4)
  sta.instNbr = vectors[offset + 282].uint8
  powerCalls = 0
  irqCalls = 0
  irqActive = false
  calledRates = default(typeof(calledRates))
  doAssert me_update_buffer_control(addr sta) == sta.txPolicy
  doAssert equalMem(sta.rcStats, unsafeAddr vectors[offset + 284], 200),
    "RC capability mutation differs at vector " & $(offset div stride)
  doAssert equalMem(sta.txPolicy, unsafeAddr vectors[offset + 484], 60),
    "TX descriptor differs at vector " & $(offset div stride)
  doAssert sta.txPolicyUpdateFlags[0] == vectors[offset + 544].uint8
  doAssert powerCalls == vectors[offset + 545].int and irqCalls == vectors[offset + 546].int
  doAssert equalMem(addr calledRates[0], unsafeAddr vectors[offset + 548], 16)
  doAssert not irqActive
  for i in 0 ..< 8:
    doAssert statsStore[i] == 0xA5 and statsStore[208 + i] == 0xA5
    doAssert policyStore[i] == 0xA5 and policyStore[68 + i] == 0xA5
"""


def u16(data, offset):
    return struct.unpack_from("<H", data, offset)[0]


def u32(data, offset):
    return struct.unpack_from("<I", data, offset)[0]


def power_index(rate):
    # tpc.o: th.extu 13:11, low seven-bit index, then an unsigned byte result.
    index = rate & 127
    if (rate >> 11) & 7:
        group = 2
    elif index & 124:
        group = 1
        index = (index - 4) & 255
    else:
        group = 0
    return (group * 73 + index * 13 + 128) & 255


def expected_policy(stats, policy, mcs, stbc_limit, flags, aggregation):
    stats, policy = bytearray(stats), bytearray(policy)
    calls = [0] * 4
    if not flags:
        return bytes(stats + policy) + struct.pack("<BBBB4I", 0, 0, 0, 0, *calls)
    phy = u32(policy, 4)
    rates = list(struct.unpack_from("<4I", policy, 20))
    if flags & 1:
        selected_mcs = 255
        stbc_nss = 0
        use_stbc = False
        stats[191] = mcs[12]
        for slot in range(4):
            rate_index = u16(stats, 128 + ((stats[176] + slot) & 3) * 8)
            rate = (u16(stats, 10 + rate_index * 12) & 0x3FFF) | 0x80000000
            if (rate >> 11) & 6:
                candidate = rate & 127
                stats[178 + slot] = mcs[slot]
                if slot == 0:
                    for bit in range(7, -1, -1):
                        if mcs[slot] & (1 << bit):
                            selected_mcs = bit
                            break
                if selected_mcs != 255:
                    stats[184] = selected_mcs
                    candidate = selected_mcs
                if not stats[175] & 64:
                    rate = (rate & ~127) | candidate
                # me_utils.o+0x118: th.extu a3,a3,4,3 (two bits).
                nss = (candidate >> 3) & 3
                if slot == 0:
                    if nss < stbc_limit:
                        stbc_nss = nss
                        use_stbc = True
                elif use_stbc:
                    use_stbc = nss == stbc_nss
            rates[slot] = rate | (rates[slot] & 0x1FFFC000)
        phy &= ~0x180
        if use_stbc:
            phy |= (stbc_nss + 1) << 7
        flags |= 18
    if flags & 2:
        for i, rate in enumerate(rates):
            if ((rate >> 11) & 7) | (rate & 124):
                rates[i] = (rate & 0xE0003FFF) | aggregation
    if flags & 16:
        calls = rates.copy()
        struct.pack_into("<4I", policy, 36, *(power_index(rate) for rate in rates))
    struct.pack_into("<I", policy, 4, phy)
    struct.pack_into("<4I", policy, 20, *rates)
    return bytes(stats + policy) + struct.pack("<BBBB4I", 0, 4 if flags & 16 else 0, 2, 0, *calls)


def vectors():
    rng = random.Random(0xB1808)

    def case(stats, policy, mcs, stbc, flags, aggregation):
        metadata = bytes(mcs) + struct.pack("<BBIBB", stbc, flags, aggregation, 1, 0)
        return bytes(stats) + bytes(policy) + metadata + expected_policy(
            stats, policy, mcs, stbc, flags, aggregation
        )

    for _ in range(8000):
        stats = bytearray(rng.randbytes(200))
        count = rng.randrange(1, 11)
        struct.pack_into("<H", stats, 192, count)
        for slot in range(4):
            struct.pack_into("<H", stats, 128 + slot * 8, rng.randrange(count))
        yield case(stats, rng.randbytes(60), rng.randbytes(16), rng.randrange(5),
                   rng.randrange(256), (rng.getrandbits(32) & 0x1FFFC000))

    # No local MCS override: every two-bit NSS chain, rotation and STBC limit.
    for chain in product(range(4), repeat=4):
        for rotation, stbc, forced in product(range(4), range(5), [0, 64]):
            stats = bytearray(200)
            struct.pack_into("<H", stats, 192, 4)
            stats[175], stats[176] = forced, rotation
            for slot, nss in enumerate(chain):
                struct.pack_into("<H", stats, 10 + slot * 12, 0x1000 | (nss << 3) | slot)
                struct.pack_into("<H", stats, 128 + slot * 8, slot)
            yield case(stats, rng.randbytes(60), bytes(16), stbc, 1, 0x01234000)


def compile_and_run(tmp_path, mode, source):
    nim = shutil.which("nim")
    if not nim:
        pytest.skip("Nim compiler is unavailable")
    path = tmp_path / "tx_policy.nim"
    path.write_text(source)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
               f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}"]
    command += ["--checks:on"] if mode == "checked" else ["-d:release", "--checks:off"]
    if mode == "asan":
        command += ["--passC:-fsanitize=address", "--passC:-fno-omit-frame-pointer", "--passL:-fsanitize=address"]
    result = subprocess.run(command + [str(path)], cwd=ROOT, text=True,
                            env={**os.environ, "ASAN_OPTIONS": "detect_leaks=0"},
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tx_policy(mode, tmp_path):
    data = tmp_path / "vectors.bin"
    data.write_bytes(b"".join(vectors()))
    layout = (FW / "layout_types.nim").read_text()
    source = PLATFORM + "\ntype\n  TxPolicyView" + layout.split("  TxPolicyView", 1)[1].split("  MichaelMicContextView", 1)[0]
    source += "\ntemplate txPolicyAt(p: pointer): ptr TxPolicyView = cast[ptr TxPolicyView](p)\n"
    tpc = procedure((FW / "tx_power_control.nim").read_text(), "tpc_get_vif_tx_power_vs_rate")
    # Instrument the actual classifier's input, leaving its body and ABI intact.
    tpc = tpc.replace(" {.exportc, cdecl.} =", " {.exportc, cdecl.} =\n  calledRates[powerCalls] = rate\n  inc powerCalls", 1)
    source += tpc
    source += procedure((FW / "scan_station_ap_me.nim").read_text(), "me_update_buffer_control")
    compile_and_run(tmp_path, mode, source + f'\nconst vectorPath = "{data}"\n' + HARNESS)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tx_power_classifier(mode, tmp_path):
    source = PLATFORM
    tpc = procedure((FW / "tx_power_control.nim").read_text(), "tpc_get_vif_tx_power_vs_rate")
    source += tpc
    call = "tpc_get_vif_tx_power_vs_rate(0, rate)" if "vifIdx: uint8" in tpc else "tpc_get_vif_tx_power_vs_rate(rate)"
    source += r"""
for highBits in [0'u32, 0x1FFFC000'u32, 0x80000000'u32, 0xFFFF0000'u32]:
  for lowBits in 0'u32 .. 65535:
    let rate = highBits or lowBits
    var index = rate and 127
    var group = 0'u32
    if ((rate shr 11) and 7) != 0: group = 2
    elif (index and 124) != 0:
      group = 1
      index = (index - 4) and 255
    let expected = (group * 73 + index * 13 + 128) and 255
""" + f"    let actual = {call}\n" + r"""
    doAssert actual.int == expected.int,
      "TX power differs at rate " & $rate & ": " & $actual & " != " & $expected
"""
    compile_and_run(tmp_path, mode, source)
