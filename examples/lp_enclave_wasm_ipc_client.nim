## LP client for the enclave WASM IPC service smoke test.

import bl808/startup
import bl808/core, bl808/ipc, bl808/memmap, bl808/mmio
import bl808/enclave/abi

when defined(bl808lp):
  {.pragma: lpRam, codegenDecl: "$# __attribute__((section(\".ramfunc\"), noinline, used)) $#$#".}
else:
  {.pragma: lpRam.}

const
  LpEnclaveWasmIpcStatusAddr* = XramBase + 0x3EC4'u
  LpEnclaveWasmIpcStageAddr* = XramBase + 0x3EC8'u
  LpEnclaveWasmIpcOk* = 0x4549_4C00'u32 # "EIL\0"
  LpEnclaveWasmIpcSendFailed* = 0x4549_4C01'u32
  LpEnclaveWasmIpcReplyTimeout* = 0x4549_4C02'u32
  LpEnclaveWasmIpcBadCaps* = 0x4549_4C04'u32
  LpEnclaveWasmIpcInstallFailed* = 0x4549_4C05'u32
  LpEnclaveWasmIpcInvokeFailed* = 0x4549_4C06'u32
  LpEnclaveWasmIpcUnloadFailed* = 0x4549_4C07'u32
  LpEnclaveWasmIpcUnexpectedTag* = 0x4549_0000'u32
  LpEnclaveWasmIpcControlFailed* = 0x4549_6000'u32
  ManagedSlot = 5'u32
  ReplyWaitLimit = 40_000_000

var AddModule = [
    byte 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7F, 0x7F, 0x01,
    0x7F, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01,
    0x03, 0x61, 0x64, 0x64, 0x00, 0x00, 0x0A, 0x09,
    0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6A,
    0x0B
  ]
var svcReq: array[128, uint8]
var svcResp: array[64, uint8]

proc putStatus(code: uint32) {.lpRam.} =
  regWrite(LpEnclaveWasmIpcStatusAddr, code)
  dcacheFlushAll()
  fenceIo()

proc putStage(code: uint32) {.lpRam.} =
  regWrite(LpEnclaveWasmIpcStageAddr, code)
  dcacheFlushAll()
  fenceIo()

proc wrU32Local(buf: var openArray[uint8], off: int, value: uint32) {.lpRam.} =
  buf[off] = (value and 0xFF).uint8
  buf[off + 1] = ((value shr 8) and 0xFF).uint8
  buf[off + 2] = ((value shr 16) and 0xFF).uint8
  buf[off + 3] = ((value shr 24) and 0xFF).uint8

proc rdU32Local(buf: openArray[uint8], off: int): uint32 {.lpRam.} =
  buf[off].uint32 or (buf[off + 1].uint32 shl 8) or
    (buf[off + 2].uint32 shl 16) or (buf[off + 3].uint32 shl 24)

proc putControlFailure(resp: openArray[uint8]) {.lpRam.} =
  let control = rdU32Local(resp, 0) and 0xF
  let manager = rdU32Local(resp, 4) and 0xF
  let store = rdU32Local(resp, 8) and 0xF
  putStatus(LpEnclaveWasmIpcControlFailed or (control shl 8) or
            (manager shl 4) or store)

proc spinDelay() {.lpRam.} =
  for _ in 0 ..< 50:
    {.emit: """asm volatile("");""".}

proc sharedRead32(address: uint): uint32 {.lpRam.} =
  dcacheFlushAll()
  dcacheInvalidateAll()
  fenceIo()
  regRead(address)

