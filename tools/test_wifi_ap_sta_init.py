"""Execute ME-to-MM station translation against the pinned BL808 wire ABI."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
  TASK_API = 9'u8
  TASK_ME = 3'u8
  TASK_APM = 5'u8
  ME_STA_ADD_CFM = 0xC06'u16
  StaTxPolicyUpdateTxPower = 0x10'u8
type
  MessageHeader = object
    srcId, destId: uint8
    paramLen: uint32
  Station = object
    supportedRates: array[13, uint8]
    capabilityFlags: uint32
    vhtCaps: array[32, uint8]
    txPolicyUpdateFlags: array[2, uint8]
    controlPortState, psState, uapsdBitmap: uint8
    rateWord, aid: uint16
  Vif = object
    apStartBeaconInterval: uint16
    key: tuple[flags: uint32]
    ht: VifHtCapabilitiesOverlay
var
  requestBytes: array[88, uint8]
  header: MessageHeader
  response: array[16, uint8]
  translated: array[28, uint8]
  stations: array[7, Station]
  vifs: array[2, Vif]
  me: tuple[htSupp: uint8]
  assigned, mmStatus: uint8
  allocationFails, rateInitFails: bool
  stationEpochs: array[7, uint32]
  deleted: seq[uint8]
  onRateInit: proc()
  calls, sent, initialized, htCalls: int
  responseLength: uint32
  responseDestination, responseSource: uint8
  aidAtInit: uint16
  deliveryAtInit, serviceAtInit: uint8
  apmPendingAssociations: array[1, tuple[request, confirmation: pointer, meQueued: bool]]

proc u16(data: openArray[uint8]; offset: int): uint16 =
  data[offset].uint16 or (data[offset + 1].uint16 shl 8)
proc u32(data: openArray[uint8]; offset: int): uint32 =
  for i in 0 ..< 4: result = result or (data[offset + i].uint32 shl (8 * i))
proc put32(data: var openArray[uint8]; offset: int; value: uint32) =
  for i in 0 ..< 4: data[offset + i] = ((value shr (8 * i)) and 255).uint8
proc keMsgHdrFromPayload(p: pointer): ptr MessageHeader =
  doAssert p == addr requestBytes[0]
  addr header
proc ke_msg_alloc(id: uint16; dst, src: uint8; size: uint32): pointer =
  doAssert id == ME_STA_ADD_CFM
  responseLength = size
  responseDestination = dst
  responseSource = src
  if not allocationFails: result = addr response[0]
proc ke_msg_send(p: pointer) =
  doAssert p == addr response[0]
  inc sent
proc staInfoForIdx(index: uint8): ptr Station = addr stations[index]
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc vifKeyPointers(vif: ptr Vif): ptr tuple[flags: uint32] = addr vif.key
proc vifHtCapabilities(vif: ptr Vif): ptr VifHtCapabilitiesOverlay = addr vif.ht
proc meEnvView(): ptr typeof(me) = addr me
proc apmPendingRequestSlot(p: pointer; queued: bool): int = 0
proc apmStaSlot(index: uint): ptr tuple[macAddr: array[6, uint8]] =
  cast[ptr tuple[macAddr: array[6, uint8]]](addr requestBytes[0])
proc aidListDelete(p: pointer) = discard
proc staDeleteEpoch(index: uint8): uint32 = stationEpochs[index]
proc staDeleteIsCurrent(index: uint8; epoch: uint32): bool = stationEpochs[index] == epoch
proc mm_sta_del(index: uint8) = deleted.add(index)
proc c_memcpy(dst, src: pointer; count: csize_t): pointer =
  copyMem(dst, src, count.int)
  dst
proc mm_sta_add(param: pointer; logicalIndex, hardwareIndex: ptr uint8): uint8 =
  inc calls
  doAssert param != addr requestBytes[0], "ME request passed directly as MM request"
  copyMem(addr translated[0], param, 28)
  if mmStatus == 0:
    logicalIndex[] = assigned
    hardwareIndex[] = assigned + 8
  mmStatus
proc me_set_sta_ht_vht_param(sta, caps: pointer) =
  doAssert sta == addr stations[assigned]
  doAssert caps == addr vifs[requestBytes[73]].ht
  inc htCalls
proc meTryInitRate(sta: pointer): bool =
  doAssert sta == addr stations[assigned]
  inc initialized
  aidAtInit = stations[assigned].aid
  deliveryAtInit = stations[assigned].psState
  serviceAtInit = stations[assigned].uapsdBitmap
  if onRateInit != nil: onRateInit()
  not rateInitFails
proc me_init_rate(sta: pointer) = discard meTryInitRate(sta)
proc reset(vif, index: uint8; flags: uint32; ampdu: uint8; htEnabled: bool) =
  for b in requestBytes.mitems: b = 0xA5
  for b in response.mitems: b = 0xDA
  stations = default(typeof(stations))
  vifs = default(typeof(vifs))
  for sta in stations.mitems: sta.capabilityFlags = 0x80
  vifs[vif].apStartBeaconInterval = 0x8E88
  vifs[vif].key.flags = 1
  me.htSupp = htEnabled.uint8
  assigned = index
  header = MessageHeader(srcId: 5, destId: TASK_ME, paramLen: 88)
  requestBytes[6] = 12
  requestBytes[22] = ampdu
  put32(requestBytes, 64, flags)
  requestBytes[68] = 0x67
  requestBytes[69] = 0x45
  requestBytes[70] = 9
  requestBytes[71] = 6
  requestBytes[73] = vif
  put32(requestBytes, 76, 0x44332211)
  put32(requestBytes, 80, 0x88776655'u32)
  requestBytes[84] = 0xD5
  requestBytes[85] = 0x9A
  mmStatus = 0
  allocationFails = false
  rateInitFails = false
  stationEpochs = default(typeof(stationEpochs))
  deleted.setLen(0)
  onRateInit = nil
  calls = 0
  sent = 0
  initialized = 0
  htCalls = 0
"""

