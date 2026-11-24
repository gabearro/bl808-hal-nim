"""Exercise BCMC rate initialization with bounded AP rate-set input."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    management = (FW / "scan_station_ap_me.nim").read_text()
    code = r'''
type Sta = object
  rateSeed: array[13, uint8]
  txPolicyUpdateFlags: uint8
var calls, assertions: int
var lastRate: uint32
proc staInfoAt(p: pointer): ptr Sta = cast[ptr Sta](p)
proc apSelfStaStart(sta: ptr Sta): ptr Sta = sta
proc assert_err(file, source: cstring; line: cint) = inc assertions
proc rc_init_bcmc_rate(staEntry: pointer; rate: uint32) =
  doAssert staEntry != nil
  inc calls
  lastRate = rate
'''
    return code + procedure(management, "me_rate_translate") + procedure(
        management, "me_init_bcmc_rate"
    )


def rc_source() -> str:
    rate_control = (FW / "rate_control.nim").read_text()
    code = r'''
type
  Policy = object
    retryRate: array[4, uint32]
  Sta = object
    txPolicy: pointer
    supportedRatesBitmap: uint16
proc staInfoAt(p: pointer): ptr Sta = cast[ptr Sta](p)
proc txPolicyAt(p: pointer): ptr Policy = cast[ptr Policy](p)
'''
    return code + procedure(rate_control, "rc_init_bcmc_rate")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_bcmc_rate_set_validation(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
var sta: Sta
sta.txPolicyUpdateFlags = 0xA5
me_init_bcmc_rate(nil)
doAssert calls == 0 and assertions == 0

for count in [0'u8, 13, 255]:
  sta.rateSeed[0] = count
  me_init_bcmc_rate(addr sta)
  doAssert calls == 0 and sta.txPolicyUpdateFlags == 0xA5
doAssert assertions == 3

sta.rateSeed[0] = 2
sta.rateSeed[1] = 1
sta.rateSeed[2] = 3
me_init_bcmc_rate(addr sta)
doAssert calls == 0 and sta.txPolicyUpdateFlags == 0xA5

sta.rateSeed[0] = 4
sta.rateSeed[1] = 0x82
sta.rateSeed[2] = 0x84
sta.rateSeed[3] = 0x8B
sta.rateSeed[4] = 0xEC
me_init_bcmc_rate(addr sta)
doAssert calls == 1 and lastRate == 11
doAssert sta.txPolicyUpdateFlags == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_bcmc_policy_writer_rejects_invalid_inputs(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, rc_source() + r'''
var policy = Policy(retryRate: [0xDEADBEEF'u32, 0xDEADBEEF'u32,
                                0xDEADBEEF'u32, 0xDEADBEEF'u32])
var sta = Sta(supportedRatesBitmap: 0x400)
rc_init_bcmc_rate(nil, 2)
rc_init_bcmc_rate(addr sta, 2)
sta.txPolicy = addr policy
for invalid in [12'u32, 255, 0xFFFF_FFFF'u32]:
  rc_init_bcmc_rate(addr sta, invalid)
for rate in policy.retryRate: doAssert rate == 0xDEADBEEF'u32

rc_init_bcmc_rate(addr sta, 2)
for rate in policy.retryRate: doAssert rate == 0x20000402'u32
rc_init_bcmc_rate(addr sta, 4)
for rate in policy.retryRate: doAssert rate == 0x20000004'u32
''')
