"""Verify probe-response size prediction and pre-write capacity rejection."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_beacon_frames import program_source

ROOT = Path(__file__).resolve().parents[1]

PUBLIC_CHECKS = r"""
var application: array[640, uint8]
for i in 0 ..< application.len: application[i] = (i and 255).uint8
for irq in [false, true]:
  reset(1, 3, 2, 1, 2437, 12)
  interruptsEnabled = irq
  appIeProbeRespPtr = addr application[0]
  appIeProbeRespLen = 600
  var length = 0xCAFE'u16
  doAssert me_build_probe_rsp(addr bytes[8], 1, addr length) == 0,
    "oversized probe response was serialized into the fixed TX buffer"
  doAssert length == 0 and interruptsEnabled == irq
  for value in bytes: doAssert value == 0xA5, "rejected probe wrote output bytes"

  # Source arrays and channel binding are validated before dereferencing them.
  for invalid in 0 .. 3:
    reset(1, 0, 0, 0, 2437, 4)
    case invalid
    of 0: vifs[1].supportedRatesLong[0] = 33
    of 1: vifs[1].basicRates[0] = 13
    of 2: vifs[1].operChan = nil
    else: discard
    length = 0xCAFE
    let vif = if invalid == 3: 255'u8 else: 1'u8
    doAssert me_build_probe_rsp(addr bytes[8], vif, addr length) == 0
    doAssert length == 0 and interruptsEnabled == irq
    for value in bytes: doAssert value == 0xA5
  length = 0xCAFE
  doAssert me_build_probe_rsp(nil, 1, addr length) == 0 and length == 0
  doAssert interruptsEnabled == irq
"""

BOUNDED_CHECKS = r"""
var application: array[640, uint8]
for i in 0 ..< application.len: application[i] = (i and 255).uint8
for vif in 0'u8 .. 1'u8:
  for flags in 0'u8 .. 3'u8:
    for privacy in 0'u8 .. 2'u8:
      for rates in [1, 8, 12]:
        for ssidLength in [0, 32]:
          for applicationLength in [0, 50]:
            reset(vif, flags, privacy, 1, 2437, rates)
            let v = addr vifs[vif]
            v.supportedRatesLong[0] = ssidLength.uint8
            for i in 1 .. ssidLength: v.supportedRatesLong[i] = i.uint8
            appIeProbeRespPtr = addr application[0]
            appIeProbeRespLen = applicationLength.uint16
            let expected = (12 + 2 + ssidLength + 2 + min(rates, 8) +
              (if rates > 8: rates - 8 + 2 else: 0) + 6 +
              (if privacy == 1: 22 elif privacy == 2: 56 else: 0) +
              (if (flags and 2) != 0: 52 else: 0) +
              (if (flags and 1) != 0: 26 else: 0) + applicationLength).uint32
            doAssert meProbeResponseLength(vif) == expected
            var length = 0xCAFE'u16
            doAssert meBuildProbeResponse(addr bytes[8], vif, expected - 1, addr length) == 0
            doAssert length == 0
            for value in bytes: doAssert value == 0xA5
            doAssert meBuildProbeResponse(addr bytes[8], vif, expected, addr length) == expected
            doAssert length.uint32 == expected
            guard(expected)
            # The public compatibility entry point produces the same bytes.
            let bounded = bytes
            for value in bytes.mitems: value = 0xA5
            doAssert me_build_probe_rsp(addr bytes[8], vif, addr length) == expected
            doAssert bytes == bounded

# The fixed pool permits a body that ends exactly at its final byte.
reset(0, 3, 2, 1, 2437, 12)
appIeProbeRespPtr = addr application[0]
appIeProbeRespLen = 0
let fixedLength = meProbeResponseLength(0)
appIeProbeRespLen = (488 - fixedLength).uint16
var length: uint16
doAssert me_build_probe_rsp(addr bytes[8], 0, addr length) == 488
guard(488)
for value in bytes.mitems: value = 0xA5
inc appIeProbeRespLen
doAssert me_build_probe_rsp(addr bytes[8], 0, addr length) == 0
doAssert length == 0
for value in bytes: doAssert value == 0xA5

# A nil application pointer retains the existing no-append behavior.
reset(0, 0, 0, 0, 2437, 4)
appIeProbeRespPtr = nil
appIeProbeRespLen = high(uint16)
doAssert me_build_probe_rsp(addr bytes[8], 0, addr length) == 30
guard(30)
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", ["public", "bounded"])
def test_probe_capacity(tmp_path: Path, mode: str, case: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    source = tmp_path / "probe_capacity.nim"
    source.write_text(program_source(PUBLIC_CHECKS if case == "public" else BOUNDED_CHECKS))
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([
        nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}", *flags[mode], str(source),
    ], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    assert result.returncode == 0, result.stdout
