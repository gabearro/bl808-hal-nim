"""Check RX timeout masking at the vendor interrupt-controller register."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_mac_state import source as mac_source
from test_wifi_message_allocation import run_program


def source() -> str:
    code = mac_source()
    code = code.replace(procedure(code, "rxl_timeout_int_handler"),
                        "proc rxl_timeout_int_handler*() {.exportc, cdecl.}\n", 1)
    code += r'''
static: doAssert MACHW_INTC_IRQ_STAT_REG == 0x24B0808C'u
var timeoutReads: seq[uint]
proc volatileLoad(p: ptr uint32): uint32 =
  let address = cast[uint](p)
  timeoutReads.add(address)
  regRead(address)
proc volatileStore(p: ptr uint32; value: uint32) =
  regWrite(cast[uint](p), value)
'''
    return code + procedure((FW / "rx_layer.nim").read_text(), "rxl_timeout_int_handler")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_timeout_clears_only_intc_mask_bit(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for enabled in [false, true]:
  for initial in [0'u32, 0x40, 0x41, 0xC0, 0x80000040'u32, 0xFFFFFFFF'u32]:
    setup(enabled)
    timeoutReads.setLen(0)
    setRegister(MACHW_INTC_IRQ_STAT_REG, initial)
    setRegister(MACHW_BASE + 0x8C, 0x12345678)
    rxl_timeout_int_handler()
    doAssert timeoutReads == @[MACHW_INTC_IRQ_STAT_REG], "wrong RX timeout register"
    doAssert writes == @[(MACHW_INTC_IRQ_STAT_REG, initial and not 0x40'u32, enabled)]
    doAssert regRead(MACHW_BASE + 0x8C) == 0x12345678
    doAssert regRead(MACHW_INTC_IRQ_STAT_REG) == (initial and not 0x40'u32)
    doAssert interrupts == enabled and events == 0 and assertions == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_general_interrupt_dispatches_real_timeout_handler(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for enabled in [false, true]:
  for status in [0x40'u32, 0xC0, 0x140, 0x1C0]:
    setup(enabled)
    timeoutReads.setLen(0)
    setRegister(MACHW_INTC_STATUS_RAW, 8)
    setRegister(MACHW_INTC_UNMASK_REG, 8)
    setRegister(MACHW_INTC_GEN_RAW, status)
    setRegister(MACHW_INTC_IRQ_STAT_REG, 0x1FF)
    setRegister(MACHW_BASE + 0x8C, 0x12345678)
    hal_machw_gen_handler()
    doAssert timeoutReads == @[MACHW_INTC_IRQ_STAT_REG]
    doAssert regRead(MACHW_INTC_IRQ_STAT_REG) == 0x1BF
    doAssert regRead(MACHW_BASE + 0x8C) == 0x12345678
    doAssert writes == @[(MACHW_INTC_STATUS_ACK, 8'u32, enabled),
      (MACHW_INTC_IRQ_SET_REG, status, enabled),
      (MACHW_INTC_IRQ_STAT_REG, 0x1BF'u32, enabled)]
    let expectedEvents = (if (status and 0x100) != 0: KE_EVT_KE_TIMER else: 0'u32) or
      (if (status and 0x80) != 0: KE_EVT_MM_TIMER else: 0'u32)
    doAssert events == expectedEvents and interrupts == enabled and assertions == 0
''')
