"""Ensure FCAL never publishes stale samples or gives up before convergence."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_lo_search import lo_source
from test_wifi_rf_power_replay import RF


def progress_source() -> str:
    rf = RF.read_text()
    code = lo_source()
    start = code.index("proc sampleRfFcalCount(): uint16 =")
    end = code.index("proc rfPriWifiPllConfig()", start)
    code = code[:start] + "proc sampleRfFcalCount(): uint16\n" + code[end:]
    code = code.replace(
        "var events:",
        "var readyAfter, readyReads, resultReads: int\nvar events:",
        1,
    ).replace(
        "  if p == (addr rf70.acalCtrlA4)",
        "  if p == (addr rf70.fcalAc):\n"
        "    inc readyReads\n"
        "    result = p[] and not 0x100000'u32\n"
        "    if readyReads > readyAfter: result = result or 0x100000'u32\n"
        "    return\n"
        "  if p == (addr rf70.calResultA8):\n"
        "    inc resultReads\n"
        "    doAssert readyReads > readyAfter, \"FCAL read a stale count before READY\"\n"
        "  if p == (addr rf70.acalCtrlA4)",
        1,
    )
    code += r'''
const
  RfFcalWaitLimit = 2
  RfFcalReadyMask = 0x100000'u32
  RfFcalStartMask = 0x10'u32
var nim_wifi_rf_fcal_wait_timeout_count: uint32
'''
    return code + procedure(rf, "waitRfFcalReady") + procedure(rf, "sampleRfFcalCount")


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_sampler_waits_past_diagnostic_thresholds(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, progress_source() + r'''
for count in [10, 0, 1, 2, 3, 4, 100]:
  loSetup(4)
  rf70.fcalAc = 0xA5000000'u32
  rf70.calResultA8 = 0xA7C31234'u32
  readyAfter = count + 1 # START RMW also reads the register.
  readyReads = 0
  resultReads = 0
  let stalls = nim_wifi_rf_fcal_wait_timeout_count
  doAssert sampleRfFcalCount() == 0xA7C3
  doAssert resultReads == 1 and readyReads > readyAfter
  doAssert (rf70.fcalAc and 0x10) == 0
  doAssert nim_wifi_rf_fcal_wait_timeout_count == stalls + (count div RfFcalWaitLimit).uint32
  doAssert delays.len == 0, "vendor READY polling has no inserted microsecond delays"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_coarse_search_keeps_retrying_until_code_is_valid(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, lo_source() + r'''
for row in 0 ..< 6:
  for attempts in [0, 1, 3, 4, 5, 20]:
    loSetup(row)
    let limits = VendorRange[row]
    for retry in 0 ..< attempts:
      for i in 0 ..< 7: sampleValues.add(limits[0] - 1)
    # On the successful attempt, move from 128 to 64, then accept 64.
    sampleValues.add(limits[0] - 1)
    sampleValues.add(limits[0] + 1)
    var wantC0 = rf70.sdmCtrlC0
    var wantB8 = rf70.txcalCtrlB8
    var expected: seq[tuple[address: uint, value: uint32]]
    for retry in 0 ..< attempts:
      wantC0 = wantC0 and not 0x10000'u32
      expected.add((cast[uint](addr rf70.sdmCtrlC0), wantC0))
      wantB8 = wantB8 or 0x10000'u32
      expected.add((cast[uint](addr rf70.txcalCtrlB8), wantB8))
      wantC0 = wantC0 or 0x10000'u32
      expected.add((cast[uint](addr rf70.sdmCtrlC0), wantC0))
      wantB8 = wantB8 and not 0x10000'u32
      expected.add((cast[uint](addr rf70.txcalCtrlB8), wantB8))
    doAssert chooseRfBaseFcalCode() == 64, "coarse FCAL fabricated code 128 before convergence"
    doAssert sampleIndex == attempts * 7 + 2
    var transitions: seq[tuple[address: uint, value: uint32]]
    for event in mmioWrites:
      if event.address in [cast[uint](addr rf70.sdmCtrlC0),
                           cast[uint](addr rf70.txcalCtrlB8)]:
        transitions.add(event)
    doAssert transitions == expected, "coarse retry resets differ in address, value, or order"
    for i in 0 ..< attempts:
      doAssert delays[i * 9 + 7 .. i * 9 + 8] == @[50'u32, 50]
''')
