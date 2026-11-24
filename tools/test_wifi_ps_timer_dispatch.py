"""Exercise TX-null timeout VIF forwarding and failed-halt handling."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


TIMER_OWNER_PLATFORM = r'''
type
  MmVifIdentity = object
    vif: pointer
    epoch: uint32
  PsTxNullOwner = object
    peer: MmVifIdentity
    serial, resetEpoch: uint32
    armed: bool
  Delivery = object
    cancelled: bool
var
  psTxNullOwner: PsTxNullOwner
  txResetEpoch, psModeBuildSerial, peerEpoch: uint32
  delivery: Delivery
  delivering: bool
proc mmTimerActiveDelivery(p: pointer): ptr Delivery =
  if delivering: addr delivery else: nil
proc mmCaptureVif(vif: pointer): MmVifIdentity =
  MmVifIdentity(vif: vif, epoch: peerEpoch)
proc mmVifCurrent(peer: MmVifIdentity): bool = peer.epoch == peerEpoch
proc claimTimer(vif: pointer) =
  psTxNullOwner = PsTxNullOwner(peer: mmCaptureVif(vif), serial: psModeBuildSerial,
    resetEpoch: txResetEpoch, armed: true)
'''

PLATFORM = TIMER_OWNER_PLATFORM + r'''
var
  ps: PsEnvView
  params: BlPsParamsView
  vifA, vifB: uint32
  expectedVif: pointer
  events: seq[string]
  clearResult: bool
  retirePeerOnClear: bool
  schedules: int
  irqSaves, irqRestores: int

proc psEnvView(): ptr PsEnvView = addr ps
proc blPsParamsView(): ptr BlPsParamsView = addr params
template psTxNullTimer(): pointer = cast[pointer](addr ps.txNullTimerWord)
template psUapsdTimer(): pointer = cast[pointer](addr ps.uapsdTimerActive)
proc mm_timer_clear(timer: pointer) =
  doAssert timer == psUapsdTimer()
  events.add("uapsd")
proc ps_set_mode(mode, requester: uint8) =
  doAssert mode == 2 and requester == 4 and (ps.flags and 0x16) == 0
  events.add("replay")
proc irqSave(): uint32 =
  inc irqSaves
  0xA5'u32
proc irqRestore(saved: uint32) =
  doAssert saved == 0xA5'u32
  inc irqRestores
proc macTimeNow(): uint32 = 100
proc mm_timer_set(timer: pointer; expiry: uint32) =
  doAssert timer == psTxNullTimer() and expiry == 150
  doAssert ps.pendingCount == 2
  inc schedules
proc ps_disable_cfm_handle(vif: pointer): uint32 =
  doAssert vif == expectedVif
  doAssert ps.pendingCount == 0 and events == @["clear"]
  events.add("disable")
  1
proc ps_enable_cfm_handle(vif: pointer) =
  doAssert vif == expectedVif
  doAssert ps.pendingCount == 0 and events == @["clear"]
  events.add("enable")
proc txl_cntrl_clear_ac(ac: uint8): bool =
  doAssert ac == 3 and ps.pendingCount == 0
  events.add("clear")
  if retirePeerOnClear: inc peerEpoch
  clearResult
proc setup(flags, pending: uint8; vif: pointer; clears: bool) =
  ps = PsEnvView(enabled: 1, flags: flags, pendingCount: pending,
                 currentVif: vif)
  expectedVif = vif
  claimTimer(vif)
  delivering = false
  delivery.cancelled = false
  retirePeerOnClear = false
  params.txNullTimeout = 50
  events.setLen(0)
  clearResult = clears
  schedules = 0
  irqSaves = 0
  irqRestores = 0
'''


def source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n"
    for name in ("PsEnvView", "BlPsParamsView"):
        types += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    power = (FW / "power_save.nim").read_text()
    return types + PLATFORM + procedure(power, "ps_tx_null_timer_handle")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("flag,kind", [(3, "disable"), (5, "enable")])
@pytest.mark.parametrize("clear_result", [False, True])
def test_timeout_dispatch_order_and_vif(
    tmp_path: Path, mode: str, flag: int, kind: str, clear_result: bool
) -> None:
    run_program(tmp_path, mode, source() + f'''
for vif in [cast[pointer](addr vifA), cast[pointer](addr vifB)]:
  setup({flag}'u8, 2, vif, {str(clear_result).lower()})
  ps_tx_null_timer_handle()
  doAssert events == (if {str(clear_result).lower()}: @["clear", "{kind}"] else: @["clear"])
  doAssert ps.pendingCount == (if {str(clear_result).lower()}: 0'u8 else: 2'u8)
  doAssert ps.currentVif == vif
  doAssert schedules == (if {str(clear_result).lower()}: 0 else: 1)
  doAssert irqSaves == 1 and irqRestores == 1
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_timeout_early_returns(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for flags in [0'u8, 2, 4, 6]:
  setup(flags, 2, addr vifA, false)
  ps_tx_null_timer_handle()
  doAssert ps.pendingCount == 2
  doAssert events.len == 0 and schedules == 0
  doAssert irqSaves == 1 and irqRestores == 1

for flags in [1'u8, 3, 5, 7]:
  setup(flags, 0, addr vifB, false)
  ps_tx_null_timer_handle()
  doAssert ps.pendingCount == 0
  doAssert events.len == 0 and schedules == 0
  doAssert irqSaves == 1 and irqRestores == 1
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_timeout_owns_its_arm_and_original_peer(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for retired in [0, 2, 3]:
  setup(5, 2, addr vifA, true)
  case retired
  of 0: inc psModeBuildSerial
  of 2:
    delivering = true
    delivery.cancelled = true
  else: psTxNullOwner.armed = false
  ps_tx_null_timer_handle()
  doAssert ps.pendingCount == 2 and ps.flags == 5
  doAssert events.len == 0 and schedules == 0
  doAssert irqSaves == 1 and irqRestores == 1

# A TX reset flushes the null frame, not the transition: the timeout still
# finishes it.
setup(5, 2, addr vifA, true)
inc txResetEpoch
ps_tx_null_timer_handle()
doAssert ps.pendingCount == 0 and not psTxNullOwner.armed
doAssert events.len != 0

for late in [false, true]:
  for transition in [0x13'u8, 0x15]:
    setup(transition, 2, addr vifA, true)
    ps.mode = 4
    ps.deferredMode = 2
    ps.uapsdTimerActive = 1
    retirePeerOnClear = late
    if not late: inc peerEpoch
    ps_tx_null_timer_handle()
    doAssert ps.pendingCount == 0 and not psTxNullOwner.armed
    if transition == 0x13:
      doAssert events == @["clear", "uapsd", "replay"] and ps.flags == 9
      doAssert ps.uapsdTimerActive == 0
    else:
      doAssert events == @["clear", "replay"] and ps.flags == 1
''')
