"""Check the exported supplicant control ABI and its status results."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = (FW / "platform_bl.nim").read_text()
FUNCTIONS = (
    "bl_wifi_timer_arm",
    "bl_wifi_timer_disarm",
    "bl_wifi_timer_done",
    "bl_wifi_timer_setfn",
    "bl_wifi_register_wpa_cb_internal",
    "bl_wifi_unregister_wpa_cb_internal",
    "bl_wifi_set_appie_internal",
    "bl_wifi_unset_appie_internal",
    "bl_wifi_set_wps_cb_internal",
    "bl_wifi_get_wps_status_internal",
    "bl_wifi_set_wps_status_internal",
    "bl_wifi_sta_set_reset_param_internal",
    "bl_wifi_sta_update_ap_info_internal",
    "bl_wifi_get_assoc_bssid_internal",
)


def source() -> str:
    code = r'''
var
  wpa_cbs, wps_cbs: pointer
  sm_env: array[64, uint8]
  macClock: uint32
  timerSetCalls: seq[tuple[timer: pointer, whenUs: uint32]]
  timerClearCalls: seq[pointer]
  assocCalls: seq[tuple[vif: uint8, ie: pointer, length: uint8]]
const MAX_VIFS = 2
type VifChannelView = object
  bssid: array[6, uint8]
type ScanuEnvObj {.packed.} = object
  preceding: array[232, uint8]
  extraIePtr: pointer
  extraIeLen: uint16
var scanu_env: ScanuEnvObj
type SmEnvView {.packed.} = object
  beforeState: array[44, uint8]
  state: uint8
  beforeVendorIe: array[3, uint8]
  vendorIePtr: pointer
  vendorIeLen: uint16
template smEnvView(): ptr SmEnvView = cast[ptr SmEnvView](addr sm_env[0])
static:
  doAssert offsetof(SmEnvView, state) == 44
  doAssert offsetof(SmEnvView, vendorIePtr) == 48
  doAssert offsetof(SmEnvView, vendorIeLen) == 48 + sizeof(pointer)
  doAssert offsetof(ScanuEnvObj, extraIePtr) == 232
var vif: VifChannelView
proc vif_mgmt_get_vif(index: uint8): pointer =
  if index == 0: addr vif else: nil
proc vifChannelAt(p: pointer): ptr VifChannelView = cast[ptr VifChannelView](p)
proc c_memcpy(dst, src: pointer; n: csize_t): pointer =
  copyMem(dst, src, n.int)
  dst
proc macTimeNow(): uint32 = macClock
proc mm_timer_set(timer: pointer, whenUs: uint32) =
  timerSetCalls.add((timer, whenUs))
proc mm_timer_clear(timer: pointer) =
  timerClearCalls.add(timer)
proc mm_set_wpa_rsn_ie(vifIdx: uint8, ie: pointer, ieLen: uint8) =
  assocCalls.add((vifIdx, ie, ieLen))
'''
    return code + "\n".join(procedure(PLATFORM, name) for name in FUNCTIONS)


@pytest.mark.parametrize("mode", ["checked", "firmware", "asan"])
def test_supplicant_control_signatures_and_results(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
let timerArm: proc(timer: pointer, delayMs: uint32, repeatFlag: bool) {.cdecl.} =
  bl_wifi_timer_arm
let timerDisarm: proc(timer: pointer) {.cdecl.} = bl_wifi_timer_disarm
let timerDone: proc(timer: pointer) {.cdecl.} = bl_wifi_timer_done
let timerFn: proc(timer, fn, cbArg: pointer) {.cdecl.} = bl_wifi_timer_setfn
let registerWpa: proc(cb: pointer): cint {.cdecl.} = bl_wifi_register_wpa_cb_internal
let unregisterWpa: proc(): cint {.cdecl.} = bl_wifi_unregister_wpa_cb_internal
let setAppIe: proc(vif: uint8, kind: cint, ie: pointer, length: uint16,
                   sta: bool): cint {.cdecl.} = bl_wifi_set_appie_internal
let unsetAppIe: proc(vif: uint8, kind: cint): cint {.cdecl.} = bl_wifi_unset_appie_internal
let setWps: proc(cb: pointer): cint {.cdecl.} = bl_wifi_set_wps_cb_internal
let getWpsStatus: proc(): cint {.cdecl.} = bl_wifi_get_wps_status_internal
let setWpsStatus: proc(status: cint) {.cdecl.} = bl_wifi_set_wps_status_internal
let setReset: proc(flag: uint8): uint8 {.cdecl.} = bl_wifi_sta_set_reset_param_internal
let updateAp: proc(): cint {.cdecl.} = bl_wifi_sta_update_ap_info_internal
let getAssoc: proc(vif: uint8; output: pointer): cint {.cdecl.} =
  bl_wifi_get_assoc_bssid_internal
doAssert timerFn != nil

var cb = 1'u32
var ie = 2'u32
macClock = 1234
timerArm(addr cb, 7, true)
timerArm(addr cb, 9, false)
doAssert timerSetCalls == @[(cast[pointer](addr cb), 8234'u32),
  (cast[pointer](addr cb), 10234'u32)]
timerDone(addr cb)
doAssert timerSetCalls.len == 2
timerFn(nil, addr cb, addr ie)
timerDisarm(addr cb)
doAssert timerClearCalls == @[cast[pointer](addr cb)]
doAssert registerWpa(addr cb) == 0 and wpa_cbs == (addr cb)
doAssert unregisterWpa() == 0 and wpa_cbs == nil
doAssert setWps(addr cb) == 0 and wps_cbs == (addr cb)
setWpsStatus(3)
doAssert getWpsStatus() == 3 and sm_env[44] == 3 and smEnvView().state == 3
setWpsStatus(0x101)
doAssert getWpsStatus() == 1 and sm_env[44] == 1 and smEnvView().state == 1
smEnvView().state = 2
doAssert getWpsStatus() == 2
doAssert sm_env[43] == 0 and sm_env[45] == 0
doAssert setReset(255) == 0 and updateAp() == 1
var bssid: array[6, uint8]
vif.bssid = [1'u8, 2, 3, 4, 5, 6]
doAssert getAssoc(0, nil) == -1
doAssert getAssoc(1, addr bssid[0]) == -1
doAssert getAssoc(0, addr bssid[0]) == 0 and bssid == vif.bssid

doAssert setAppIe(1, 0, addr ie, 0x1234, true) == 0
doAssert assocCalls == @[(1'u8, cast[pointer](addr ie), 0x34'u8)]
doAssert setAppIe(1, 0, nil, 1, true) == -1
doAssert assocCalls.len == 1
doAssert setAppIe(2, 0, addr ie, 1, true) == -1
doAssert setAppIe(255, 0, addr ie, 1, true) == -1
doAssert assocCalls.len == 1
doAssert setAppIe(1, 0, nil, 256, true) == 0
doAssert assocCalls[^1] == (1'u8, nil, 0'u8)
doAssert setAppIe(0, 1, addr ie, 170, false) == 0
doAssert scanu_env.extraIePtr == (addr ie) and scanu_env.extraIeLen == 170
doAssert setAppIe(0, 1, nil, 1, false) == -1
doAssert scanu_env.extraIePtr == (addr ie) and scanu_env.extraIeLen == 170
doAssert setAppIe(0, 1, nil, 171, false) == -1
doAssert scanu_env.extraIePtr == (addr ie) and scanu_env.extraIeLen == 170
doAssert setAppIe(0, 2, addr ie, 50, false) == 0
doAssert smEnvView().vendorIePtr == (addr ie) and smEnvView().vendorIeLen == 50
doAssert setAppIe(0, 2, nil, 1, false) == -1
doAssert smEnvView().vendorIePtr == (addr ie) and smEnvView().vendorIeLen == 50
doAssert setAppIe(0, 2, nil, 51, false) == -1
doAssert smEnvView().vendorIePtr == (addr ie) and smEnvView().vendorIeLen == 50
doAssert setAppIe(0, 257, nil, 0, false) == 0
doAssert scanu_env.extraIePtr == (addr ie) and scanu_env.extraIeLen == 170
doAssert unsetAppIe(0, 1) == 0
doAssert scanu_env.extraIePtr == nil and scanu_env.extraIeLen == 0
doAssert unsetAppIe(0, 2) == 0
doAssert smEnvView().vendorIePtr == nil and smEnvView().vendorIeLen == 0
''')


@pytest.mark.parametrize("mode", ["checked", "firmware", "asan"])
def test_wpa_rsn_ie_setter_rejects_invalid_vif_and_null_data(
    tmp_path: Path, mode: str
) -> None:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    code = r'''
const MAX_VIFS = 2
type
  Security = object
    rsnIePtr: uint32
    rsnIeLen: uint8
  VifChannelView = object
    security: Security
var
  vifs: array[MAX_VIFS, VifChannelView]
  nimFwDbgWpaRsnIeSet, nimFwDbgWpaRsnIeLen, nimFwDbgWpaRsnIePtr: uint32
proc vifChannelForIdx(i: uint8): ptr VifChannelView =
  doAssert i < MAX_VIFS.uint8
  addr vifs[i]
proc vifSecurity(vif: ptr VifChannelView): ptr Security = addr vif.security
'''
    code += procedure(kernel, "mm_set_wpa_rsn_ie")
    code += r'''
var ie = [48'u8, 2, 1, 0]
mm_set_wpa_rsn_ie(0, addr ie[0], 4)
doAssert vifs[0].security.rsnIePtr == cast[uint32](addr ie[0])
doAssert vifs[0].security.rsnIeLen == 4
doAssert nimFwDbgWpaRsnIeSet == 1
let before = vifs
mm_set_wpa_rsn_ie(2, addr ie[0], 4)
mm_set_wpa_rsn_ie(255, addr ie[0], 4)
mm_set_wpa_rsn_ie(1, nil, 4)
doAssert vifs == before and nimFwDbgWpaRsnIeSet == 1
mm_set_wpa_rsn_ie(1, nil, 0)
doAssert vifs[1].security.rsnIePtr == 0 and vifs[1].security.rsnIeLen == 0
doAssert nimFwDbgWpaRsnIeSet == 2
'''
    run_program(tmp_path, mode, code)
