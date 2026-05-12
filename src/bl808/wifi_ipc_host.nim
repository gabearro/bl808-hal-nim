## Nim implementation of the Bouffalo WiFi host IPC shim used by Nim firmware.
##
## The remaining SDK host driver still allocates and passes the C structs from
## ipc_host.h/ipc_shared.h. Keep this module at the C ABI boundary and access
## fields by the fixed BL808 M0 layout used by wifi.nim's CFG_TXDESC=4 build.

import mmio

const
  IpcRegBase = 0x2480_0000'u
  IpcApp2EmbTrigger = IpcRegBase + 0x00'u
  IpcEmb2AppRawStatus = IpcRegBase + 0x04'u
  IpcEmb2AppAck = IpcRegBase + 0x08'u
  IpcEmb2AppUnmaskSet = IpcRegBase + 0x0c'u
  IpcEmb2AppUnmaskClear = IpcRegBase + 0x10'u
  IpcEmb2AppStatus = IpcRegBase + 0x1c'u

  NxTxDescCnt = 4'u32
  IpcTxQueueCnt = 4

  IpcIrqA2eMsg = 1'u32 shl 1
  IpcIrqA2eTxDescFirstBit = 8'u32

  IpcIrqE2aDbg = 1'u32 shl 0
  IpcIrqE2aMsgAck = 1'u32 shl 2
  IpcIrqE2aRxDesc = 1'u32 shl 3
  IpcIrqE2aTbttPrim = 1'u32 shl 4
  IpcIrqE2aTbttSec = 1'u32 shl 5
  IpcIrqE2aRadar = 1'u32 shl 6
  IpcIrqE2aTxCfmPos = 7
  IpcIrqE2aTxCfm = ((1'u32 shl NxTxDescCnt) - 1'u32) shl IpcIrqE2aTxCfmPos
  IpcIrqE2aAll = IpcIrqE2aTxCfm or IpcIrqE2aRxDesc or IpcIrqE2aMsgAck or
                 (1'u32 shl 1) or IpcIrqE2aDbg or IpcIrqE2aTbttPrim or
                 IpcIrqE2aTbttSec or IpcIrqE2aRadar

  IpcHostEnvSize = 140'u
  IpcHostCbSize = 32'u
  EnvSharedOff = 32'u
  EnvTxbufOff = 36'u
  EnvTxdescFreeIdxOff = 40'u
  EnvTxdescUsedIdxOff = 44'u
  EnvListFreeOff = 72'u
  EnvListOngoingOff = 76'u
  EnvListCfmOff = 80'u
  EnvMsgA2eCntOff = 84'u
  EnvMsgA2eHostidOff = 88'u
  EnvDbgArrayOff = 92'u
  EnvDbgIdxOff = 124'u
  EnvPthisOff = 136'u

  SharedMsgBodyOff = 4'u
  SharedMsgBodySize = 127'u32 * 4'u32
  SharedPatternAddrOff = 512'u
  SharedTxbufOff = 516'u
  SharedTxbufSize = 1604'u
  SharedTxdesc0Off = 6932'u
  SharedTxdescHostSize = 620'u
  SharedListFreeOff = 9412'u
  SharedListOngoingOff = 9420'u
  SharedListCfmOff = 9428'u
  SharedEnvSize = 9436'u

  BlCmdA2eMsgOff = 12'u
  LmacMsgSrcIdOff = 3'u

  TxdescHostHostIdOff = 4'u
  TxdescHostReadyOff = 8'u

type
  SendDataCfm = proc(pthis, hostId: pointer): cint {.cdecl.}
  RecvInd = proc(pthis, hostId: pointer): uint8 {.cdecl.}
  TbttInd = proc(pthis: pointer) {.cdecl.}

proc c_memset(s: pointer, c: cint, n: csize_t): pointer
  {.importc: "memset", header: "<string.h>", cdecl.}
proc c_memcpy(dest, src: pointer, n: csize_t): pointer
  {.importc: "memcpy", header: "<string.h>", cdecl.}

template ptrAt(base: pointer; off: uint): pointer =
  cast[pointer](cast[uint](base) + off)

proc loadPtr(base: pointer; off: uint): pointer {.inline.} =
  cast[ptr pointer](ptrAt(base, off))[]

proc storePtr(base: pointer; off: uint; value: pointer) {.inline.} =
  cast[ptr pointer](ptrAt(base, off))[] = value

proc loadU8(base: pointer; off: uint): uint8 {.inline.} =
  cast[ptr uint8](ptrAt(base, off))[]

proc storeU8(base: pointer; off: uint; value: uint8) {.inline.} =
  cast[ptr uint8](ptrAt(base, off))[] = value

proc loadU32(base: pointer; off: uint): uint32 {.inline.} =
  cast[ptr uint32](ptrAt(base, off))[]

proc storeU32(base: pointer; off: uint; value: uint32) {.inline.} =
  cast[ptr uint32](ptrAt(base, off))[] = value

proc listInit(list: pointer) {.inline.} =
  storePtr(list, 0, nil)
  storePtr(list, 4, nil)

proc listPushBack(list, hdr: pointer) {.inline.} =
  if hdr == nil:
    return
  storePtr(hdr, 0, nil)
  let last = loadPtr(list, 4)
  if last != nil:
    storePtr(last, 0, hdr)
  else:
    storePtr(list, 0, hdr)
  storePtr(list, 4, hdr)

proc listPopFront(list: pointer): pointer {.inline.} =
  result = loadPtr(list, 0)
  if result != nil:
    let next = loadPtr(result, 0)
    storePtr(list, 0, next)
    if next == nil:
      storePtr(list, 4, nil)
    storePtr(result, 0, nil)

proc listPick(list: pointer): pointer {.inline.} =
  if list == nil: nil else: loadPtr(list, 0)

proc envCb(env: pointer; off: uint): pointer {.inline.} =
  loadPtr(env, off)

proc callSendDataCfm(env, hostId: pointer) {.inline.} =
  let fn = cast[SendDataCfm](envCb(env, 0))
  if fn != nil:
    discard fn(loadPtr(env, EnvPthisOff), hostId)

proc callRecvMsgAck(env, hostId: pointer) {.inline.} =
  let fn = cast[RecvInd](envCb(env, 16))
  if fn != nil:
    discard fn(loadPtr(env, EnvPthisOff), hostId)

proc callRecvDbg(env, hostId: pointer): uint8 {.inline.} =
  let fn = cast[RecvInd](envCb(env, 20))
  if fn == nil:
    return 1
  fn(loadPtr(env, EnvPthisOff), hostId)

proc callTbtt(env: pointer; off: uint) {.inline.} =
  let fn = cast[TbttInd](envCb(env, off))
  if fn != nil:
    fn(loadPtr(env, EnvPthisOff))

proc roundUp4(value: uint32): uint32 {.inline.} =
  (value + 3'u32) and not 3'u32

proc ipc_host_init*(env, cb, sharedEnv, pthis: pointer) {.exportc, cdecl.} =
  discard c_memset(sharedEnv, 0, SharedEnvSize.csize_t)
  discard c_memset(env, 0, IpcHostEnvSize.csize_t)
  discard c_memcpy(env, cb, IpcHostCbSize.csize_t)

  storePtr(env, EnvSharedOff, sharedEnv)
  storePtr(env, EnvTxbufOff, ptrAt(sharedEnv, SharedTxbufOff))
  storePtr(env, EnvListFreeOff, ptrAt(sharedEnv, SharedListFreeOff))
  storePtr(env, EnvListOngoingOff, ptrAt(sharedEnv, SharedListOngoingOff))
  storePtr(env, EnvListCfmOff, ptrAt(sharedEnv, SharedListCfmOff))
  storePtr(env, EnvPthisOff, pthis)

  let freeList = loadPtr(env, EnvListFreeOff)
  let ongoingList = loadPtr(env, EnvListOngoingOff)
  let cfmList = loadPtr(env, EnvListCfmOff)
  listInit(freeList)
  listInit(ongoingList)
  listInit(cfmList)
  for i in 0'u ..< NxTxDescCnt.uint:
    listPushBack(freeList, ptrAt(sharedEnv, SharedTxdesc0Off + i * SharedTxdescHostSize))

proc ipc_host_msg_push*(env, msgBuf: pointer; len: uint16): cint {.exportc, cdecl.} =
  if env == nil or msgBuf == nil:
    return -1
  let sharedEnv = loadPtr(env, EnvSharedOff)
  let msg = loadPtr(msgBuf, BlCmdA2eMsgOff)
  let copyLen = len.uint32
  if sharedEnv == nil or msg == nil:
    return -1
  if loadPtr(env, EnvMsgA2eHostidOff) != nil:
    return -1
  if roundUp4(copyLen) > SharedMsgBodySize:
    return -1

  storeU8(msg, LmacMsgSrcIdOff, loadU8(env, EnvMsgA2eCntOff))
  discard c_memcpy(ptrAt(sharedEnv, SharedMsgBodyOff), msg, roundUp4(copyLen).csize_t)
  storePtr(env, EnvMsgA2eHostidOff, msgBuf)
  regWrite(IpcApp2EmbTrigger, IpcIrqA2eMsg)
  0

proc ipc_host_patt_addr_push*(env: pointer; patternAddr: uint32) {.exportc, cdecl.} =
  if env == nil:
    return
  let sharedEnv = loadPtr(env, EnvSharedOff)
  if sharedEnv != nil:
    storeU32(sharedEnv, SharedPatternAddrOff, patternAddr)

proc ipc_host_get_status*(env: pointer): uint32 {.exportc, cdecl.} =
  discard env
  regRead(IpcEmb2AppStatus)

proc ipc_host_get_rawstatus*(env: pointer): uint32 {.exportc, cdecl.} =
  discard env
  regRead(IpcEmb2AppRawStatus)

proc ipc_host_txbuf_get*(env: pointer): pointer {.exportc, cdecl.} =
  if env == nil:
    return nil
  let txbuf = loadPtr(env, EnvTxbufOff)
  if txbuf == nil:
    return nil
  for i in 0'u ..< NxTxDescCnt.uint:
    let buf = ptrAt(txbuf, i * SharedTxbufSize)
    if loadU32(buf, 0) == 0'u32:
      storeU32(buf, 0, 1'u32)
      return buf

proc ipc_host_txbuf_free*(buf: pointer) {.exportc, cdecl.} =
  if buf != nil:
    storeU32(buf, 0, 0'u32)

proc ipc_host_txdesc_get*(env: pointer): pointer {.exportc, cdecl.} =
  if env == nil:
    return nil
  listPick(loadPtr(env, EnvListFreeOff))

proc ipc_host_txdesc_left*(env: pointer; queueIdx, userPos: cint): cint {.exportc, cdecl.} =
  discard queueIdx
  discard userPos
  if env == nil:
    return 0
  let usedIdx = loadU32(env, EnvTxdescUsedIdxOff)
  let freeIdx = loadU32(env, EnvTxdescFreeIdxOff)
  cint(NxTxDescCnt - (freeIdx - usedIdx))

proc ipc_host_txdesc_push*(env, hostId: pointer) {.exportc, cdecl.} =
  if env == nil:
    return
  let freeList = loadPtr(env, EnvListFreeOff)
  let txdesc = listPopFront(freeList)
  if txdesc == nil:
    return
  storeU32(txdesc, TxdescHostReadyOff, 0xffff_ffff'u32)
  storePtr(txdesc, TxdescHostHostIdOff, hostId)
  listPushBack(loadPtr(env, EnvListOngoingOff), txdesc)
  regWrite(IpcApp2EmbTrigger, 1'u32 shl IpcIrqA2eTxDescFirstBit)

proc ipcHostMsgAckHandler(env: pointer) =
  let hostId = loadPtr(env, EnvMsgA2eHostidOff)
  if hostId == nil:
    return
  storePtr(env, EnvMsgA2eHostidOff, nil)
  storeU8(env, EnvMsgA2eCntOff, loadU8(env, EnvMsgA2eCntOff) + 1'u8)
  callRecvMsgAck(env, hostId)

proc ipcHostTxCfmHandler(env: pointer) =
  let cfmList = loadPtr(env, EnvListCfmOff)
  var txdesc = listPopFront(cfmList)
  while txdesc != nil:
    callSendDataCfm(env, loadPtr(txdesc, TxdescHostHostIdOff))
    storePtr(txdesc, TxdescHostHostIdOff, nil)
    listPushBack(loadPtr(env, EnvListFreeOff), txdesc)
    txdesc = listPopFront(cfmList)

proc ipcHostDbgHandler(env: pointer) =
  let idx = loadU8(env, EnvDbgIdxOff).uint
  let hostId = loadPtr(env, EnvDbgArrayOff + idx * 8'u)
  while callRecvDbg(env, hostId) == 0'u8:
    discard

proc ipc_host_irq*(env: pointer; statusIn: uint32) {.exportc, cdecl.} =
  if env == nil:
    return

  regWrite(IpcEmb2AppAck, statusIn)
  let status = statusIn or regRead(IpcEmb2AppStatus)

  if (status and IpcIrqE2aTxCfm) != 0'u32:
    for i in 0 ..< IpcTxQueueCnt:
      if (status and (1'u32 shl (i + IpcIrqE2aTxCfmPos))) != 0'u32:
        ipcHostTxCfmHandler(env)

  if (status and IpcIrqE2aMsgAck) != 0'u32:
    ipcHostMsgAckHandler(env)
  if (status and IpcIrqE2aRadar) != 0'u32:
    discard
  if (status and IpcIrqE2aDbg) != 0'u32:
    ipcHostDbgHandler(env)
  if (status and IpcIrqE2aTbttPrim) != 0'u32:
    callTbtt(env, 24)
  if (status and IpcIrqE2aTbttSec) != 0'u32:
    callTbtt(env, 28)

proc ipc_host_enable_irq*(env: pointer; value: uint32) {.exportc, cdecl.} =
  discard env
  regWrite(IpcEmb2AppUnmaskSet, value)

proc ipc_host_disable_irq*(env: pointer; value: uint32) {.exportc, cdecl.} =
  discard env
  regWrite(IpcEmb2AppUnmaskClear, value)

proc ipc_host_disable_irq_e2a*() {.exportc, cdecl.} =
  regWrite(IpcEmb2AppUnmaskClear, IpcIrqE2aAll)
