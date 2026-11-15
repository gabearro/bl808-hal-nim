"""Keep host TX completion delivery intact across optional processing errors."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_host_completion_owner import CHECKS
from test_wifi_message_allocation import run_program
from test_wifi_tx_confirmation_handoff import source as handoff_source


def source() -> str:
    helpers = CHECKS.split("# A station restart", 1)[0]
    code = handoff_source().replace(CHECKS, helpers, 1)
    code = """
var failRate = -1
var failTrace, failDrain: bool
var rateCalls: array[7, int]
""" + code
    old = procedure(code, "rc_update_counters").split("\nvar\n", 1)[0]
    code = code.replace(old, r'''
proc rc_update_counters(station: uint8; attempts, failures: uint32;
                        aggregate, retry: bool) {.raises: [Exception].} =
  doAssert not interruptsEnabled
  inc rateCalls[station]
  stationAttempts[station] += attempts
  if station.int == failRate:
    raise newException(ValueError, "rate processing stopped")
''', 1)
    code = code.replace(procedure(code, "nimFwTrace2U32"), r'''
proc nimFwTrace2U32(s: string; a, b: uint32) {.raises: [Exception].} =
  if failTrace:
    failTrace = false
    raise newException(ValueError, "trace stopped")
''', 1)
    old = procedure(code, "txl_frame_evt")
    code = code.replace(old, old.replace("  inc internalDrains\n",
        "  inc internalDrains\n"
        "  if failDrain: raise newException(ValueError, \"internal completion stopped\")\n"), 1)
    return code + r'''
proc prepare(ac: uint8; incoming: bool) =
  setup()
  interruptsEnabled = incoming
  requireCritical = true
  expectedDrainIrq = incoming
  failRate = -1
  failTrace = false
  failDrain = false
  rateCalls = default(typeof(rateCalls))
  internalQueued = 0
  internalDrains = 0
  ke_env[0] = txl_cfm_evt_bit[ac] or 0x1000
  nimFwDbgCfmTraceCount = 0
proc queue(ac: uint8; index: int) =
  inc txEnv.packetCounter
  co_list_push_back(addr confirmLists[ac], addr wrappers[index].txDesc.link)
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_rate_error_still_completes_current_host_frame(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for ac in 0'u8 .. 4:
  for incoming in [false, true]:
    prepare(ac, incoming)
    queue(ac, 0)
    queue(ac, 1)
    failRate = 0
    var raised = false
    try: txl_cfm_evt(ac)
    except ValueError: raised = true
    doAssert raised and interruptsEnabled == incoming
    doAssert outputs[0] == (0x80800200'u32 or 1)
    doAssert published.first == (addr wrappers[0].link)
    doAssert published.last == (addr wrappers[0].link)
    doAssert txEnv.packetCounter == 1 and wrappers[0].txDesc.active == 0
    doAssert rateCalls[0] == 1 and rateCalls[1] == 0
    doAssert confirmLists[ac].first == (addr wrappers[1].txDesc.link)
    doAssert ke_env[0] == (0x1000 or txl_cfm_evt_bit[ac])
    doAssert indications == @[(1'u32 shl ac)]
    failRate = -1
    txl_cfm_evt(ac)
    doAssert txEnv.packetCounter == 0 and rateCalls[0] == 1 and rateCalls[1] == 1
    doAssert indications == @[(1'u32 shl ac), (1'u32 shl ac)]
    doAssert ke_env[0] == 0x1000 and interruptsEnabled == incoming
    drainPublished()
    doAssert consumed == @[0, 1]
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_trace_error_rearms_remaining_confirmations(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for ac in 0'u8 .. 4:
  for incoming in [false, true]:
    prepare(ac, incoming)
    queue(ac, 0)
    queue(ac, 1)
    failTrace = true
    var raised = false
    try: txl_cfm_evt(ac)
    except ValueError: raised = true
    doAssert raised and txEnv.packetCounter == 1
    doAssert ke_env[0] == (0x1000 or txl_cfm_evt_bit[ac])
    doAssert indications == @[(1'u32 shl ac)]
    doAssert confirmLists[ac].first == (addr wrappers[1].txDesc.link)
    doAssert interruptsEnabled == incoming
    txl_cfm_evt(ac)
    doAssert txEnv.packetCounter == 0 and rateCalls[0] == 1 and rateCalls[1] == 1
    doAssert indications == @[(1'u32 shl ac), (1'u32 shl ac)]
    doAssert ke_env[0] == 0x1000 and interruptsEnabled == incoming
    drainPublished()
    doAssert consumed == @[0, 1]
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_batch_host_notification_survives_internal_completion_error(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for ac in 0'u8 .. 4:
  for incoming in [false, true]:
    prepare(ac, incoming)
    var batch: CoList
    for index in 0 .. 1:
      co_list_push_back(addr batch, addr wrappers[index].txDesc.link)
    txEnv.packetCounter = 2
    failDrain = true
    var raised = false
    try: txl_cfm_flush(ac, addr batch, 0x40000000'u32)
    except ValueError: raised = true
    doAssert raised and txEnv.packetCounter == 0 and internalDrains == 1
    doAssert batch.first == nil and interruptsEnabled == incoming
    doAssert published.first == (addr wrappers[0].link)
    doAssert published.last == (addr wrappers[1].link)
    doAssert indications == @[(1'u32 shl ac)], "published completions were not notified"
    drainPublished()
    doAssert consumed == @[0, 1]
''')
