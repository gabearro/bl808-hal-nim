"""Execute AP teardown callers and message ownership with the vendor ABI."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"


def procedure(source: str, name: str) -> str:
    match = re.search(r"(?ms)^proc " + name + r"\*?.*?(?=^proc |^\{\.emit:|\Z)", source)
    assert match, name
    return match.group(0)


PLATFORM = r'''
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
  STA_MGMT_FREE_STAS = 5
  TASK_ME = 3'u16
  TASK_APM = 5'u16
  TASK_API = 9'u16
  VIF_TYPE_AP = 2'u8
  KeMsgConsumed = 0.cint
  ME_STA_DEL_REQ = 0xC07'u16
  APM_STA_DEL_IND = 0x1405'u16
  APM_STA_DEL_CFM = 0x1408'u16
  WLAN_FW_APM_DELETESTA_BY_USER = 1
  WLAN_FW_APM_DEATUH_BY_STA = 2
  WLAN_FW_APM_DISASSOCIATE_BY_STA = 3
  WLAN_FW_APM_DELETECONNECTION_TIMEOUT = 4
  WLAN_FW_APM_DELETESTA_FOR_NEW_CONNECTION = 5
  WLAN_FW_APM_DEAUTH_BY_AUTHENTICATOR = 6
type
  PlatformLogFunc = proc(level, severity: uint32; file: pointer;
    line: uint32) {.cdecl, varargs.}
  Header = object
    srcId, destId: uint16
    paramLen: uint32
  Message = object
    header: Header
    body: array[16, uint8]
  Station = object
    macAddr: array[6, uint8]
    valid, instNbr: uint8
    aid: uint16
    connectionStart: uint32
    apmWpaContext: pointer
  Vif = object
    vifType, apChanSwitchPending, state: uint8
    chanCtxt: pointer
  Rx = object
    frameLen: uint16
    vifIdx, staIdx: uint8
    reason: uint16
    staMac: array[6, uint8]
var
  stations: array[7, Station]
  vifs: array[2, Vif]
  apm: tuple[hostapdCtx: pointer, maxSta: uint8]
  request: array[2, uint8]
  requestHeader: Header
  rxHeader: Header
  rx: Rx
  messages: array[3, Message]
  messageIds: array[3, uint16]
  sent: seq[int]
  events: seq[string]
  frames: seq[tuple[vif: int, subtype: uint16, mac: array[6, uint8], reason: uint]]
  timers: seq[tuple[id, task: uint16, delay: uint32]]
  allocations, freeCount, aidDeletes, keyDeletes, logs: int
  failAt, expectedStation: int
  now, searchResult, channelCount: uint32
  clockEnabled, logEnabled: bool
  apmPendingCancelMask: uint8
  apmStoppingVifs, startupMask: uint8
  rxVifEpochs: array[MAX_VIFS, uint32]
  staDeleteEpochs: array[5, uint32]
  callbackHook: proc()
  callbackSite: string
  logRecords: seq[tuple[level: uint32, file: string, line: cint, message: string]]

proc runCallback(site: string) =
  if callbackHook != nil and callbackSite == site:
    let hook = callbackHook
    callbackHook = nil
    hook()

proc staInfoForIdx(index: uint8): ptr Station = addr stations[index]
proc irqSave(): uint32 = 8
proc txlHaltVifQueues(vif: uint8; selected: var uint8): bool = true
proc txl_retire_vif(vif: uint8; selected: uint8) = discard
proc irqRestore(saved: uint32) = doAssert saved == 8
proc apmStartPendingForVif(vif: uint8): bool = (startupMask and (1'u8 shl vif)) != 0
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc apmEnvView(): ptr typeof(apm) = addr apm
proc apmRxMgmtPrefix(p: pointer): ptr Rx = cast[ptr Rx](p)
proc apmStaDelReqView(p: pointer): ptr ApmStaDelReqPayload = cast[ptr ApmStaDelReqPayload](p)
proc c_memcmp(a, b: pointer; n: csize_t): cint = cmpMem(a, b, n.int).cint
proc keMsgHdrFromPayload(p: pointer): ptr Header =
  if p == addr rx: return addr rxHeader
  if p == addr request[0]: return addr requestHeader
  for i in 0 ..< messages.len:
    if p == addr messages[i].body[0]: return addr messages[i].header
  doAssert false, "unknown message payload"
proc ke_msg_alloc(id, dest, source: uint16; length: uint32): pointer =
  inc allocations
  if allocations == failAt: return nil
  doAssert allocations <= messages.len
  let index = allocations - 1
  messageIds[index] = id
  messages[index].header = Header(srcId: source, destId: dest, paramLen: length)
  for b in messages[index].body.mitems: b = 0xD5
  result = addr messages[index].body[0]
  runCallback("allocate" & $allocations)
proc ke_msg_free(p: pointer) =
  var found = false
  for i in 0 ..< messages.len:
    if p == addr messages[i].header: found = true
  doAssert found, "must release message header, not payload"
  inc freeCount
proc ke_msg_send(p: pointer) =
  var index = -1
  for i in 0 ..< messages.len:
    if p == addr messages[i].body[0]: index = i
  doAssert index >= 0
  sent.add(index)
  if messageIds[index] == APM_STA_DEL_IND: events.add("host")
  elif messageIds[index] == ME_STA_DEL_REQ: events.add("me")
  if messageIds[index] == APM_STA_DEL_IND: runCallback("host")
proc aidListDelete(p: pointer) =
  doAssert cmpMem(p, addr stations[expectedStation].macAddr[0], 6) == 0
  inc aidDeletes
  events.add("aid")
  runCallback("aid")
proc mm_sec_machwkey_del(index: uint8) =
  doAssert index.int == expectedStation + 8
  inc keyDeletes
  events.add("key")
  runCallback("key")
proc clockRead(): uint32 {.cdecl.} = now
{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc logger(level: uint32; tag, file: cstring; line: cint;
            format: cstring) {.cdecl, varargs.} =
  doAssert tag == nil and file != nil
  doAssert cast[uint](format) > 4096
  var output: array[256, char]
  var written: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ",
           written, " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
           format, ", args); va_end(args);"].}
  doAssert written >= 0 and written < output.len.cint
  logRecords.add((level, $file, line, $cast[cstring](addr output[0])))
  inc logs
  runCallback("logWrite")
proc getLogFunc(offset: int): PlatformLogFunc =
  doAssert offset == 204
  runCallback("log")
  if logEnabled: cast[PlatformLogFunc](logger) else: nil
proc blOpsFunc(offset: int): pointer =
  if offset == 204:
    return if logEnabled: cast[pointer](logger) else: nil
  doAssert offset == 200
  if clockEnabled: cast[pointer](clockRead) else: nil
proc KE_FIRST_MSG(task: uint16): uint16 = task shl 10
proc ke_timer_set(id, task: uint16; delay: uint32) = timers.add((id, task, delay))
proc apm_send_mlme(vif: pointer; subtype: uint16; mac, callback, argument, extra: pointer) =
  doAssert callback == nil and argument == nil
  runCallback("mlme")
  var vifIndex = -1
  for i in 0 ..< vifs.len:
    if vif == addr vifs[i]: vifIndex = i
  doAssert vifIndex >= 0, "MLME received an index or MAC in place of a VIF pointer"
  frames.add((vifIndex, subtype, cast[ptr array[6, uint8]](mac)[], cast[uint](extra)))
proc hal_machw_search_addr(mac: pointer; unused: uint32): uint32 =
  doAssert mac == addr rx.staMac[0]
  runCallback("search")
  searchResult
proc chan_ctxt_cnt(): uint32 =
  runCallback("channelCount")
  channelCount
proc chan_ctxt_trigger(context: pointer) =
  doAssert context == vifs[rx.vifIdx].chanCtxt
  runCallback("channelTrigger")

proc reset(index = 3) =
  stations = default(typeof(stations))
  vifs = default(typeof(vifs))
  for i in 0 ..< stations.len:
    stations[i] = Station(macAddr: [2'u8, i.uint8, 4, 5, 6, 7],
      valid: 1, instNbr: (i and 1).uint8, aid: (i + 1).uint16,
      connectionStart: 100, apmWpaContext: cast[pointer](0x12345678))
  for i in 0 ..< vifs.len:
    vifs[i] = Vif(vifType: 2, state: 1, chanCtxt: cast[pointer](0x100 + i))
  apmPendingCancelMask = 0
  apmStoppingVifs = 0
  startupMask = 0
  callbackHook = nil
  callbackSite = ""
  expectedStation = index
  rx = Rx(frameLen: 30, vifIdx: stations[index].instNbr, staIdx: index.uint8,
    reason: 0xABCD, staMac: stations[index].macAddr)
  rxHeader = Header(paramLen: 62)
  request = [rx.vifIdx, rx.staIdx]
  requestHeader = Header(srcId: TASK_API, destId: TASK_APM, paramLen: 2)
  apm.hostapdCtx = nil
  messages = default(typeof(messages))
  messageIds = default(typeof(messageIds))
  sent.setLen(0)
  events.setLen(0)
  frames.setLen(0)
  timers.setLen(0)
  allocations = 0
  freeCount = 0
  aidDeletes = 0
  keyDeletes = 0
  logs = 0
  logRecords.setLen(0)
  failAt = 0
  clockEnabled = true
  logEnabled = false
  now = 80000
  searchResult = index.uint32
  channelCount = 0

proc checkDeletion(status, reason: uint16; withConfirmation = false) =
  let host = if withConfirmation: 2 else: 1
  let me = if withConfirmation: 1 else: 0
  doAssert messageIds[host] == APM_STA_DEL_IND and messageIds[me] == ME_STA_DEL_REQ
  doAssert messages[host].header == Header(srcId: TASK_APM, destId: TASK_API, paramLen: 6)
  doAssert messages[me].header == Header(srcId: TASK_APM, destId: TASK_ME, paramLen: 1)
  doAssert messages[host].body[0] == (status and 255).uint8
  doAssert messages[host].body[1] == (status shr 8).uint8
  doAssert messages[host].body[2] == (reason and 255).uint8
  doAssert messages[host].body[3] == (reason shr 8).uint8
  doAssert messages[host].body[4] == expectedStation.uint8 and messages[host].body[5] == 0
  doAssert messages[me].body[0] == expectedStation.uint8
  for i in 6 ..< 16: doAssert messages[host].body[i] == 0xD5
  for i in 1 ..< 16: doAssert messages[me].body[i] == 0xD5
  doAssert aidDeletes == 1 and freeCount == 0
  doAssert stations[expectedStation].apmWpaContext == nil
  doAssert sent[0] == host and sent[1] == me
'''


CHECKS = r"""
for index in 0 ..< 5:
  for status in [0'u16, 1, 4, 5, 6, 0x1234, 65535]:
    for reason in [0'u16, 1, 2, 8, 0xABCD, 65535]:
      for hostapd in [false, true]:
        for hasClock in [false, true]:
          for hasLog in [false, true]:
            reset(index)
            apm.hostapdCtx = if hostapd: cast[pointer](1) else: nil
            clockEnabled = hasClock
            logEnabled = hasLog
            doAssert apm_sta_delete(index.uint8, addr rx.staMac[0], status, reason)
            checkDeletion(status, reason)
            doAssert keyDeletes == hostapd.int
            doAssert events == (if hostapd: @["aid", "key", "host", "me"] else: @["aid", "host", "me"])
for failed in [1, 2]:
  reset()
  failAt = failed
  doAssert not apm_sta_delete(3, addr rx.staMac[0], 4, 65535)
  doAssert aidDeletes == 0 and keyDeletes == 0 and sent.len == 0
  doAssert freeCount == failed - 1 and stations[3].apmWpaContext == cast[pointer](0x12345678)
for index in [5'u8, 6, 7, 255]:
  reset()
  doAssert not apm_sta_delete(index, addr rx.staMac[0], 4, 65535)
  doAssert allocations == 0
reset()
doAssert not apm_sta_delete(3, nil, 4, 65535)
rx.staMac[2] = 99
doAssert not apm_sta_delete(3, addr rx.staMac[0], 4, 65535)
doAssert allocations == 0

for index in 0 ..< 5:
  reset(index)
  doAssert apm_sta_remove(rx.vifIdx, index.uint8, 6, 0x1234)
  checkDeletion(6, 0x1234)
  doAssert frames == @[(rx.vifIdx.int, 0xC0'u16, rx.staMac, 0x1234'u)]
  reset(index)
  apm_sta_fw_delete(index.uint8, 4, 65535)
  checkDeletion(4, 65535)
  doAssert frames.len == 0
  reset(index)
  let api: proc(vif, sta: uint8; reason: uint32): cint {.cdecl.} = bl_wifi_ap_deauth_internal
  doAssert api(rx.vifIdx, index.uint8, 0xFFFF1234'u32) == 0
  checkDeletion(6, 0x1234)
  doAssert frames[0].reason == 0x1234
reset()
doAssert not apm_sta_remove(0, 3, 6, 2)
doAssert not apm_sta_remove(2, 3, 6, 2)
doAssert not apm_sta_remove(1, 7, 6, 2)
doAssert not apm_sta_remove(1, 5, 6, 2)
doAssert not apm_sta_remove(0, 6, 6, 2)
stations[3].valid = 0
doAssert not apm_sta_remove(1, 3, 6, 2)
doAssert allocations == 0 and frames.len == 0

for index in 0 ..< 5:
  for reason in [0'u16, 1, 0x1234, 65535]:
    reset(index)
    rx.reason = reason
    apm_deauth_handler(addr rx)
    checkDeletion(2, reason)
    doAssert frames.len == 0
    reset(index)
    rx.reason = reason
    apm_disassoc_handler(addr rx)
    checkDeletion(3, reason)
    doAssert frames == @[(rx.vifIdx.int, 0xC0'u16, rx.staMac, 2'u)]
  reset(index)
  channelCount = 2
  apm_auth_handler(addr rx)
  checkDeletion(5, 65535)
  doAssert frames == @[(rx.vifIdx.int, 0xB0'u16, rx.staMac, 0'u)]
  doAssert vifs[rx.vifIdx].apChanSwitchPending == 1
for invalid in 0 ..< 5:
  reset()
  case invalid
  of 0: rx.vifIdx = 255
  of 1: rx.staIdx = 7
  of 2: rx.vifIdx = 0
  of 3: stations[3].valid = 0
  else: rx.staMac[0] = 99
  apm_deauth_handler(addr rx)
  apm_disassoc_handler(addr rx)
  doAssert allocations == 0 and frames.len == 0
reset()
apm_deauth_handler(nil)
apm_disassoc_handler(nil)
apm_auth_handler(nil)
doAssert allocations == 0 and frames.len == 0

for phase in 0 .. 3:
  reset()
  case phase
  of 0: vifs[rx.vifIdx].state = 0
  of 1: apmPendingCancelMask = 1'u8 shl rx.vifIdx
  of 2: apmStoppingVifs = 1'u8 shl rx.vifIdx
  else: startupMask = 1'u8 shl rx.vifIdx
  apm_auth_handler(addr rx)
  doAssert allocations == 0 and frames.len == 0

for site in ["search", "channelCount", "channelTrigger"]:
  reset()
  channelCount = 2
  callbackSite = site
  callbackHook = proc() =
    discard rxInvalidateVif(rx.vifIdx)
    discard rxInvalidateVif(rx.vifIdx)
  apm_auth_handler(addr rx)
  doAssert frames.len == 0, "authentication response crossed an AP restart"

for index in 0 ..< 5:
  for source in [9'u16, 100]:
    reset(index)
    requestHeader.srcId = source
    doAssert apm_sta_del_req_handler(addr request[0]) == 0
    checkDeletion(1, 2, true)
    doAssert sent == @[2, 1, 0]
    doAssert messageIds[0] == APM_STA_DEL_CFM
    doAssert messages[0].header == Header(srcId: TASK_APM, destId: source, paramLen: 3)
    doAssert messages[0].body[0 .. 2] == @[0'u8, 0, 0]
    doAssert messages[0].body[3] == 0xD5
for invalid in 0 ..< 8:
  reset()
  case invalid
  of 0: request[0] = 2
  of 1: request[1] = 7
  of 2: request[0] = 0
  of 3: vifs[1].vifType = 0
  of 4: stations[3].valid = 0
  of 5: requestHeader.paramLen = 1
  of 6: failAt = 2
  else: failAt = 3
  doAssert apm_sta_del_req_handler(addr request[0]) == 0
  doAssert sent == @[0] and messages[0].body[0] == 255
  doAssert aidDeletes == 0 and keyDeletes == 0
reset()
failAt = 1
doAssert apm_sta_del_req_handler(addr request[0]) == 0
doAssert sent.len == 0 and frames.len == 0
doAssert apm_sta_del_req_handler(nil) == 0

for time in [80000'u32, 20]:
  for index in 0 ..< 5:
    for elapsed in [30000'u32, 30001, 0x7FFFFFFF, 0x80000000'u32, 0xFFFFFFFF'u32]:
      reset(index)
      now = time
      for sta in stations.mitems: sta.connectionStart = 0
      stations[index].connectionStart = now - elapsed
      apm_sta_connect_timeout_ind_handler(nil)
      if elapsed > 30000 and elapsed < 0x80000000'u32:
        checkDeletion(4, 65535)
      else:
        doAssert allocations == 0
      doAssert timers == @[(0x1406'u16, TASK_APM, 5000000'u32)]
reset()
clockEnabled = false
apm_sta_connect_timeout_ind_handler(nil)
doAssert allocations == 0 and timers.len == 1

proc retireDuringDelete() =
  inc staDeleteEpochs[3]
  stations[3].apmWpaContext = cast[pointer](0x76543210)
  stations[3].macAddr[1] = 99
for site in ["allocate1", "allocate2", "aid", "key", "log", "host"]:
  reset()
  apm.hostapdCtx = cast[pointer](1)
  callbackSite = site
  callbackHook = retireDuringDelete
  let accepted = apm_sta_delete(3, addr stations[3].macAddr[0], 4, 65535)
  doAssert stations[3].apmWpaContext == cast[pointer](0x76543210)
  if site == "host":
    doAssert accepted and sent == @[1, 0]
    doAssert messages[0].body[0] == 255
  else:
    doAssert not accepted and sent.len == 0 and freeCount == 2

for path in ["remove", "disassoc", "deauth", "api"]:
  reset()
  let oldMac = stations[3].macAddr
  callbackSite = if path == "api": "allocate1" elif path == "deauth": "log" else: "mlme"
  callbackHook = retireDuringDelete
  case path
  of "remove": doAssert not apm_sta_remove(1, 3, 4, 1)
  of "disassoc": apm_disassoc_handler(addr rx)
  of "deauth": apm_deauth_handler(addr rx)
  else:
    apm_sta_del_req_handler(addr request[0])
    doAssert sent == @[0] and messages[0].body[0] == 255
  doAssert aidDeletes == 0 and keyDeletes == 0
  doAssert stations[3].apmWpaContext == cast[pointer](0x76543210)
  if path in ["remove", "disassoc"]:
    doAssert frames.len == 1 and frames[0].mac == oldMac
  else:
    doAssert frames.len == 0
"""


def program_source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    declarations = "type\n"
    for name in ["MeStaDelReqPayload", "ApmStaDelIndPayload", "ApmStaDelCfmPayload", "ApmStaDelReqPayload"]:
        declarations += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    declarations += "const\n"
    for name in ["MeStaDelReqPayload", "ApmStaDelIndPayload", "ApmStaDelCfmPayload"]:
        declarations += f"  {name}Size = sizeof({name}).uint32\n"
    handlers = (FW / "task_handlers.nim").read_text()
    scan = (FW / "scan_station_ap_me.nim").read_text()
    sta = (FW / "sta_management.nim").read_text()
    bodies = procedure(sta, "staDeleteEpoch") + procedure(sta, "staDeleteIsCurrent")
    bodies += procedure((FW / "rx_layer.nim").read_text(), "rxInvalidateQuiescentVif")
    bodies += procedure((FW / "rx_layer.nim").read_text(), "rxInvalidateVif")
    bodies += procedure(handlers, "apmVifRunning")
    bodies += procedure(scan, "apmSessionCurrent")
    bodies += procedure(handlers, "apm_sta_delete")
    for name in ["apm_sta_remove", "apm_sta_fw_delete", "apmRxFrameFits", "apm_auth_handler",
                 "apm_deauth_handler", "apm_disassoc_handler"]:
        bodies += procedure(scan, name)
    bodies += procedure(handlers, "apm_sta_del_req_handler")
    bodies += procedure(handlers, "apm_sta_connect_timeout_ind_handler")
    bodies += procedure((FW / "platform_bl.nim").read_text(), "bl_wifi_ap_deauth_internal")
    assert "asm volatile" not in bodies
    return declarations + PLATFORM + bodies


@pytest.mark.parametrize("build", ["checked", "release", "asan"])
def test_ap_teardown_abi_and_ownership(tmp_path: Path, build: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    program = tmp_path / "ap_teardown.nim"
    program.write_text(program_source() + CHECKS)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
               f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}"]
    if build == "release":
        command += ["-d:release", "--assertions:on"]
    elif build == "asan":
        command += ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]
    result = subprocess.run(command + [str(program)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
