"""Keep station TX policy bytes intact unless the diagnostic override is enabled."""

from pathlib import Path

import pytest

from test_wifi_lower_preparation import CHECKS, build_program
from test_wifi_message_allocation import run_program


def source(trace: bool, flags: tuple[str, ...] = ()) -> str:
    defines = (["bl808WifiConnectTrace"] if trace else []) + list(flags)
    prefix = "".join(f"{{.define: {flag}.}}\n" for flag in defines)
    return prefix + build_program().split(CHECKS, 1)[0]


CHECK_POLICY = r'''
for protocol in [0x0800'u16, 0x0806, 0x888E, 0x8E88, 0x86DD, 0x88B5, 1500, 1536]:
  for seed in 0'u32 .. 7:
    reset()
    invalidated = false
    frames = default(typeof(frames))
    links = default(typeof(links))
    hw = default(typeof(hw))
    backup = default(typeof(backup))
    let frameLen = lmacGateHalfword(protocol)
    frames[0] = HostTxDescView(vifIdx: 1, staInfoIdx: 0, staIdx: 0,
      hdrLen: (if protocol >= 1536: 34'u8 else: 26'u8), frameLen: frameLen,
      policy: addr templateBytes, hwDesc: addr hw[0], queueFirst: cast[pointer](1))
    var expectedWords: array[15, uint32]
    for word in 0 ..< expectedWords.len:
      expectedWords[word] = 0xA5000080'u32 + word.uint32 * 0x103 + seed * 0x11
    copyMem(addr templateBytes[0], addr expectedWords[0], sizeof(templateBytes))
    let original = templateBytes
    when defined(bl808WifiBootstrapRetryWorkaround):
      if protocol in [0x0800'u16, 0x0806, 0x888E, 0x8E88]:
        when not defined(bl808WifiKeepEapolRcPrimary):
          expectedWords[5] = 0x80000400'u32
        when defined(bl808WifiForceEapolPrimaryLegacy):
          expectedWords[5] = 0x8000040A'u32
        expectedWords[6] = 0x8000040A'u32
        expectedWords[7] = 0x80001007'u32
        expectedWords[8] = 0x80000400'u32
        for word in 9 .. 12: expectedWords[word] = 0x70
    var expected: array[60, uint8]
    copyMem(addr expected[0], addr expectedWords[0], sizeof(expected))
    doAssert txl_buffer_alloc(addr frames[0], 3, 0) == cast[pointer](addr links[0])
    doAssert templateBytes == original, "station policy source changed"
    doAssert links[0].rateTemplate == expected, "copied TX policy was overwritten"
    doAssert backup[3].first == cast[pointer](addr links[0])
    doAssert backup[3].last == cast[pointer](addr links[0]) and links[0].next == nil
    doAssert interrupts
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("trace", [False, True], ids=["no-trace", "trace"])
def test_default_preserves_station_policy(tmp_path: Path, mode: str, trace: bool) -> None:
    run_program(tmp_path, mode, source(trace) + CHECK_POLICY)


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("primary", [(), ("bl808WifiKeepEapolRcPrimary",),
                                    ("bl808WifiForceEapolPrimaryLegacy",),
                                    ("bl808WifiKeepEapolRcPrimary", "bl808WifiForceEapolPrimaryLegacy")],
                         ids=["default", "keep", "legacy", "legacy-over-keep"])
def test_explicit_workaround(tmp_path: Path, mode: str, primary: tuple[str, ...]) -> None:
    flags = ("bl808WifiBootstrapRetryWorkaround",) + primary
    run_program(tmp_path, mode, source(True, flags) + CHECK_POLICY)


@pytest.mark.parametrize("flags", [("bl808WifiKeepEapolRcPrimary",),
                                  ("bl808WifiForceEapolPrimaryLegacy",),
                                  ("bl808WifiKeepEapolRcPrimary", "bl808WifiForceEapolPrimaryLegacy")])
def test_primary_options_do_not_enable_workaround(tmp_path: Path, flags: tuple[str, ...]) -> None:
    run_program(tmp_path, "checked", source(True, flags) + CHECK_POLICY)
