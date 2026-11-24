"""Check fixed-rate validation and request ABI against the BL808 RC object."""

from itertools import product
from pathlib import Path
import random
import struct

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_tx_policy import compile_and_run

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
const
  RCS_RATE_MAP = 182
  RCS_RATE_BITMAP = 178
  STA_INFO_TAB_ENTRIES = 7
  StaTxPolicyUpdateTxPower = 16'u8
proc rcU8(p: pointer; offset: int): var uint8 = cast[ptr uint8](cast[uint](p) + offset.uint)[]
proc rcU16(p: pointer; offset: int): var uint16 = cast[ptr uint16](cast[uint](p) + offset.uint)[]
type Sta = object
  rcStats: pointer
  valid, infoIdx: uint8
  txPolicyUpdateFlags: array[1, uint8]
type MsgHdr = object
  paramLen: uint32
var
  stations: array[7, Sta]
  requestHeader = MsgHdr(paramLen: 6)
  errors, updates: int
  updateArgs: array[3, uint8]
proc keMsgHdrFromPayload(p: pointer): ptr MsgHdr =
  doAssert p != nil
  addr requestHeader
proc staInfoForIdx(index: uint8): ptr Sta =
  doAssert index < 7
  addr stations[index]
proc assert_err(file, expr: cstring; line: int) = inc errors
proc rc_update_bw_nss_max(staIdx, bandwidth, nss: uint8) =
  inc updates
  updateArgs = [staIdx, bandwidth, nss]
"""

HARNESS = r"""
let vectors = readFile(vectorPath)
const stride = 200 + 65536
doAssert vectors.len mod stride == 0
var storage: array[216, uint8]
let stats = addr storage[8]
for offset in countup(0, vectors.len - stride, stride):
  for value in storage.mitems: value = 0xA5
  copyMem(stats, unsafeAddr vectors[offset], 200)
  for rate in 0 .. 65535:
    let actual = rc_check_fixed_rate_config(stats, rate.uint16)
    doAssert actual == (vectors[offset + 200 + rate] != '\0'),
      "fixed-rate validation differs at profile " & $(offset div stride) & " rate " & $rate
  doAssert equalMem(stats, unsafeAddr vectors[offset], 200), "validation mutated RC state"
  for i in 0 ..< 8: doAssert storage[i] == 0xA5 and storage[208 + i] == 0xA5
doAssert not rc_check_fixed_rate_config(nil, 0)

