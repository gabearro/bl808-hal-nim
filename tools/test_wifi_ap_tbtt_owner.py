"""Keep one AP TBTT event bound to its original VIFs across callbacks."""

from pathlib import Path

import pytest

from test_wifi_beacon_event import source as event_source
from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    code = "proc boundary(name: string)\n" + event_source()
    code = code.replace('  operations.add("log")\n',
                        '  operations.add("log")\n  boundary("log")\n', 1)
    code = code.replace('  operations.add("flush")\n',
                        '  operations.add("flush")\n  boundary("flush")\n', 1)
    replacements = {
        "vif_mgmt_bcn_to_prog": r'''
proc vif_mgmt_bcn_to_prog(p: pointer) =
  programmed.add(p)
  boundary(if p == addr vifs[0]: "program0" else: "program1")
''',
        "chan_tbtt_switch_update": r'''
proc chan_tbtt_switch_update(p: pointer; expiry: uint32) =
  switchTimes.add(expiry)
  boundary(if p == addr vifs[0]: "switch0" else: "switch1")
''',
        "mm_bcn_transmit": r'''
proc mm_bcn_transmit(index: uint8) =
  doAssert index == 0
  boundary("transmit")
''',
        "sta_mgmt_aging_postponed_desc": r'''
proc sta_mgmt_aging_postponed_desc(p: pointer; status: uint32): uint32 =
  inc aged
  boundary("age")
''',
    }
    for name, replacement in replacements.items():
        code = code.replace(procedure(code, name), replacement, 1)
    return code + r'''
var
  steps: seq[string]
  onBoundary: proc(name: string)
proc boundary(name: string) =
  doAssert steps.len < 32, "TBTT revisited a changed VIF link"
  steps.add(name)
  if onBoundary != nil: onBoundary(name)
proc prepareOwner(irq: bool) =
  setup()
  interrupts = irq
  logging = true
  steps.setLen(0)
  onBoundary = nil
  for i in 0 .. 1:
    vifs[i].vifType = VIF_TYPE_AP
    vifs[i].staIdx = 255
    vifs[i].beaconCountdown = 1
    vifs[i].beaconDivisor = (3 + i).uint8
    vifs[i].apBeaconInterval = 100
    vifs[i].chanCtxt = addr mm
  vifs[0].next = addr vifs[1]
  env.activeList.first = addr vifs[0]
  mmTbttAgingCount0 = 1
  mmTbttAgingCount1 = 1
'''


CASES = {
    "vif_replacement_and_list_changes": r'''
for irq in [false, true]:
  for stage in ["log", "flush", "program0", "switch0"]:
    for target in 0 .. 1:
      prepareOwner(irq)
      var fired = false
      var snapshot: Vif
      onBoundary = proc(name: string) =
        if fired or name != stage: return
        fired = true
        inc rxVifEpochs[target]
        vifs[target].beaconCountdown = 77
        vifs[target].next = addr vifs[target]
        snapshot = vifs[target]
      mm_tbtt_evt()
      doAssert fired and interrupts == irq and not mmTbttActive
      doAssert vifs[target] == snapshot, "old TBTT changed a replacement VIF"
      if target == 0:
        doAssert vifs[1].beaconCountdown == 4 and "program1" in steps
      else:
        doAssert "program1" notin steps and "switch1" notin steps

# A changed link alone must not repeat the first VIF or skip the captured tail.
prepareOwner(true)
onBoundary = proc(name: string) =
  if name == "program0": vifs[0].next = addr vifs[0]
mm_tbtt_evt()
doAssert steps == @["log", "flush", "program0", "switch0", "program1", "switch1", "transmit", "age"]
''',
    "reset_during_callbacks": r'''
let order = @["log", "flush", "program0", "switch0", "program1", "switch1", "transmit", "age"]
for irq in [false, true]:
  for position in 0 ..< order.len:
    prepareOwner(irq)
    onBoundary = proc(name: string) =
      if name == order[position]:
        inc txResetEpoch
        for vif in vifs.mitems: vif.beaconCountdown = 77
        mmTbttAgingCount0 = 7
        mmTbttAgingCount1 = 9
    mm_tbtt_evt()
    doAssert steps == order[0 .. position], "TBTT continued after MAC reset"
    doAssert interrupts == irq and not mmTbttActive
    doAssert vifs[0].beaconCountdown == 77 and vifs[1].beaconCountdown == 77
    doAssert mmTbttAgingCount0 == 7 and mmTbttAgingCount1 == 9
''',
    "nested_event_and_new_vif": r'''
for stage in ["log", "flush", "program0", "transmit", "age"]:
  prepareOwner(true)
  var fired = false
  onBoundary = proc(name: string) =
    if fired or name != stage: return
    fired = true
    keEvtField = keEvtField or 0x02000000'u32
    doAssert mmTbttActive
    mm_tbtt_evt()
    doAssert mmTbttActive
  mm_tbtt_evt()
  doAssert steps == @["log", "flush", "program0", "switch0", "program1", "switch1", "transmit", "age"]
  doAssert keEvtField == 0x02000020'u32
  doAssert vifs[0].beaconCountdown == 3 and vifs[1].beaconCountdown == 4
  doAssert mmTbttAgingCount0 == 2 and mmTbttAgingCount1 == 10 and not mmTbttActive

prepareOwner(true)
env.activeList.first = nil
onBoundary = proc(name: string) =
  if name == "log": env.activeList.first = addr vifs[0]
mm_tbtt_evt()
doAssert vifs[0].beaconCountdown == 1 and vifs[1].beaconCountdown == 1
doAssert "transmit" notin steps, "old TBTT transmitted a newly registered AP"
''',
    "guard_recovers_after_errors": r'''
for stage in ["log", "flush", "program0", "switch0", "transmit", "age"]:
  prepareOwner(true)
  onBoundary = proc(name: string) =
    if name == stage: raise newException(ValueError, "TBTT callback interrupted")
  var raised = false
  try: mm_tbtt_evt()
  except ValueError: raised = true
  doAssert raised and interrupts and not mmTbttActive
  prepareOwner(true)
  mm_tbtt_evt()
  doAssert steps == @["log", "flush", "program0", "switch0", "program1", "switch1", "transmit", "age"]
''',
    "invalid_lists_and_reset_gate": r'''
for kind in 0 .. 2:
  prepareOwner(true)
  var foreign: Vif
  if kind == 0: vifs[1].next = addr vifs[0]
  elif kind == 1: env.activeList.first = addr foreign
  else: resetting = true
  let first = vifs[0]
  let second = vifs[1]
  mm_tbtt_evt()
  doAssert interrupts and not mmTbttActive
  doAssert vifs[0] == first and vifs[1] == second
  doAssert steps.len == 0 and keEvtField == 0x01000020'u32
  doAssert assertions.len == (if kind == 2: 0 else: 1)
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_ap_tbtt_ownership(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
