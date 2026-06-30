## D0 client for the enclave WASM IPC service smoke test.

import bl808/startup
import bl808/core, bl808/ipc, bl808/memmap, bl808/mmio
import bl808/enclave/abi

const
  D0EnclaveWasmIpcStatusAddr* = XramBase + 0x3EC0'u
  D0EnclaveWasmIpcOk* = 0x4549_5700'u32 # "EIW\0"
  D0EnclaveWasmIpcSendFailed* = 0x4549_5701'u32
  D0EnclaveWasmIpcReplyTimeout* = 0x4549_5702'u32
  D0EnclaveWasmIpcBadReply* = 0x4549_5703'u32
  D0EnclaveWasmIpcBadCaps* = 0x4549_5704'u32
  D0EnclaveWasmIpcInstallFailed* = 0x4549_5705'u32
  D0EnclaveWasmIpcInvokeFailed* = 0x4549_5706'u32
  D0EnclaveWasmIpcUnloadFailed* = 0x4549_5707'u32
  D0EnclaveWasmIpcUnexpectedTag* = 0x4549_0000'u32
  D0EnclaveWasmIpcControlFailed* = 0x4549_5000'u32
  ManagedSlot = 3'u32
  ReplyWaitLimit = 40_000_000

  AddModule = [
    byte 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7F, 0x7F, 0x01,
    0x7F, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01,
    0x03, 0x61, 0x64, 0x64, 0x00, 0x00, 0x0A, 0x09,
    0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6A,
    0x0B
  ]

proc putStatus(code: uint32) =
  regWrite(D0EnclaveWasmIpcStatusAddr, code)
  dcacheFlushAll()
  fenceIo()

proc wrU32Local(buf: var openArray[uint8], off: int, value: uint32) =
  buf[off] = (value and 0xFF).uint8
  buf[off + 1] = ((value shr 8) and 0xFF).uint8
  buf[off + 2] = ((value shr 16) and 0xFF).uint8
  buf[off + 3] = ((value shr 24) and 0xFF).uint8

proc rdU32Local(buf: openArray[uint8], off: int): uint32 =
  buf[off].uint32 or (buf[off + 1].uint32 shl 8) or
    (buf[off + 2].uint32 shl 16) or (buf[off + 3].uint32 shl 24)

proc putControlFailure(resp: openArray[uint8]) =
  let control = rdU32Local(resp, 0) and 0xF
  let manager = rdU32Local(resp, 4) and 0xF
  let store = rdU32Local(resp, 8) and 0xF
  putStatus(D0EnclaveWasmIpcControlFailed or (control shl 8) or
            (manager shl 4) or store)

proc spinDelay() =
  for _ in 0 ..< 50:
    {.emit: """asm volatile("");""".}

proc callSvc(svc: SvcId, req: openArray[uint8],
             resp: var openArray[uint8], respLen: var int): bool =
  if not ipcSendMessage(ipcM0, SvcIpcTagBase + svc.uint16, req):
    putStatus(D0EnclaveWasmIpcSendFailed)
    return false
  var tag: uint16
  for _ in 0 ..< ReplyWaitLimit:
    var n = ipcRecvMessage(ipcM0, tag, resp)
    if n < 0:
      n = ipcRecvBufferedMessage(ipcM0, tag, resp)
    if n >= 0:
      respLen = n
      if tag != svcOk.uint16:
        putStatus(D0EnclaveWasmIpcUnexpectedTag or tag.uint32)
        return false
      return true
    spinDelay()
  putStatus(D0EnclaveWasmIpcReplyTimeout)
  false

proc checkCaps(): bool =
  var resp: array[64, uint8]
  var respLen = 0
  let empty: array[0, uint8] = []
  if not callSvc(svcWasmCapabilities, empty, resp, respLen):
    return false
  result = respLen == 32 and
    rdU32Local(resp, 0) == 1'u32 and  # M0 enclave VM profile
    rdU32Local(resp, 4) == 1'u32 and  # compact
    rdU32Local(resp, 8) == 1'u32 and  # flash-backed
    rdU32Local(resp, 12) == 1'u32 and # software f32
    rdU32Local(resp, 16) == 1'u32 and
    rdU32Local(resp, 20) == 1'u32 and
    rdU32Local(resp, 24) == 0'u32 and
    rdU32Local(resp, 28) == 0'u32
  if not result:
    putStatus(D0EnclaveWasmIpcBadCaps)

proc installSlot(): bool =
  var req: array[96, uint8]
  wrU32Local(req, 0, ManagedSlot)
  wrU32Local(req, 4, 11'u32)
  wrU32Local(req, 8, 0'u32)
  wrU32Local(req, 12, AddModule.len.uint32)
  for i in 0 ..< AddModule.len:
    req[16 + i] = AddModule[i]
  var resp: array[64, uint8]
  var respLen = 0
  if not callSvc(svcWasmInstallBytes,
                 req.toOpenArray(0, 16 + AddModule.len - 1),
                 resp, respLen):
    return false
  result = respLen == 16 and rdU32Local(resp, 0) == 0'u32 and
    cast[int32](rdU32Local(resp, 12)) == ManagedSlot.int32
  if not result:
    if respLen == 16:
      putControlFailure(resp)
      return
    putStatus(D0EnclaveWasmIpcInstallFailed)

proc invokeSlot(): bool =
  var req: array[32, uint8]
  let name = "add"
  wrU32Local(req, 0, ManagedSlot)
  wrU32Local(req, 4, name.len.uint32)
  wrU32Local(req, 8, 2)
  wrU32Local(req, 12, cast[uint32](19'i32))
  wrU32Local(req, 16, cast[uint32](23'i32))
  for i in 0 ..< name.len:
    req[20 + i] = name[i].uint8
  var resp: array[64, uint8]
  var respLen = 0
  if not callSvc(svcWasmInvokeI32,
                 req.toOpenArray(0, 20 + name.len - 1),
                 resp, respLen):
    return false
  result = respLen == 16 and rdU32Local(resp, 0) == 0'u32 and
    cast[int32](rdU32Local(resp, 12)) == 42'i32
  if not result:
    if respLen == 16:
      putControlFailure(resp)
      return
    putStatus(D0EnclaveWasmIpcInvokeFailed)

proc unloadSlot(): bool =
  var req: array[4, uint8]
  wrU32Local(req, 0, ManagedSlot)
  var resp: array[64, uint8]
  var respLen = 0
  if not callSvc(svcWasmUnloadSlot, req, resp, respLen):
    return false
  result = respLen == 16 and rdU32Local(resp, 0) == 0'u32 and
    cast[int32](rdU32Local(resp, 12)) == ManagedSlot.int32
  if not result:
    if respLen == 16:
      putControlFailure(resp)
      return
    putStatus(D0EnclaveWasmIpcUnloadFailed)

proc main() {.exportc, cdecl.} =
  systemInit()
  ipcInit()
  putStatus(0)
  if checkCaps() and installSlot() and invokeSlot() and unloadSlot():
    putStatus(D0EnclaveWasmIpcOk)
  while true:
    wfi()
