"""Check directed-scan WMM queue order, admission bits, and HT copy controls."""

from pathlib import Path
import textwrap

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const
  API_AC_BK = 0'u8
  API_AC_BE = 1'u8
  API_AC_VI = 2'u8
  API_AC_VO = 3'u8
  IE_ID_HT_CAP = 45'u8
var WMM_OUI = [0'u8, 0x50, 0xF2, 2, 1]
type
  Vif = object
    wmmQosInfo, wmmAcFlags: uint8
    capabilityInfo: uint16
  GuardedAp = object
    before: array[16, uint8]
    value: array[96, uint8]
    after: array[16, uint8]
  GuardedHt = object
    before: array[16, uint8]
    value: VifHtCapabilitiesOverlay
    after: array[16, uint8]
var
  vif: Vif
  ap: GuardedAp
  ht: GuardedHt
  management: tuple[htSupp: uint8]
  ies: array[54, uint8]
proc macIeAt(p: uint): ptr MacIeView = cast[ptr MacIeView](p)
proc totalLen(p: ptr MacIeView): uint = p.len.uint + 2
template macIePayload(p: ptr MacIeView): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](cast[uint](p) + 2)
proc wmmParameterIeAt(p: pointer): ptr WmmParameterIeView = cast[ptr WmmParameterIeView](p)
proc htCapIeAt(p: pointer): ptr HtCapIeView = cast[ptr HtCapIeView](p)
proc meEnvView(): ptr typeof(management) = addr management
proc apConfigView(): ptr VifApConfigOverlay = cast[ptr VifApConfigOverlay](addr ap.value[0])
proc setup(admission: uint8) =
  vif = Vif(wmmQosInfo: 0xFF, wmmAcFlags: 0xFF, capabilityInfo: 0x41)
  let apBytes = cast[ptr UncheckedArray[uint8]](addr ap)
  let htBytes = cast[ptr UncheckedArray[uint8]](addr ht)
  for i in 0 ..< sizeof(ap): apBytes[i] = 0xA5
  for i in 0 ..< sizeof(ht): htBytes[i] = 0xA5
  apConfigView().securityFlags = 0
  management.htSupp = 1
  ies = default(typeof(ies))
  let wmm = wmmParameterIeAt(addr ies[0])
  wmm.ie = MacIeView(id: 221, len: 24)
  wmm.oui = [0'u8, 0x50, 0xF2]
  wmm.ouiType = 2
  wmm.ouiSubtype = 1
  wmm.version = 1
  wmm.qosInfo = 0x83
  for i, word in [0x0000A403'u32, 0x0000A427'u32, 0x005E4342'u32, 0x002F3262'u32]:
    wmm.ac[i].setLe32(word or (((admission.uint32 shr i) and 1) shl 4))
  let capabilities = htCapIeAt(addr ies[26])
  capabilities.ie = MacIeView(id: 45, len: 26)
  capabilities.capInfo = 0x1234
  capabilities.ampduParams = 7
  for i in 0 ..< 16: capabilities.mcsSet[i] = (i + 1).uint8
  capabilities.extCap = 0x2468
  capabilities.txBfCapsLo = 0x5678
  capabilities.txBfCapsHi = 0x9ABC
  capabilities.aselCap = 0xDD
proc guard() =
  for bytes in [ap.before, ap.after, ht.before, ht.after]:
    for value in bytes: doAssert value == 0xA5
  for i in 16 .. 27: doAssert ap.value[i] == 0xA5
  for i in 32 ..< ap.value.len: doAssert ap.value[i] == 0xA5
'''


def source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    scan = (FW / "scan_station_ap_me.nim").read_text()
    body = procedure(scan, "scanu_frame_handler").split(
        "      let wmmO =", 1)[1].split("      securityState.connected", 1)[0]
    body = "      let wmmO =" + body
    code = layouts("MacIeView", "WmmAcParamRecord", "WmmParameterIeView",
                   "HtCapIeView", "VifApConfigOverlay", "VifHtCapabilitiesOverlay")
    code += procedure(layout[layout.index("proc le32*(rec:"):], "le32")
    code += procedure(layout, "setLe32")
    code += "template vifApEdcaWord" + layout.split(
        "template vifApEdcaWord", 1)[1].split("\n\n", 1)[0] + "\n"
    code += PLATFORM
    mac = (FW / "mac_config_debug.nim").read_text()
    code += procedure(mac, "mac_ie_find") + procedure(mac, "mac_vsie_find")
    code += r'''
proc apply(includeWmm = true; includeHt = true) =
  let vifView = addr vif
  let apConfig = apConfigView()
  let htCaps = addr ht.value
  let ieStart = if includeWmm: addr ies[0] else: addr ies[26]
  let ieLen = (if includeWmm: (if includeHt: 54 else: 26)
               else: (if includeHt: 28 else: 0)).uint32
  apConfigView().securityFlags = 0
'''
    return code + textwrap.indent(textwrap.dedent(body), "  ")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_wmm_queue_mapping_and_admission_bits(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
const admissionByWireMask = [0'u8, 2, 1, 3, 4, 6, 5, 7, 8, 10, 9, 11, 12, 14, 13, 15]
for admission in 0'u8 .. 15'u8:
  setup(admission)
  apply()
  doAssert vif.wmmQosInfo == 0x83 and vif.capabilityInfo == 0x241
  doAssert vifApEdcaWord(apConfigView(), 0)[] == 0xA47
  doAssert vifApEdcaWord(apConfigView(), 1)[] == 0xA43
  doAssert vifApEdcaWord(apConfigView(), 2)[] == 0x5E432
  doAssert vifApEdcaWord(apConfigView(), 3)[] == 0x2F322
  doAssert vif.wmmAcFlags == admissionByWireMask[admission]
  doAssert apConfigView().securityFlags == 3
  guard()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_repeated_wmm_replaces_admission_mask(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup(13)
vif.wmmAcFlags = 0
apply()
doAssert vif.wmmAcFlags == 14
let wmm = wmmParameterIeAt(addr ies[0])
for record in wmm.ac.mitems:
  record.setLe32(record.le32 and not 0x10'u32)
apply()
doAssert vif.wmmAcFlags == 0
wmm.ac[1].setLe32(wmm.ac[1].le32 or 0x10)
apply()
doAssert vif.wmmAcFlags == 1
guard()
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_default_edca_and_ht_copy_gates(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for haveWmm in [false, true]:
  for haveHt in [false, true]:
    for htEnabled in [0'u8, 1'u8]:
      setup(0)
      management.htSupp = htEnabled
      let originalHt = ht.value
      apply(haveWmm, haveHt)
      let copiesHt = haveWmm and haveHt and htEnabled != 0
      doAssert apConfigView().securityFlags == haveWmm.uint32 + 2 * copiesHt.uint32
      if not haveWmm:
        for ac in 0 .. 3: doAssert vifApEdcaWord(apConfigView(), ac)[] == 0xA43
      if copiesHt:
        doAssert ht.value.capInfo == 0x1234 and ht.value.ampduParams == 7
        for i in 0 ..< 16: doAssert ht.value.mcsSet[i] == (i + 1).uint8
        doAssert ht.value.extCap == 0x2468 and ht.value.aselCap == 0xDD
        doAssert ht.value.txBfCaps == 0x5678 # The vendor copies the low halfword.
        doAssert ht.value.mcsSetToExtCapPadding == 0xA5
      else:
        doAssert ht.value == originalHt
      guard()
''')