# Run the actual request handler with the actual validator, not a register shim.
zeroMem(stats, 200)
let caps = rcRateCapabilities(stats)
caps.formatMod = 2
caps.legacyRateMap = 0xF
caps.mcsBitmaps[0] = 0xF
caps.maxBandwidth = 1
caps.maxNss = 0
stations[0].rcStats = stats
stations[0].infoIdx = 3
stations[0].valid = 1
var req: MeRcSetRateReqPayload
for flags in 0 .. 255:
  for requested in [0x1001'u16, 0x1007'u16, 0xFFFF'u16]:
    for power in [0'u16, 0x100'u16]:
      req = MeRcSetRateReqPayload(staIdx: 0, fixedRate: requested, mcsRate: power)
      rcTrialControl(stats).info = flags.uint8
      caps.fixedRate = 0x1002
      stations[0].txPolicyUpdateFlags[0] = 0x81
      updates = 0
      doAssert me_rc_set_rate_req_handler(addr req) == 0
      if requested == 0xFFFF:
        doAssert caps.fixedRate == 0xFFFF
        doAssert rcTrialControl(stats).info == (flags.uint8 and not 0x60'u8)
        doAssert updates == 1 and updateArgs == [3'u8, 1, 0]
      elif requested == 0x1001:
        doAssert caps.fixedRate == requested
        doAssert rcTrialControl(stats).info == ((flags.uint8 and not 0x60'u8) or 0x20'u8)
        doAssert updates == 0
      else:
        doAssert caps.fixedRate == 0x1002 and rcTrialControl(stats).info == flags.uint8
        doAssert updates == 0
      doAssert stations[0].txPolicyUpdateFlags[0] == (if power == 0: 0x81'u8 else: 0x91'u8)
doAssert errors == 0
req.staIdx = 255
doAssert me_rc_set_rate_req_handler(addr req) == 0
req.staIdx = 0
stations[0].valid = 0
me_rc_set_rate_req_handler(addr req)
stations[0].valid = 1
stations[0].rcStats = nil
for size in 0'u32 .. 5'u32:
  requestHeader.paramLen = size
  doAssert me_rc_set_rate_req_handler(addr req) == 0
doAssert errors == 0
requestHeader.paramLen = 6
me_rc_set_rate_req_handler(addr req)
doAssert errors == 1
doAssert me_rc_set_rate_req_handler(nil) == 0
doAssert errors == 1
"""


def valid(stats, rate):
    fmt = (rate >> 11) & 7
    maximum = stats[177]
    if fmt > maximum:
        return False
    if maximum == 4 and fmt != 4:
        return False
    legacy = not fmt & 6
    if maximum in (2, 3) and legacy and stats[185] > 3:
        return False
    if legacy:
        if not rate & 0x400 and stats[190] == 1:
            return False
    else:
        if rate & 0x200 and not stats[189]:
            return False
        if ((rate >> 7) & 3) > stats[187]:
            return False
        nss = (rate >> 3) & 3 if fmt in (2, 3) else 0
        if nss > stats[188]:
            return False
    # The archive's rc_check_valid_rate accepts formats above HT here.
    if legacy:
        index = rate & 127
        return index < 16 and bool(struct.unpack_from("<H", stats, 182)[0] & (1 << index))
    if fmt > 3:
        return True
    return bool(stats[178 + ((rate >> 3) & 3)] & (1 << (rate & 7)))


def profiles():
    rng = random.Random(0xF1808)
    for fmt, gi, preamble, bandwidth in product(range(5), range(2), range(2), range(4)):
        stats = bytearray(rng.randbytes(200))
        stats[177] = fmt
        stats[178:182] = bytes([0x55, 0xAA, 0xF0, 0x0F])
        struct.pack_into("<H", stats, 182, 0x0F5B)
        stats[185] = 0 if (fmt + gi + preamble + bandwidth) & 1 else 4
        stats[187:191] = bytes([bandwidth, (fmt + bandwidth) & 3, gi, preamble])
        yield stats


def test_fixed_rate_abi():
    source = (FW / "rate_control.nim").read_text()
    assert "proc rc_check_fixed_rate_config*(stats: pointer, rateConfig: uint16): bool" in source
    handler = procedure((FW / "task_handlers.nim").read_text(), "me_rc_set_rate_req_handler")
    assert "rc_check_fixed_rate_config(rcPtr, fixedRate)" in handler
    assert ".emit:" not in handler and "__asm__" not in handler


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_fixed_rate(mode, tmp_path):
    # Fail clearly on the old, pointer-truncating ABI before compiling its asm.
    test_fixed_rate_abi()
    vectors = tmp_path / "vectors.bin"
    vectors.write_bytes(b"".join(bytes(stats) + bytes(valid(stats, rate) for rate in range(65536))
                                 for stats in profiles()))
    layout = (FW / "layout_types.nim").read_text()
    helpers = (FW / "runtime_helpers.nim").read_text()
    source = PLATFORM
    source += "\ntype\n  RcRateEntryView" + layout.split("  RcRateEntryView", 1)[1].split("  TxFrameEnvView", 1)[0]
    source += "\ntype\n  MeRcSetRateReqPayload" + layout.split("  MeRcSetRateReqPayload", 1)[1].split("  MeTrafficIndReqPayload", 1)[0]
    source += "\nconst MeRcSetRateReqPayloadSize = sizeof(MeRcSetRateReqPayload).uint32\n"
    source += "\ntemplate meRcSetRateReqView(p: pointer): ptr MeRcSetRateReqPayload = cast[ptr MeRcSetRateReqPayload](p)\n"
    source += "\ntemplate rcTrialControl" + helpers.split("template rcTrialControl", 1)[1].split("template rcThroughputArray", 1)[0]
    rate = (FW / "rate_control.nim").read_text()
    for name in ["rc_get_mcs_index", "rc_get_nss", "rc_check_valid_rate", "rc_check_fixed_rate_config"]:
        source += procedure(rate, name)
    source += procedure((FW / "task_handlers.nim").read_text(), "me_rc_set_rate_req_handler")
    compile_and_run(tmp_path, mode, source + f'\nconst vectorPath = "{vectors}"\n' + HARNESS)
