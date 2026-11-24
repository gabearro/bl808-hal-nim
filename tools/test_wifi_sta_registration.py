"""Run station registration against vendor field effects and reentrant logs."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
const
  MAX_VIFS = 2
  STA_MGMT_FREE_STAS = 5
type
  Keys = object
    defaultKeyPtr, groupKeyPtr: uint32
    flags: uint32
  Vif = object
    keys: Keys
    stations: CoList
var
  stations: array[7, StaInfoView]
  vifs: array[MAX_VIFS, Vif]
  descriptors: array[5, uint32]
  sta_info_env: CoList
  rxVifEpochs: array[MAX_VIFS, uint32]
  stationEpochs: array[5, uint32]
  request: StaMgmtRegisterParamView
  output: uint8
  irq, logging: bool
  logs, pops: int
  hook: proc()
  logStations: array[7, StaInfoView]
  logVifs: array[MAX_VIFS, Vif]
  logFree: CoList
  expectedLine: uint32
proc sta_mgmt_register*(param: pointer; staIdxOut: ptr uint8): uint8 {.exportc, cdecl.}
proc staInfoForIdx(index: uint8): ptr StaInfoView =
  doAssert index < stations.len.uint8
  addr stations[index]
proc staInfoAt(p: uint): ptr StaInfoView = cast[ptr StaInfoView](p)
proc staMgmtRegisterParamView(p: pointer): ptr StaMgmtRegisterParamView =
  cast[ptr StaMgmtRegisterParamView](p)
proc vifChannelForIdx(index: uint8): ptr Vif =
  doAssert index < MAX_VIFS
  addr vifs[index]
proc vifKeyPointers(vif: ptr Vif): ptr Keys = addr vif.keys
proc vifPostponedStaList(vif: ptr Vif): ptr CoList = addr vif.stations
proc staRxSequence(sta: ptr StaInfoView): ptr StaRxSequenceOverlay =
  cast[ptr StaRxSequenceOverlay](sta)
proc txBufferControlDescAt(index: int): ptr uint32 = addr descriptors[index]
proc staDeleteEpoch(index: uint8): uint32 = stationEpochs[index]
proc irqSave(): uint32 =
  result = if irq: 8'u32 else: 0'u32
  irq = false
proc irqRestore(saved: uint32) = irq = (saved and 8) != 0
proc co_list_push_back(list: ptr CoList; node: ptr CoListHdr) =
  node.next = nil
  if list.first == nil: list.first = node
  else: list.last.next = node
  list.last = node
proc co_list_pop_front(list: ptr CoList): ptr CoListHdr =
  doAssert not irq
  inc pops
  result = list.first
  if result != nil:
    list.first = result.next
    # Preserve the vendor's stale-last convention for an empty list.
{.emit: "#include <stdarg.h>".}
proc logger(level: uint32; tag, file: cstring; line: cint;
            format: cstring) {.cdecl, varargs.} =
  doAssert not irq and level == 2 and tag == nil
  doAssert cast[uint](format) > 4096, "log format is not a string"
  doAssert file == cstring("sta_mgmt.c") and line == expectedLine.cint
  var reportedLine: cint
  var holder, key: pointer
  {.emit: ["va_list args; va_start(args, ", format, "); ",
           reportedLine, " = va_arg(args, int); ",
           holder, " = va_arg(args, void *); ",
           key, " = va_arg(args, void *); va_end(args);"].}
  doAssert reportedLine == expectedLine.cint
  if (vifs[request.instNbr].keys.flags and 8) != 0:
    doAssert format == cstring("------ %d set default key %p, key ptr %p\r\n")
    let candidate = cast[ptr StaInfoView](sta_info_env.first)
    doAssert holder == (addr candidate.keyHolder) and key == candidate.keyHolder
  else:
    doAssert format == cstring("------ %d set default key %p, ptr %p\r\n")
    doAssert holder == (addr vifs[request.instNbr].keys)
    doAssert key == cast[pointer](vifs[request.instNbr].keys.defaultKeyPtr.uint)
  doAssert output == 0xFF
  doAssert stations == logStations and vifs == logVifs
  doAssert sta_info_env == logFree, "a station was reserved before the callback"
  inc logs
  if hook != nil:
    let callback = hook
    hook = nil
    callback()
proc getLogFunc(offset: int): pointer =
  doAssert offset == 204
  if logging: cast[pointer](logger) else: nil
proc setup(vif: uint8 = 0; flags: uint32 = 0; incomingIrq = true) =
  vifs = default(typeof(vifs))
  sta_info_env = default(CoList)
  for i in 0 ..< stations.len:
    zeroMem(addr stations[i], sizeof(StaInfoView))
    let bytes = cast[ptr UncheckedArray[uint8]](addr stations[i])
    for j in 0 ..< sizeof(StaInfoView): bytes[j] = 0xA5
    stations[i].valid = 0
    stations[i].instNbr = 0xFF
    stations[i].link.next = nil
  for i in 0 ..< 5:
    co_list_push_back(addr sta_info_env, addr stations[i].link)
  rxVifEpochs = [19'u32, 23]
  stationEpochs = [1'u32, 2, 3, 4, 5]
  request = StaMgmtRegisterParamView(vif: cast[pointer](0x1234'u),
    rateSet: 0x5678, macAddr: [2'u8, 3, 4, 5, 6, 7], phyBwMax: 12,
    instNbr: vif, extFlag: 0xD2, assocInfoWord0: 0x12345678,
    assocInfoWord1: 0x90123456'u32, paramFlag: 0x69)
  if vif < MAX_VIFS:
    vifs[vif].keys.flags = flags
    vifs[vif].keys.defaultKeyPtr = 0x12345678
  output = 0xCE
  irq = incomingIrq
  logging = true
  logs = 0
  pops = 0
  hook = nil
proc invoke(): uint8 =
  logStations = stations
  logVifs = vifs
  logFree = sta_info_env
  expectedLine = if (vifs[request.instNbr].keys.flags and 8) != 0: 282 else: 293
  sta_mgmt_register(addr request, addr output)
proc expectBytes(actual, expected: pointer; length: int) =
  let a = cast[ptr UncheckedArray[uint8]](actual)
  let e = cast[ptr UncheckedArray[uint8]](expected)
  for i in 0 ..< length:
    doAssert a[i] == e[i], "unexpected write at " & $i
"""

