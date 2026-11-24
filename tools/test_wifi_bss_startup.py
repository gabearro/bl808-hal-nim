"""Check BSS startup failures across the production registration handoff."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_registration_exchange import source as registration_source


def source() -> str:
    code = "var bssFailAt: int\ntype CoList = object\n  first, last: pointer\n" + registration_source()
    code = code.replace("  if not failAlloc:\n", "  if not failAlloc and allocations != bssFailAt:\n", 1)
    code = code.replace("vifIdx, ssidLen: uint8", "vifIdx, ssidLen, qosInfo: uint8", 1)
    code = code.replace("    basicRates: array[13, uint8]", """    basicRates: array[13, uint8]
    wmmQosInfo: uint8
    beaconIntervalTu: uint16
    edcaParams: array[16, uint8]""", 1)
    code = code.replace("  vif.operChan = addr channel\n  vif.keys.flags",
                        "  vif.operChan = addr channel\n  vif.basicRates[0] = 1\n"
                        "  vif.basicRates[1] = 12\n  vif.keys.flags", 1)
    code = code.replace("connectModeFlags: uint8]",
                        "connectModeFlags: uint8, pendingBssParams: CoList]", 1)
    code = code.replace("7'u8, 0'u8, 0'u8)", "7'u8, 0'u8, 0'u8, default(CoList))", 1)
    code = code.replace("  else:\n    doAssert id in [SCANU_START_CFM, SCANU_JOIN_CFM]", """  elif id in [16'u16, 17, 18, 19, 20, 21, 22, 23, 0xC0D, 0xC0E, 0xC0F, 0xC10]:
    discard
  else:
    doAssert id in [SCANU_START_CFM, SCANU_JOIN_CFM]""", 1)
    code = code.replace(procedure(code, "sm_set_bss_param"),
                        "proc sm_set_bss_param*() {.exportc, cdecl.}\n", 1)
    code = "proc smBssForget(header: pointer)\n" + code
    code = code.replace("  smRegistrationForget(p)\n",
                        "  smBssForget(p)\n  smRegistrationForget(p)\n", 1)
    names = ["MeSetPsDisableReqPayload", "MmSetBssidReqPayload", "MmSetBasicRatesReqPayload",
             "MmSetBeaconIntReqPayload", "MeSetActiveReqPayload", "MmSetEdcaReqPayload"]
    code += layouts(*names)
    code += "const\n" + "".join(f"  {name}Size = sizeof({name}).uint32\n" for name in names)
    code += r'''
const
  TASK_ME = 3'u8
  SmSettingBssState = 4'u16
  ME_SET_PS_DISABLE_REQ = 0xC0F'u16
  ME_SET_ACTIVE_REQ = 0xC0D'u16
  MM_SET_BSSID_REQ = 20'u16
  MM_SET_BASIC_RATES_REQ = 18'u16
  MM_SET_BEACON_INT_REQ = 16'u16
  MM_SET_EDCA_REQ = 22'u16
let mac_ac2uapsd = [4'u8, 8, 2, 1]
var ps: tuple[uapsdPeriod: uint32]
proc psEnvView(): ptr typeof(ps) = addr ps
proc vifEdcaPsGate(vif: ptr Vif): int8 = cast[int8](vif.wmmQosInfo)
proc me_legacy_rate_bitfield_build(p: pointer; basic: uint8): uint32 = 0x1234
proc keMsgPayload(header: ptr KeMsgHdr): pointer = cast[pointer](cast[uint](header) + sizeof(KeMsgHdr).uint)
proc co_list_init(list: ptr CoList) = list[] = default(CoList)
proc co_list_push_back(list: ptr CoList; node: ptr KeMsgHdr) =
  node.next = nil
  if list.last == nil: list.first = node
  else: cast[ptr KeMsgHdr](list.last).next = node
  list.last = node
proc co_list_pop_front(list: ptr CoList): pointer =
  result = list.first
  if result != nil:
    list.first = cast[ptr KeMsgHdr](result).next
    if list.first == nil: list.last = nil
    cast[ptr KeMsgHdr](result).next = nil
type CoListHdr = KeMsgHdr
proc smBssCancelControl(request, reply: pointer; vifIndex: uint8): bool = false
proc meCancelQueuedPayload(payload: pointer) = discard
'''
    code += (FW / "station_bss.nim").read_text()
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code += procedure(scan, "sm_send_next_bss_param") + procedure(scan, "sm_set_bss_param")
    return code


CASES = {
    "allocation_failure_after_handoff": r'''
for initialIrq in [false, true]:
  for point in 1..18:
    resetExchange()
    let reply = completeRegistration(issue())
    enabled = initialIrq
    bssFailAt = allocations + point
    let station = vifs[conn.vifIdx].staIdx
    onFailure = proc() =
      doAssert live.len == 1 and smBssTags == nil
      doAssert queued.len == 0 and sm.pendingBssParams.first == nil
      state = 10
      mm_sta_del(station)
    doAssert mm_sta_add_cfm_handler(reply) == 0
    doAssert enabled == initialIrq and state == 10
    doAssert failures == @[(14'u16, 0xFFFF'u16)] and deletions == 1
    bssFailAt = 0
    release(reply)
    smRegistrationService()
    doAssert deletions == 1 and not smRegistrationNeedsService()
    finishExchange()
''',
    "replacement_during_startup": r'''
resetExchange()
let reply = completeRegistration(issue())
onAlloc = replaceOwner
doAssert mm_sta_add_cfm_handler(reply) == 0
doAssert failures.len == 0 and queued.len == 0 and state == 6
release(reply)
smRegistrationService()
doAssert deletions == 0
finishExchange()
''',
    "complete_batch_after_handoff": r'''
resetExchange()
let reply = completeRegistration(issue())
doAssert mm_sta_add_cfm_handler(reply) == 0
doAssert state == 4 and smBss.active and queued.len == 1 and live.len == 19
release(reply)
while queued.len != 0:
  let request = take()
  let response = smBssTakeReply(request, SmBssRequests[smBss.step] + 1, 0)
  doAssert response != nil and smBssConsumeReply(response)
  release(request)
  release(response)
  if smBss.active: smBssSendNext()
doAssert failures.len == 0 and deletions == 0 and not smBss.active
finishExchange()
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_registration_bss_startup(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
