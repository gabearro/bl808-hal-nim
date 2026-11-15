"""Check basic-rate filtering and the two-input VHT map ABI."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
var
  warnings: int
  warningHook: proc()
proc malloc(size: csize_t): pointer {.importc, header: "<stdlib.h>".}
proc free(p: pointer) {.importc, header: "<stdlib.h>".}
proc rateSetAt(p: pointer): ptr RateSetView = cast[ptr RateSetView](p)
proc assert_warn(a, b: cstring; line: cint) =
  doAssert line == 411
  inc warnings
  if warningHook != nil:
    let callback = warningHook
    warningHook = nil
    callback()
'''


def helpers() -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    return layouts("RateSetView") + PLATFORM + procedure(scan, "me_rate_translate")


def source() -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    return helpers() + procedure(scan, "me_legacy_rate_bitfield_build") + \
        procedure(scan, "me_rate_bitfield_vht_build") + r'''
proc intersect(rx, tx: uint32): uint32 =
  type VendorAbi = proc(rx, tx: uint32): uint32 {.cdecl.}
  cast[VendorAbi](me_rate_bitfield_vht_build)(rx, tx)
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_legacy_basic_only_and_all_rates(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
let rates = [2'u8, 4, 11, 22, 12, 18, 24, 36, 48, 72, 96, 108]
for basicIndex in 0 ..< rates.len:
  var encoded: array[13, uint8]
  encoded[0] = 12
  for i in 0 ..< rates.len: encoded[i + 1] = rates[i]
  encoded[basicIndex + 1] = encoded[basicIndex + 1] or 0x80
  for flag in [1'u8, 2'u8, 255'u8]:
    doAssert me_legacy_rate_bitfield_build(addr encoded[0], flag) ==
      (1'u32 shl basicIndex)
  doAssert me_legacy_rate_bitfield_build(addr encoded[0], 0) == 0xFFF
  doAssert warnings == 0
var duplicate = [4'u8, 0x82, 0x82, 0x04, 0x8C]
doAssert me_legacy_rate_bitfield_build(addr duplicate[0], 1) == 0x11
doAssert me_legacy_rate_bitfield_build(addr duplicate[0], 0) == 0x13
var empty = [0'u8]
doAssert me_legacy_rate_bitfield_build(addr empty[0], 0) == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_nonbasic_unknown_rate_does_not_warn(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
var encoded = [3'u8, 0x7F, 0x82, 0xFF]
doAssert me_legacy_rate_bitfield_build(addr encoded[0], 1) == 1
doAssert warnings == 1
warnings = 0
doAssert me_legacy_rate_bitfield_build(addr encoded[0], 0) == 1
doAssert warnings == 2
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_rate_snapshot_survives_warning_callback(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for release in [true, false]:
  var owned = malloc(13)
  doAssert owned != nil
  let bytes = cast[ptr UncheckedArray[uint8]](owned)
  zeroMem(owned, 13)
  bytes[0] = 3
  bytes[1] = 0x7F
  bytes[2] = 0x82
  bytes[3] = 0x8C
  warnings = 0
  warningHook = proc() =
    if release:
      free(owned)
      owned = nil
    else:
      bytes[0] = 1
      bytes[2] = 0xEC
      bytes[3] = 0xEC
  doAssert me_legacy_rate_bitfield_build(owned, 0) == 0x11
  doAssert warnings == 1
  if owned != nil: free(owned)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_invalid_rate_count_is_not_read(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
doAssert me_legacy_rate_bitfield_build(nil, 0) == 0
let p = malloc(1)
doAssert p != nil
for count in [13'u8, 255'u8]:
  cast[ptr uint8](p)[] = count
  doAssert me_legacy_rate_bitfield_build(p, 1) == 0
free(p)
doAssert warnings == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_vht_abi_intersects_both_maps(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
doAssert intersect(0, 0xFFFF) == 0xFFFF
doAssert intersect(0xFFFF, 0) == 0xFFFF
doAssert intersect(0, 0xAAAA) == 0
doAssert intersect(0xAAAA, 0) == 0
for group in 0 ..< 8:
  let shift = group * 2
  let fieldMask = 3'u32 shl shift
  for rxField in 0'u32 .. 3'u32:
    for txField in 0'u32 .. 3'u32:
      let rx = (0xAAAA'u32 and not fieldMask) or (rxField shl shift)
      let tx = (0xAAAA'u32 and not fieldMask) or (txField shl shift)
      var expected = (0xAAAA'u32 and not fieldMask) or (min(rxField, txField) shl shift)
      if rxField == 3 or txField == 3:
        let prefixMask = (1'u32 shl shift) - 1
        expected = (0xAAAA'u32 and prefixMask) or (0xFFFF'u32 and not prefixMask)
      doAssert intersect(rx, tx) == expected
      doAssert intersect(rx or 0xCAFE0000'u32, tx or 0xABCD0000'u32) == expected
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_vht_c_declaration_has_two_scalar_arguments(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
{.emit: """
_Static_assert(__builtin_types_compatible_p(__typeof__(&me_rate_bitfield_vht_build),
    NU32 (*)(NU32, NU32)), "VHT map ABI requires two scalar arguments");
""".}
doAssert intersect(0, 0xFFFF) == 0xFFFF
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_bss_request_contains_only_basic_rates(tmp_path: Path, mode: str) -> None:
    from test_wifi_sm_bss_allocation import LIFETIME, source as bss_source

    names = ["MeSetPsDisableReqPayload", "MmSetBssidReqPayload", "MmSetBasicRatesReqPayload",
             "MmSetBeaconIntReqPayload", "MeSetActiveReqPayload", "MmSetEdcaReqPayload"]
    types = layouts(*names)
    types += "const\n" + "".join(f"  {name}Size = sizeof({name}).uint32\n" for name in names)
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code = bss_source(types, scan)
    rate_helpers = helpers()
    rate_helpers = rate_helpers.replace(procedure(rate_helpers, "free"), "", 1)
    code = code.replace(procedure(code, "me_legacy_rate_bitfield_build"),
                        rate_helpers + procedure(scan, "me_legacy_rate_bitfield_build"), 1)
    run_program(tmp_path, mode, code + LIFETIME + r'''
setup()
vif.basicRates = [4'u8, 0x82, 0x04, 0x8C, 0x6C, 0, 0, 0, 0, 0, 0, 0, 0]
sm_set_bss_param(nil)
while sm.pendingBssParams.first != nil:
  acknowledgeBss()
  sm_send_next_bss_param(nil)
acknowledgeBss()
doAssert sent.len == 9
doAssert keMsgHdrFromPayload(sent[2]).id == MM_SET_BASIC_RATES_REQ
let rates = cast[ptr MmSetBasicRatesReqPayload](sent[2])
doAssert rates.rateBitfield == 0x11 and rates.vifIdx == 1
finish()
''')
