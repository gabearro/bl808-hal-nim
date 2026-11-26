"""The TX-null timer: the deadline of a DPSM sleep (ps_machine.nim).

The timer is armed with the sleep's stamp before its first null frame is
sent. Its expiry ends the sleep as if every frame were confirmed and only then
flushes AC3, as pinned ps.o:ps_tx_null_timer_handle does (finalize at +0x2a,
tail call to txl_cntrl_clear_ac(3)); the flushed confirmations are stale. The
commit updates the VIF of the last frame accepted while it is still the same
VIF. An expiry with another stamp changes nothing.
"""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_ps_table import ps_source

SLEEP = r'''
proc sleepWith(count: int) =
  ## Dynamic PS, awake, then an idle sample: a sleep with `count` frames out.
  enter(2, count)
  discard ps_traffic_status_update(0, 4)
  frames.setLen(0)
  discard ps_traffic_status_update(0, 0)
  doAssert psOwn.kind == psSleep and nullTimerArmed and frames.len == count
  doAssert opCurrent(psOwn.op, opEnvStamp(ps.txNullTimerEnv))
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_timeout_ends_the_sleep_then_flushes(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, ps_source() + SLEEP + r'''
for count in [1, 2]:
  for halted in [true, false]:
    sleepWith(count)
    clearResult = halted
    var flushedLive = false
    proc watch(p: pointer; status: uint32) {.cdecl.} =
      flushedLive = psOwn.kind != psIdle
    frames.insert(Frame(sta: 2, callback: cast[pointer](watch)), 0)
    let last = if count == 2: 1 else: 0
    doAssert fireNullTimer()
    # Ended first: the flush finds PS idle, a failed halt included (its
    # assert_rec recovers the MAC).
    doAssert not flushedLive and psOwn.kind == psIdle and ps.flags == 1
    doAssert ps.pendingCount == 0 and not nullTimerArmed
    for frame in frames: doAssert frame.done
    doAssert vifs[last].keyPsState == 1 and (vifs[last].flags and 0x42) == 0
    checkPs()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_timeout_does_not_touch_a_replaced_vif(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, ps_source() + SLEEP + r'''
sleepWith(1)
vifs[0].keyPsState = 7
inc rxVifEpochs[0]   # the VIF was removed and added again at its index
doAssert fireNullTimer()
doAssert psOwn.kind == psIdle and ps.flags == 1 and vifs[0].keyPsState == 7
checkPs()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_stale_expiry_changes_nothing(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, ps_source() + SLEEP + r'''
sleepWith(1)
let stale = ps.txNullTimerEnv
deliver(0, TxAck)
doAssert psOwn.kind == psIdle and not nullTimerArmed
# A delivery already taken from the list when the sleep ended.
let before = (psOwn, ps, frames.len)
ps_tx_null_timer_handle(stale)
doAssert (psOwn, ps, frames.len) == before
# The next sleep's timer is not ended by the old stamp either.
discard ps_traffic_status_update(0, 4)
discard ps_traffic_status_update(0, 0)
doAssert psOwn.kind == psSleep
ps_tx_null_timer_handle(stale)
doAssert psOwn.kind == psSleep and nullTimerArmed and ps.pendingCount == 1
ps_tx_null_timer_handle(nil)
doAssert psOwn.kind == psSleep
doAssert fireNullTimer() and psOwn.kind == psIdle
''')