CHECKS = r"""
for vif in 0'u8 .. 1:
  for flags in 0'u32 .. 31:
    for selected in 0 ..< 5:
      for incomingIrq in [false, true]:
        setup(vif, flags, incomingIrq)
        sta_info_env = default(CoList)
        co_list_push_back(addr sta_info_env, addr stations[selected].link)
        var expected = stations
        let req = request
        let sta = addr expected[selected]
        sta.macAddr = req.macAddr
        sta.phyBwMax = 16
        sta.rateSet = req.rateSet
        sta.vif = req.vif
        sta.instNbr = vif
        sta.extFlag = req.extFlag
        sta.assocInfoWord0 = req.assocInfoWord0
        sta.assocInfoWord1 = req.assocInfoWord1
        sta.paramFlag = req.paramFlag
        sta.infoIdx = selected.uint8
        sta.initialRateConfig = 0x19000
        let rx = staRxSequence(sta)
        rx.nonQosSeqCtrl = 0xFFFF
        for entry in rx.qosSeqCtrl.mitems: entry = 0xFFFF
        sta.txPolicy = addr descriptors[selected]
        sta.controlPortState = 0
        sta.keyMat = if (flags and 8) != 0:
          cast[pointer](addr stations[selected].keyHolder)
        else: cast[pointer](addr vifs[vif].keys)
        if (flags and 16) != 0: sta.capabilityFlags = sta.capabilityFlags or 8
        sta.valid = 1
        doAssert invoke() == 0 and output == selected.uint8
        doAssert irq == incomingIrq and logs == 1 and pops == 1
        doAssert request == req
        expectBytes(addr stations, addr expected, sizeof(stations))
        doAssert sta_info_env.first == nil
        doAssert vifs[vif].stations.first == addr stations[selected].link
        doAssert vifs[vif].stations.last == addr stations[selected].link
        doAssert vifs[vif xor 1].stations.first == nil

for bandwidth in 0'u16 .. 255:
  setup()
  request.phyBwMax = bandwidth.uint8
  logging = false
  doAssert invoke() == 0
  doAssert stations[0].phyBwMax == max(16, bandwidth.int).uint8
  doAssert logs == 0 and irq

for incomingIrq in [false, true]:
  setup(incomingIrq = incomingIrq)
  let original = request
  hook = proc() =
    request = default(StaMgmtRegisterParamView)
    vifs[0].keys.flags = 24
  doAssert invoke() == 0 and irq == incomingIrq
  doAssert stations[0].macAddr == original.macAddr
  doAssert stations[0].rateSet == original.rateSet
  doAssert stations[0].assocInfoWord1 == original.assocInfoWord1
  doAssert stations[0].keyMat == addr vifs[0].keys
  doAssert stations[0].capabilityFlags == 0xA5A5A5AD'u32

  setup(flags = 16, incomingIrq = incomingIrq)
  hook = proc() = vifs[0].keys.flags = 0
  doAssert invoke() == 0 and irq == incomingIrq
  doAssert stations[0].keyMat == addr vifs[0].keys
  doAssert stations[0].capabilityFlags == 0xA5A5A5A5'u32

  setup(incomingIrq = incomingIrq)
  let originalStations = stations
  hook = proc() =
    inc rxVifEpochs[0]
    vifs[0].keys.flags = 0xFE
  doAssert invoke() != 0 and output == 0xFF and pops == 0
  doAssert stations == originalStations and irq == incomingIrq
  doAssert vifs[0].keys.flags == 0xFE and vifs[0].stations.first == nil

  # A slot recycled by the callback must not be adopted by the outer add,
  # whose caller captured the earlier station epochs.
  setup(incomingIrq = incomingIrq)
  hook = proc() = inc stationEpochs[0]
  doAssert invoke() != 0 and output == 0xFF and pops == 0
  doAssert stations == logStations and irq == incomingIrq
  doAssert invoke() == 0 and output == 0

setup(1, 24)
var nestedOutput = 0xAA'u8
hook = proc() =
  logging = false
  var nestedRequest = request
  nestedRequest.macAddr[5] = 99
  doAssert sta_mgmt_register(addr nestedRequest, addr nestedOutput) == 0
doAssert invoke() == 0 and output == 1 and nestedOutput == 0
doAssert vifs[1].stations.first == addr stations[0].link
doAssert stations[0].link.next == addr stations[1].link
doAssert vifs[1].stations.last == addr stations[1].link
doAssert stations[0].macAddr[5] == 99 and stations[1].macAddr[5] == 7

setup()
hook = proc() =
  logging = false
  for i in 0 ..< 5:
    var index: uint8
    doAssert sta_mgmt_register(addr request, addr index) == 0 and index == i.uint8
doAssert invoke() != 0 and output == 0xFF and pops == 5
for sta in stations[0 .. 4]: doAssert sta.valid == 1

for invalid in 2'u16 .. 255:
  setup()
  request.instNbr = invalid.uint8
  let before = stations
  doAssert sta_mgmt_register(addr request, addr output) != 0
  doAssert output == 0xFF and stations == before and logs == 0 and pops == 0
  doAssert irq
for first in [0'u8, 1'u8, 0xFF'u8]:
  setup()
  request.macAddr = [first, 0, 0, 0, 0, 0]
  let before = stations
  let freeHead = sta_info_env.first
  doAssert sta_mgmt_register(addr request, addr output) != 0
  doAssert output == 0xFF and stations == before and
    sta_info_env.first == freeHead and logs == 0 and pops == 0 and irq
setup()
doAssert sta_mgmt_register(nil, addr output) != 0
doAssert sta_mgmt_register(addr request, nil) != 0
doAssert pops == 0 and logs == 0 and irq

setup()
sta_info_env.first = nil
doAssert invoke() != 0 and output == 0xFF and logs == 0 and pops == 0

for badHead in 0 .. 3:
  setup()
  logging = false
  var foreign: CoListHdr
  case badHead
  of 0: sta_info_env.first = addr foreign
  of 1: sta_info_env.first = addr stations[5].link
  of 2: stations[0].valid = 1
  else: stations[0].instNbr = 0
  let before = stations
  let beforeFree = sta_info_env
  doAssert invoke() != 0 and output == 0xFF
  doAssert stations == before and sta_info_env == beforeFree and pops == 0
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "port", "request", "vif", "epoch", "active", "output", "callback", "flags"])
def test_sta_registration(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    body = procedure((FW / "sta_management.nim").read_text(), "sta_mgmt_register")
    if mutation == "port":
        body = body.replace("sta.controlPortState = 0", "sta.trafficFlags = 0")
    elif mutation == "request":
        body = body.replace("let req = staMgmtRegisterParamView(param)[]", "let req = staMgmtRegisterParamView(param)")
    elif mutation == "vif":
        body = body.replace("rxVifEpochs[instNbr] != vifEpoch", "false")
    elif mutation == "epoch":
        body = body.replace("staDeleteEpoch(staIdx) != stationEpochs[staIdx]", "false")
    elif mutation == "active":
        body = body.replace("sta.valid != 0 or sta.instNbr != 0xFF", "false")
    elif mutation == "output":
        body = body.replace("staIdxOut[] = 0xFF", "staIdxOut[] = 0")
    elif mutation == "callback":
        start = body.index("  let logFn = getLogFunc(204)")
        end = body.index("  if rxVifEpochs[instNbr]", start)
        callback = body[start:end]
        body = body[:start] + body[end:]
        body = body.replace("  sta.macAddr = req.macAddr", callback + "  sta.macAddr = req.macAddr")
    elif mutation == "flags":
        body = body.replace("if (keyPtrs.flags and 16) != 0", "if (vifFlags and 16) != 0")
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n  CoListHdr = object\n    next: ptr CoListHdr\n  CoList = object\n    first, last: ptr CoListHdr\n"
    for name in ["StaInfoView", "StaRxSequenceOverlay", "StaMgmtRegisterParamView"]:
        types += re.search(rf"(?ms)^  {name}[^\n]*\n.*?(?=\n\n)", layout).group(0) + "\n"
    path = tmp_path / "registration.nim"
    path.write_text(types + PLATFORM + body + CHECKS)
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
