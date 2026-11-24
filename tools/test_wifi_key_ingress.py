"""Exercise the real supplicant key builders and public C entry points."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r'''
const
  MAX_VIFS = 2
  STA_MGMT_FREE_STAS = 5
  STA_INFO_TAB_ENTRIES = 7
  VIF_TYPE_STA = 0'u8
  VIF_TYPE_AP = 2'u8
type
  Vif = object
    vifType: uint8
  Sta = object
    valid, instNbr: uint8
    macAddr: array[6, uint8]
  PlatformLogFunc = proc(a, b: uint32; c: pointer; line: uint32) {.cdecl, varargs.}
var
  vifs: array[2, Vif]
  stations: array[7, Sta]
  rxVifEpochs: array[2, uint32]
  stationEpochs: array[5, uint32]
  sourceKey: array[64, uint8]
  sourcePn: array[16, uint8]
  received: MachwKeyWriteParamView
  writes, maps: int
  deleted: seq[uint8]
  mapping: array[2, array[3, uint8]]
  hardwareResult, mapStatus: uint8
  irq, logging: bool
  events: seq[string]
  hook: proc(point: string)
  nimFwDbgSetKey0, nimFwDbgSetKey1, nimFwDbgSetKey2, nimFwDbgSetKey3: uint32
proc fire(point: string) =
  doAssert not irq
  events.add(point)
  if hook != nil: hook(point)
proc irqSave(): uint32 =
  result = if irq: 8'u32 else: 0'u32
  irq = false
proc irqRestore(saved: uint32) = irq = (saved and 8) != 0
proc vifChannelForIdx(index: uint8): ptr Vif =
  doAssert index < 2
  addr vifs[index]
proc staInfoForIdx(index: uint8): ptr Sta =
  doAssert index < 7
  addr stations[index]
proc staDeleteEpoch(index: uint8): uint32 =
  if index < 5: stationEpochs[index] else: 0
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc c_memcpy(dst, src: pointer; size: csize_t): pointer =
  doAssert size <= 32
  copyMem(dst, src, size.int)
  dst
proc supplicantTkipKeyData(req: ptr SupplicantKeyParamView): ptr SupplicantTkipKeyDataView =
  cast[ptr SupplicantTkipKeyDataView](addr req.keyData[0])
proc mm_sec_machwkey_wr(p: pointer): uint8 =
  received = cast[ptr MachwKeyWriteParamView](p)[]
  inc writes
  result = hardwareResult
  fire("write")
proc mmDeleteSecurityKey(index: uint8): bool =
  doAssert index >= 8 and index < 15
  deleted.add(index)
  fire("delete")
  hardwareResult != 0xFF
proc sm_get_set_machwkey_index(mode: bool; vif: uint8; p: ptr uint8;
                              kind: uint8): cint =
  doAssert not mode and vif < 2 and kind < 3
  inc maps
  if mapStatus == 0: mapping[vif][kind] = p[]
  result = mapStatus.cint
  fire("map")
proc ingressLog(line: uint32) {.exportc, cdecl.} = fire("log" & $line)
{.emit: """
#include <stdint.h>
#include <stddef.h>
extern void ingressLog(uint32_t);
static void ingress_logger(uint32_t level, const char *tag, const char *file,
                           int line, const char *format, ...) {
  ingressLog(line);
}
extern int bl_wifi_set_ap_key_internal(uint8_t, uint8_t, uint32_t, int32_t, void *, size_t, NIM_BOOL);
extern int bl_wifi_set_sta_key_internal(uint8_t, uint8_t, uint32_t, int32_t, int32_t, void *, size_t, void *, size_t, NIM_BOOL);
extern int bl_wifi_set_igtk_internal(uint8_t, uint8_t, uint16_t, void *, void *);
static int ingress_call_ap(void *key, size_t size) {
  return bl_wifi_set_ap_key_internal(1, 2, 3, 1, key, size, (NIM_BOOL)1);
}
static int ingress_call_sta(void *pn, void *key) {
  return bl_wifi_set_sta_key_internal(1, 2, 3, 2, 1, pn, 6, key, 16, (NIM_BOOL)1);
}
static int ingress_call_igtk(void *pn, void *key) {
  return bl_wifi_set_igtk_internal(1, 2, 5, pn, key);
}
""".}
proc ingress_logger(level: uint32; tag, file: cstring; line: cint;
                     format: cstring) {.importc, cdecl, varargs, nodecl.}
proc ingress_call_ap(key: pointer; size: csize_t): cint {.importc, cdecl, nodecl.}
proc ingress_call_sta(pn, key: pointer): cint {.importc, cdecl, nodecl.}
proc ingress_call_igtk(pn, key: pointer): cint {.importc, cdecl, nodecl.}
proc getLogFunc(offset: int): PlatformLogFunc =
  doAssert offset == 204
  if logging: cast[PlatformLogFunc](ingress_logger) else: nil
proc setup(role = VIF_TYPE_STA; vif = 0'u8; incomingIrq = true) =
  for entry in vifs.mitems: entry.vifType = role
  for i in 0 ..< stations.len:
    stations[i] = Sta(valid: (i < 5).uint8, instNbr: (if i < 5: vif else: (i - 5).uint8),
      macAddr: [i.uint8, 2, 3, 4, 5, 6])
  rxVifEpochs = [21'u32, 22]
  stationEpochs = [11'u32, 12, 13, 14, 15]
  for i in 0 ..< sourceKey.len: sourceKey[i] = (i + 1).uint8
  for i in 0 ..< sourcePn.len: sourcePn[i] = (0x80 + i).uint8
  received = default(MachwKeyWriteParamView)
  mapping = [[0xFF'u8, 0xFF, 0xFF], [0xFF'u8, 0xFF, 0xFF]]
  hardwareResult = 13
  mapStatus = 0
  writes = 0
  maps = 0
  deleted.setLen(0)
  events.setLen(0)
  hook = nil
  irq = incomingIrq
  logging = true
proc expectRequest(vif, sta, keyId: uint8; length, pnLength: int; pairwise: bool) =
  var expected: SupplicantKeyParamView
  expected.keyIdx = vif
  expected.addrIdx = keyId
  expected.keyType = if pairwise: sta else: 0xFF'u8
  expected.pairwise = pairwise.uint8
  expected.keyLen = length.uint8
  expected.macLen = pnLength.uint8
  for i in 0 ..< length: expected.keyData[i] = (i + 1).uint8
  for i in 0 ..< pnLength: expected.macAddr[i] = (0x80 + i).uint8
  expected.translatedCipher = case length
    of 5: 0'u8
    of 13: 3'u8
    of 16: 2'u8
    else: 1'u8
  if length == 32:
    for i in 0 ..< 8:
      expected.keyData[16 + i] = (25 + i).uint8
      expected.keyData[24 + i] = (17 + i).uint8
  let actual = cast[ptr UncheckedArray[uint8]](addr received)
  let want = cast[ptr UncheckedArray[uint8]](addr expected)
  for i in 0 ..< 56:
    doAssert actual[i] == want[i], "descriptor byte " & $i & " got " & $actual[i] & " expected " & $want[i]
'''

CHECKS = r'''
for length in [5, 13, 16, 32]:
  for pnLength in 0 .. 8:
    for pairwise in [false, true]:
      for vif in 0'u8 .. 1:
        for keyId in 0'u8 .. 3:
          setup(vif = vif)
          doAssert setKey(vif, 2, keyId, addr sourcePn[0], pnLength.csize_t,
            addr sourceKey[0], length.csize_t, pairwise) == 13
          doAssert writes == 1 and irq
          expectRequest(vif, 2, keyId, length, pnLength, pairwise)
for length in 0 .. 255:
  if length in [5, 13, 16, 32]: continue
  setup()
  doAssert setKey(0, 0, 0, nil, 0, addr sourceKey[0], length.csize_t, true) == 0xFF
  doAssert writes == 0 and irq
for length in [272.csize_t, high(csize_t)]:
  setup()
  doAssert setKey(0, 0, 0, nil, 0, addr sourceKey[0], length, true) == 0xFF
for length in 9 .. 255:
  setup()
  doAssert setKey(0, 0, 0, addr sourcePn[0], length.csize_t, addr sourceKey[0], 16, true) == 0xFF
  doAssert writes == 0
setup()
doAssert setKey(0, 0, 0, nil, 1, addr sourceKey[0], 16, true) == 0xFF
doAssert setKey(0, 0, 0, nil, 0, nil, 16, true) == 0xFF
doAssert writes == 0

for role in [VIF_TYPE_STA, VIF_TYPE_AP]:
  for vif in 0'u8 .. 1:
    for pairwise in [false, true]:
      for (alg, length) in [(1'u32, 5), (2'u32, 32), (3'u32, 16), (5'u32, 13), (6'u32, 5), (6'u32, 13)]:
        for incomingIrq in [false, true]:
          setup(role, vif, incomingIrq)
          let status = if role == VIF_TYPE_STA:
            bl_wifi_set_sta_key_internal(vif, 2, alg, 1, 1, addr sourcePn[0], 6,
              addr sourceKey[0], length.csize_t, pairwise)
          else:
            bl_wifi_set_ap_key_internal(vif, 2, alg, 1, addr sourceKey[0], length.csize_t, pairwise)
          doAssert status == 0 and irq == incomingIrq
          doAssert writes == 1 and deleted.len == 0
          expectRequest(vif, 2, 1, length, (if role == VIF_TYPE_STA: 6 else: 0), pairwise)
          if role == VIF_TYPE_STA:
            doAssert maps == 1 and mapping[vif][(if pairwise: 0 else: 1)] == 13
            doAssert events == @["write", "map", "log211", "log212", "log213"]
          else:
            doAssert maps == 0 and events == @["write", "log192"]

for pairwise in [false, true]:
  setup(VIF_TYPE_AP)
  doAssert bl_wifi_set_ap_key_internal(0, 2, 0, 0, nil, 0, pairwise) == 0
  doAssert writes == 0 and deleted == @[10'u8] and events == @["delete", "log192"]
  setup(VIF_TYPE_AP)
  hardwareResult = 0xFF
  doAssert bl_wifi_set_ap_key_internal(0, 2, 0, 0, nil, 0, pairwise) == -1
  doAssert writes == 0 and deleted == @[10'u8] and events == @["delete"] and irq
for changed in 0 .. 2:
  setup(VIF_TYPE_AP)
  hook = proc(stage: string) =
    if stage != "delete": return
    case changed
    of 0: inc rxVifEpochs[0]
    of 1: inc stationEpochs[2]
    else: stations[2].macAddr[0] = 99
  doAssert bl_wifi_set_ap_key_internal(0, 2, 0, 0, nil, 0, true) == -1
  doAssert events == @["delete"]

for keyId in [4'u16, 5]:
  setup()
  doAssert bl_wifi_set_igtk_internal(0, 2, keyId, addr sourcePn[0], addr sourceKey[0]) == 0
  doAssert received.addrIdx == keyId.uint8 and received.keyIdx == 0
  doAssert received.keyType == 0xFF and received.keyLen == 16 and received.cipherType == 5
  doAssert received.macLen == 6 and received.keyFlags == 0 and received.spp == 0
  for i in 0 ..< 6: doAssert received.macAddr[i] == (0x80 + i).uint8
  doAssert received.macAddrCipherPadding == [0'u8, 0]
  for i in 0 ..< 4:
    doAssert received.keyWords[i] == ((i * 4 + 1).uint32 or ((i * 4 + 2).uint32 shl 8) or
      ((i * 4 + 3).uint32 shl 16) or ((i * 4 + 4).uint32 shl 24))
  doAssert mapping[0][2] == 13 and events == @["write", "map", "log237"]
for keyId in [0'u16, 1, 2, 3, 6, 255, 260, high(uint16)]:
  setup()
  doAssert bl_wifi_set_igtk_internal(0, 2, keyId, addr sourcePn[0], addr sourceKey[0]) == -1
  doAssert writes == 0 and maps == 0

proc install(kind: int): cint =
  case kind
  of 0: bl_wifi_set_ap_key_internal(0, 2, 3, 1, addr sourceKey[0], 16, true)
  of 1: bl_wifi_set_sta_key_internal(0, 2, 3, 1, 0, addr sourcePn[0], 6, addr sourceKey[0], 16, true)
  else: bl_wifi_set_igtk_internal(0, 2, 4, addr sourcePn[0], addr sourceKey[0])
for kind in 0 .. 2:
  setup(if kind == 0: VIF_TYPE_AP else: VIF_TYPE_STA)
  hardwareResult = 0xFF
  doAssert install(kind) == -1 and maps == 0 and events == @["write"]
  if kind != 0:
    setup()
    mapStatus = 7
    doAssert install(kind) == -1 and maps == 1 and events == @["write", "map"]
  let points = if kind == 0: @["write", "log192"]
    elif kind == 1: @["write", "map", "log211", "log212", "log213"]
    else: @["write", "map", "log237"]
  for point in points:
    for action in 0 .. 3:
      setup(if kind == 0: VIF_TYPE_AP else: VIF_TYPE_STA)
      var fired = false
      hook = proc(stage: string) =
        if fired or stage != point: return
        fired = true
        case action
        of 0: inc rxVifEpochs[0]
        of 1: inc stationEpochs[2]
        of 2: stations[2].macAddr[0] = 99
        else: vifs[0].vifType = 4
        mapping[0] = [99'u8, 99, 99]
      doAssert install(kind) == -1 and fired and irq
      doAssert mapping[0] == [99'u8, 99, 99]
      if point == "write": doAssert maps == 0
  setup(if kind == 0: VIF_TYPE_AP else: VIF_TYPE_STA)
  hook = proc(point: string) =
    if point == "write" or point == "log192":
      for b in sourceKey.mitems: b = 0xEE
      for b in sourcePn.mitems: b = 0xEF
  doAssert install(kind) == 0
  doAssert (received.keyWords[0] and 0xFF) == 1

for role in [VIF_TYPE_STA, VIF_TYPE_AP]:
  for badAlg in [4'u32, 7, 8, 9, 255, high(uint32)]:
    setup(role)
    let status = if role == VIF_TYPE_STA:
      bl_wifi_set_sta_key_internal(0, 2, badAlg, 0, 0, nil, 0, addr sourceKey[0], 16, true)
    else: bl_wifi_set_ap_key_internal(0, 2, badAlg, 0, addr sourceKey[0], 16, true)
    doAssert status == -1 and writes == 0
  for badIndex in [-1'i32, 4, 256, high(int32)]:
    setup(role)
    let status = if role == VIF_TYPE_STA:
      bl_wifi_set_sta_key_internal(0, 2, 3, badIndex, 0, nil, 0, addr sourceKey[0], 16, true)
    else: bl_wifi_set_ap_key_internal(0, 2, 3, badIndex, addr sourceKey[0], 16, true)
    doAssert status == -1 and writes == 0
  for alg in [1'u32, 2, 3, 5, 6]:
    for length in 0 .. 64:
      let valid = case alg
        of 1: length == 5
        of 2: length == 32
        of 3: length == 16
        of 5: length == 13
        else: length == 5 or length == 13
      setup(role)
      let status = if role == VIF_TYPE_STA:
        bl_wifi_set_sta_key_internal(0, 2, alg, 0, 0, nil, 0, addr sourceKey[0], length.csize_t, true)
      else: bl_wifi_set_ap_key_internal(0, 2, alg, 0, addr sourceKey[0], length.csize_t, true)
      doAssert (status == 0) == valid and writes == valid.int

for kind in 0 .. 2:
  setup(if kind == 0: VIF_TYPE_AP else: VIF_TYPE_STA)
  let point = if kind == 0: "log192" elif kind == 1: "log211" else: "log237"
  var nested = false
  hook = proc(stage: string) =
    if nested or stage != point: return
    nested = true
    hardwareResult = 12
    sourceKey[0] = 0xAA
    doAssert install(kind) == 0
  doAssert install(kind) == 0 and nested and writes == 2
  doAssert (received.keyWords[0] and 0xFF) == 0xAA
  if kind != 0: doAssert mapping[0][(if kind == 1: 0 else: 2)] == 12

setup(VIF_TYPE_AP)
for station in stations.mitems: station.valid = 0
doAssert bl_wifi_set_ap_key_internal(0, 0xFF, 3, 1, addr sourceKey[0], 16, false) == 0
expectRequest(0, 0xFF, 1, 16, 0, false)

for kind in 0 .. 2:
  setup(if kind == 0: VIF_TYPE_AP else: VIF_TYPE_STA)
  logging = false
  doAssert install(kind) == 0
  doAssert events == (if kind == 0: @["write"] else: @["write", "map"])
for vif in 0'u8 .. 1:
  for index in 0'u8 .. 6:
    setup(VIF_TYPE_AP, vif)
    let valid = index < 5 or index == 5 + vif
    doAssert (bl_wifi_set_ap_key_internal(vif, index, 3, 0, addr sourceKey[0], 16, true) == 0) == valid
    doAssert writes == valid.int

for kind in 0 .. 2:
  for badVif in [2'u8, 3, 255]:
    setup(if kind == 0: VIF_TYPE_AP else: VIF_TYPE_STA)
    let status = if kind == 0: bl_wifi_set_ap_key_internal(badVif, 2, 3, 0, addr sourceKey[0], 16, true)
      elif kind == 1: bl_wifi_set_sta_key_internal(badVif, 2, 3, 0, 0, nil, 0, addr sourceKey[0], 16, true)
      else: bl_wifi_set_igtk_internal(badVif, 2, 4, addr sourcePn[0], addr sourceKey[0])
    doAssert status == -1 and writes == 0 and maps == 0
  for action in 0 .. 3:
    setup(if kind == 0: VIF_TYPE_AP else: VIF_TYPE_STA)
    case action
    of 0: stations[2].valid = 0
    of 1: stations[2].instNbr = 1
    of 2: vifs[0].vifType = 4
    else: vifs[0].vifType = (if kind == 0: VIF_TYPE_STA else: VIF_TYPE_AP)
    doAssert install(kind) == -1 and writes == 0 and maps == 0

setup()
doAssert bl_wifi_set_sta_key_internal(0, 2, 3, 0, 0, addr sourcePn[0], 262, addr sourceKey[0], 16, true) == -1
doAssert bl_wifi_set_sta_key_internal(0, 2, 3, 0, 0, nil, 0, addr sourceKey[0], 272, true) == -1
doAssert bl_wifi_set_sta_key_internal(0, 2, 3, 0, 0, nil, 1, addr sourceKey[0], 16, true) == -1
doAssert bl_wifi_set_igtk_internal(0, 2, 4, nil, addr sourceKey[0]) == -1
doAssert bl_wifi_set_igtk_internal(0, 2, 4, addr sourcePn[0], nil) == -1
doAssert writes == 0 and maps == 0

setup(VIF_TYPE_AP, 1)
doAssert ingress_call_ap(addr sourceKey[0], 16) == 0
expectRequest(1, 2, 1, 16, 0, true)
setup(VIF_TYPE_STA, 1)
doAssert ingress_call_sta(addr sourcePn[0], addr sourceKey[0]) == 0
expectRequest(1, 2, 2, 16, 6, true)
setup(VIF_TYPE_STA, 1)
doAssert ingress_call_igtk(addr sourcePn[0], addr sourceKey[0]) == 0
doAssert received.addrIdx == 5 and received.keyIdx == 1 and mapping[1][2] == 13
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "key_bound", "pn_bound", "pairwise", "ap_delete", "delete_error", "index", "igtk_pn", "igtk_slot", "owner", "hardware_error", "algorithm"])
def test_key_ingress(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    source = (FW / "platform_bl.nim").read_text()
    typedef = re.search(r"(?ms)^type\n  SupplicantKeyOwner = object.*?(?=^proc captureSupplicantKeyOwner)", source).group(0)
    names = ["captureSupplicantKeyOwner", "supplicantKeyOwnerCurrent", "supplicantKeyLengthValid", "setKey",
             "bl_wifi_set_ap_key_internal", "bl_wifi_set_sta_key_internal", "bl_wifi_set_igtk_internal"]
    parts = {name: procedure(source, name) for name in names}
    if mutation == "key_bound":
        parts["setKey"] = parts["setKey"].replace("keyLen notin [5.csize_t, 13.csize_t, 16.csize_t, 32.csize_t]", "false")
    elif mutation == "pn_bound":
        parts["setKey"] = parts["setKey"].replace("macLen > 8", "false")
    elif mutation == "pairwise":
        parts["setKey"] = parts["setKey"].replace("keyDescriptor.pairwise = pairwise.uint8", "keyDescriptor.pairwise = 3")
    elif mutation == "ap_delete":
        parts["bl_wifi_set_ap_key_internal"] = parts["bl_wifi_set_ap_key_internal"].replace("if alg == 0:", "if not pairwise:")
    elif mutation == "delete_error":
        parts["bl_wifi_set_ap_key_internal"] = parts["bl_wifi_set_ap_key_internal"].replace(
            "if not mmDeleteSecurityKey(staIdx + 8'u8):", "if mmDeleteSecurityKey(staIdx + 8'u8) and false:")
    elif mutation == "index":
        parts["bl_wifi_set_sta_key_internal"] = parts["bl_wifi_set_sta_key_internal"].replace("  let keyType = if pairwise:", "  hardwareIndex = 0\n  let keyType = if pairwise:")
    elif mutation == "igtk_pn":
        parts["bl_wifi_set_igtk_internal"] = parts["bl_wifi_set_igtk_internal"].replace("  discard c_memcpy(addr req.macAddr[0], pn, 6.csize_t)\n", "")
    elif mutation == "igtk_slot":
        parts["bl_wifi_set_igtk_internal"] = parts["bl_wifi_set_igtk_internal"].replace("addr hardwareIndex, 2'u8)", "addr hardwareIndex, 5'u8)")
    elif mutation == "owner":
        parts["supplicantKeyOwnerCurrent"] = "proc supplicantKeyOwnerCurrent(owner: SupplicantKeyOwner): bool = true\n"
    elif mutation == "hardware_error":
        for name in names:
            parts[name] = parts[name].replace("hardwareIndex == 0xFF", "false")
    elif mutation == "algorithm":
        parts["supplicantKeyLengthValid"] = "proc supplicantKeyLengthValid(alg: uint32; keyLen: csize_t): bool = true\n"
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n"
    for name in ["SupplicantKeyParamView", "SupplicantTkipKeyDataView", "MachwKeyWriteParamView"]:
        types += re.search(rf"(?ms)^  {name}[^\n]*\n.*?(?=\n\n)", layout).group(0) + "\n"
    path = tmp_path / "ingress.nim"
    path.write_text(types + typedef + PLATFORM + "\n".join(parts.values()) + CHECKS)
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}", *flags[mode], str(path)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and any(reason in result.stdout for reason in
            ["AssertionDefect", "IndexDefect", "AddressSanitizer", "SIGSEGV"]), result.stdout
