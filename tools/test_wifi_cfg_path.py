"""Exercise the real CFG encoder, TLV helpers, registry and firmware handler."""
from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program

DEBUG = FW / "mac_config_debug.nim"
HANDLERS = FW / "task_handlers.nim"
SENDER = FW.parent / "msg_tx/cfg_task.nim"
TLV = FW.parent / "support/utils_facade_parts/bin_tlv_crc.nim"


def layouts(*names: str) -> str:
    text = (FW / "layout_types.nim").read_text()
    return "type\n" + "".join(re.search(r"(?ms)^  " + name + r"\b.*?(?=^  \w|\Z)", text)[0] for name in names)


PLATFORM = r'''
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  KeMsgHdr = object
    next: pointer
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  Message = object
    header: KeMsgHdr
    body: array[36, uint8]
  BlHw = object
    unused: uint32
const
  CFG_START_REQ = 0x2000'u16
  CFG_START_CFM = 0x2001'u16
  TASK_CFG = 8'u8
  DRV_TASK_ID = 100'u8
  SizeCfgStartReq = 36'u16
  StatusCfmPayloadSize = 1'u32
  Enomem = 12
  CfgOpsOff = 0'u
  CfgSetTaskOff = 4'u
  CfgSetElementOff = 8'u
  CfgSetTypeOff = 12'u
  CfgSetLengthOff = 16'u
  CfgSetBufOff = 20'u
var
  mm: MmEnvView
  scan_env: ScanEnvObj
  sm: SmEnvView
  ps: BlPsParamsView
  sm_reconn_dominant_flag: uint32
  cfgElements: array[32, uint32] # Frozen implementation's unrelated scratch store.
  cfgElementCount: uint32
  cfgApiEntries: array[13, CfgApiElementEntryView]
  messages: seq[string]
  putsMessages: seq[string]
  slots: seq[int]
  printEnabled, putsEnabled: bool
  printAction: proc()
  callbackEntry, callbackValue, callbackExtra: pointer
  callbackCount: int
  request: Message
  hw: BlHw
  confirmation: array[8, uint8]
  allocated, sent, confirmed, packed: int
  allocationFails, confirmationFails, dispatch: bool
  sendResult, packResult: cint
proc mmEnvView(): ptr MmEnvView = addr mm
proc smEnvView(): ptr SmEnvView = addr sm
proc blPsParamsView(): ptr BlPsParamsView = addr ps
proc cfgApiElementEntryAt(p: pointer): ptr CfgApiElementEntryView = cast[ptr CfgApiElementEntryView](p)
proc c_memset(p: pointer; v: cint; n: csize_t): pointer =
  doAssert v == 0
  zeroMem(p, n.int)
  p
proc element_notify() {.cdecl.} = discard
proc element_notify_status_enabled(): uint32 {.cdecl.} = 0
{.pragma: wifiCtrl.}
{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc printer(format: cstring) {.cdecl, varargs.} =
  var output: array[192, char]
  var count: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", count,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert count >= 0 and count < output.len.cint
  messages.add($cast[cstring](addr output[0]))
  if printAction != nil:
    let action = printAction
    printAction = nil
    action()
proc putter(text: cstring) {.cdecl.} = putsMessages.add($text)
proc blOpsFunc(slot: int): pointer =
  slots.add(slot)
  case slot
  of 4: (if printEnabled: cast[pointer](printer) else: nil)
  of 8: (if putsEnabled: cast[pointer](putter) else: nil)
  else: raiseAssert "incorrect CFG platform operation"
proc c_snprintf(output: pointer; capacity: csize_t; format: cstring): cint
  {.importc: "snprintf", header: "<stdio.h>", varargs.}
proc ptrAt(p: pointer; offset: uint): pointer = cast[pointer](cast[uint](p) + offset)
proc storeU32(p: pointer; offset: uint; value: uint32) =
  cast[ptr uint32](ptrAt(p, offset))[] = value
proc word(offset: uint): uint32 = cast[ptr uint32](ptrAt(addr request.body[0], offset))[]
proc keMsgHdrFromPayload(p: pointer): ptr KeMsgHdr =
  doAssert p == cast[pointer](addr request.body[0])
  addr request.header
proc ke_msg_alloc(id: uint16; dest, source: uint8; size: uint32): pointer =
  doAssert id == CFG_START_CFM and dest == DRV_TASK_ID and source == TASK_CFG and size == 1
  inc confirmed
  if confirmationFails: return nil
  addr confirmation[0]
proc ke_msg_send(p: pointer) =
  doAssert p == cast[pointer](addr confirmation[0]) and confirmation[0] == 0
  for i in 1 ..< confirmation.len: doAssert confirmation[i] == 0xA5
proc blMsgZalloc(id: uint16; dest, source: uint8; size: uint16): pointer =
  doAssert id == CFG_START_REQ and dest == TASK_CFG and source == DRV_TASK_ID and size == 36
  inc allocated
  if allocationFails: return nil
  request.header = KeMsgHdr(id: id, destId: dest, srcId: source, paramLen: size.uint32)
  request.body = default(typeof(request.body))
  addr request.body[0]
proc customSet(entry, value, extra: pointer): cint {.cdecl.} =
  inc callbackCount
  callbackEntry = entry
  callbackValue = value
  callbackExtra = extra
  -17
'''


