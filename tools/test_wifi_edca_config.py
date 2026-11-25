"""Check the vendor EDCA request fields and per-VIF configuration writes."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program

PLATFORM = r'''
const
  MAX_VIFS = 2
  VIF_TYPE_STA = 0'u8
  MACHW_BASE = 0x24B00000'u
  KeMsgConsumed = 0.cint
  MM_SET_EDCA_CFM = 23'u16
  MmSetEdcaReqPayloadSize = 8'u32
type
  Vif = object
    vifType, state: uint8
    edcaRegs: array[4, uint32]
  Header = object
    paramLen: uint32
var
  vifs: array[2, Vif]
  header: Header
  request: MmSetEdcaReqPayload
  writes: seq[tuple[address: uint, value: uint32]]
  powerCalls: seq[tuple[vif: uint, ac: uint8, enabled: uint32]]
  durationCalls: int
  ownerIndex: uint8
  mmEdcaRefresh: tuple[vif: uint8]
proc irqSave(): uint32 = 0
proc irqRestore(saved: uint32) = discard
proc mmEdcaRefreshCurrent(): bool = false
proc mmProgramEdca(vif: ptr Vif) = doAssert false
proc mmEdcaOwner(): ptr Vif =
  if vifs[ownerIndex].state != 0: addr vifs[ownerIndex] else: nil
proc vifEntryAddr(index: uint8): uint =
  doAssert index < 2, "EDCA selected VIF from parameter word"
  cast[uint](addr vifs[index])
proc vifChannelAt(p: uint): ptr Vif = cast[ptr Vif](p)
proc vifChannelForIdx(index: uint8): ptr Vif =
  doAssert index < 2
  addr vifs[index]
proc regWrite(address: uint; value: uint32) = writes.add((address, value))
proc mm_env_max_ampdu_duration_set(value: uint32) = inc durationCalls
proc smActivationAdmitRequest(request: pointer): bool = true
proc ps_uapsd_set(p: pointer; ac: uint8; enabled: uint32) =
  powerCalls.add((cast[uint](p), ac, enabled))
proc reset() =
  vifs = default(typeof(vifs))
  writes.setLen(0)
  powerCalls.setLen(0)
  durationCalls = 0
  header.paramLen = 8
'''

CHECKS = r'''
for vif in 0'u8..1:
  for ac in 0'u8..3:
    for active in 0'u8..1:
      for enabled in 0'u8..1:
        reset()
        ownerIndex = vif
        vifs[vif].state = active
        request = MmSetEdcaReqPayload(edcaParam: 0xABCD1234'u32, vifIdx: vif,
                                      acmFlag: ac, uapsdAc: enabled)
        doAssert applyEdca(addr request) == 23
        doAssert vifs[vif].edcaRegs[ac] == request.edcaParam
        doAssert vifs[1 - vif].edcaRegs == default(array[4, uint32])
        doAssert powerCalls == @[(cast[uint](addr vifs[vif]), ac, enabled.uint32)]
        if active != 0:
          doAssert writes == @[(MACHW_BASE + 0x200 + ac.uint * 4, request.edcaParam)]
          doAssert durationCalls == 1
        else:
          doAssert writes.len == 0 and durationCalls == 0
reset()
vifs[1].vifType = 2
request = MmSetEdcaReqPayload(edcaParam: 0x12345678, vifIdx: 1, acmFlag: 3, uapsdAc: 1)
doAssert applyEdca(addr request) == 23 and powerCalls.len == 0
reset()
ownerIndex = 0
vifs[0].state = 1
vifs[1].state = 1
request = MmSetEdcaReqPayload(edcaParam: 0x11223344, vifIdx: 1, acmFlag: 2)
doAssert applyEdca(addr request) == 23 and vifs[1].edcaRegs[2] == 0x11223344
doAssert writes.len == 0 and durationCalls == 0
for bad in 0..2:
  reset()
  request = MmSetEdcaReqPayload(vifIdx: 1, acmFlag: 0, edcaParam: 0xFFFFFFFF'u32)
  if bad == 0: request.vifIdx = 2
  elif bad == 1: request.acmFlag = 4
  else: header.paramLen = 7
  # An out-of-range VIF or queue changes nothing but is answered; a short
  # payload is not a request.
  doAssert applyEdca(addr request) == (if bad == 2: 0 else: 23)
  doAssert writes.len == 0 and powerCalls.len == 0 and durationCalls == 0
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_edca_fields(tmp_path: Path, mode: str) -> None:
    source = (FW / "task_handlers.nim").read_text()
    body = procedure(source, "mm_hw_config_handler").split("  of 22:", 1)[1].split("  of 24:", 1)[0]
    body = "\n".join(line[2:] for line in body.splitlines()[1:])
    wrapper = '''
proc applyEdca(param: pointer): cint =
  let msgBody = param
  let hdr = addr header
  if hdr.paramLen < MmSetEdcaReqPayloadSize: return 0
  let edcaRefresh = false
  var cfmBasicId: uint16
'''
    run_program(tmp_path, mode, layouts("MmSetEdcaReqPayload") + PLATFORM + wrapper + body
                + "\n  cfmBasicId.cint\n" + CHECKS)