CHECKS = r"""
for vif in 0'u8 .. 1'u8:
  for index in 0'u8 .. 4'u8:
    for flags in [0'u32, 1, 2, 3, 4, 5, 8, 9, 10, 11, 0x10003]:
      for htEnabled in [false, true]:
        for ampduValue in 0'u16 .. 255'u16:
          let ampdu = ampduValue.uint8
          reset(vif, index, flags, ampdu, htEnabled)
          me_sta_add_req_handler(addr requestBytes[0])
          doAssert calls == 1 and sent == 1 and initialized == 1
          doAssert responseLength == 2 and responseDestination == 5 and responseSource == TASK_ME
          doAssert response[0] == index and response[1] == 0
          for i in 2 ..< response.len: doAssert response[i] == 0xDA
          let mask = if (flags and 2) != 0: (1'u32 shl ((ampdu and 3).uint32 + 13)) - 1 else: 0'u32
          let density = (ampdu shr 2) and 7
          let bandwidth = if (flags and 2) == 0: 0'u8
            elif density <= 2: 1'u8 else: 1'u8 shl (density - 3)
          doAssert u32(translated, 0) == 0 and u16(translated, 4) == mask.uint16
          for i in 0 ..< 6: doAssert translated[6 + i] == requestBytes[i]
          doAssert translated[12] == bandwidth and translated[13] == vif
          doAssert translated[14] == 0xD5 and translated[15] == 0
          doAssert u32(translated, 16) == 0x44332211 and u32(translated, 20) == 0x88776655'u32
          doAssert translated[24] == 0x9A and translated[25] == 0
          doAssert translated[26] == 0 and translated[27] == 0
          let ht = (flags and 3) == 3 and htEnabled
          let expectedCaps = 0x80'u32 or (flags and 1) or (flags and 8) or (if ht: 2'u32 else: 0'u32)
          doAssert stations[index].capabilityFlags == expectedCaps
          doAssert htCalls == ht.int
          if ht:
            for i in 0 ..< 32: doAssert stations[index].vhtCaps[i] == requestBytes[20 + i]
          else:
            doAssert stations[index].vhtCaps == default(typeof(stations[index].vhtCaps))
          doAssert aidAtInit == 0x4567 and deliveryAtInit == 9 and serviceAtInit == 6
          doAssert stations[index].controlPortState == 1 and stations[index].rateWord == 0x888E
          doAssert stations[index].txPolicyUpdateFlags == [0x10'u8, 0'u8]
          for other in 0 ..< stations.len:
            if other != index.int:
              doAssert stations[other].capabilityFlags == 0x80 and stations[other].aid == 0

for source in [5'u8, 9'u8]:
  for error in [1'u8, 7, 255]:
    reset(0, 2, 3, 0, true)
    header.srcId = source
    mmStatus = error
    me_sta_add_req_handler(addr requestBytes[0])
    doAssert calls == 1 and sent == 1 and initialized == 0 and htCalls == 0
    doAssert response[0] == 255 and response[1] == error
    doAssert responseDestination == source

for shortLength in 0'u32 .. 85'u32:
  reset(0, 0, 0, 0, false)
  header.paramLen = shortLength
  me_sta_add_req_handler(addr requestBytes[0])
  doAssert calls == 0 and sent == 1 and response[1] != 0
for badVif in [2'u8, 255]:
  reset(0, 0, 0, 0, false)
  requestBytes[73] = badVif
  me_sta_add_req_handler(addr requestBytes[0])
  doAssert calls == 0 and sent == 1 and response[1] != 0
for count in [13'u8, 255]:
  reset(0, 0, 0, 0, false)
  requestBytes[6] = count
  me_sta_add_req_handler(addr requestBytes[0])
  doAssert calls == 0 and sent == 1 and response[1] != 0
reset(0, 0, 0, 0, false)
allocationFails = true
me_sta_add_req_handler(addr requestBytes[0])
doAssert calls == 0 and sent == 0
me_sta_add_req_handler(nil)
doAssert calls == 0 and sent == 0
doAssert sizeof(MeStaAddReqPayload) == 88 and sizeof(MmStaAddReqPayload) == 28
"""


