"""Exercise valid MAC IE search parity and malformed-element bounds checks."""

from pathlib import Path

import pytest

from test_wifi_ap_teardown import FW, procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    mac = (FW / "mac_config_debug.nim").read_text()
    return r'''
type MacIeView {.packed.} = object
  id, len: uint8
var diagnostics: seq[string]
proc macIeAt(p: uint): ptr MacIeView = cast[ptr MacIeView](p)
proc totalLen(p: ptr MacIeView): uint = p.len.uint + 2
template macIePayload(p: ptr MacIeView): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](cast[uint](p) + 2)
proc diagnosticPuts(message: cstring) {.cdecl.} =
  diagnostics.add($message)
proc blOpsFunc(offset: int): pointer =
  doAssert offset == 8
  cast[pointer](diagnosticPuts)
''' + procedure(mac, "mac_ie_find") + procedure(mac, "mac_vsie_find")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_ie_search_matches_vendor_scan_order_without_out_of_bounds_reads(
    tmp_path: Path, mode: str
) -> None:
    run_program(tmp_path, mode, source() + r'''
var ordinary = [1'u8, 0, 32, 0]
let ordinaryStart = cast[pointer](addr ordinary[0])
let ordinaryTarget = cast[pointer](addr ordinary[2])
doAssert mac_ie_find(ordinaryStart, 4, 32) == ordinaryTarget
doAssert mac_ie_find(ordinaryStart, 3, 32) == nil
doAssert mac_ie_find(ordinaryStart, 4, 42) == nil
doAssert mac_ie_find(ordinaryStart, 0, 1) == nil
doAssert mac_ie_find(nil, 4, 1) == nil

var loneId = [32'u8]
let loneStart = cast[pointer](addr loneId[0])
doAssert mac_ie_find(loneStart, 1, 32) == nil
doAssert mac_ie_find(loneStart, 1, 42) == nil

var skippedOverrun = [1'u8, 255, 32]
doAssert mac_ie_find(addr skippedOverrun[0], 3, 32) == nil

var oui = [0x12'u8, 0x34, 0x56]
var shortDeclared = [221'u8, 0, 0x12, 0x34, 0x56]
let shortStart = cast[pointer](addr shortDeclared[0])
doAssert mac_vsie_find(shortStart, 2, addr oui[0], 3) == nil
doAssert diagnostics.len == 0

var repeated = [221'u8, 3, 0x12, 0x34, 0,
                221, 3, 0x12, 0x34, 0x56]
let repeatedStart = cast[pointer](addr repeated[0])
doAssert mac_vsie_find(repeatedStart, 10, addr oui[0], 3) ==
  cast[pointer](addr repeated[5])

var loneVendorId = [221'u8]
let loneVendorStart = cast[pointer](addr loneVendorId[0])
doAssert mac_vsie_find(loneVendorStart, 1, nil, 0) == nil
doAssert mac_vsie_find(loneVendorStart, 1, addr oui[0], 3) == nil
doAssert diagnostics.len == 0

var exactEnd = [1'u8, 0]
doAssert mac_vsie_find(addr exactEnd[0], 2, addr oui[0], 3) == nil
doAssert diagnostics.len == 0

var overrun = [1'u8, 9, 0]
doAssert mac_vsie_find(addr overrun[0], 3, addr oui[0], 3) == nil
doAssert diagnostics == @["--->>> addr != end\r\n"]

var shortPayload = [221'u8, 9, 0x12]
doAssert mac_vsie_find(addr shortPayload[0], 3, addr oui[0], 3) == nil
doAssert diagnostics.len == 2
''')