SETUP = r'''
let initialEntries = cfgApiEntries
proc setup() =
  cfgApiEntries = initialEntries
  mm = default(typeof(mm))
  scan_env = default(typeof(scan_env))
  sm = default(typeof(sm))
  ps = default(typeof(ps))
  sm_reconn_dominant_flag = 0
  cfgElements = default(typeof(cfgElements))
  cfgElementCount = 0
  messages.setLen(0)
  putsMessages.setLen(0)
  slots.setLen(0)
  printEnabled = true
  putsEnabled = true
  printAction = nil
  callbackEntry = nil
  callbackValue = nil
  callbackExtra = nil
  callbackCount = 0
  request = default(typeof(request))
  request.header = KeMsgHdr(id: CFG_START_REQ, srcId: DRV_TASK_ID, destId: TASK_CFG, paramLen: 36)
  for b in confirmation.mitems: b = 0xA5
  allocated = 0
  sent = 0
  confirmed = 0
  packed = 0
  allocationFails = false
  confirmationFails = false
  dispatch = false
  sendResult = -19
  packResult = 4
proc pointerText(p: pointer): string =
  var output: array[64, char]
  discard c_snprintf(addr output[0], output.len.csize_t, "%p", p)
  $cast[cstring](addr output[0])
'''


def source(include_messages: bool = True, unsigned_pack_abi: bool = False) -> str:
    code = layouts("MmEnvView", "SmEnvView", "BlPsParamsView", "ScanEnvObj",
                   "CfgApiElementEntryView", "CfgStartReqPayload", "StatusCfmPayload")
    # SmEnvView uses CoList, so the small common declarations precede the layouts.
    code = PLATFORM[:PLATFORM.index("const\n")] + code + PLATFORM[PLATFORM.index("const\n"):]
    tlv = TLV.read_text()
    for name in ["utils_tlv_bl_unpack_auto", "utils_tlv_bl_pack_auto"]:
        body = procedure(tlv, name)
        if name == "utils_tlv_bl_pack_auto" and unsigned_pack_abi:
            body = body.replace("utils_tlv_bl_pack_auto*", "cfgTlvPack*")
        code += body
    if unsigned_pack_abi:
        # The frozen host module imported this C int result as uint32.
        code += "\nproc utils_tlv_bl_pack_auto(buf: ptr uint32; n: cint; typ: uint16; input: pointer): uint32 =\n  cast[uint32](cfgTlvPack(buf, n, typ, input))\n"
    text = DEBUG.read_text()
    for name in ["cfg_api_element_dump", "cfg_api_element_general_get", "cfg_api_element_general_set"]:
        code += procedure(text, name).replace("include mac_config_entries\n", "")
    code += (FW / "mac_config_entries.nim").read_text()
    for name in ["cfg_api_element_set", "dump_cfg_entries"]:
        code += procedure(text, name)
    code += "\nproc c_utils_tlv_bl_unpack_auto(buf: ptr uint32; n: cint; typ: uint16; output: pointer): cint =\n  utils_tlv_bl_unpack_auto(buf, n, typ, output)\n"
    if include_messages:
        code += procedure(HANDLERS.read_text(), "cfg_start_req_handler")
        code += r'''
proc blSendMsg(p: ptr BlHw; body: pointer; wait: cint; cfm: uint16; output: pointer): cint =
  doAssert p == (addr hw) and body == cast[pointer](addr request.body[0])
  doAssert wait == 1 and cfm == CFG_START_CFM and output == nil
  inc sent
  if dispatch: discard cfg_start_req_handler(body)
  sendResult
'''
        code += SENDER.read_text()
    code += SETUP
    return code


