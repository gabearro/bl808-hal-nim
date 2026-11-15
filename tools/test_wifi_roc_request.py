"""Check ROC storage, helper ABI, and confirmation against the vendor object."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


def source(handler: bool = False) -> str:
    layout = (FW / "layout_types.nim").read_text()
    code = ""
    for name in ["ChanCtxtDefView", "ChanRocOverlay", "ChanConnLessDelayReqPayload",
                 "MmRemainOnChannelReqPayload", "MmRemainOnChannelCfmPayload"]:
        code += "type\n  " + name + layout.split("  " + name, 1)[1].split("\n\n", 1)[0] + "\n"
    code += r'''
const
  MM_REMAIN_ON_CHANNEL_CFM = 53'u16
  MmRemainOnChannelReqPayloadSize = sizeof(MmRemainOnChannelReqPayload).uint32
  MmRemainOnChannelCfmPayloadSize = sizeof(MmRemainOnChannelCfmPayload).uint32
  KeMsgConsumed = 0
type
  Storage = object
    before: array[16, uint8]
    bytes: array[140, uint8]
    after: array[16, uint8]
  EnvironmentStorage = object
    before: array[16, uint8]
    bytes: array[132, uint8]
    after: array[64, uint8]
  Env = object
    flags: uint8
    scheduledCtxt: pointer
  Header = object
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  Message = object
    header: Header
    bytes: array[20, uint8]
var
  pool: Storage
  environment: EnvironmentStorage
  env: Env
  request: Message
  delayCalls: int
  switches: seq[pointer]
  allocations: seq[tuple[id: uint16, dest, src: uint8, size: uint32]]
  replies: seq[array[3, uint8]]
  reply: array[3, uint8]
  failAllocation: bool
  onDelay, onAllocate, onSend: proc()
  interrupts = true
  chanCtxtEpochs: array[5, uint32]
template chan_ctxt_pool: untyped = pool.bytes
template chan_env: untyped = environment.bytes
proc chanEnvView(): ptr Env = addr env
proc chanCtxtForIdx(index: uint8): pointer = addr pool.bytes[index.int * 28]
proc c_memcpy(dst, src: pointer; count: csize_t): pointer =
  copyMem(dst, src, count.int)
  dst
proc invoke(hook: var proc()) =
  if hook != nil:
    let action = hook
    hook = nil
    action()
proc irqSave(): uint32 =
  result = interrupts.uint32 * 8
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = (saved and 8) != 0
proc chanBcnRequestAdmit(p: pointer): bool = true
proc chanBcnRequestClaim(p: pointer; taskId: uint8): bool = true
proc chanBcnRequestFinish(p: pointer; status: uint8) = discard
proc chan_conn_less_delay_prog() =
  inc delayCalls
  invoke(onDelay)
proc chan_switch_start(target: pointer) = switches.add(target)
proc keMsgHdrFromPayload(p: pointer): ptr Header =
  cast[ptr Header](cast[uint](p) - sizeof(Header).uint)
proc ke_msg_alloc(id: uint16; dest, src: uint8; size: uint32): pointer =
  allocations.add((id, dest, src, size))
  invoke(onAllocate)
  if failAllocation: return nil
  reply = default(typeof(reply))
  addr reply[0]
proc ke_msg_send(p: pointer) =
  doAssert p == addr reply[0]
  replies.add(reply)
  invoke(onSend)
proc reset(op = 0'u8; vif = 1'u8; duration = 10'u32) =
  pool.before = [0xA5'u8, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5,
                 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5, 0xA5]
  pool.after = pool.before
  for index in 0..<pool.bytes.len: pool.bytes[index] = (index xor 0x5A).uint8
  pool.bytes[135] = 255
  for byte in environment.before.mitems: byte = 0xA5
  for byte in environment.bytes.mitems: byte = 0xA5
  for byte in environment.after.mitems: byte = 0xA5
  # Let the legacy wrong-base implementation reach its write path.
  environment.after[3] = 255
  env = Env(flags: 0x80)
  request = default(Message)
  request.header = Header(id: 52, destId: 0, srcId: 9, paramLen: 20)
  request.bytes[0] = op
  request.bytes[1] = vif
  for index in 0..<4: request.bytes[4 + index] = (duration shr (8 * index)).uint8
  for index in 0..<10: request.bytes[8 + index] = (0x30 + index).uint8
  delayCalls = 0
  switches.setLen(0)
  allocations.setLen(0)
  replies.setLen(0)
  failAllocation = false
  onDelay = nil
  onAllocate = nil
  onSend = nil
proc payload(): pointer = addr request.bytes[0]
'''
    for name in ["chanRocOverlay", "mmRemainOnChannelReqView"]:
        code += "template " + name + layout.split("template " + name, 1)[1].split("\n\n", 1)[0] + "\n"
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    body = procedure(kernel, "chan_roc_req")
    code += body
    if "taskId: uint8" in body.split("=", 1)[0]:
        code += "proc callRoc(p: pointer; task: uint8): uint8 = chan_roc_req(p, task)\n"
    else:
        code += "proc callRoc(p: pointer; task: uint8): uint8 =\n  chan_roc_req(p)\n  0\n"
    if handler:
        code += procedure((FW / "task_handlers.nim").read_text(), "mm_remain_on_channel_req_handler")
    return code


CASES = {
    "storage": r'''
for task in [0'u8, 1, 3, 9, 255]:
  for scheduled in [false, true]:
    for vif in [0'u8, 1, 255]:
      for duration in [0'u32, 1, 10, 67108, 0xFFFFFFFF'u32]:
        reset(vif = vif, duration = duration)
        if scheduled: env.scheduledCtxt = cast[pointer](1)
        let originalRequest = request
        let originalEnvironment = environment
        let originalBefore = pool.before
        let originalAfter = pool.after
        var expected = pool.bytes
        for index in 0..<10: expected[116 + index] = request.bytes[8 + index]
        expected[126] = task
        let ticks = ((duration * 1000'u32) shr 10).uint16
        expected[130] = ticks.uint8
        expected[131] = (ticks shr 8).uint8
        expected[134] = 1
        expected[135] = 4
        expected[137] = vif
        doAssert callRoc(payload(), task) == 0
        doAssert pool.bytes == expected, "ROC must populate context slot 4"
        doAssert pool.before == originalBefore and pool.after == originalAfter
        doAssert environment == originalEnvironment, "ROC must not write beyond chan_env"
        doAssert request == originalRequest, "ROC request is const"
        doAssert env.flags == (if task == 0: 0x94'u8 else: 0x81'u8)
        doAssert delayCalls == (task != 0).int
        doAssert switches.len == (task == 0 and not scheduled).int
        if switches.len != 0: doAssert switches[0] == chanCtxtForIdx(4)
''',
    "operations": r'''
for op in 1'u8..255:
  reset(op = op)
  let originalRequest = request
  let originalPool = pool
  let originalEnvironment = environment
  doAssert callRoc(payload(), 9) == (if op == 1: 0'u8 else: 1'u8)
  doAssert request == originalRequest, "op_code must not be decremented in place"
  doAssert pool == originalPool and environment == originalEnvironment
  doAssert env.flags == 0x80 and delayCalls == 0 and switches.len == 0
''',
    "busy": r'''
for marker in [0'u8, 1, 4, 254]:
  for task in [0'u8, 1, 9, 255]:
    reset()
    pool.bytes[135] = marker
    let originalPool = pool
    let originalRequest = request
    let originalEnvironment = environment
    doAssert callRoc(payload(), task) == 1
    doAssert pool == originalPool and request == originalRequest
    doAssert environment == originalEnvironment
    doAssert env.flags == 0x80 and delayCalls == 0 and switches.len == 0
''',
    "layout": r'''
reset()
doAssert sizeof(ChanRocOverlay) == 22
doAssert cast[uint](chanRocOverlay()) - cast[uint](addr pool.bytes[0]) == 116
doAssert offsetof(ChanRocOverlay, channel) == 0
doAssert offsetof(ChanRocOverlay, vifIdx) == 10
doAssert offsetof(ChanRocOverlay, durationTicks) == 14
doAssert offsetof(ChanRocOverlay, stateLo) == 18
doAssert offsetof(ChanRocOverlay, slot) == 19
doAssert offsetof(ChanRocOverlay, requestVifIdx) == 21
doAssert MmRemainOnChannelReqPayloadSize == 20
doAssert MmRemainOnChannelCfmPayloadSize == 3
''',
    "abi": r'''
type RocRequest = proc(p: pointer; taskId: uint8): uint8 {.cdecl.}
let callback: RocRequest = chan_roc_req
reset(op = 2)
doAssert callback(payload(), 9) == 1
''',
    "nil_request": r'''
reset()
let beforePool = pool
let beforeEnvironment = environment
doAssert callRoc(nil, 9) == 1
doAssert pool == beforePool and environment == beforeEnvironment
doAssert delayCalls == 0 and switches.len == 0
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_roc_request(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


HANDLER_CASES = {
    "confirmation": r'''
for op in [0'u8, 1, 2, 255]:
  for busy in [false, true]:
    for origin in [0'u8, 3, 9, 255]:
      for destination in [0'u8, 4]:
        reset(op = op)
        request.header.srcId = origin
        request.header.destId = destination
        if busy: pool.bytes[135] = 4
        let before = request
        doAssert mm_remain_on_channel_req_handler(payload()) == KeMsgConsumed
        doAssert request == before
        if origin == 0:
          doAssert allocations.len == 0 and replies.len == 0
        else:
          let status = if op > 1 or (op == 0 and busy): 1'u8 else: 0'u8
          doAssert allocations == @[(53'u16, origin, destination, 3'u32)]
          doAssert replies == @[[op, status, 4'u8]]
''',
    "snapshot": r'''
for phase in 0..1:
  reset(op = 0)
  proc replaceRequest() =
    request.header = Header(id: 255, srcId: 3, destId: 4, paramLen: 0)
    request.bytes = default(typeof(request.bytes))
    request.bytes[0] = 2
    request.bytes[1] = 255
  if phase == 0: onDelay = replaceRequest
  else: onAllocate = replaceRequest
  doAssert mm_remain_on_channel_req_handler(payload()) == KeMsgConsumed
  doAssert allocations == @[(53'u16, 9'u8, 0'u8, 3'u32)]
  doAssert replies == @[[0'u8, 0, 4]]
''',
    "allocation_failure": r'''
reset()
failAllocation = true
doAssert mm_remain_on_channel_req_handler(payload()) == KeMsgConsumed
doAssert allocations.len == 1 and replies.len == 0
doAssert pool.bytes[135] == 4
''',
    "short_payload": r'''
for length in 0'u32..<20:
  reset()
  request.header.paramLen = length
  let beforePool = pool
  let beforeEnvironment = environment
  doAssert mm_remain_on_channel_req_handler(payload()) == KeMsgConsumed
  doAssert pool == beforePool and environment == beforeEnvironment
  doAssert allocations.len == 0 and replies.len == 0
doAssert mm_remain_on_channel_req_handler(nil) == KeMsgConsumed
''',
}


@pytest.mark.parametrize("case", HANDLER_CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_roc_confirmation(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source(handler=True) + HANDLER_CASES[case])


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_beacon_roc_request_round_trip(tmp_path: Path, mode: str) -> None:
    code = source(handler=True).replace("    flags: uint8\n", "    flags, ctxtCount: uint8\n", 1)
    code = code.replace(procedure(code, "chanCtxtForIdx"),
                        "proc chanCtxtForIdx(index: uint8): pointer\n", 1)
    code = code.replace(procedure(code, "ke_msg_alloc"), r'''
proc ke_msg_alloc(id: uint16; dest, src: uint8; size: uint32): pointer =
  doAssert id == 52 and dest == 0 and src == 0 and size == 20
  allocations.add((id, dest, src, size))
  if failAllocation: return nil
  request.header = Header(id: id, destId: dest, srcId: src, paramLen: size)
  addr request.bytes[0]
''', 1)
    code = code.replace(procedure(code, "ke_msg_send"), r'''
proc ke_msg_send(p: pointer) =
  doAssert p == addr request.bytes[0]
  doAssert mm_remain_on_channel_req_handler(p) == KeMsgConsumed
''', 1)
    code = "proc mm_remain_on_channel_req_handler*(param: pointer): cint {.exportc, cdecl, discardable.}\n" + code
    code += layouts("MmVifIdentity", "ChanCtxtLease")
    code += r'''
const
  ChanConnLessDelayReqPayloadSize = sizeof(ChanConnLessDelayReqPayload).uint32
  MAX_CHAN_CTXT = 3
  STA_INFO_TAB_ENTRIES = 2
type
  Vif = object
    chanCtxt: pointer
    vifIdx, staIdx: uint8
  Context = object
    channel: ChanCtxtDefView
  Sta = object
    initialRateConfig: uint32
    valid, instNbr: uint8
var context: Context
var stations: array[2, Sta]
var chanCtxtLinkEpochs: array[2, uint32]
var txResetEpoch: uint32
var chanBcnDetectActive: bool
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc chanCtxtAt(p: pointer): ptr Context = cast[ptr Context](p)
proc staInfoForIdx(index: uint8): ptr Sta = addr stations[index]
proc assert_err(condition, file: cstring; line: cint) = doAssert false
proc chanCtxtForIdx(index: uint8): pointer =
  if index == 0: cast[pointer](addr context)
  else: cast[pointer](addr pool.bytes[index.int * 28])
proc mmCaptureVif(p: pointer): MmVifIdentity =
  let vif = vifChannelAt(p)
  MmVifIdentity(vif: p, index: vif.vifIdx, station: vif.staIdx, captured: true)
proc mmStaTimerCurrent(identity: MmVifIdentity; resetEpoch: uint32): bool = identity.captured
proc chanLeaseCurrent(lease: ChanCtxtLease): bool = lease.held
proc ke_msg_free_payload(p: pointer) = doAssert false, "unexpected stale request"
proc chanBcnRequestAllocate(identity: MmVifIdentity; lease: ChanCtxtLease;
                          channel: ChanCtxtDefView; interval, resetEpoch: uint32): pointer =
  ke_msg_alloc(52, 0, 0, 20)
proc chanBcnRequestPrune() = discard
proc chanBcnRequestPublish(p: pointer): bool =
  env.flags = env.flags or 0x40
  true
'''
    code += procedure((FW / "kernel_mac_channel.nim").read_text(), "chan_bcn_detect_start")
    code += r'''
for index in 0'u8..1:
  for scheduled in [false, true]:
    for allocationFails in [false, true]:
      reset()
      env.ctxtCount = 2
      if scheduled: env.scheduledCtxt = cast[pointer](1)
      failAllocation = allocationFails
      context.channel = ChanCtxtDefView(band: 1, chanType: 2, primFreq: 5200,
        centerFreq1: 5210, centerFreq2: 0, txPower: 17, phyEnvFlags: 3)
      var vif = Vif(chanCtxt: addr context, vifIdx: index, staIdx: index xor 1)
      stations[vif.staIdx] = Sta(initialRateConfig: 100000, valid: 1, instNbr: index)
      let before = pool
      chan_bcn_detect_start(addr vif)
      doAssert allocations == @[(52'u16, 0'u8, 0'u8, 20'u32)]
      doAssert replies.len == 0 and delayCalls == 0
      if allocationFails:
        doAssert pool == before and env.flags == 0x80 and switches.len == 0
      else:
        doAssert request.bytes[0] == 0 and request.bytes[1] == index
        doAssert chanRocOverlay().channel == context.channel
        doAssert chanRocOverlay().requestVifIdx == index and chanRocOverlay().vifIdx == 0
        doAssert chanRocOverlay().slot == 4 and chanRocOverlay().durationTicks == 92
        doAssert env.flags == 0xD4
        doAssert switches.len == (not scheduled).int
        if not scheduled: doAssert switches[0] == chanCtxtForIdx(4)
'''
    run_program(tmp_path, mode, code)