proc recvM0ReplyFast(tag: var uint16, buf: var openArray[uint8]): int {.lpRam.} =
  putStage(0x4C50_8100'u32)
  dcacheFlushAll()
  dcacheInvalidateAll()
  fenceIo()
  let header = regRead(XramBufM0toLP)
  putStage(0x4C50_8200'u32 or (header and 0xFF))
  let source = regRead(XramBufM0toLP + 4'u)
  putStage(0x4C50_8300'u32 or (source and 0xFF))
  let sender = (source and 0xFF'u32).int
  let magic = (source shr 16).uint16
  if magic != IpcMsgMagic or sender != ipcM0.ord:
    return -1
  putStage(0x4C50_8400'u32)

  tag = (header and 0xFFFF).uint16
  let length = (header shr 16).int
  result = min(length, buf.len)
  putStage(0x4C50_8500'u32 or (result.uint32 and 0xFF))
  var offset = IpcMsgHeaderSize.uint
  var i = 0
  while i + 3 < result:
    let word = regRead(XramBufM0toLP + offset)
    buf[i] = (word and 0xFF).uint8
    buf[i + 1] = ((word shr 8) and 0xFF).uint8
    buf[i + 2] = ((word shr 16) and 0xFF).uint8
    buf[i + 3] = ((word shr 24) and 0xFF).uint8
    offset += 4
    i += 4
  if i < result:
    let word = regRead(XramBufM0toLP + offset)
    for j in 0 ..< result - i:
      buf[i + j] = ((word shr (j * 8)) and 0xFF).uint8

  regWrite(XramBufM0toLP, 0)
  regWrite(XramBufM0toLP + 4'u, 0)
  dcacheFlushAll()
  fenceIo()

proc sendM0RequestFast(tag: uint16, data: openArray[uint8]): bool {.lpRam.} =
  if data.len.uint32 + IpcMsgHeaderSize.uint32 > XramBufLPtoM0Size.uint32:
    return false
  let header0 = (data.len.uint16.uint32 shl 16) or tag.uint32
  let header1 = ipcLP.ord.uint32 or (2'u32 shl 8) or (IpcMsgMagic.uint32 shl 16)
  regWrite(XramBufLPtoM0, header0)
  regWrite(XramBufLPtoM0 + 4'u, header1)

  var offset = IpcMsgHeaderSize.uint
  var i = 0
  while i + 3 < data.len:
    let word = data[i].uint32 or
               (data[i + 1].uint32 shl 8) or
               (data[i + 2].uint32 shl 16) or
               (data[i + 3].uint32 shl 24)
    regWrite(XramBufLPtoM0 + offset, word)
    offset += 4
    i += 4
  if i < data.len:
    var word = 0'u32
    for j in 0 ..< data.len - i:
      word = word or (data[i + j].uint32 shl (j * 8))
    regWrite(XramBufLPtoM0 + offset, word)

  dcacheFlushAll()
  fenceIo()
  regWrite(Ipc0Base + IpcCpu1Iswr, 1'u32 shl 3)
  true

proc callSvc(svc: SvcId, req: openArray[uint8],
             resp: var openArray[uint8], respLen: var int): bool {.lpRam.} =
  putStage(0x4C50_1000'u32 or svc.uint32)
  regWrite(XramBufM0toLP, 0)
  regWrite(XramBufM0toLP + 4'u, 0)
  dcacheFlushAll()
  fenceIo()
  if not sendM0RequestFast(SvcIpcTagBase + svc.uint16, req):
    putStatus(LpEnclaveWasmIpcSendFailed)
    return false
  putStage(0x4C50_2000'u32 or svc.uint32)
  var tag: uint16
  for attempt in 0 ..< ReplyWaitLimit:
    if (attempt and 0xFFFF) == 0:
      putStage(0x4C50_7000'u32 or ((attempt.uint32 shr 16) and 0xFF))
    var n = recvM0ReplyFast(tag, resp)
    if n >= 0:
      putStage(0x4C50_6000'u32 or svc.uint32)
    if n >= 0:
      respLen = n
      if tag != svcOk.uint16:
        putStatus(LpEnclaveWasmIpcUnexpectedTag or tag.uint32)
        return false
      return true
    spinDelay()
  putStatus(LpEnclaveWasmIpcReplyTimeout)
  false

proc checkCaps(): bool {.lpRam.} =
  var respLen = 0
  let empty: array[0, uint8] = []
  if not callSvc(svcWasmCapabilities, empty, svcResp, respLen):
    return false
  putStage(0x4C50_9100'u32 or (respLen.uint32 and 0xFF))
  result = respLen == 32 and
    rdU32Local(svcResp, 0) == 1'u32 and
    rdU32Local(svcResp, 4) == 1'u32 and
    rdU32Local(svcResp, 8) == 1'u32 and
    rdU32Local(svcResp, 12) == 1'u32 and
    rdU32Local(svcResp, 16) == 1'u32 and
    rdU32Local(svcResp, 20) == 1'u32 and
    rdU32Local(svcResp, 24) == 0'u32 and
    rdU32Local(svcResp, 28) == 0'u32
  putStage(if result: 0x4C50_9201'u32 else: 0x4C50_9200'u32)
  if not result:
    putStatus(LpEnclaveWasmIpcBadCaps)

proc installSlot(): bool {.lpRam.} =
  putStage(0x4C50_A000'u32)
  wrU32Local(svcReq, 0, ManagedSlot)
  wrU32Local(svcReq, 4, 13'u32)
  wrU32Local(svcReq, 8, 0'u32)
  wrU32Local(svcReq, 12, AddModule.len.uint32)
  for i in 0 ..< AddModule.len:
    svcReq[16 + i] = AddModule[i]
  putStage(0x4C50_A100'u32)
  var respLen = 0
  if not callSvc(svcWasmInstallBytes,
                 svcReq.toOpenArray(0, 16 + AddModule.len - 1),
                 svcResp, respLen):
    return false
  result = respLen == 16 and rdU32Local(svcResp, 0) == 0'u32 and
    cast[int32](rdU32Local(svcResp, 12)) == ManagedSlot.int32
  if not result:
    if respLen == 16:
      putControlFailure(svcResp)
      return
    putStatus(LpEnclaveWasmIpcInstallFailed)

proc invokeSlot(): bool {.lpRam.} =
  let name = "add"
  wrU32Local(svcReq, 0, ManagedSlot)
  wrU32Local(svcReq, 4, name.len.uint32)
  wrU32Local(svcReq, 8, 2)
  wrU32Local(svcReq, 12, cast[uint32](17'i32))
  wrU32Local(svcReq, 16, cast[uint32](25'i32))
  for i in 0 ..< name.len:
    svcReq[20 + i] = name[i].uint8
  var respLen = 0
  if not callSvc(svcWasmInvokeI32,
                 svcReq.toOpenArray(0, 20 + name.len - 1),
                 svcResp, respLen):
    return false
  result = respLen == 16 and rdU32Local(svcResp, 0) == 0'u32 and
    cast[int32](rdU32Local(svcResp, 12)) == 42'i32
  if not result:
    if respLen == 16:
      putControlFailure(svcResp)
      return
    putStatus(LpEnclaveWasmIpcInvokeFailed)

proc unloadSlot(): bool {.lpRam.} =
  wrU32Local(svcReq, 0, ManagedSlot)
  var respLen = 0
  if not callSvc(svcWasmUnloadSlot, svcReq.toOpenArray(0, 3), svcResp, respLen):
    return false
  result = respLen == 16 and rdU32Local(svcResp, 0) == 0'u32 and
    cast[int32](rdU32Local(svcResp, 12)) == ManagedSlot.int32
  if not result:
    if respLen == 16:
      putControlFailure(svcResp)
      return
    putStatus(LpEnclaveWasmIpcUnloadFailed)

proc main() {.exportc, cdecl, lpRam.} =
  systemInit()
  ipcInit()
  putStatus(0)
  putStage(0x4C50_0001'u32)
  while sharedRead32(XramSyncLP) != IpcSyncFlag:
    spinDelay()
  putStage(0x4C50_0002'u32)
  if checkCaps() and installSlot() and invokeSlot() and unloadSlot():
    putStatus(LpEnclaveWasmIpcOk)
  while true:
    wfi()
