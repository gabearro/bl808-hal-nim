"""Serialize real beacon/probe IEs and inspect their bytes and write boundaries."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_ap_teardown import procedure


ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

AP_EXTRAS_PLATFORM = r'''
proc ieCursorAfter(p: pointer; size: uint): pointer =
  addr cast[ptr UncheckedArray[uint8]](p)[size]
proc copyIeBytes(dst, src: pointer; size: uint): pointer =
  copyMem(dst, src, size.int)
  ieCursorAfter(dst, size)
proc c_memmove(dst, src: pointer; size: csize_t): pointer {.importc: "memmove", header: "<string.h>".}
'''

PLATFORM = r'''
const
  MAX_VIFS = 2
  VIF_TYPE_STA = 0'u8
  TxlFramePayloadSize = 512'u32
type
  Channel = object
    prim20Freq: uint16
    band: uint8
  Context = object
    channel: tuple[band, chanType: uint8, primFreq, centerFreq1: uint16, txPower: uint8]
    invalidMarker: uint8
  Vif = object
    vifType: uint8
    capabilityInfo: uint16
    macAddr: array[6, uint8]
    supportedRatesLong: array[34, uint8]
    basicRates: array[13, uint8]
    beaconIntervalTu: uint16
    operChan, chanCtxt: pointer
    config: tuple[privacyFlag: uint8, securityFlags: uint32, beaconInterval: uint16]
    security: tuple[rsnIePtr: uint, rsnIeLen: uint8]
    wmmQosInfo: uint8
    edcaRegs: array[4, uint32]
  VifChannelView = Vif
  ScanChannelEntry = Channel
  Ie = object
    id: uint8
    payload: seq[uint8]
var
  vifs: array[2, Vif]
  channels: array[2, Channel]
  contexts: array[2, Context]
  me: tuple[htCaps: array[32, uint8]]
  sequence: tuple[seqCounter: uint16]
  mac_addr_bcst_fwd = [255'u8, 255, 255, 255, 255, 255]
  rsn = [48'u8, 20, 1, 0, 0, 15, 0xAC, 4, 1, 0, 0, 15, 0xAC, 4,
         1, 0, 0, 15, 0xAC, 2, 0, 0]
  bytes: array[2048, uint8]
  interruptsEnabled = true
proc irqSave(): uint32 =
  result = interruptsEnabled.uint32
  interruptsEnabled = false
proc irqRestore(saved: uint32) = interruptsEnabled = saved != 0
proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc vifApConfig(v: ptr Vif): ptr typeof(v.config) = addr v.config
proc vifSecurity(v: ptr Vif): ptr typeof(v.security) = addr v.security
proc vifWpaCipher(v: ptr Vif): uint8 = v.wmmQosInfo
proc chanCtxtAt(p: pointer): ptr Context = cast[ptr Context](p)
proc meEnvView(): ptr typeof(me) = addr me
proc meBeaconSequence(): ptr typeof(sequence) = addr sequence
proc encodedArgU8(p: pointer): uint8 = cast[uint](p).uint8
proc c_memcpy(dst, src: pointer; size: csize_t): pointer =
  copyMem(dst, src, size.int)
  dst
proc co_pack8p(dst, src: pointer; size: uint32) = copyMem(dst, src, size.int)
proc parse(start, length: int): seq[Ie] =
  var offset = start
  while offset < start + length:
    doAssert offset + 2 <= start + length
    let size = bytes[offset + 1].int
    doAssert offset + 2 + size <= start + length, "IE extends beyond returned length"
    result.add(Ie(id: bytes[offset], payload: @bytes[offset + 2 ..< offset + 2 + size]))
    offset += size + 2
proc find(ies: seq[Ie]; id: uint8; vendorType = -1): int =
  for i, ie in ies:
    if ie.id == id and (vendorType < 0 or
        (ie.payload.len >= 4 and ie.payload[0..2] == @[0'u8, 0x50, 0xF2] and
         ie.payload[3].int == vendorType)):
      return i
  -1
proc guard(length: uint32) =
  for i in 0 ..< 8: doAssert bytes[i] == 0xA5
  for i in 8 + length.int ..< bytes.len: doAssert bytes[i] == 0xA5
proc reset(vif, flags, security, width: uint8; freq: uint16; count: int) =
  vifs = default(typeof(vifs))
  channels[vif] = Channel(prim20Freq: freq, band: 0)
  contexts[vif] = default(Context)
  contexts[vif].channel.band = 0
  contexts[vif].channel.primFreq = freq
  contexts[vif].channel.chanType = width
  contexts[vif].channel.centerFreq1 =
    if width == 1: freq + 10 elif width == 2: freq - 10 else: freq
  contexts[vif].invalidMarker = 3
  let v = addr vifs[vif]
  v.vifType = 2
  v.macAddr = [2'u8, vif, 4, 5, 6, 7]
  v.supportedRatesLong[0] = 4
  v.supportedRatesLong[1 .. 4] = [97'u8, 0, 98, 99]
  v.basicRates = [count.uint8, 0x82, 0x84, 0x8B, 0x96, 0x0C, 0x12, 0x18, 0x24, 0x30, 0x48, 0x60, 0x6C]
  v.beaconIntervalTu = 3
  v.config = (security, flags.uint32, 100'u16)
  v.operChan = addr channels[vif]
  v.chanCtxt = addr contexts[vif]
  v.wmmQosInfo = 0x85
  v.edcaRegs = [0x0A47'u32, 0x0A43, 0x005E432, 0x002F322]
  if security != 0:
    v.security.rsnIePtr = cast[uint](addr rsn[0])
    v.security.rsnIeLen = rsn.len.uint8
  for i in 0 ..< me.htCaps.len: me.htCaps[i] = (i + 16).uint8
  for b in bytes.mitems: b = 0xA5
proc checkIes(ies: seq[Ie]; flags, security, width: uint8; freq: uint16;
              beacon: bool; hidden: uint8; rateCount: int; withExtras = false) =
  # IEEE 802.11-2012 Tables 8-20 and 8-27, independently ordered.
  var expected = @[0'u8, 1, 3]
  if beacon: expected.add(5)
  if withExtras: expected.add(7)
  expected.add(42)
  if rateCount > 8: expected.add(50)
  if security != 0: expected.add(48)
  if (flags and 2) != 0: expected.add([45'u8, 61])
  if security == 2: expected.add(221)
  if (flags and 1) != 0: expected.add(221)
  if withExtras: expected.add([221'u8, 221])
  var ids: seq[uint8]
  for ie in ies: ids.add(ie.id)
  doAssert ids == expected, $ids & " != " & $expected
  let ssid = find(ies, 0)
  doAssert ssid == 0
  doAssert ies[ssid].payload == (if beacon and hidden != 0: @[] else: @[97'u8, 0, 98, 99])
  let ht = find(ies, 45)
  doAssert (ht >= 0) == ((flags and 2) != 0), "legacy beacon unexpectedly advertises HT"
  if ht >= 0:
    doAssert ies[ht].payload.len == 26
    doAssert ies[ht].payload[21 .. 24] == @[40'u8, 41, 42, 43], "wrong HT beamforming source offset"
    let operation = find(ies, 61)
    doAssert operation >= 0 and ies[operation].payload.len == 22
    let expectedOffset = if width == 0: 0'u8 elif width == 1: 5'u8 else: 7'u8
    doAssert ies[operation].payload[1] == expectedOffset, "wrong 20/40 MHz secondary-channel field"
  let wpa = find(ies, 221, 1)
  doAssert (wpa >= 0) == (security == 2), "QoS/HT must not manufacture a WPA security IE"
  if wpa >= 0:
    doAssert ies[wpa].payload.len == 28
    doAssert ies[wpa].payload[26 .. 27] == @[0'u8, 0], "WPA capabilities contain stale memory"
  let wmm = find(ies, 221, 2)
  doAssert (wmm >= 0) == ((flags and 1) != 0), "QoS beacon is missing WMM parameters"
  if wmm >= 0:
    let data = ies[wmm].payload
    doAssert data.len == 24 and data[4 .. 7] == @[1'u8, 1, 0x85, 0]
    doAssert data[8 .. 23] == @[3'u8, 0xA4, 0, 0, 0x27, 0xA4, 0, 0,
                               0x42, 0x43, 0x5E, 0, 0x62, 0x32, 0x2F, 0]
  let ds = find(ies, 3)
  doAssert ds >= 0 and ies[ds].payload == @[if freq == 2484: 14'u8 else: 6'u8]
  doAssert find(ies, 37) < 0, "channel-context marker was mistaken for CSA state"
  doAssert find(ies, 127) < 0
  doAssert (find(ies, 5) >= 0) == beacon
'''

CHECKS = r'''
var missingCursor: pointer = nil
doAssert me_add_ie_ht_capa(nil) == 0
doAssert me_add_ie_ht_capa(addr missingCursor) == 0
doAssert me_add_ie_ht_oper(nil, nil) == 0
doAssert me_add_ie_ht_oper(addr missingCursor, nil) == 0
for mode in [1'u8, 2'u8]:
  doAssert me_add_ie_rsn(nil, mode) == 0
  doAssert me_add_ie_rsn(addr missingCursor, mode) == 0
doAssert me_add_ie_wpa(nil, 2) == 0
doAssert me_add_ie_wpa(addr missingCursor, 2) == 0
let rsnCcmp = @[48'u8, 20, 1, 0, 0, 15, 0xAC, 4, 1, 0, 0, 15, 0xAC, 4,
                1, 0, 0, 15, 0xAC, 2, 0, 0]
let rsnMixed = @[48'u8, 24, 1, 0, 0, 15, 0xAC, 2, 2, 0, 0, 15, 0xAC, 2,
                 0, 15, 0xAC, 4, 1, 0, 0, 15, 0xAC, 2, 0, 0]
let wpaMixed = @[221'u8, 28, 0, 80, 0xF2, 1, 1, 0, 0, 80, 0xF2, 2,
                 2, 0, 0, 80, 0xF2, 2, 0, 80, 0xF2, 4, 1, 0,
                 0, 80, 0xF2, 2, 0, 0]
for mode in 0'u8 .. 3'u8:
  for b in bytes.mitems: b = 0xA5
  var cursor: pointer = addr bytes[8]
  let expected = if mode == 1: rsnCcmp elif mode == 2: rsnMixed else: @[]
  let length = me_add_ie_rsn(addr cursor, mode)
  doAssert length == expected.len.uint32
  doAssert cursor == cast[pointer](cast[uint](addr bytes[8]) + length.uint)
  doAssert bytes[8 ..< 8 + length.int] == expected
  guard(length)
let wpaBuilder: proc(buf: pointer; mode: uint8): uint32 {.cdecl.} = me_add_ie_wpa
for mode in 0'u8 .. 3'u8:
  for b in bytes.mitems: b = 0xA5
  var cursor: pointer = addr bytes[8]
  let expected = if mode == 2: wpaMixed else: @[]
  let length = wpaBuilder(addr cursor, mode)
  doAssert length == expected.len.uint32
  doAssert cursor == cast[pointer](cast[uint](addr bytes[8]) + length.uint)
  doAssert bytes[8 ..< 8 + length.int] == expected
  guard(length)
for b in bytes.mitems: b = 0xA5
var timCursor: pointer = addr bytes[8]
doAssert me_add_ie_tim(addr timCursor, 3) == 6
doAssert cast[uint](timCursor) == cast[uint](addr bytes[14])
doAssert bytes[8 .. 13] == [5'u8, 4, 0xA5, 3, 0xA5, 0xA5],
  "TIM template builder overwrote fields owned by the live TIM descriptor"
for vif in 0'u8 .. 1'u8:
  for flags in 0'u8 .. 3'u8:
    for security in 0'u8 .. 2'u8:
      for width in 0'u8 .. 2'u8:
        for freq in [2437'u16, 2484]:
          for count in [4, 8, 12]:
            for hidden in 0'u8 .. 1'u8:
              reset(vif, flags, security, width, freq, count)
              sequence.seqCounter = 65535
              var timOffset: uint16
              var timLength: uint8
              let expectedLength = meBeaconFrameLength(vif, hidden)
              let size = me_build_beacon(addr bytes[8], vif, addr timOffset, addr timLength, hidden)
              doAssert size.uint64 == expectedLength, "beacon size prediction differs from serialization"
              doAssert bytes[8 .. 11] == [0x80'u8, 0, 0, 0]
              doAssert bytes[30 .. 31] == [0'u8, 0]
              for i in 32 .. 39: doAssert bytes[i] == 0, "beacon timestamp leaked old buffer data"
              let cap = bytes[42].uint16 or (bytes[43].uint16 shl 8)
              doAssert cap == (if security != 0: 0x411'u16 else: 0x401'u16)
              guard(size)
              let ies = parse(44, size.int - 36)
              checkIes(ies, flags, security, width, freq, true, hidden, count)
              doAssert timLength == 6 and bytes[8 + timOffset.int] == 5
              for b in bytes.mitems: b = 0xA5
              var output: uint16
              let probeSize = me_build_probe_rsp(addr bytes[8], vif, addr output)
              doAssert probeSize == output.uint32
              doAssert probeSize == meProbeResponseLength(vif),
                "probe response size prediction differs from serialization"
              guard(probeSize)
              for i in 8 .. 15: doAssert bytes[i] == 0, "probe timestamp leaked old buffer data"
              checkIes(parse(20, probeSize.int - 12), flags, security, width, freq, false, hidden, count)

var vendorA = [221'u8, 4, 2, 3, 4, 9]
var country = [7'u8, 6, 85, 83, 32, 1, 11, 20]
var vendorB = [221'u8, 4, 2, 3, 4, 11]
for first in 0 .. 2:
  let raw = case first
    of 0: @country & @vendorA & @vendorB
    of 1: @vendorA & @country & @vendorB
    else: @vendorA & @vendorB & @country
  var extras: ApFrameExtras
  doAssert readApFrameExtras(unsafeAddr raw[0], raw.len.uint32, extras)
  for beacon in [false, true]:
    reset(0, 3, 1, 0, 2437, 12)
    var countryAt: uint16
    let fixed = if beacon: 36 else: 12
    let built = block:
      if beacon:
        var timLength: uint8
        let n = me_build_beacon(addr bytes[8], 0, addr countryAt, addr timLength, 0)
        doAssert bytes[8 + countryAt.int] == 5 and timLength == 6
        countryAt += timLength
        n
      else:
        meBuildProbeResponse(addr bytes[8], 0, 512, nil, addr countryAt)
    let total = built + raw.len.uint32
    let before = bytes
    doAssert not appendApFrameExtras(addr bytes[8], built, countryAt.uint32, total - 1, extras)
    doAssert bytes == before
    doAssert appendApFrameExtras(addr bytes[8], built, countryAt.uint32, total, extras)
    doAssert bytes[8 + countryAt.int] == 7
    let ies = parse(8 + fixed, total.int - fixed)
    checkIes(ies, 3, 1, 0, 2437, beacon, 0, 12, true)
    doAssert ies[find(ies, 7)].payload == @country[2 .. ^1]
    doAssert ies[^2].payload == @vendorA[2 .. ^1] and ies[^1].payload == @vendorB[2 .. ^1]
    guard(total)
var extras: ApFrameExtras
let duplicateCountry = @country & @country
doAssert not readApFrameExtras(unsafeAddr duplicateCountry[0], duplicateCountry.len.uint32, extras)
doAssert not readApFrameExtras(addr country[0], country.len.uint32 - 1, extras)
var padded = [7'u8, 10, 85, 83, 32, 1, 11, 20, 36, 4, 20, 0]
doAssert readApFrameExtras(addr padded[0], padded.len.uint32, extras)
padded[^1] = 1
doAssert not readApFrameExtras(addr padded[0], padded.len.uint32, extras)

reset(0, 1, 0, 0, 2437, 4)
vifs[0].edcaRegs[1] = (vifs[0].edcaRegs[1] and not 0xF'u32) or 9
var offset: uint16
var timSize: uint8
let changedSize = me_build_beacon(addr bytes[8], 0, addr offset, addr timSize, 0)
let changed = parse(44, changedSize.int - 36)
doAssert changed[find(changed, 221, 2)].payload[8] == 9,
  "WMM must advertise the configured AIFSN"
guard(changedSize)

'''


def program_source(checks: str = CHECKS) -> str:
    layout = (FW / "layout_types.nim").read_text()
    names = ["ApFrameExtras", "MacIeView", "MacIeDataView", "RateSetView", "SsidIeView", "DsParamSetIeView",
             "OneByteMacIeView", "HtCapIeView", "HtOperIeView", "RsnSuiteView",
             "RsnCcmpPskIeView", "RsnTkipCcmpIeView", "WpaVendorIeView", "WpaPskVendorIeView",
             "CsaIeView", "TimIeView", "WmmAcParamRecord", "WmmParameterIeView",
             "BeaconFrameFixedView", "ProbeRspFixedBodyView", "MacDataFrameHeaderView"]
    declarations = "type\n"
    for name in names:
        declarations += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    helpers = ""
    for name in ["rateSetAt", "ssidIeAt", "macIeDataAt", "dsParamSetIeAt", "oneByteMacIeAt",
                 "htCapIeAt", "htOperIeAt", "rsnCcmpPskIeAt", "rsnTkipCcmpIeAt", "wpaVendorIeAt",
                 "wpaPskVendorIeAt", "csaIeAt", "timIeAt", "wmmParameterIeAt",
                 "beaconFrameFixedView", "beaconFrameIeBody", "probeRspFixedBodyView", "probeRspIeBody"]:
        match = re.search(r"(?ms)^template " + name + r"\b.*?(?=^template |^proc |\Z)", layout)
        assert match, name
        helpers += match.group(0)
    scan = (FW / "scan_station_ap_me.nim").read_text()
    bodies = procedure(layout, "setLe32")
    bodies += procedure((FW / "kernel_mac_channel.nim").read_text(), "phy_freq_to_channel").replace("weakExport, ", "")
    for name in ["readApFrameExtras", "appendApFrameExtras",
                 "me_build_capability", "me_add_ie_ssid", "me_add_ie_supp_rates",
                 "me_add_ie_ext_supp_rates", "me_add_ie_ds", "me_add_ie_erp", "me_add_ie_ht_capa",
                 "me_add_ie_ht_oper", "me_add_ie_rsn", "me_add_ie_wpa", "me_add_ie_tim",
                 "writeWpaPskVendorIe", "writeCsaIe", "writeWmmParameterIe",
                 "meBeaconFrameLength", "me_build_beacon", "meProbeResponseLength",
                 "meBuildProbeResponse", "me_build_probe_rsp"]:
        if re.search(r"^proc " + name + r"\*?\b", scan, re.M):
            bodies += procedure(scan, name)
    return declarations + PLATFORM + AP_EXTRAS_PLATFORM + helpers + bodies + checks


@pytest.mark.parametrize("build", ["checked", "release", "asan"])
def test_beacon_and_probe_bytes(tmp_path: Path, build: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    program = tmp_path / "beacon.nim"
    program.write_text(program_source())
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
               f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}"]
    if build == "release":
        command += ["-d:release", "--assertions:on"]
    elif build == "asan":
        command += ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]
    result = subprocess.run(command + [str(program)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
