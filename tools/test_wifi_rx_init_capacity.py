"""Require a current descriptor and a submitted descriptor in both RX rings."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_rx_init_owner import source as owner_source
from test_wifi_rx_init_result import source as result_source


CASES = {
    "insufficient_capacity": r'''
for headerCount in 0..4:
  for payloadCount in 0..4:
    if headerCount >= 2 and payloadCount >= 2: continue
    for incoming in [0'u32, 8]:
      setup()
      irqLevel = incoming
      markReplacement()
      for i in 0..<41:
        headers[i].usedFlag = (i >= headerCount).uint32
        payloads[i].usedFlag = (i >= payloadCount).uint32
      let oldHeaders = headers
      let oldPayloads = payloads
      let oldSoftware = software
      let oldLower = lower
      let oldHardware = hardware
      doAssert not rxl_hwdesc_init(0), "incomplete RX rings reported success"
      doAssert headers == oldHeaders and payloads == oldPayloads
      doAssert software == oldSoftware and lower == oldLower and hardware == oldHardware
      doAssert triggers.len == 0 and hdSubmitted == 0 and pdSubmitted == 0
      doAssert forgotten.len == 0
      doAssert enters == 1 and exits == 1 and irqLevel == incoming
      doAssert txControlState.resetInProgress == 1 and disabledMacIrqs == 1
      doAssert resetEvents == 0x80000000'u32
''',
    "minimum_complete_chains": r'''
for headerCount in 2..4:
  for payloadCount in 2..4:
    setup()
    for i in 0..<41:
      headers[i].usedFlag = (i >= headerCount).uint32
      payloads[i].usedFlag = (i >= payloadCount).uint32
    let oldHeaders = headers
    let oldPayloads = payloads
    doAssert rxl_hwdesc_init(0)
    doAssert lower.currentHd == addr headers[0]
    doAssert lower.submittedHead == addr headers[1]
    doAssert lower.submittedTail == addr headers[headerCount - 1]
    doAssert hardware.pdCurrent == addr payloads[0]
    doAssert hardware.pdTail == addr payloads[payloadCount - 1]
    doAssert hdSubmitted == pointerAddrU32(addr headers[1])
    doAssert pdSubmitted == pointerAddrU32(addr payloads[1])
    doAssert triggers == @[0x04000000'u32, 0x08000000'u32]
    for i in 0..<headerCount:
      let next = if i + 1 < headerCount: cast[pointer](addr headers[i + 1]) else: nil
      doAssert headers[i].next == next
    for i in 0..<payloadCount:
      let next = if i + 1 < payloadCount: cast[pointer](addr payloads[i + 1]) else: nil
      doAssert payloads[i].next == next
    for i in headerCount..<41: doAssert headers[i] == oldHeaders[i]
    for i in payloadCount..<41: doAssert payloads[i] == oldPayloads[i]
    doAssert txControlState.resetInProgress == 0 and resetEvents == 0
    doAssert enters == 1 and exits == 1 and irqLevel == 8
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_rx_ring_capacity(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, owner_source() + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_rx_capacity_failure_stops_recovery(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, result_source() + r'''
for forced in [false, true]:
  for headersShort in [false, true]:
    for incoming in [0'u32, 8]:
      setupRun(incoming)
      let oldMm = mm
      for i in 1..<41:
        if headersShort: headers[i].usedFlag = 1
        else: payloads[i].usedFlag = 1
      if forced: doAssert not mm_force_idle_req()
      else: bl_reset_evt()
      let expected = if forced: @["mac-reset"]
                     else: @["clear:2147483648", "mac-reset"]
      doAssert steps == expected and states.len == 0 and mm == oldMm
      doAssert triggers.len == 0 and listClears == 0 and upperInitializations == 0
      doAssert txControlState.resetInProgress == 1 and disabledMacIrqs == 1
      doAssert resetEvents == 0x84000000'u32 and irqLevel == incoming
      checkReplacement()

      for i in 0..<41:
        headers[i].usedFlag = 0
        payloads[i].usedFlag = 0
      steps.setLen(0)
      if forced: doAssert mm_force_idle_req()
      else: bl_reset_evt()
      doAssert "tx-reset" in steps
      doAssert txControlState.resetInProgress == 0 and irqLevel == incoming
      doAssert triggers == @[0x04000000'u32, 0x08000000'u32]
      doAssert lower.queue.first == nil and upper.uploadList.first == nil
''')