CASES = {
    "registry_and_live_storage": r'''
setup()
let targets = [cast[pointer](addr mm.flagsHigh), addr mm.keepAliveTimestamp, addr mm.keepAliveCounter,
  addr mm.rxPromiscUploadFlag, addr mm.apPromiscUploadFlag, addr mm.keepAliveInterval,
  addr mm.tbttPreDuration, addr ps.txNullTimeout, addr scan_env.passiveDuration,
  addr scan_env.activeDuration, addr scan_env.joinActiveDuration, addr sm.authRetryLimit,
  addr sm_reconn_dominant_flag]
const labels = ["Keep Alive On/Off Status", "Keep Alive Frame last received", "Keep Alive Frame Counter",
  "Accept All Beacon for VIF_STA", "Accept All Beacon for VIF_AP", "Beacon Timeout", "PSM TBTT Pre-time",
  "PS NULL TX TIMEOUT", "duration for passive scan", "duration for active scan", "duration for active join scan",
  "Auth/Assoc Retry Limit", "Reconnect Dominant Trigger Flag"]
for index in 0 ..< cfgApiEntries.len:
  let row = cfgApiEntries[index]
  let task = (if index < 8: 0'u32 elif index < 11: 1'u32 else: 4'u32)
  let element = (if index < 8: index elif index < 11: index - 8 else: index - 11).uint16
  let typ = (if index == 0: 1 else: 7).uint16
  doAssert row.id == task and row.subId == element and row.typeId == typ
  doAssert row.valueStorage == targets[index]
  doAssert $cast[cstring](row.name) == labels[index]
  doAssert row.setHandler == cast[pointer](cfg_api_element_general_set)
  doAssert row.getHandler == cast[pointer](cfg_api_element_general_get)
  doAssert row.notifyHandler == (if index < 8: cast[pointer](element_notify) else: cast[pointer](element_notify_status_enabled))
  var value = 0xA1B2C300'u32 + index.uint32
  cfg_api_element_set(task, element, typ, addr value, nil)
  if index == 0: doAssert mm.flagsHigh == value.uint8
  else: doAssert cast[ptr uint32](targets[index])[] == value
doAssert cfgElements == default(typeof(cfgElements)) and cfgElementCount == 0
''',
    "matching_and_opaque_callback_arguments": r'''
setup()
var data, extra: uint32
cfgApiEntries[0].id = 19
cfgApiEntries[0].subId = 0xABCD
cfgApiEntries[0].typeId = 7
cfgApiEntries[0].setHandler = cast[pointer](customSet)
cfg_api_element_set(19, 0xABCD'u16, 7'u16, addr data, addr extra)
doAssert callbackCount == 1 and callbackEntry == addr cfgApiEntries[0]
doAssert callbackValue == (addr data) and callbackExtra == (addr extra)
cfg_api_element_set(19, 0xABCD'u16, 7'u16, nil, addr extra)
doAssert callbackCount == 2 and callbackValue == nil and callbackExtra == addr extra
for task in [18'u32, 20, high(uint32)]: cfg_api_element_set(task, 0xABCD'u16, 7'u16, addr data, nil)
cfg_api_element_set(19, 0xABCC'u16, 7'u16, addr data, nil)
doAssert callbackCount == 2
cfgApiEntries[1] = cfgApiEntries[0]
cfgApiEntries[0].typeId = 1
cfg_api_element_set(19, 0xABCD'u16, 7'u16, addr data, nil)
doAssert callbackCount == 3 and callbackEntry == addr cfgApiEntries[1]
doAssert messages == @["type 7 NOT matched on element: 19 43981 1\r\n"]
''',
    "general_set_reloads_after_printer": r'''
setup()
var value = 0xAABBCCDD'u32
var redirected = 0'u32
proc redirect() = cfgApiEntries[8].valueStorage = addr redirected
printAction = redirect
cfg_api_element_set(1, 0'u16, 7'u16, addr value, nil)
doAssert scan_env.passiveDuration == 0 and redirected == value
doAssert messages == @["  updating element: duration for passive scan\r\n"]
''',
    "registered_dump_fields_and_order": r'''
setup()
scan_env.passiveDuration = 1234
scan_env.activeDuration = 5678
sm.authRetryLimit = 0xFFFFFFFF'u32
dump_cfg_entries()
doAssert messages.len == 13 * 7 and putsMessages.len == 15
doAssert putsMessages[0] == "================= CFG TASK =================\r\n"
doAssert putsMessages[^1] == "---------------------------------------------\r\n"
for index, row in cfgApiEntries:
  let start = index * 7
  doAssert messages[start] == "entry " & pointerText(addr cfgApiEntries[index]) & "\r\n"
  doAssert messages[start + 1] == "    task    : " & $row.id & "\r\n"
  doAssert messages[start + 2] == "    element : " & $row.subId & "\r\n"
  doAssert messages[start + 3] == "    type    : " & $row.typeId & "\r\n"
  doAssert messages[start + 4] == "    name    : " & $cast[cstring](row.name) & "\r\n"
  doAssert messages[start + 5] == "    type    : " & (if index == 0: "Boolean" else: "UINT32") & "\r\n"
  doAssert putsMessages[index + 1] == "------------------------\r\n"
doAssert messages[8 * 7 + 6] == "    val     : 1234\r\n"
doAssert messages[9 * 7 + 6] == "    val     : 5678\r\n"
doAssert messages[11 * 7 + 6] == "    val     : 4294967295\r\n"
''',
    "set_request_roundtrip": r'''
for (task, element) in [(0'u32, 5'u32), (1'u32, 0'u32), (1'u32, 1'u32), (4'u32, 0'u32)]:
  setup()
  dispatch = true
  sendResult = 0
  var value = 0xF1234567'u32
  doAssert bl_send_cfg_task_req(addr hw, 0, task, element, 7, addr value, nil) == 0
  doAssert allocated == 1 and sent == 1 and confirmed == 1
  doAssert word(0) == 0 and word(4) == task and word(8) == element and word(12) == 7
  doAssert word(16) == 4 and word(20) == value
  let actual = if task == 0: mm.keepAliveInterval
    elif task == 4: sm.authRetryLimit
    elif element == 0: scan_env.passiveDuration else: scan_env.activeDuration
  doAssert actual == value and cfgElements == default(typeof(cfgElements))
  doAssert messages[0] == "unpack ret is 4, result is 4045620583\r\n"
for enabled in [false, true]:
  setup()
  dispatch = true
  var value = enabled
  discard bl_send_cfg_task_req(addr hw, 0, 0, 0, 1, addr value, nil)
  doAssert word(16) == 4 and word(20) == enabled.uint32
  doAssert mm.flagsHigh == enabled.uint8 and confirmed == 1
''',
    "operation_dispatch_and_confirmation_failure": r'''
for operation in [1'u32, 2, 3, 4, high(uint32)]:
  setup()
  storeU32(addr request.body[0], 0, operation)
  discard cfg_start_req_handler(addr request.body[0])
  doAssert confirmed == 1
  doAssert messages.len == (if operation < 3: 0 else: 91)
setup()
confirmationFails = true
storeU32(addr request.body[0], 0, 2)
discard cfg_start_req_handler(addr request.body[0])
doAssert confirmed == 1
''',
    "sender_allocation_and_noop_operations": r'''
for operation in [1'u32, 2, 3]:
  setup()
  var value = 0x12345678'u32
  doAssert bl_send_cfg_task_req(addr hw, operation, 9, 17, 7, addr value, nil) == -19
  doAssert allocated == 1 and sent == 1 and word(0) == operation
  if operation == 3:
    doAssert word(4) == 9 and word(8) == 17 and word(16) == 0
  else:
    for offset in [4'u, 8, 12, 16, 20]: doAssert word(offset) == 0
setup()
allocationFails = true
var validValue = 1'u32
doAssert bl_send_cfg_task_req(addr hw, 0, 1, 0, 7, addr validValue, nil) == -12
doAssert sent == 0
for typ in [1'u32, 7'u32, 3'u32]:
  setup()
  let input = if typ == 3: addr validValue else: nil
  doAssert bl_send_cfg_task_req(addr hw, 0, 0, 0, typ, input, nil) == -2
  doAssert allocated == 0 and sent == 0
''',
    "short_tlv_and_payload_guards": r'''
for typ in [1'u32, 7'u32]:
  for length in [0'u32, 1, 3]:
    setup()
    storeU32(addr request.body[0], 12, typ)
    storeU32(addr request.body[0], 16, length)
    if typ == 7:
      storeU32(addr request.body[0], 8, 5)
      mm.keepAliveInterval = 1234
    discard cfg_start_req_handler(addr request.body[0])
    doAssert confirmed == 1
    doAssert messages[0] == "unpack ret is -1, result is " & (if typ == 1: "1" else: "0") & "\r\n"
    doAssert mm.flagsHigh == 0
    doAssert mm.keepAliveInterval == (if typ == 7: 1234'u32 else: 0'u32)
for length in [17'u32, high(uint32)]:
  setup()
  storeU32(addr request.body[0], 16, length)
  discard cfg_start_req_handler(addr request.body[0])
  doAssert confirmed == 1 and messages.len == 0
for (typ, length) in [(1'u32, 8'u32), (7'u32, 8'u32), (3'u32, 4'u32)]:
  setup()
  if typ == 7: storeU32(addr request.body[0], 8, 5)
  if typ == 3:
    cfgApiEntries[0].typeId = 3
    mm.flagsHigh = 1
  storeU32(addr request.body[0], 12, typ)
  storeU32(addr request.body[0], 16, length)
  storeU32(addr request.body[0], 20, 1)
  discard cfg_start_req_handler(addr request.body[0])
  doAssert confirmed == 1
  doAssert mm.flagsHigh == (if typ == 3: 1'u8 else: 0'u8)
  doAssert mm.keepAliveInterval == 0
''',
    "dump_reloads_the_printf_slot": r'''
setup()
proc disablePrinter() = printEnabled = false
printAction = disablePrinter
dump_cfg_entries()
doAssert messages.len == 1 and putsMessages.len == 15
doAssert messages[0] == "entry " & pointerText(addr cfgApiEntries[0]) & "\r\n"
''',
    "snapshot_request_before_diagnostic_callback": r'''
setup()
storeU32(addr request.body[0], 4, 1)
storeU32(addr request.body[0], 8, 0)
storeU32(addr request.body[0], 12, 7)
storeU32(addr request.body[0], 16, 4)
storeU32(addr request.body[0], 20, 123456)
proc mutatePayload() =
  storeU32(addr request.body[0], 4, 4)
  storeU32(addr request.body[0], 8, 0)
printAction = mutatePayload
discard cfg_start_req_handler(addr request.body[0])
doAssert scan_env.passiveDuration == 123456 and sm.authRetryLimit == 0
doAssert confirmed == 1
setup()
storeU32(addr request.body[0], 12, 1)
storeU32(addr request.body[0], 16, 8)
storeU32(addr request.body[0], 20, 1)
proc shrinkLength() = storeU32(addr request.body[0], 16, 4)
printAction = shrinkLength
discard cfg_start_req_handler(addr request.body[0])
doAssert mm.flagsHigh == 0 and confirmed == 1
''',
    "snapshot_reply_routing_before_diagnostic_callback": r'''
setup()
storeU32(addr request.body[0], 12, 1)
storeU32(addr request.body[0], 16, 4)
storeU32(addr request.body[0], 20, 1)
proc mutateRoute() =
  request.header.srcId = 77
  request.header.destId = 99
printAction = mutateRoute
discard cfg_start_req_handler(addr request.body[0])
doAssert confirmed == 1 and mm.flagsHigh == 1
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_cfg_path(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_cfg_full_width_selector_and_handler_abi(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
type SetApi = proc(task, element, typ: uint32; value, extra: pointer): cint {.cdecl.}
type GeneralApi = proc(entry, value, extra: pointer): cint {.cdecl.}
let api: SetApi = cfg_api_element_set
let set: GeneralApi = cfg_api_element_general_set
let get: GeneralApi = cfg_api_element_general_get
setup()
var value = 0xAABBCCDD'u32
doAssert api(1, 0x10000, 7, addr value, nil) == 0
doAssert scan_env.passiveDuration == 0
doAssert api(1, 0, 0x10007, addr value, nil) == 0
doAssert scan_env.passiveDuration == 0
doAssert messages == @["type 65543 NOT matched on element: 1 0 7\r\n"]
doAssert get(nil, nil, nil) == 0 and set(nil, nil, nil) == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_tlv_scalar_values_and_error_contract(tmp_path: Path, mode: str) -> None:
    code = "".join(procedure(TLV.read_text(), name) for name in
                   ["utils_tlv_bl_unpack_auto", "utils_tlv_bl_pack_auto"])
    run_program(tmp_path, mode, code + r'''
for raw in [0'u32, 1, 255, 0x80000000'u32, high(uint32)]:
  for typ in [1'u16, 7'u16]:
    var input = raw
    if typ == 1: input = (raw != 0).uint32
    for capacity in [-1.cint, 0, 1, 3, 4, 8]:
      var wire = [0x11111111'u32, 0x22222222'u32, 0x33333333'u32]
      let packed = utils_tlv_bl_pack_auto(addr wire[1], capacity, typ, addr input)
      doAssert packed == (if capacity < 4: -1 else: 4)
      doAssert wire[0] == 0x11111111'u32 and wire[2] == 0x33333333'u32
      doAssert wire[1] == (if capacity < 4: 0x22222222'u32 else: input)
      var output = [0xAAAA5555'u32, 0xA5A5A5A5'u32, 0x5555AAAA'u32]
      wire[1] = raw
      let unpacked = utils_tlv_bl_unpack_auto(addr wire[1], capacity, typ, addr output[1])
      doAssert unpacked == (if capacity < 4: -1 else: 4)
      let value = if typ == 1:
          0xA5A5A500'u32 or (if capacity < 4: 1'u32 else: (raw != 0).uint32)
        elif capacity < 4: 0'u32 else: raw
      doAssert output == [0xAAAA5555'u32, value, 0x5555AAAA'u32]
for typ in [0'u16, 2, 3, 4, 5, 6, 8, high(uint16)]:
  var input, output = 0xDEADBEEF'u32
  doAssert utils_tlv_bl_pack_auto(addr output, 4, typ, addr input) == -2
  doAssert utils_tlv_bl_unpack_auto(addr input, 4, typ, addr output) == -2
  doAssert output == 0xDEADBEEF'u32
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_configured_scan_duration_selection(tmp_path: Path, mode: str) -> None:
    platform = r'''
type
  Channel = object
    flags, band: uint8
    prim20Freq: uint16
    txPower: int8
  ScanRequest = object
    vifIdx: uint8
    sendProbe: uint32
    ieBodyLen: uint16
    addIeLen: uint32
    channelCount: uint8
    channelList: array[2, Channel]
  ChanScanReqPayload = object
    vifIdx, band: uint8
    duration: uint32
    prim20Freq, center1Freq, center2Freq: uint16
    txPower: int8
  DsParam = object
    id, len: uint8
    currentChannel: uint8
  MacIeView = object
    id, len: uint8
  ScanProbeReqIeObj = object
    endOffset, writeOffset: uint32
    ieData: array[200, uint8]
var
  scanRequest: ScanRequest
  replacementRequest: ScanRequest
  scanRequestEpoch: uint32
  stateSets: int
  channelRequests: int
  selected: ChanScanReqPayload
  chanRequestHook: proc()
  traceHook: proc(text: cstring)
  scan_probe_req_ie: ScanProbeReqIeObj
  foundLength: uint32
  ieResult: pointer
  nimFwDbgScanReqChanMeta, nimFwDbgScanReqChanFreq: uint32
const TASK_SCAN = 1'u8
const ScanChannelPendingState = 2'u8
proc scanStartReqView(p: pointer): ptr ScanRequest = cast[ptr ScanRequest](p)
proc activeScanReq(): ptr ScanRequest = scanStartReqView(scan_env.paramPtr)
template scanProbeReqIeDataPtr(ie: var ScanProbeReqIeObj): pointer =
  cast[pointer](addr ie.ieData[0])
template scanProbeReqIeDataBase(ie: var ScanProbeReqIeObj): uint32 =
  cast[uint32](cast[uint](addr ie.ieData[0]))
proc mac_ie_find(ie: pointer; length, id: uint32): pointer =
  doAssert ie == scanProbeReqIeDataPtr(scan_probe_req_ie) and id == 3
  foundLength = length
  ieResult
proc nimFwTrace2U32(text: cstring; a, b: uint32) =
  if traceHook != nil: traceHook(text)
proc chanScanChannel(p: ptr ChanScanReqPayload): ptr ChanScanReqPayload = p
proc dsParamSetIeAt(p: pointer): ptr DsParam = cast[ptr DsParam](p)
proc packChannelMeta(p: ptr ChanScanReqPayload): uint32 = 0
proc packChannelFreq(p: ptr ChanScanReqPayload): uint32 = 0
proc chan_scan_req(p: ptr ChanScanReqPayload) =
  inc channelRequests
  selected = p[]
  if chanRequestHook != nil: chanRequestHook()
proc ke_state_set(task, state: uint8) =
  doAssert task == TASK_SCAN and state == ScanChannelPendingState
  inc stateSets
'''
    scan_source = (FW / "scan_station_ap_me.nim").read_text()
    body = procedure(scan_source, "scanChannelValid")
    body += procedure(scan_source, "scan_set_channel_request")
    body += procedure(scan_source, "scan_ie_download")
    body += procedure(scan_source, "scan_get_chan")
    body += procedure(scan_source, "scan_get_scan_duration")
    run_program(tmp_path, mode, source() + platform + body + r'''
setup()
scanRequest.channelCount = 2
scanRequest.channelList[0] = Channel(prim20Freq: 2412, txPower: 7)
scan_env.paramPtr = addr scanRequest
doAssert scan_get_scan_duration() == 0x35B60'u32
scanRequest.addIeLen = 12345
doAssert scan_get_scan_duration() == 12345'u32
scanRequest.addIeLen = 0
scan_env.channelIndex = 1
doAssert scan_get_chan() == addr scanRequest.channelList[1]
scan_env.channelIndex = 0
doAssert scan_get_chan() == addr scanRequest.channelList[0]
scan_env.channelIndex = scanRequest.channelCount
doAssert scan_get_chan() == nil
scanRequest.channelCount = 3
doAssert scan_get_chan() == nil
scanRequest.channelCount = 2
scan_env.channelIndex = 0
var passive = 11000'u32
var active = 22000'u32
var join = 33000'u32
cfg_api_element_set(1, 0, 7, addr passive, nil)
cfg_api_element_set(1, 1, 7, addr active, nil)
cfg_api_element_set(1, 2, 7, addr join, nil)
for flags in [0'u8, 1, 2, 3]:
  for probing in [0'u32, 1]:
    for power in [-20'i8, -1'i8, 0'i8, 1'i8, 7'i8, 20'i8]:
      scanRequest.channelList[0].flags = flags
      scanRequest.channelList[0].txPower = power
      scanRequest.sendProbe = probing
      scan_set_channel_request()
      let expected = if probing != 0: join elif (flags and 1) != 0: passive else: active
      doAssert selected.duration == expected and selected.prim20Freq == 2412
      doAssert selected.txPower == power

var oldIe = DsParam(id: 3, len: 1, currentChannel: 91)
var newIe = DsParam(id: 3, len: 1, currentChannel: 92)
scanRequest.channelList[0] = Channel(band: 0, prim20Freq: 2412, txPower: 7)
scan_env.chanInfoPtr = addr oldIe
chanRequestHook = proc() =
  doAssert oldIe.currentChannel == 91 and newIe.currentChannel == 92
  scanRequest.channelList[0].prim20Freq = 2437
  scan_env.chanInfoPtr = addr newIe
scan_set_channel_request()
doAssert selected.prim20Freq == 2412 and selected.txPower == 7
doAssert oldIe.currentChannel == 91 and newIe.currentChannel == 1
chanRequestHook = nil

# Diagnostics must not read or submit a retired scan, nor mix channel fields
# if a callback edits the same request in place.
for tracePoint in ["[WIFI-NIMFW] scan_set start ", "[WIFI-NIMFW] scan_set chan "]:
  scan_env.paramPtr = addr scanRequest
  scan_env.channelIndex = 0
  scanRequest.channelList[0] = Channel(band: 0, prim20Freq: 2412, txPower: 7)
  let beforeRequests = channelRequests
  let beforeStates = stateSets
  traceHook = proc(text: cstring) =
    if $text == tracePoint:
      inc scanRequestEpoch
      scan_env.paramPtr = addr replacementRequest
  scan_set_channel_request()
  doAssert channelRequests == beforeRequests and stateSets == beforeStates
  traceHook = nil

scan_env.paramPtr = addr scanRequest
scanRequest.channelList[0] = Channel(band: 0, prim20Freq: 2412, txPower: 7)
traceHook = proc(text: cstring) =
  if $text == "[WIFI-NIMFW] scan_set start ":
    scanRequest.channelList[0].prim20Freq = 2437
    scanRequest.channelList[0].txPower = 19
scan_set_channel_request()
doAssert selected.prim20Freq == 2412 and selected.txPower == 7
traceHook = nil

scan_env.chanInfoPtr = addr oldIe
scanRequest.channelList[0].band = 1
for frequency in [4995'u16, 5000, 5005, 5006, 5825, 5830]:
  scanRequest.channelList[0].prim20Freq = frequency
  oldIe.currentChannel = 99
  let previousRequests = channelRequests
  let previousStates = stateSets
  scan_set_channel_request()
  let expectedChannel =
    if frequency == 5005: 1'u8
    elif frequency == 5825: 165'u8
    else: 0'u8
  if expectedChannel == 0:
    doAssert channelRequests == previousRequests and stateSets == previousStates
    doAssert oldIe.currentChannel == 99
  else:
    doAssert channelRequests == previousRequests + 1 and stateSets == previousStates + 1
    doAssert selected.prim20Freq == frequency
    doAssert oldIe.currentChannel == expectedChannel

scanRequest.channelList[0] = Channel(band: 0, prim20Freq: 2413, txPower: 7)
let previousRequests = channelRequests
let previousStates = stateSets
scan_set_channel_request()
doAssert channelRequests == previousRequests and stateSets == previousStates
scanRequest.channelList[0].prim20Freq = 2484
scan_set_channel_request()
doAssert channelRequests == previousRequests + 1 and stateSets == previousStates + 1

scanRequest.channelList[0] = Channel(band: 0, prim20Freq: 2412, txPower: 7)
scanRequest.ieBodyLen = 7
scan_env.paramPtr = addr scanRequest
var messageRequest = ScanRequest(ieBodyLen: 12)
ieResult = addr oldIe
scan_probe_req_ie.writeOffset = 77
chanRequestHook = proc() = messageRequest.ieBodyLen = 19
scan_ie_download(addr messageRequest)
doAssert foundLength == 7
doAssert oldIe.currentChannel == 1
doAssert scan_probe_req_ie.writeOffset == 0
doAssert scan_probe_req_ie.endOffset ==
  scanProbeReqIeDataBase(scan_probe_req_ie) - 1 + 12'u32

messageRequest.ieBodyLen = 12
scan_probe_req_ie.writeOffset = 77
scan_probe_req_ie.endOffset = 88
chanRequestHook = proc() = messageRequest.ieBodyLen = 201
scan_ie_download(addr messageRequest)
doAssert scan_probe_req_ie.writeOffset == 0
doAssert scan_probe_req_ie.endOffset ==
  scanProbeReqIeDataBase(scan_probe_req_ie) - 1 + 12'u32
scan_probe_req_ie.writeOffset = 77
scan_ie_download(nil)
doAssert scan_probe_req_ie.writeOffset == 77

# A reentrant channel callback can replace the scan before the archive's
# post-submission IE and state writes. The stale request must stop there.
scan_env.paramPtr = addr scanRequest
scan_env.chanInfoPtr = addr oldIe
oldIe.currentChannel = 91
newIe.currentChannel = 92
let stateSetsBefore = stateSets
chanRequestHook = proc() =
  inc scanRequestEpoch
  scan_env.paramPtr = addr replacementRequest
  scan_env.chanInfoPtr = addr newIe
scan_set_channel_request()
doAssert stateSets == stateSetsBefore
doAssert oldIe.currentChannel == 91 and newIe.currentChannel == 92

scan_env.paramPtr = addr scanRequest
scan_env.chanInfoPtr = addr oldIe
scan_probe_req_ie.writeOffset = 77
scan_probe_req_ie.endOffset = 88
scan_ie_download(addr scanRequest)
doAssert scan_probe_req_ie.writeOffset == 77
doAssert scan_probe_req_ie.endOffset == 88

chanRequestHook = nil
scan_env.paramPtr = nil
scan_set_channel_request()
doAssert stateSets == stateSetsBefore
scan_env.paramPtr = addr scanRequest
scan_env.channelIndex = scanRequest.channelCount
scan_set_channel_request()
doAssert stateSets == stateSetsBefore
''')
