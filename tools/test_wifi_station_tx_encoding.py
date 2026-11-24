"""Exercise station body encoders with real IE writers and bounded storage."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, ROOT, procedure

PLATFORM = r'''
const
  MAX_VIFS = 2
  STA_MGMT_FREE_STAS = 5
type
  SmTxBuildContext = object
    current: bool
    capacity: uint32
  Buffer = object
    before: array[16, uint8]
    data: array[512, uint8]
    after: array[16, uint8]
  Assoc = object
    ssidLen: uint8
    ssidData: array[49, uint8]
    basicRates: array[13, uint8]
    securityFlags: uint32
    rsnIePtr: pointer
    rsnIeLen, wmmQosInfo: uint8
  Conn = object
    listenInterval: uint16
    qosInfo: uint8
    keyString: array[64, uint8]
  Vif = object
    bssid, currentBssid, macAddr: array[6, uint8]
    staIdx: uint8
  Sta = object
    macAddr: array[6, uint8]
  Env = object
    connectInfo, vendorIePtr: pointer
    vendorIeLen: uint16
  ScanEnv = object
    extraIePtr: pointer
    extraIeLen: uint16
  Me = object
    htSupp: uint8
    htCaps: array[29, uint8]
  Ps = object
    reserved: array[8, uint32]
    uapsdPeriod: uint32
var
  buffer: Buffer
  context: SmTxBuildContext
  assoc: Assoc
  conn: Conn
  vif: Vif
  stas: array[STA_MGMT_FREE_STAS, Sta]
  expectedPeerMac: array[6, uint8]
  env: Env
  scanu_env: ScanEnv
  me: Me
  ps_env: array[14, uint32]
  wpa_cbs: pointer
  callbacks: array[15, pointer]
  payload: array[600, uint8]
  payloadLength: uint32
  payloadMissing: bool
  replacementAt: int
  callbackCalls: int
  nimFwDbgVifIeLenAtAssoc: uint32
proc smTxFits(build: ptr SmTxBuildContext; p: pointer; length: uint32): bool =
  if p == nil: return false
  if build == nil: return true
  let base = cast[uint](addr buffer.data[0])
  let address = cast[uint](p)
  build.current and address >= base and address - base <= build.capacity.uint and
    length.uint <= build.capacity.uint - (address - base)
proc replaceAt(stage: int) =
  if replacementAt != stage: return
  context.current = false
  for b in buffer.data.mitems: b = 0xAC
  conn = default(Conn)
  if stage == 3:
    stas[1].macAddr = [0xAA'u8, 0xBB, 0xCC, 0xDD, 0xEE, 0xF0]
    vif.macAddr = [0xA2'u8, 0xB2, 0xC2, 0xD2, 0xE2, 0xF2]
proc vifChannelForIdx(i: uint8): ptr Vif =
  doAssert i == 1
  addr vif
proc staInfoForIdx(i: uint8): ptr Sta = addr stas[i]
proc smEnvView(): ptr Env = addr env
proc mm_set_wpa_rsn_ie(vifIdx: uint8; ie: pointer; ieLen: uint8) = discard
proc meEnvView(): ptr Me = addr me
proc psEnvView(): ptr Ps = cast[ptr Ps](addr ps_env[0])
proc connectInfoView(p: pointer): ptr Conn = cast[ptr Conn](p)
proc connectInfoCredentials(p: pointer): ptr Conn = cast[ptr Conn](p)
proc vifAssocInfo(p: pointer): ptr Assoc = cast[ptr Assoc](p)
proc ssidIeAt(p: pointer): ptr SsidIeView = cast[ptr SsidIeView](p)
proc rateSetAt(p: pointer): ptr RateSetView = cast[ptr RateSetView](p)
proc macIeDataAt(p: pointer): ptr MacIeDataView = cast[ptr MacIeDataView](p)
proc htCapIeAt(p: pointer): ptr HtCapIeView = cast[ptr HtCapIeView](p)
proc wmmInfoIeAt(p: pointer): ptr WmmInfoIeView = cast[ptr WmmInfoIeView](p)
proc c_memcpy(dst, src: pointer; count: csize_t): pointer =
  doAssert count <= 600
  copyMem(dst, src, count.int)
  dst
proc co_pack8p(dst, src: pointer; count: uint32) =
  discard c_memcpy(dst, src, count.csize_t)
proc me_build_capability(p: pointer): uint16 =
  replaceAt(1)
  0x0431
proc nimFwTrace2U32(label: string; a, b: uint32) = replaceAt(2)
proc getSae(bssid, mac, passphrase: pointer; kind: uint32;
            length: ptr uint32): pointer {.cdecl.} =
  inc callbackCalls
  doAssert kind == 1
  let savedBssid = cast[ptr array[6, uint8]](bssid)[]
  let savedMac = cast[ptr array[6, uint8]](mac)[]
  doAssert savedBssid == expectedPeerMac
  doAssert savedMac == vif.macAddr
  replaceAt(3)
  if replacementAt == 3:
    doAssert cast[ptr array[6, uint8]](bssid)[] == savedBssid
    doAssert cast[ptr array[6, uint8]](mac)[] == savedMac
  if passphrase != nil:
    let text = cast[ptr UncheckedArray[uint8]](passphrase)
    for i in 0..<64: doAssert text[i] == 0x44
    doAssert text[64] == 0
  length[] = payloadLength
  if payloadMissing: nil else: addr payload[0]
proc reset() =
  for b in buffer.before.mitems: b = 0xA5
  for b in buffer.data.mitems: b = 0xCC
  for b in buffer.after.mitems: b = 0xA5
  context = SmTxBuildContext(current: true, capacity: 512)
  assoc = Assoc(ssidLen: 3, basicRates: [12'u8, 2, 4, 11, 22, 12, 18, 24, 36, 48, 72, 96, 108])
  assoc.ssidData[0] = 0x41
  assoc.ssidData[1] = 0x42
  assoc.ssidData[2] = 0x43
  conn = Conn(listenInterval: 9, qosInfo: 0x65)
  for b in conn.keyString.mitems: b = 0x44
  vif = Vif(bssid: [2'u8, 3, 4, 5, 6, 7], currentBssid: [4'u8, 5, 6, 7, 8, 9],
            macAddr: [6'u8, 7, 8, 9, 10, 11], staIdx: 1)
  stas = default(typeof(stas))
  stas[1].macAddr = vif.bssid
  expectedPeerMac = stas[1].macAddr
  env = Env(connectInfo: addr conn)
  me = Me(htSupp: 1)
  ps_env = default(typeof(ps_env))
  ps_env[8] = 1
  assoc.wmmQosInfo = 0x80
  payloadLength = 8
  payloadMissing = false
  for i in 0..<payload.len: payload[i] = (i mod 256).uint8
  callbacks[14] = cast[pointer](getSae)
  wpa_cbs = addr callbacks
  replacementAt = 0
  callbackCalls = 0
proc guards() =
  for b in buffer.before: doAssert b == 0xA5
  for b in buffer.after: doAssert b == 0xA5
  for i in context.capacity.int..<512: doAssert buffer.data[i] == 0xCC
'''

CHECKS = r'''
proc encodeAssoc(reassoc: pointer = nil): tuple[length: uint32, cursor: pointer, ies: uint16] =
  result.cursor = cast[pointer](1)
  result.ies = 0xFFFF
  result.length = meBuildAssociateReq(addr buffer.data[24], addr assoc, reassoc,
    cast[pointer](1), addr result.cursor, addr result.ies, env.connectInfo, addr context)
proc encodeSae(): uint32 =
  meBuildSaeAuthenticate(addr buffer.data[24], 3, 1, 0, 1, addr context)
'''

CASES = {
    "sae_capacity": r'''
for length in [0'u32, 1, 481, 482, 483, 600, high(uint32)]:
  reset()
  payloadLength = length
  let n = encodeSae()
  doAssert n == (if length <= 482: length + 6 else: 0)
  if n != 0:
    for i in 0..<length.int: doAssert buffer.data[30 + i] == payload[i]
  guards()
''',
    "sae_callback_replacement": r'''
reset()
replacementAt = 3
doAssert encodeSae() == 0
for b in buffer.data: doAssert b == 0xAC
guards()
''',
    "sae_missing_inputs": r'''
for kind in 0..3:
  reset()
  case kind
  of 0: wpa_cbs = nil
  of 1: callbacks[14] = nil
  of 2: payloadMissing = true
  else: context.current = false
  doAssert encodeSae() == 0
  guards()
reset()
vif.bssid = default(typeof(vif.bssid))
doAssert encodeSae() == 14
reset()
env.connectInfo = nil
doAssert encodeSae() == 14
''',
    "sae_peer_address_source": r'''
reset()
vif.bssid = default(typeof(vif.bssid))
doAssert encodeSae() == 14 and callbackCalls == 1
reset()
stas[1].macAddr = [8'u8, 9, 10, 11, 12, 13]
expectedPeerMac = vif.bssid
doAssert encodeSae() == 14 and callbackCalls == 1
reset()
vif.staIdx = 0xFF
expectedPeerMac = vif.bssid
doAssert encodeSae() == 14 and callbackCalls == 1
reset()
vif.staIdx = 0xFF
vif.bssid = default(typeof(vif.bssid))
expectedPeerMac = vif.currentBssid
doAssert encodeSae() == 14 and callbackCalls == 1
reset()
vif.staIdx = 0xFF
vif.bssid = default(typeof(vif.bssid))
vif.currentBssid = default(typeof(vif.currentBssid))
doAssert encodeSae() == 0 and callbackCalls == 0
''',
    "association_bytes": r'''
for flags in 0'u32..3:
  for reassoc in [false, true]:
    reset()
    assoc.securityFlags = flags
    var bssid = [8'u8, 7, 6, 5, 4, 3]
    let built = encodeAssoc(if reassoc: addr bssid[0] else: nil)
    let fixed = if reassoc: 10 else: 4
    let expected = fixed + 5 + 10 + 6 + (if (flags and 1) != 0: 9 else: 0) +
      (if (flags and 2) != 0: 28 else: 0)
    doAssert built.length == expected.uint32 and built.ies == (expected - fixed).uint16
    doAssert cast[uint](built.cursor) == cast[uint](addr buffer.data[24]) + fixed.uint
    doAssert buffer.data[24] == 0x31 and buffer.data[25] == 0x04
    doAssert buffer.data[26] == 9 and buffer.data[27] == 0
    let first = 24 + fixed
    doAssert buffer.data[first..first + 4] == @[0'u8, 3, 0x41, 0x42, 0x43]
    doAssert buffer.data[first + 5..first + 6] == @[1'u8, 8]
    doAssert buffer.data[first + 15..first + 16] == @[50'u8, 4]
    if (flags and 1) != 0:
      let wmmAt = first + 21
      doAssert buffer.data[wmmAt..wmmAt + 8] ==
        @[221'u8, 7, 0, 80, 242, 2, 0, 1, 0x65]
    if (flags and 2) != 0:
      let htAt = first + 21 + (if (flags and 1) != 0: 9 else: 0)
      doAssert buffer.data[htAt] == 45 and buffer.data[htAt + 1] == 26
    if reassoc:
      for i in 0..<6: doAssert buffer.data[28 + i] == bssid[i]
    for i in 24 + expected..<512: doAssert buffer.data[i] == 0xCC
    guards()
''',
    "association_ie_order": r'''
reset()
assoc.securityFlags = 3
var securityIe = [48'u8, 2, 1, 0]
var vendorIe = [221'u8, 3, 1, 2, 3]
assoc.rsnIePtr = addr securityIe[0]
assoc.rsnIeLen = securityIe.len.uint8
env.vendorIePtr = addr vendorIe[0]
env.vendorIeLen = vendorIe.len.uint16
let built = encodeAssoc()
doAssert built.length == 25 + securityIe.len.uint32 + 9 + 28 + vendorIe.len.uint32
let first = 28
doAssert buffer.data[first + 21 ..< first + 25] == securityIe
doAssert buffer.data[first + 25 ..< first + 34] ==
  @[221'u8, 7, 0, 80, 242, 2, 0, 1, 0x65]
doAssert buffer.data[first + 34] == 45 and buffer.data[first + 35] == 26
doAssert buffer.data[first + 62 ..< first + 67] == vendorIe
guards()
''',
    "association_wmm_qos_gate": r'''
for psEnabled in [false, true]:
  for uapsdConfigured in [false, true]:
    for vifGate in [false, true]:
      reset()
      assoc.securityFlags = 1
      ps_env[0] = psEnabled.uint32
      ps_env[8] = uapsdConfigured.uint32
      assoc.wmmQosInfo = if vifGate: 0x80'u8 else: 0x7F'u8
      let built = encodeAssoc()
      doAssert built.length == 34 and built.ies == 30
      doAssert built.cursor == addr buffer.data[28]
      doAssert buffer.data[57] ==
        (if uapsdConfigured and vifGate: 0x65'u8 else: 0'u8)
      guards()
reset()
assoc.securityFlags = 1
env.connectInfo = nil
doAssert encodeAssoc().length == 34
doAssert buffer.data[57] == 0
guards()
''',
    "association_each_capacity": r'''
for capacity in 24'u32..112:
  reset()
  context.capacity = capacity
  assoc.securityFlags = 3
  let built = encodeAssoc()
  doAssert (built.length != 0) == (capacity >= 24 + 62)
  if built.length == 0:
    doAssert built.cursor == cast[pointer](1) and built.ies == 0xFFFF
  guards()
''',
    "association_large_vendor_ie": r'''
for length in [462'u16, 463, 464, 600]:
  reset()
  env.vendorIePtr = addr payload[0]
  env.vendorIeLen = length
  let built = encodeAssoc()
  doAssert (built.length != 0) == (length <= 463)
  guards()
''',
    "association_invalid_fields": r'''
for kind in 0..5:
  reset()
  case kind
  of 0: assoc.ssidLen = 33
  of 1: assoc.basicRates[0] = 13
  of 2: assoc.rsnIeLen = 1
  of 3: env.vendorIeLen = 1
  of 4: assoc.basicRates[0] = 0
  else: assoc.ssidLen = 0
  doAssert encodeAssoc().length == 0
  guards()
''',
    "association_replacement": r'''
for stage in 1..2:
  reset()
  replacementAt = stage
  assoc.securityFlags = 3
  doAssert encodeAssoc().length == 0
  for b in buffer.data: doAssert b == 0xAC
  guards()
''',
    "public_abi": r'''
reset()
let sae = me_build_sae_authenticate(addr buffer.data[24], 3, 1, 0, 1)
doAssert sae == 14
reset()
var cursor: pointer
var ies: uint16
let length = me_build_associate_req_impl(addr buffer.data[24], addr assoc, nil,
  cast[pointer](1), addr cursor, addr ies, addr conn)
doAssert length == 25 and ies == 21
doAssert cursor == addr buffer.data[28]
guards()
''',
    "association_setter_alias": r'''
reset()
let baseLength = encodeAssoc().length
reset()
var vendor = [221'u8, 3, 1, 2, 3]
doAssert bl_wifi_set_appie_internal(1, 2, addr vendor[0], vendor.len.uint16, true) == 0
doAssert env.vendorIePtr == (addr vendor[0]) and env.vendorIeLen == vendor.len.uint16
let built = encodeAssoc()
doAssert built.length == baseLength + vendor.len.uint32
doAssert buffer.data[24 + baseLength.int ..< 24 + built.length.int] == vendor
guards()
reset()
doAssert bl_wifi_set_appie_internal(1, 2, addr vendor[0], vendor.len.uint16, true) == 0
doAssert bl_wifi_unset_appie_internal(1, 2) == 0
doAssert env.vendorIePtr == nil and env.vendorIeLen == 0
doAssert encodeAssoc().length == baseLength
guards()
''',
    "association_vif_bounds": r'''
for rawIndex in [2'u, 255'u, 256'u, 257'u, high(uint)]:
  reset()
  var cursor = cast[pointer](0x1234)
  var ies = 0xABCD'u16
  let before = buffer
  let length = meBuildAssociateReq(addr buffer.data[24], addr assoc, nil,
    cast[pointer](rawIndex), addr cursor, addr ies, env.connectInfo, addr context)
  doAssert length == 0 and buffer == before
  doAssert cursor == cast[pointer](0x1234) and ies == 0xABCD'u16
  guards()
''',
}


def source() -> str:
    code = (FW / "scan_station_ap_me.nim").read_text()
    names = ["me_add_ie_ssid", "me_add_ie_supp_rates", "me_add_ie_ext_supp_rates",
             "me_add_ie_ht_capa", "macPtrIsSpecific", "macPtrEquals",
             "meBuildSaeAuthenticate", "me_build_sae_authenticate",
             "meBuildAssociateReq", "me_build_associate_req_impl"]
    return layouts("AuthFixedBodyView", "AuthBodyDataView", "AssocReqFixedBodyView",
                   "MacIeView", "SsidIeView", "RateSetView", "MacIeDataView",
                   "WmmInfoIeView", "HtCapIeView") + PLATFORM + "".join(
        procedure(code, name) for name in names) + "".join(
        procedure((FW / "platform_bl.nim").read_text(), name) for name in
        ["bl_wifi_set_appie_internal", "bl_wifi_unset_appie_internal"]) + CHECKS


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_station_tx_encoding(tmp_path: Path, case: str, mode: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    path = tmp_path / "encoding.nim"
    path.write_text(source() + "\n" + CASES[case])
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}[mode]
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", "--checks:on", *flags, f"--nimcache:{tmp_path / 'cache'}",
        f"-o:{tmp_path / 'check'}", str(path)], cwd=ROOT, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    assert result.returncode == 0, result.stdout
