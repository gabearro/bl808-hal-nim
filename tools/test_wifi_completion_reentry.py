"""Retain dequeued host completions and rate ownership across reentrant work."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_flush_recovery import integrated_source
from test_wifi_message_allocation import run_program
from test_wifi_rate_confirmation import PLATFORM as RATE_PLATFORM


def host_source() -> str:
    code = integrated_source()
    old = procedure(code, "me_tx_cfm_singleton")
    code = code.replace(old, r'''
var onRate: proc()
proc me_tx_cfm_singleton(p: pointer) =
  if onRate != nil: onRate()
''', 1)
    tx = (FW / "tx_layer.nim").read_text()
    body = procedure(tx, "txlCfmPending") + procedure(tx, "txl_cfm_evt")
    existing = set(re.findall(r"\bnimFwDbg\w+", code))
    declarations = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", body)) - existing)
    )
    return code + declarations + body


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_reset_accounts_for_current_completion_before_reuse(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, host_source() + r'''
for incoming in [false, true]:
  setup(incoming)
  for i in 0 .. 1:
    frames[i].queueFirst = cast[pointer](1)
    frames[i].usedFlag = 1
    co_list_push_back(addr confirmLists[2], addr frames[i].link)
  txEnv.packetCounter = 2
  ke_env[0] = txl_cfm_evt_bit[2]
  var replacement: HostTxDescView
  var newHardware: HwDesc
  onRate = proc() =
    onRate = nil
    doAssert interruptsEnabled == incoming
    doAssert txl_reset()
    doAssert txEnv.packetCounter == 0 and hardwareResets == 1
    doAssert hostCompletions.len == 2
    frames[0].hwDesc = addr newHardware
    frames[0].active = 1
    frames[0].bufDesc = cast[pointer](0x1234)
    txEnv.ac[3].current = addr newHardware
    co_list_push_back(addr txEnv.ac[3].pending, addr frames[0].link)
    txEnv.packetCounter = 1
    replacement = frames[0]
  txl_cfm_evt(2)
  doAssert frames[0] == replacement
  doAssert txEnv.packetCounter == 1 and txEnv.ac[3].pending.first == (addr frames[0].link)
  doAssert hostCompletions.len == 2 and hostCompletions[0] != hostCompletions[1]
  doAssert txActiveFlush == nil and interruptsEnabled == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_nested_flush_delivers_current_completion_only_once(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, host_source() + r'''
for incoming in [false, true]:
  setup(incoming)
  var ancestor: TxFlushBatch
  txActiveFlush = addr ancestor
  for i in 0 .. 1:
    frames[i].queueFirst = cast[pointer](1)
    frames[i].usedFlag = 1
    co_list_push_back(addr confirmLists[2], addr frames[i].link)
  txEnv.packetCounter = 2
  ke_env[0] = txl_cfm_evt_bit[2]
  onRate = proc() =
    onRate = nil
    doAssert interruptsEnabled == incoming
    doAssert txActiveFlush != nil and txActiveFlush != (addr ancestor)
    doAssert txActiveFlush.confirmations.first == (addr frames[0].link)
    txl_cfm_flush(2, addr txActiveFlush.confirmations, 0x40000000'u32)
    doAssert txEnv.packetCounter == 1 and txActiveFlush.confirmations.first == nil
  txl_cfm_evt(2)
  doAssert txEnv.packetCounter == 0 and hostCompletions.len == 2
  doAssert hostCompletions[0] == (addr frames[0]) and hostCompletions[1] == (addr frames[1])
  doAssert indications == @[4'u32, 4]
  doAssert txActiveFlush == (addr ancestor) and interruptsEnabled == incoming
  txActiveFlush = nil
''')


def rate_source() -> str:
    code = RATE_PLATFORM
    support = r'''
var assertionHook: proc()
'''
    code = code.replace("proc assert_err(", support + "proc assert_err(", 1)
    code = code.replace("= assertionLines.add(line)", "=\n  assertionLines.add(line)\n  if assertionHook != nil: assertionHook()", 1)
    source = (FW / "rate_control.nim").read_text()
    body = procedure(source, "rcAccountCounters") + procedure(source, "rc_update_counters")
    declarations = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", body)))
    )
    return code + declarations + body


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_assertion_replacement_stops_old_rate_updates(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, rate_source() + r'''
for kind in 0 .. 4:
  for incoming in [false, true]:
    setup()
    interrupts = incoming
    txResetEpoch = 0
    stationEpochs = default(typeof(stationEpochs))
    rxVifEpochs = default(typeof(rxVifEpochs))
    stats[0].entries[0] = RateEntry(attempts: 65535, successes: 4)
    var alternate, snapshot: Stats
    var oldSnapshot: Stats
    assertionHook = proc() =
      assertionHook = nil
      doAssert not interrupts
      case kind
      of 0: inc stationEpochs[0]
      of 1: inc txResetEpoch
      of 2: inc rxVifEpochs[0]
      of 3: stations[0].instNbr = 1
      else: stations[0].rcStats = addr alternate
      stats[0] = default(Stats)
      stats[0].retryLimit = 7
      alternate.retryLimit = 9
      snapshot = alternate
      oldSnapshot = stats[0]
    rc_update_counters(0, 8, 8, false, false)
    doAssert assertionLines == @[2040]
    doAssert stats[0] == oldSnapshot and alternate == snapshot,
      "old rate update changed replacement state after its assertion callback"
    doAssert interrupts == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_counter_assertion_stops_retry_and_stage_updates(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, rate_source() + r'''
for incoming in [false, true]:
  for failedSlot in 0 .. 3:
    for stage in 0'u8 .. 3:
      for finalGroup in [false, true]:
        setup()
        interrupts = incoming
        stats[0].updateStage = stage
        stats[0].retryLimit = 7
        stats[0].entries[failedSlot] = RateEntry(attempts: 65535, successes: 4)
        var atAssertion: Stats
        assertionHook = proc() =
          doAssert not interrupts
          atAssertion = stats[0]
        let attempts = failedSlot.uint32 * 4 + (if finalGroup: 1'u32 else: 8'u32)
        let failures = if finalGroup: failedSlot.uint32 * 4 else: attempts
        rc_update_counters(0, attempts, failures, false, false)
        doAssert assertionLines == @[2040]
        doAssert stats[0] == atAssertion,
          "counter assertion must stop later retry and state-machine updates"
        doAssert interrupts == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_counter_assertion_preserves_same_identity_repair(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, rate_source() + r'''
for incoming in [false, true]:
  setup()
  interrupts = incoming
  stats[0].entries[0] = RateEntry(attempts: 65535, successes: 4)
  var repaired: Stats
  assertionHook = proc() =
    doAssert not interrupts
    stats[0] = default(Stats)
    stats[0].retryLimit = 7
    for slot in 0 .. 3: stats[0].retrySlots[slot].rateIdx = slot.uint16
    repaired = stats[0]
  rc_update_counters(0, 8, 8, false, false)
  doAssert assertionLines == @[2040] and stats[0] == repaired
  doAssert interrupts == incoming
''')
