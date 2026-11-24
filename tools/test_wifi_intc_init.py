"""Check the pinned intc.o IRQ enables and handler-table relocations."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_intc_init(tmp_path: Path, mode: str) -> None:
    source = (FW / "coex_intc_sysctrl.nim").read_text()
    bodies = "".join(procedure(source, name) for name in [
        "intc_enable_irq", "intc_handlers_init", "intc_init",
    ])
    run_program(tmp_path, mode, r'''
var intc_handler_tab: array[64, pointer]
var writes: seq[tuple[address: uint, value: uint32]]

proc regWrite(address: uint; value: uint32) =
  writes.add((address, value))

proc phy_mdm_isr() = discard
proc phy_rc_isr() = discard
proc intc_spurious() = discard
proc rxl_timer_int_handler() = discard
proc txl_transmit_trigger() = discard
proc hal_machw_gen_handler() = discard
proc ipc_emb_msg_irq() = discard
proc ipc_emb_cfmback_irq() = discard
proc ipc_emb_tx_irq() = discard
''' + bodies + r'''
for slot in mitems(intc_handler_tab):
  slot = cast[pointer](1)

intc_init()
let irqs = [63'u32, 62, 61, 24, 25, 26, 27, 28, 29, 30, 31, 32,
            55, 53, 50, 52, 54, 10, 11]
doAssert writes.len == irqs.len
for index, irq in irqs:
  doAssert writes[index] ==
    (0x24910010'u + (irq shr 5).uint * 4'u, 1'u32 shl (irq and 31))

var expected: array[64, pointer]
expected[10] = cast[pointer](phy_mdm_isr)
expected[11] = cast[pointer](phy_rc_isr)
for index in 24 .. 39:
  expected[index] = cast[pointer](intc_spurious)
expected[50] = cast[pointer](rxl_timer_int_handler)
expected[51] = cast[pointer](intc_spurious)
expected[52] = cast[pointer](rxl_timer_int_handler)
expected[53] = cast[pointer](txl_transmit_trigger)
expected[54] = cast[pointer](hal_machw_gen_handler)
expected[55] = cast[pointer](intc_spurious)
expected[60] = cast[pointer](intc_spurious)
expected[61] = cast[pointer](ipc_emb_msg_irq)
expected[62] = cast[pointer](ipc_emb_cfmback_irq)
expected[63] = cast[pointer](ipc_emb_tx_irq)
doAssert intc_handler_tab == expected

writes.setLen(0)
for irq in [0'u32, 31, 32, 63, 64]:
  intc_enable_irq(irq)
doAssert writes == @[
  (0x24910010'u, 0x00000001'u32),
  (0x24910010'u, 0x80000000'u32),
  (0x24910014'u, 0x00000001'u32),
  (0x24910014'u, 0x80000000'u32),
  (0x24910018'u, 0x00000001'u32),
]
''')
