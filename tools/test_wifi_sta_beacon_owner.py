"""Exercise station beacon timers across callback-driven session changes."""

from pathlib import Path

import pytest

from test_wifi_beacon_event import source as event_source
from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    code = event_source()
    code = r'''
var
  steps: seq[string]
  onBoundary: proc(name: string)
  incomingIrq: bool
proc boundary(name: string) =
  doAssert interrupts == incomingIrq, "callback did not preserve the incoming IRQ state"
  steps.add(name)
  if onBoundary != nil: onBoundary(name)
''' + code
    # The globals above need only a forward reference to the fixture IRQ flag.
    code = code.replace("proc boundary(name: string) =", "proc boundary(name: string)\nproc observedBoundary(name: string) =", 1)
    code = code.replace("  doAssert interrupts == incomingIrq,", "  doAssert irqEnabled() == incomingIrq,", 1)
    code = "proc irqEnabled(): bool\n" + code
    code += "\nproc irqEnabled(): bool = interrupts\nproc boundary(name: string) = observedBoundary(name)\n"
    replacements = {
        "mm_timer_set": r'''
proc mm_timer_set(timer: ptr Timer; expiry: uint32) =
  timer.expiry = expiry
  boundary(if timer == addr vifs[0].tbttTimer: "tbtt" else: "keepalive")
''',
        "vif_mgmt_bcn_to_prog": r'''
proc vif_mgmt_bcn_to_prog(p: pointer) = boundary("program")
''',
        "chan_tbtt_switch_update": r'''
proc chan_tbtt_switch_update(p: pointer; expiry: uint32) = boundary("switch")
''',
        "chan_is_on_channel": r'''
proc chan_is_on_channel(p: pointer): bool =
  boundary("channel")
  true
''',
        "ps_check_tbtt": r'''
proc ps_check_tbtt(p: pointer) = boundary("ps")
''',
        "txl_frame_send_null_frame": r'''
proc txl_frame_send_null_frame(sta: uint8; callback: pointer; arg: uint32): uint8 =
  doAssert sta == 3 and callback == cast[pointer](mm_ap_probe_cfm)
  doAssert arg == pointerAddrU32(addr vifs[0])
  boundary("send")
  1
''',
        "wifi_hosal_pm_post_event": r'''
proc wifi_hosal_pm_post_event(event, value: uint32; arg: pointer) =
  boundary("pm")
''',
    }
    for name, replacement in replacements.items():
        code = code.replace(procedure(code, name), replacement, 1)
    code = code.replace('  operations.add("log")\n', '  operations.add("log")\n  boundary("log")\n', 1)
    return code + r'''
proc prepareOwner(irq: bool; probe = 100'u8) =
  setup()
  incomingIrq = irq
  interrupts = irq
  logging = true
  steps.setLen(0)
  onBoundary = nil
  vifs[0].state = 1
  vifs[0].staIdx = 3
  vifs[0].probeCount = probe
  vifs[0].tbttTimer.expiry = 1000
  stations[3].initialRateConfig = 102400
  mm.keepAliveInterval = 500
'''


CASES = {
    "tbtt_ownership": r'''
let order = @["log", "tbtt", "keepalive", "program", "switch", "channel", "ps", "send"]
for irq in [false, true]:
  for position in 0 .. 6:
    for change in 0 .. 8:
      prepareOwner(irq)
      var snapshot: Vif
      onBoundary = proc(name: string) =
        if name != order[position]: return
        case change
        of 0: inc rxVifEpochs[0]
        of 1: inc stationEpochs[3]
        of 2: inc txResetEpoch
        of 3: resetting = true
        of 4: retiring[0] = true
        of 5: vifs[0].state = 0
        of 6: stations[3].valid = 0
        of 7: stations[3].instNbr = 1
        else: inc rxVifEpochs[1]
        snapshot = vifs[0]
      mm_sta_tbtt(addr vifs[0])
      doAssert interrupts == irq
      if change == 8:
        doAssert steps == order and vifs[0].probeCount == 101
      else:
        doAssert steps == order[0 .. position], "TBTT continued after its session changed"
        doAssert vifs[0] == snapshot, "old TBTT changed the replaced VIF"
''',
    "timeout_ownership": r'''
for irq in [false, true]:
  for change in 0 .. 6:
    prepareOwner(irq)
    vifs[0].flags = 0xA5A50003'u32
    vifs[0].beaconLossCount = 7
    onBoundary = proc(name: string) =
      if name != "log": return
      case change
      of 0: inc rxVifEpochs[0]
      of 1: inc stationEpochs[3]
      of 2: inc txResetEpoch
      of 3: resetting = true
      of 4: retiring[0] = true
      of 5: vifs[0].staIdx = 4
      else: inc rxVifEpochs[1]
    mm_sta_timer_bcn_timeout(addr vifs[0])
    doAssert interrupts == irq and steps == @["log"]
    if change == 6:
      doAssert vifs[0].beaconLossCount == 8 and vifs[0].flags == 0xA5A50002'u32
    else:
      doAssert vifs[0].beaconLossCount == 7 and vifs[0].flags == 0xA5A50003'u32,
        "expired beacon timer changed the replacement VIF"
''',
    "invalid_and_blocked_inputs": r'''
for irq in [false, true]:
  for action in 0 .. 1:
    for gate in 0 .. 2:
      prepareOwner(irq)
      let before = vifs[0]
      var foreign = before
      if gate == 0: resetting = true
      elif gate == 1: retiring[0] = true
      let p = if gate == 2: cast[pointer](addr foreign) else: cast[pointer](addr vifs[0])
      if action == 0: mm_sta_tbtt(p)
      else: mm_sta_timer_bcn_timeout(p)
      doAssert steps.len == 0 and vifs[0] == before and foreign == before
      doAssert interrupts == irq
    prepareOwner(irq)
    if action == 0: mm_sta_tbtt(nil)
    else: mm_sta_timer_bcn_timeout(nil)
    doAssert steps.len == 0 and interrupts == irq
  for station in [7'u8, 8, 254, 255]:
    prepareOwner(irq)
    vifs[0].staIdx = station
    let before = vifs[0]
    mm_sta_tbtt(addr vifs[0])
    doAssert steps == @["log"] and vifs[0] == before and interrupts == irq,
      "invalid station index reached TBTT scheduling"
''',
    "errors_and_normal_flow": r'''
let order = @["log", "tbtt", "keepalive", "program", "switch", "channel", "ps"]
for irq in [false, true]:
  for position in 0 .. 6:
    prepareOwner(irq)
    onBoundary = proc(name: string) =
      if name == order[position]: raise newException(ValueError, "timer callback stopped")
    var raised = false
    try: mm_sta_tbtt(addr vifs[0])
    except ValueError: raised = true
    doAssert raised and steps == order[0 .. position] and interrupts == irq
  for probe in [0'u8, 49, 100, 255]:
    prepareOwner(irq, probe)
    mm_sta_tbtt(addr vifs[0])
    let count = probe + 1
    var expected = order
    if count > 100: expected.add("send")
    elif count > 49: expected.add("pm")
    doAssert steps == expected and interrupts == irq
    doAssert vifs[0].tbttTimer.expiry == 103400
    doAssert vifs[0].keepAliveTimer.expiry == 244
    doAssert vifs[0].tbttCount == 1 and vifs[0].probeCount == count
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_station_beacon_timer_owner(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
