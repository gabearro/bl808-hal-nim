"""Check the DMA confirmation flag against the vendor's power-save target."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_mac_state import source as mac_source
from test_wifi_message_allocation import run_program


PLATFORM = r'''
type PsGuard = object
  before: array[16, uint8]
  value: PsEnvView
  after: array[16, uint8]
var
  ps: PsGuard
  txl_cfm_env: array[10, uint32]
  interrupts: bool
proc psEnvView(): ptr PsEnvView = addr ps.value
proc bytes(p: pointer; size: int): seq[uint8] =
  let data = cast[ptr UncheckedArray[uint8]](p)
  for i in 0 ..< size: result.add(data[i])
'''


def handler() -> str:
    return procedure((FW / "tx_layer.nim").read_text(),
                     "txl_cfm_dma_int_handler_backup")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_dma_completion_clears_only_power_save_bit(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, layouts("PsEnvView") + PLATFORM + handler() + r'''
static: doAssert offsetof(PsEnvView, statusFlags) == 4
for enabled in [false, true]:
  for flags in [1'u32, 0, 2, 3, 0x80000001'u32, 0xFFFFFFFE'u32, 0xFFFFFFFF'u32]:
    let raw = cast[ptr UncheckedArray[uint8]](addr ps)
    for i in 0 ..< sizeof(ps): raw[i] = (0xA0 + i mod 16).uint8
    ps.value.statusFlags = flags
    for i in 0 ..< txl_cfm_env.len:
      txl_cfm_env[i] = 0x13570001'u32 + (i.uint32 shl 8)
    let before = bytes(addr ps, sizeof(ps))
    let queues = txl_cfm_env
    interrupts = enabled
    for repeated in 0 .. 1:
      txl_cfm_dma_int_handler_backup()
      doAssert ps.value.statusFlags == (flags and not 1'u32),
        "DMA completion did not clear the power-save flag"
      doAssert txl_cfm_env == queues, "DMA completion changed the TX queues"
      doAssert interrupts == enabled
      let after = bytes(addr ps, sizeof(ps))
      let flagOffset = offsetof(PsGuard, value) + offsetof(PsEnvView, statusFlags)
      for i in 0 ..< before.len:
        if i < flagOffset or i >= flagOffset + 4:
          doAssert after[i] == before[i], "DMA completion changed adjacent state"
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_dma_and_idle_completion_preserve_each_others_flags(tmp_path: Path, mode: str) -> None:
    code = mac_source() + "\nvar txl_cfm_env: array[10, uint32]\n" + handler()
    run_program(tmp_path, mode, code + r'''
for enabled in [false, true]:
  setup(enabled)
  ps.value.statusFlags = ps.value.statusFlags or 1
  txl_cfm_env[1] = 0x13570001'u32
  let queues = txl_cfm_env
  let before = bytes(addr ps, sizeof(ps))
  hal_machw_idle_req()
  doAssert ps.value.statusFlags == 0xC000000F'u32
  txl_cfm_dma_int_handler_backup()
  doAssert ps.value.statusFlags == 0xC000000E'u32
  setRegister(MACHW_INTC_STATUS_RAW, 4)
  hal_machw_gen_handler()
  doAssert ps.value.statusFlags == 0xC000000A'u32
  doAssert events == KE_EVT_IDLE and assertions == 0 and interrupts == enabled
  doAssert txl_cfm_env == queues
  checkPsUnchangedExceptFlags(before)
''')
