"""Check station capability initialization against vendor offsets and ABI."""

from pathlib import Path
import re

import pytest

from test_wifi_ap_sta_init import PLATFORM as AP_PLATFORM
from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    layout = (FW / "layout_types.nim").read_text()
    code = layouts("CoListHdr")
    code += "type\n" + re.search(r"(?ms)^  CoList\*? = object\n.*?(?=\n\n)", layout).group(0) + "\n"
    code += layouts("StaInfoView", "MeEnvView")
    code += r'''
type GuardedStation = object
  before: array[16, uint8]
  station: StaInfoView
  after: array[16, uint8]
var
  me_env: array[136, uint8]
  storage: GuardedStation
  bss: array[160, uint8]
proc meEnvView(): ptr MeEnvView = cast[ptr MeEnvView](addr me_env[0])
proc staInfoAt(p: pointer): ptr StaInfoView = cast[ptr StaInfoView](p)
proc setup(nss: uint8; activeMask: uint32) =
  for byte in me_env.mitems: byte = 0xD3
  meEnvView().activeMask = activeMask
  meEnvView().nss = nss
  let bytes = cast[ptr UncheckedArray[uint8]](addr storage)
  for i in 0 ..< sizeof(storage): bytes[i] = 0xA5
  for byte in bss.mitems: byte = 0xC7
'''
    return code + procedure(scan, "me_set_sta_ht_vht_param")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_station_uses_configured_nss_not_active_mask(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for nss in [0'u8, 1, 2, 3, 255]:
  for mask in [0'u32, 1, 2, 0x01020304'u32, 0xFFFFFFFF'u32]:
    for hasBss in [false, true]:
      setup(nss, mask)
      var expected = storage
      expected.station.bwConfigState = 0
      expected.station.nssBwMax = 0
      expected.station.htVhtConfig = nss
      let expectedMe = me_env
      let expectedBss = bss
      me_set_sta_ht_vht_param(addr storage.station,
        if hasBss: addr bss[0] else: nil)
      doAssert storage == expected and me_env == expectedMe and bss == expectedBss
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_station_capability_boolean_abi(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
{.emit: """
_Static_assert(__builtin_types_compatible_p(__typeof__(&me_set_sta_ht_vht_param),
    NIM_BOOL (*)(void *, void *)), "station capability ABI returns bool");
""".}
setup(1, 2)
doAssert not me_set_sta_ht_vht_param(addr storage.station, nil)
let expected = storage
doAssert not me_set_sta_ht_vht_param(nil, nil)
doAssert storage == expected
''')


def ap_source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code = layouts("MeStaAddReqPayload", "MmStaAddReqPayload", "MeStaAddCfmPayload",
                   "VifHtCapabilitiesOverlay")
    code += "const\n  MeStaAddCfmPayloadSize = sizeof(MeStaAddCfmPayload).uint32\n"
    code += "  MeStaAddReqPayloadSize = sizeof(MeStaAddReqPayload).uint32\n"
    code += "var me_env: array[136, uint8]\nvar expectedAtInit: tuple[bw, maxBw, stbc: uint8]\n"
    platform = AP_PLATFORM.replace(
        "  Station = object\n", "  Station = object\n    bwConfigState, nssBwMax, htVhtConfig: uint8\n", 1)
    platform = platform.replace("me: tuple[htSupp: uint8]", "me: tuple[htSupp, nss: uint8]", 1)
    platform = platform.replace(procedure(platform, "me_set_sta_ht_vht_param"),
        "proc staInfoAt(p: pointer): ptr Station = cast[ptr Station](p)\n" +
        procedure(scan, "me_set_sta_ht_vht_param"), 1)
    platform = platform.replace("  inc initialized\n", """  inc initialized
  doAssert (stations[assigned].bwConfigState, stations[assigned].nssBwMax,
            stations[assigned].htVhtConfig) == expectedAtInit
""", 1)
    code += platform
    code += procedure(layout, "mmStaFillAggregation").split("\ntemplate ", 1)[0]
    for name in ["meStaAddReqView", "meStaAddReqCapBlock", "meStaAddReqHtCaps"]:
        code += re.search(rf"(?ms)^template {name}.*?(?=^template |^proc |\Z)", layout).group(0)
    code += procedure(layout, "lmacGateHalfword")
    return code + procedure((FW / "task_handlers.nim").read_text(), "me_sta_add_req_handler")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_registration_initializes_caps_before_rates(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, ap_source() + r'''
for flags in [0'u32, 1, 2, 3, 11]:
  for enabled in [false, true]:
    for nss in [0'u8, 1, 2]:
      reset(1, 2, flags, 7, enabled)
      me_env[0] = 0xED
      me.nss = nss
      stations[2].bwConfigState = 0xA5
      stations[2].nssBwMax = 0xA6
      stations[2].htVhtConfig = 0xA7
      expectedAtInit = if (flags and 3) == 3 and enabled:
        (0'u8, 0'u8, nss)
      else:
        (0xA5'u8, 0xA6'u8, 0xA7'u8)
      doAssert me_sta_add_req_handler(addr requestBytes[0]) == 0
      doAssert initialized == 1 and sent == 1
      doAssert response[0] == 2 and response[1] == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tx_policy_uses_initialized_stbc_limit(tmp_path: Path, mode: str) -> None:
    from test_wifi_tx_policy import PLATFORM as TX_PLATFORM

    scan = (FW / "scan_station_ap_me.nim").read_text()
    platform = TX_PLATFORM.replace("    instNbr, htVhtConfig: uint8",
        "    instNbr, htVhtConfig, bwConfigState, nssBwMax: uint8", 1)
    code = layouts("TxPolicyView") + platform + r'''
var
  me_env: array[136, uint8]
  configuration: tuple[nss: uint8]
proc meEnvView(): ptr typeof(configuration) = addr configuration
proc txPolicyAt(p: pointer): ptr TxPolicyView = cast[ptr TxPolicyView](p)
'''
    code += procedure(scan, "me_set_sta_ht_vht_param")
    code += procedure((FW / "tx_power_control.nim").read_text(), "tpc_get_vif_tx_power_vs_rate")
    code += procedure(scan, "me_update_buffer_control")
    run_program(tmp_path, mode, code + r'''
for nss in [0'u8, 1'u8]:
  var statsStore: array[216, uint8]
  var policyStore: array[76, uint8]
  configuration.nss = nss
  me_env[0] = nss xor 1
  sta = default(typeof(sta))
  vif = default(typeof(vif))
  sta.txPolicy = addr policyStore[0]
  sta.rcStats = addr statsStore[0]
  sta.txPolicyUpdateFlags[0] = StaTxPolicyUpdateRateControl
  rcU16(sta.rcStats, 10) = 0x1000
  rcU16(sta.rcStats, RCS_N_RATES) = 1
  rcU8(sta.rcStats, RCS_FLAGS) = 0x40
  irqActive = false
  irqCalls = 0
  originalPolicy = default(typeof(originalPolicy))
  me_set_sta_ht_vht_param(addr sta, nil)
  discard me_update_buffer_control(addr sta)
  doAssert (txPolicyAt(sta.txPolicy).bufferAddr and 0x180) ==
    (if nss == 0: 0'u32 else: 0x80'u32)
  doAssert irqCalls == 2 and not irqActive
''')
