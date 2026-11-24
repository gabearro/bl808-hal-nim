"""Check the pinned sysctrl register sequence before Nim table initialization."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_sysctrl_clocks_precede_runtime_tables(tmp_path: Path, mode: str) -> None:
    sysctrl = procedure((FW / "coex_intc_sysctrl.nim").read_text(), "sysctrl_init")
    run_program(tmp_path, mode, r'''
const MAC_PL_BASE = 0x24900000'u
var calls: seq[string]

proc regWrite(address: uint; value: uint32) =
  if address == MAC_PL_BASE + 0x68'u:
    doAssert value == 0x8000000C'u32
    doAssert calls.len == 0
    calls.add("diagnostic")
  else:
    doAssert address == MAC_PL_BASE + 0xE0'u
    doAssert value == 0xA501FF20'u32
    doAssert calls == @["diagnostic", "clock-read"]
    calls.add("clock-write")

proc regRead(address: uint): uint32 =
  doAssert address == MAC_PL_BASE + 0xE0'u
  doAssert calls == @["diagnostic"]
  calls.add("clock-read")
  0xA5000020'u32

proc wifi_fw_runtime_init() =
  doAssert calls == @["diagnostic", "clock-read", "clock-write"]
  calls.add("runtime")

proc ke_task_init() =
  doAssert calls == @["diagnostic", "clock-read", "clock-write", "runtime"]
  calls.add("task")
''' + sysctrl + r'''
sysctrl_init()
doAssert calls == @["diagnostic", "clock-read", "clock-write", "runtime", "task"]
''')