def procedure(source: str, name: str) -> str:
    match = re.search(r"(?ms)^proc " + name + r"\*?.*?(?=^proc |^\{\.emit:|\Z)", source)
    assert match, name
    return match.group(0)


@pytest.mark.parametrize("build", ["checked", "release", "asan"])
def test_ap_station_wire_translation(tmp_path: Path, build: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    layout = (FW / "layout_types.nim").read_text()
    handlers = (FW / "task_handlers.nim").read_text()
    declarations = "type\n"
    for name in ["MeStaAddReqPayload", "MmStaAddReqPayload", "MeStaAddCfmPayload",
                 "VifHtCapabilitiesOverlay"]:
        declarations += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    declarations += "const\n  MeStaAddCfmPayloadSize = sizeof(MeStaAddCfmPayload).uint32\n"
    declarations += "  MeStaAddReqPayloadSize = sizeof(MeStaAddReqPayload).uint32\n"
    helpers = ""
    helpers += procedure(layout, "mmStaFillAggregation").split("\ntemplate ", 1)[0]
    for name in ["meStaAddReqView", "meStaAddReqCapBlock", "meStaAddReqHtCaps"]:
        match = re.search(r"(?ms)^template " + name + r".*?(?=^template |^proc |\Z)", layout)
        if match:
            helpers += match.group(0)
    helpers += procedure(layout, "lmacGateHalfword")
    body = procedure(handlers, "me_sta_add_req_handler")
    program = tmp_path / "ap_sta_init.nim"
    program.write_text(declarations + PLATFORM + helpers + body + CHECKS)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
               f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}"]
    if build == "release":
        command += ["-d:release", "--assertions:on"]
    elif build == "asan":
        command += ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]
    result = subprocess.run(command + [str(program)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout


@pytest.mark.parametrize("build", ["checked", "release", "asan"])
def test_ap_station_confirmation_rejects_failure(tmp_path: Path, build: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    layout = (FW / "layout_types.nim").read_text()
    view = "type\n  ApmStaAddCfmParamView" + layout.split(
        "  ApmStaAddCfmParamView", 1
    )[1].split("\n\n  ", 1)[0] + "\n"
    body = procedure((FW / "task_handlers.nim").read_text(), "apm_sta_add_cfm_handler")
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", body)))
    )
    platform = r"""
const STA_INFO_TAB_ENTRIES = 7
type
  Station = object
    macAddr: array[6, uint8]
    apmWpaContext: pointer
    valid, instNbr: uint8
  Slot = object
    active, staIdx: uint8
    macAddr: array[6, uint8]
    staHandle: pointer
var
  stations: array[7, Station]
  slots: array[5, Slot]
  apm: tuple[hostapdCtx: pointer]
  wpa_cbs: pointer
  callbacks: tuple[staAdd: pointer]
  confirmation: array[2, uint8]
  additions, notifications: int
  selectedSlot: int
  apmPendingAssociations: array[5, tuple[generation: uint32, vifIdx: uint8]]
proc apmPendingConfirmationSlot(p: pointer): int = selectedSlot
proc apmPendingClear(index: int) = inc apmPendingAssociations[index].generation
proc aidListDelete(p: pointer) = slots[selectedSlot].active = 0
proc mm_sta_del(index: uint8) = discard
proc staInfoForIdx(index: uint8): ptr Station = addr stations[index]
proc apmStaAddCfmParamView(p: pointer): ptr ApmStaAddCfmParamView = cast[ptr ApmStaAddCfmParamView](p)
proc apmEnvView(): ptr typeof(apm) = addr apm
proc apmStaSlot(index: uint): ptr Slot = addr slots[index]
proc wpaCallbacks(): ptr typeof(callbacks) = addr callbacks
proc c_memcmp(a, b: pointer; count: csize_t): cint = cmpMem(a, b, count.int).cint
proc apm_sta_add(index: uint8): uint8 =
  doAssert index == confirmation[0]
  inc additions
proc notified(context: pointer; index: uint8) {.cdecl.} =
  doAssert context == cast[pointer](0x12345678) and index == confirmation[0]
  inc notifications
"""
    checks = r"""
for status in [0'u8, 1, 255]:
  for index in [0'u8, 4, 6, 7, 255]:
    for slotIndex in 0 ..< 5:
      selectedSlot = slotIndex
      additions = 0
      notifications = 0
      slots = default(typeof(slots))
      confirmation = [index, status]
      apm.hostapdCtx = cast[pointer](1)
      wpa_cbs = cast[pointer](1)
      callbacks.staAdd = cast[pointer](notified)
      if index < 7:
        stations[index].valid = 1
        stations[index].macAddr = [2'u8, 3, 4, 5, 6, 7]
        slots[slotIndex] = Slot(active: 1, staIdx: 255,
          macAddr: stations[index].macAddr, staHandle: cast[pointer](0x12345678))
      let before = slots
      apm_sta_add_cfm_handler(addr confirmation[0])
      if status == 0 and index < 7:
        doAssert additions == 1 and notifications == 1
        doAssert slots[slotIndex].staIdx == index
      else:
        doAssert additions == 0 and notifications == 0 and slots[slotIndex].active == 0
apm_sta_add_cfm_handler(nil)
"""
    program = tmp_path / "ap_confirmation.nim"
    program.write_text(view + platform + debug + body + checks)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
               f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}"]
    if build == "release":
        command += ["-d:release", "--assertions:on"]
    elif build == "asan":
        command += ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]
    result = subprocess.run(command + [str(program)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
