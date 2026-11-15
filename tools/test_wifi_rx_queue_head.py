"""Reject invalid RX queue heads without turning them into repeated generation retries."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rx_admission import admission_source


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_invalid_ready_head_reports_once_without_dereference(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, admission_source() + r'''
for incoming in [false, true]:
  for invalid in [cast[pointer](1), cast[pointer](addr rx_swdesc_tab[1]),
                  cast[pointer](cast[uint](addr rx_swdesc_tab[0]) + sizeof(rx_swdesc_tab).uint)]:
    reset(0x0208, 24)
    interrupts = incoming
    env.queue.first = cast[ptr CoListHdr](invalid)
    env.queue.last = env.queue.first
    rxl_cntrl_evt()
    doAssert recovered == 1, "invalid ready head was retried instead of reported"
    doAssert assertIrqs == @[incoming]
    doAssert env.queue.first == cast[ptr CoListHdr](invalid)
    doAssert powerCalls == 0 and clockCalls == 0 and upperCalls == 0 and freed == 0
    doAssert events == 0 and not rxlControlActive and interrupts == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_callback_replacement_is_rechecked_before_pointer_validation(tmp_path: Path, mode: str) -> None:
    code = "var replaceOnClear: proc()\n" + admission_source()
    code = code.replace(procedure(code, "ke_evt_clear"), r'''
proc ke_evt_clear(mask: uint32) =
  events = events and not mask
  if replaceOnClear != nil:
    let callback = replaceOnClear
    replaceOnClear = nil
    callback()
''', 1)
    run_program(tmp_path, mode, code + r'''
for incoming in [false, true]:
  for staleGeneration in [false, true]:
    reset(0x0208, 24)
    interrupts = incoming
    let valid = addr rxSwTableDescAt(0).link
    if staleGeneration:
      env.queue.first = valid
    else:
      env.queue.first = cast[ptr CoListHdr](1)
    env.queue.last = env.queue.first
    replaceOnClear = proc() =
      env.queue.first = valid
      env.queue.last = valid
      if staleGeneration: inc rxUploadEpochs[0]
    rxl_cntrl_evt()
    doAssert recovered == 0 and freed == 1 and upperCalls == 1
    doAssert env.queue.first == nil and events == 0
    doAssert interrupts == incoming and not rxlControlActive
''')
