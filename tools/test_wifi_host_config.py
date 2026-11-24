"""Propagate firmware configuration failures through host startup."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    startup = FW.parent / "main/startup_parts"
    code = f'import "{FW.parent / "host_table_layout.nim"}"\n' + r'''
type
  BlHw = object
    bytes: array[1024, uint8]
  MmVersionCfm = object
    bytes: array[24, uint8]
const
  BlHwVifsOff = 52'u
  BlHwModParamsOff = WifiHostModParamsOffset
  BlHwIpcEnvOff = 48'u
  SizeMmVersionCfm = 24
  IpcIrqE2aAll = 0x000007FF'u32
var
  hw: BlHw
  bl_mod_params: array[48, uint8]
  calls: seq[string]
  failedStage: int
  failure: cint
  ipc = cast[pointer](0x1234'u)
proc hwPtr(): ptr BlHw = addr hw
proc step(name: string; stage: int): cint =
  calls.add(name)
  if failedStage == stage: failure else: 0
proc initListHead(p: pointer; offset: uint) =
  doAssert p == (addr hw) and offset == BlHwVifsOff
  calls.add("list")
proc storePtr(p: pointer; offset: uint; value: pointer) =
  doAssert p == (addr hw) and offset == BlHwModParamsOff
  doAssert value == addr bl_mod_params
  calls.add("params")
proc loadPtr(p: pointer; offset: uint): pointer =
  doAssert p == (addr hw) and offset == BlHwIpcEnvOff
  ipc
proc zero(p: pointer; count: int) = zeroMem(p, count)
proc bl_platform_on(p: ptr BlHw): cint =
  doAssert p == addr hw
  step("platform", 0)
proc ipc_host_enable_irq(p: pointer; mask: uint32) =
  doAssert p == ipc and mask == IpcIrqE2aAll
  calls.add("ipc-irq")
proc bl_wifi_enable_irq(): cint = step("wifi-irq", -2)
proc bl_send_reset(p: ptr BlHw): cint = step("reset", 1)
proc bl_os_msleep(ms: uint32) =
  doAssert ms == 5
  calls.add("wait")
proc bl_send_version_req(p: ptr BlHw; cfm: ptr MmVersionCfm): cint =
  doAssert cfm[].bytes == default(typeof(cfm[].bytes))
  step("version", 2)
proc bl_handle_dynparams(p: ptr BlHw): cint = step("dynamic", 3)
proc bl_send_me_config_req(p: ptr BlHw): cint = step("me-config", 4)
proc bl_send_me_chan_config_req(p: ptr BlHw): cint = step("channels", 5)
proc bl_main_lowlevel_init() = calls.add("lowlevel")
proc bl_open(p: ptr BlHw): cint =
  doAssert p == addr hw
  step("open", 6)
proc setup(stage: int; status: cint) =
  calls.setLen(0)
  failedStage = stage
  failure = status
const stages = ["list", "params", "platform", "ipc-irq", "wifi-irq",
                "reset", "wait", "version", "dynamic", "me-config", "channels"]
const stop = [3, 6, 8, 9, 10, 11]
'''
    code += procedure((startup / "cfg80211_init.nim").read_text(), "cfg80211_init")
    code += procedure((startup / "rtthread_start.nim").read_text(), "bl_main_rtthread_start")
    return code


CASES = {
    "configuration_results": r'''
for status in [-12.cint, -16.cint, -2.cint]:
  for stage in 0..5:
    setup(stage, status)
    doAssert cfg80211_init(addr hw) == status,
      "configuration error was not returned: " & $stage
    doAssert calls == @stages[0..<stop[stage]]
setup(-1, 0)
doAssert cfg80211_init(addr hw) == 0 and calls == @stages
setup(-1, 0)
doAssert cfg80211_init(nil) == -1 and calls.len == 0
''',
    "startup_does_not_open_after_configuration_error": r'''
for status in [-12.cint, -16.cint, -2.cint]:
  for stage in 0..6:
    setup(stage, status)
    var resultHw: ptr BlHw
    doAssert bl_main_rtthread_start(addr resultHw) == status
    doAssert resultHw == addr hw
    let expected = if stage == 6: @["lowlevel"] & @stages & @["open"]
                   else: @["lowlevel"] & @stages[0..<stop[stage]]
    doAssert calls == expected
setup(-1, 0)
doAssert bl_main_rtthread_start(nil) == -1 and calls.len == 0
''',
    "configuration_retry": r'''
for stage in [4, 5]:
  setup(stage, -12)
  var resultHw: ptr BlHw
  doAssert bl_main_rtthread_start(addr resultHw) == -12
  doAssert "open" notin calls
  setup(-1, 0)
  doAssert bl_main_rtthread_start(addr resultHw) == 0
  doAssert resultHw == addr hw
  doAssert calls == @["lowlevel"] & @stages & @["open"]
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_host_configuration(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
