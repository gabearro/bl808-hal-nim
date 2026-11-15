"""Exercise rate IE extraction and returning diagnostic callbacks."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
type GuardedRates = object
  before: array[16, uint8]
  data: array[13, uint8]
  after: array[16, uint8]
var
  output: GuardedRates
  incoming: pointer
  incomingLength: uint32
  errors: int
  hook: proc()
proc malloc(size: csize_t): pointer {.importc, header: "<stdlib.h>".}
proc free(p: pointer) {.importc, header: "<stdlib.h>".}
proc macIeAt(p: uint): ptr MacIeView = cast[ptr MacIeView](p)
proc rateSetAt(p: pointer): ptr RateSetView = cast[ptr RateSetView](p)
proc totalLen(p: ptr MacIeView): uint = p.len.uint + 2
template macIePayload(p: ptr MacIeView): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](cast[uint](p) + 2)
proc assert_err(a, b: cstring; line: cint) =
  doAssert line == 897
  inc errors
  if hook != nil: hook()
proc setup(rates, extra: openArray[uint8]; supported = true; extended = true) =
  if incoming != nil: free(incoming)
  incomingLength = ((if supported: rates.len + 2 else: 0) +
                    (if extended: extra.len + 2 else: 0)).uint32
  incoming = malloc(max(1'u32, incomingLength).csize_t)
  doAssert incoming != nil
  let bytes = cast[ptr UncheckedArray[uint8]](incoming)
  var offset = 0
  if supported:
    bytes[offset] = 1
    bytes[offset + 1] = rates.len.uint8
    offset += 2
    for value in rates:
      bytes[offset] = value
      inc offset
  if extended:
    bytes[offset] = 50
    bytes[offset + 1] = extra.len.uint8
    offset += 2
    for value in extra:
      bytes[offset] = value
      inc offset
  for i in 0 ..< output.before.len: output.before[i] = 0xA5
  for i in 0 ..< output.data.len: output.data[i] = 0xA5
  for i in 0 ..< output.after.len: output.after[i] = 0xA5
  errors = 0
  hook = nil
proc finish() =
  if incoming != nil:
    free(incoming)
    incoming = nil
  for value in output.before: doAssert value == 0xA5
  for value in output.after: doAssert value == 0xA5
'''


def source() -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code = layouts("MacIeView", "RateSetView") + PLATFORM
    code += procedure((FW / "mac_config_debug.nim").read_text(), "mac_ie_find")
    code += procedure(scan, "me_extract_rate_set")
    return code + r'''
proc parse() =
  me_extract_rate_set(incoming, incomingLength, addr output.data[0])
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_valid_supported_and_extended_rates(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for count in 0 .. 12:
  for baseCount in 0 .. count:
    var base, extra: seq[uint8]
    for i in 0 ..< baseCount: base.add((0x82 + i).uint8)
    for i in baseCount ..< count: extra.add((0x82 + i).uint8)
    setup(base, extra)
    parse()
    doAssert output.data[0] == count.uint8 and errors == 0
    for i in 0 ..< count: doAssert output.data[i + 1] == (0x82 + i).uint8
    for i in count + 1 ..< 13: doAssert output.data[i] == 0xA5
    finish()
setup([0x82'u8, 4, 11], [], extended = false)
parse()
doAssert output.data[0] == 3 and errors == 0
doAssert output.data[1] == 0x82 and output.data[3] == 11
finish()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_missing_truncated_and_oversized_elements(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup([], [2'u8, 4], supported = false)
parse()
doAssert output.data[0] == 0 and errors == 0
finish()
setup([2'u8, 4], [12'u8, 24])
dec incomingLength
parse()
doAssert output.data[0] == 2 and output.data[2] == 4 and errors == 0
finish()
var oversized: array[13, uint8]
setup(oversized, [])
parse()
doAssert output.data[0] == 0 and errors == 0
for i in 1 ..< 13: doAssert output.data[i] == 0xA5
finish()
setup([2'u8, 4], [])
me_extract_rate_set(incoming, incomingLength, nil)
finish()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_oversized_extended_rates_keep_supported_prefix(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup([2'u8, 4, 11, 22, 12, 18, 24, 36], [48'u8, 72, 96, 108, 127])
parse()
doAssert errors == 1 and output.data[0] == 8
doAssert output.data[1] == 2 and output.data[8] == 36
for i in 9 ..< 13: doAssert output.data[i] == 0xA5
finish()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_returning_diagnostic_preserves_replacement(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for newCount in [0'u8, 1'u8]:
  setup([2'u8, 4, 11, 22, 12, 18, 24, 36], [48'u8, 72, 96, 108, 127])
  var expected: GuardedRates
  hook = proc() =
    for i in 0 ..< output.data.len: output.data[i] = 0xCC
    output.data[0] = newCount
    expected = output
  parse()
  doAssert errors == 1 and output == expected
  finish()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_returning_diagnostic_can_release_input(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup([2'u8, 4, 11, 22, 12, 18, 24, 36], [48'u8, 72, 96, 108, 127])
var expected: GuardedRates
hook = proc() =
  output.data[0] = 0
  expected = output
  free(incoming)
  incoming = nil
parse()
doAssert errors == 1 and output == expected
finish()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_extracted_rates_feed_basic_rate_selection(tmp_path: Path, mode: str) -> None:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code = source() + "proc assert_warn(a, b: cstring; line: cint) = doAssert false\n"
    code += procedure(scan, "me_rate_translate")
    code += procedure(scan, "me_legacy_rate_bitfield_build")
    run_program(tmp_path, mode, code + r'''
setup([0x82'u8, 4, 0x8B, 22], [0x8C'u8, 18, 0x98, 36, 48, 72, 96, 108])
parse()
doAssert output.data[0] == 12 and errors == 0
doAssert me_legacy_rate_bitfield_build(addr output.data[0], 1) == 0x55
doAssert me_legacy_rate_bitfield_build(addr output.data[0], 0) == 0xFFF
finish()
''')
