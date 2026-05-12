## Cross-core IPC bridge for the BL808 kernel.
##
## Enables CPS tasks on one core to await results computed on another:
##
##   # On M0:
##   let result = await ipcCallU32To(ipcLP, MyRpcTag, arg)
##
##   # On D0 (registered handler):
##   ipcRegisterHandler(MyRpcTag, proc(data: openArray[uint8]): uint32 = ...)
##
## Protocol uses XRAM shared memory + IPC hardware signals:
##   1. Caller writes request (tag + payload) to XRAM
##   2. Caller sends IPC signal 3 to target core
##   3. Target core's ISR posts callback to scheduler
##   4. Scheduler runs handler, writes result to XRAM
##   5. Target sends IPC signal 3 back to caller
##   6. Caller's scheduler completes the pending future

import ../ipc, ../irq, ../core, ../mmio
import ./runtime, ./sched

# =============================================================================
# Constants
# =============================================================================

const
  IpcSignalKernel* = 3
    ## IPC signal bit reserved for kernel cross-core RPC.

  MaxRpcHandlers* = 16
    ## Maximum number of registered RPC handlers per core.

  MaxPendingCalls* = 8
    ## Maximum concurrent cross-core calls per core.

  MaxIpcCompletions* = 16
    ## Maximum IPC completions deferred from response parsing to scheduler code.

  IpcCallTimeoutMsDefault* = 0'u64
    ## Default timeout for one cross-core RPC call. 0 disables the timeout.

  IpcRespErrorNoHandler = 0xFFFF_FFFF'u32
    ## Remote side had no handler for this RPC tag.

  IpcPollKeepAliveMsDefault* = 500'u64
    ## Periodic IPC poll fallback interval.
    ## Keeps scheduler wakeups flowing under very slow/unreliable emulation.

# =============================================================================
# XRAM kernel region layout (within XramUserBase, 4096 bytes)
#
# Eight 512-byte slots for two routed core pairs (req + resp in each direction):
#   M0↔D0, M0↔LP
#
# Each slot: [token:u32][tag:u16|len:u16][data...] (request)
#         or [token:u32][respLen:u32][data...]      (response)
# =============================================================================

const
  XramKernelBase = XramUserBase  # 0x40003000
  XramSlotSize   = 0x200'u      # 512 bytes per slot

  # M0 ↔ D0
  XramM0toD0Req*  = XramKernelBase + 0x000'u
  XramM0toD0Resp* = XramKernelBase + 0x200'u
  # D0 → M0
  XramD0toM0Req*  = XramKernelBase + 0x400'u
  XramD0toM0Resp* = XramKernelBase + 0x600'u
  # M0 ↔ LP
  XramM0toLPReq*  = XramKernelBase + 0x800'u
  XramM0toLPResp* = XramKernelBase + 0xA00'u
  # LP → M0
  XramLPtoM0Req*  = XramKernelBase + 0xC00'u
  XramLPtoM0Resp* = XramKernelBase + 0xE00'u

# =============================================================================
# RPC handler registration (server side)
# =============================================================================

type
  RpcHandler* = proc(tag: uint16, reqData: ptr UncheckedArray[uint8],
                     reqLen: int, respData: ptr UncheckedArray[uint8],
                     respBufSize: int): int {.cdecl.}
    ## Handler returns the response data length written to respData.

var
  rpcHandlers: array[MaxRpcHandlers, tuple[tag: uint16, handler: RpcHandler]]
  rpcHandlerCount: int = 0

proc ipcRegisterHandler*(tag: uint16, handler: RpcHandler) =
  ## Register an RPC handler for the given tag on this core.
  if rpcHandlerCount < MaxRpcHandlers:
    rpcHandlers[rpcHandlerCount] = (tag: tag, handler: handler)
    inc rpcHandlerCount

proc findHandler(tag: uint16): RpcHandler =
  for i in 0 ..< rpcHandlerCount:
    if rpcHandlers[i].tag == tag:
      return rpcHandlers[i].handler
  nil

# =============================================================================
# Pending call tracking (client side)
# =============================================================================

type
  IpcCompletionKind = enum
    ipcCompleteNone
    ipcCompleteVoid
    ipcCompleteU32

  PendingCall = object
    token: uint32
    future: CpsVoidFuture
    u32Future: CpsFuture[uint32]
    active: bool
    reqAddr: uint
    respAddr: uint
    timeoutTimer: TimerId
    ## Result pointer — caller provides buffer for response
    resultPtr: pointer
    resultBufSize: int
    resultLen: ptr int

var
  pendingCalls: array[MaxPendingCalls, PendingCall]
  ipcCompletionKinds: array[MaxIpcCompletions, IpcCompletionKind]
  ipcCompletionVoidFuts: array[MaxIpcCompletions, CpsVoidFuture]
  ipcCompletionU32Futs: array[MaxIpcCompletions, CpsFuture[uint32]]
  ipcCompletionValues: array[MaxIpcCompletions, uint32]
  ipcCompletionErrors: array[MaxIpcCompletions, ref CatchableError]
  ipcCompletionHead, ipcCompletionTail, ipcCompletionCount: int
  ipcCompletionOverflows*: uint64 = 0
  nextToken: uint32 = 1
  ipcPollKeepAliveMs*: uint64 = IpcPollKeepAliveMsDefault
    ## Keep-alive interval for periodic `ipcPoll`.
    ## Set to 0 to disable periodic polling.
  ipcPollKeepAliveArmed = false

proc timeoutPendingCall(token: uint32)

proc enqueueIpcVoidCompletion(fut: CpsVoidFuture,
                              err: ref CatchableError = nil) =
  if fut == nil or fut.finished:
    return
  if ipcCompletionCount >= MaxIpcCompletions:
    ipcCompletionOverflows.inc
    if err == nil:
      complete(fut)
    else:
      fail(fut, err)
    return
  ipcCompletionKinds[ipcCompletionHead] = ipcCompleteVoid
  ipcCompletionVoidFuts[ipcCompletionHead] = fut
  ipcCompletionU32Futs[ipcCompletionHead] = nil
  ipcCompletionValues[ipcCompletionHead] = 0
  ipcCompletionErrors[ipcCompletionHead] = err
  ipcCompletionHead = (ipcCompletionHead + 1) mod MaxIpcCompletions
  ipcCompletionCount.inc

proc enqueueIpcU32Completion(fut: CpsFuture[uint32], value: uint32,
                             err: ref CatchableError = nil) =
  if fut == nil or fut.finished:
    return
  if ipcCompletionCount >= MaxIpcCompletions:
    ipcCompletionOverflows.inc
    if err == nil:
      complete(fut, value)
    else:
      fail(fut, err)
    return
  ipcCompletionKinds[ipcCompletionHead] = ipcCompleteU32
  ipcCompletionVoidFuts[ipcCompletionHead] = nil
  ipcCompletionU32Futs[ipcCompletionHead] = fut
  ipcCompletionValues[ipcCompletionHead] = value
  ipcCompletionErrors[ipcCompletionHead] = err
  ipcCompletionHead = (ipcCompletionHead + 1) mod MaxIpcCompletions
  ipcCompletionCount.inc

proc drainIpcCompletions() =
  while ipcCompletionCount > 0:
    let idx = ipcCompletionTail
    let kind = ipcCompletionKinds[idx]
    let voidFut = ipcCompletionVoidFuts[idx]
    let u32Fut = ipcCompletionU32Futs[idx]
    let value = ipcCompletionValues[idx]
    let err = ipcCompletionErrors[idx]

    ipcCompletionKinds[idx] = ipcCompleteNone
    ipcCompletionVoidFuts[idx] = nil
    ipcCompletionU32Futs[idx] = nil
    ipcCompletionValues[idx] = 0
    ipcCompletionErrors[idx] = nil
    ipcCompletionTail = (idx + 1) mod MaxIpcCompletions
    ipcCompletionCount.dec

    case kind
    of ipcCompleteNone:
      discard
    of ipcCompleteVoid:
      if voidFut != nil and not voidFut.finished:
        if err == nil:
          complete(voidFut)
        else:
          fail(voidFut, err)
    of ipcCompleteU32:
      if u32Fut != nil and not u32Fut.finished:
        if err == nil:
          complete(u32Fut, value)
        else:
          fail(u32Fut, err)

proc wireSlotActive(reqAddr, respAddr: uint): bool =
  for i in 0 ..< MaxPendingCalls:
    if pendingCalls[i].active and
       (pendingCalls[i].reqAddr == reqAddr or pendingCalls[i].respAddr == respAddr):
      return true
  false

proc allocPendingCall(fut: CpsVoidFuture, u32Future: CpsFuture[uint32],
                      resultPtr: pointer,
                      resultBufSize: int, resultLen: ptr int,
                      reqAddr, respAddr: uint,
                      timeoutMs: uint64): int =
  ## Allocate a pending call slot, returning the slot index or -1.
  let token = nextToken
  nextToken += 1
  for i in 0 ..< MaxPendingCalls:
    if not pendingCalls[i].active:
      pendingCalls[i] = PendingCall(
        token: token, future: fut, u32Future: u32Future, active: true,
        reqAddr: reqAddr, respAddr: respAddr,
        resultPtr: resultPtr, resultBufSize: resultBufSize, resultLen: resultLen)
      if timeoutMs > 0:
        pendingCalls[i].timeoutTimer =
          addTimerMs(timeoutMs, proc() = timeoutPendingCall(token))
      return i
  -1  # no slots available

proc completePendingCallAt(idx: int, err: ref CatchableError = nil) =
  if idx < 0 or idx >= MaxPendingCalls or not pendingCalls[idx].active:
    return
  let fut = pendingCalls[idx].future
  let u32Fut = pendingCalls[idx].u32Future
  let timer = pendingCalls[idx].timeoutTimer
  pendingCalls[idx] = PendingCall()
  if timer != 0:
    cancelTimer(timer)
  if err == nil:
    enqueueIpcVoidCompletion(fut)
  else:
    enqueueIpcVoidCompletion(fut, err)
    enqueueIpcU32Completion(u32Fut, 0, err)

proc completePendingCallU32At(idx: int, val: uint32) =
  if idx < 0 or idx >= MaxPendingCalls or not pendingCalls[idx].active:
    return
  let fut = pendingCalls[idx].u32Future
  let timer = pendingCalls[idx].timeoutTimer
  pendingCalls[idx] = PendingCall()
  if timer != 0:
    cancelTimer(timer)
  enqueueIpcU32Completion(fut, val)

proc completePendingCall(token: uint32, err: ref CatchableError = nil) =
  for i in 0 ..< MaxPendingCalls:
    if pendingCalls[i].active and pendingCalls[i].token == token:
      completePendingCallAt(i, err)
      return

proc findPendingCallIndex(token: uint32): int =
  for i in 0 ..< MaxPendingCalls:
    if pendingCalls[i].active and pendingCalls[i].token == token:
      return i
  -1

proc sharedWriteBarrier() {.inline.} =
  ## Publish cached XRAM writes before signaling another core.
  core.dcacheFlushAll()
  core.fence()

proc sharedReadBarrier() {.inline.} =
  ## Refresh cached XRAM lines before consuming data from another core.
  core.dcacheFlushAll()
  core.dcacheInvalidateAll()
  core.fence()

proc timeoutPendingCall(token: uint32) =
  let idx = findPendingCallIndex(token)
  if idx < 0:
    return
  let reqAddr = pendingCalls[idx].reqAddr
  let respAddr = pendingCalls[idx].respAddr
  sharedReadBarrier()
  if reqAddr != 0 and regRead(reqAddr) == token:
    regWrite(reqAddr, 0)
  if respAddr != 0 and regRead(respAddr) == token:
    regWrite(respAddr, 0)
  sharedWriteBarrier()
  completePendingCallAt(idx, newException(IOError, "IPC bridge: call timed out"))

proc getRemoteCore(): IpcTarget

proc clearKernelSignal() =
  let signals = ipcReadSignals(getRemoteCore())
  if (signals and (1'u32 shl IpcSignalKernel.uint32)) != 0:
    ipcClearSignal(getRemoteCore(), IpcSignalKernel.IpcSignal)

# =============================================================================
# IPC ISR handler
# =============================================================================

proc getIncomingReqAddr(): uint =
  ## XRAM address where incoming requests arrive for this core.
  when defined(bl808m0):
    XramD0toM0Req     # D0 sends requests here
  elif defined(bl808d0):
    XramM0toD0Req     # M0 sends requests here
  elif defined(bl808lp):
    XramM0toLPReq     # M0 sends requests here
  else:
    0'u

proc getIncomingReqAddrLP(): uint =
  ## Second incoming request slot (M0 receives from LP as well as D0).
  when defined(bl808m0):
    XramLPtoM0Req
  else:
    0'u

proc getIncomingRespAddr(): uint =
  ## XRAM address where incoming responses arrive for this core.
  when defined(bl808m0):
    XramM0toD0Resp    # Response to M0's request to D0
  elif defined(bl808d0):
    XramD0toM0Resp    # Response to D0's request to M0
  elif defined(bl808lp):
    XramLPtoM0Resp    # Response to LP's request to M0
  else:
    0'u

proc getIncomingRespAddrLP(): uint =
  ## Second incoming response slot (M0 gets responses from LP too).
  when defined(bl808m0):
    XramM0toLPResp
  else:
    0'u

proc getOutgoingReqAddr(): uint =
  ## XRAM address where this core writes requests.
  when defined(bl808m0):
    XramM0toD0Req     # M0 sends requests to D0
  elif defined(bl808d0):
    XramD0toM0Req     # D0 sends requests to M0
  elif defined(bl808lp):
    XramLPtoM0Req     # LP sends requests to M0
  else:
    0'u

proc getOutgoingRespAddr(): uint =
  ## XRAM address where this core writes responses to incoming requests.
  when defined(bl808m0):
    XramD0toM0Resp    # M0 responds to D0's request
  elif defined(bl808d0):
    XramM0toD0Resp    # D0 responds to M0's request
  elif defined(bl808lp):
    XramM0toLPResp    # LP responds to M0's request
  else:
    0'u

proc getOutgoingRespAddrLP(): uint =
  ## M0's response slot for LP requests.
  when defined(bl808m0):
    XramLPtoM0Resp
  else:
    0'u

proc getRemoteCore(): IpcTarget =
  when defined(bl808m0):
    ipcD0
  elif defined(bl808d0):
    ipcM0
  elif defined(bl808lp):
    ipcM0
  else:
    ipcM0

var processCount*: int = 0

proc processIncomingRequest() =
  ## Called from the scheduler when an IPC signal arrives.
  ## Reads the request from XRAM, dispatches to handler, writes response.
  processCount += 1
  let reqAddr = getIncomingReqAddr()
  let respAddr = getOutgoingRespAddr()

  sharedReadBarrier()

  # Read request header: [token:u32][tag:u16][len:u16]
  let tokenWord = regRead(reqAddr)
  let tagLen = regRead(reqAddr + 4)
  let tag = (tagLen and 0xFFFF).uint16
  let reqLen = (tagLen shr 16).int
  let maxWireLen = (XramSlotSize - 8).int

  if tokenWord == 0:
    return  # no pending request

  let handler = findHandler(tag)
  if reqLen < 0 or reqLen > maxWireLen:
    regWrite(respAddr, tokenWord)
    regWrite(respAddr + 4, IpcRespErrorNoHandler)
  elif handler != nil:
    # Call handler with request data, get response
    let respLen = handler(
      tag,
      cast[ptr UncheckedArray[uint8]](reqAddr + 8),
      reqLen,
      cast[ptr UncheckedArray[uint8]](respAddr + 8),
      (XramSlotSize - 8).int)

    # Publish response metadata, then token last as the ready flag.
    regWrite(respAddr + 4, respLen.uint32)
    sharedWriteBarrier()
    regWrite(respAddr, tokenWord)  # token written last => response is ready
  else:
    # No handler — write error response
    regWrite(respAddr + 4, IpcRespErrorNoHandler)
    sharedWriteBarrier()
    regWrite(respAddr, tokenWord)

  # Clear the request
  regWrite(reqAddr, 0)

  sharedWriteBarrier()

  # Signal back to the caller
  ipcSendSignal(getRemoteCore(), IpcSignalKernel.IpcSignal)

proc processIncomingResponse() =
  ## Called when an IPC signal arrives that might be a response.
  let respAddr = getIncomingRespAddr()
  sharedReadBarrier()
  let token = regRead(respAddr)
  if token == 0:
    return

  let rawRespLen = regRead(respAddr + 4)
  let idx = findPendingCallIndex(token)
  var completionErr: ref CatchableError = nil

  if idx < 0:
    completionErr = newException(IOError, "IPC bridge: response token has no pending call")
  elif rawRespLen == IpcRespErrorNoHandler:
    completionErr = newException(IOError, "IPC bridge: remote handler missing")
  else:
    let respLen = rawRespLen.int
    let maxWireLen = (XramSlotSize - 8).int
    if respLen < 0 or respLen > maxWireLen:
      completionErr = newException(IOError, "IPC bridge: invalid response length")
    elif pendingCalls[idx].u32Future != nil:
      if respLen != 4:
        completionErr = newException(IOError, "IPC bridge: invalid uint32 response length")
      else:
        let val = regRead(respAddr + 8)
        regWrite(respAddr, 0)
        sharedWriteBarrier()
        completePendingCallU32At(idx, val)
        return
    elif respLen > pendingCalls[idx].resultBufSize:
      completionErr = newException(IOError, "IPC bridge: response buffer too small")
    else:
      if pendingCalls[idx].resultPtr != nil and respLen > 0:
        let src = respAddr + 8
        let dst = cast[uint](pendingCalls[idx].resultPtr)
        var off = 0'u
        while off + 3 < respLen.uint:
          let word = regRead(src + off)
          cast[ptr uint32](dst + off)[] = word
          off += 4
        if off < respLen.uint:
          let word = regRead(src + off)
          for j in 0'u ..< (respLen.uint - off):
            cast[ptr uint8](dst + off + j)[] = ((word shr (j * 8)) and 0xFF).uint8
      if pendingCalls[idx].resultLen != nil:
        pendingCalls[idx].resultLen[] = respLen

  # Clear the response slot
  regWrite(respAddr, 0)
  sharedWriteBarrier()

  # Complete/fail the pending future
  completePendingCall(token, completionErr)

proc ipcProcessPosted() =
  processIncomingRequest()
  processIncomingResponse()
  drainIpcCompletions()

proc ipcKernelHandler() {.cdecl.} =
  ## IPC ISR handler for kernel signals.
  ## Posts a fixed callback to the scheduler for processing.
  clearKernelSignal()
  postFromIsr(ipcProcessPosted)

# =============================================================================
# Initialization
# =============================================================================

proc processRequestAt(reqAddr, respAddr: uint) =
  ## Process a request at a specific XRAM slot pair.
  sharedReadBarrier()
  if reqAddr == 0 or regRead(reqAddr) == 0: return
  # Temporarily override the addresses used by processIncomingRequest
  # by calling the processing logic inline:
  processCount += 1
  let tokenWord = regRead(reqAddr)
  let tagLen = regRead(reqAddr + 4)
  let tag = (tagLen and 0xFFFF).uint16
  let reqLen = (tagLen shr 16).int
  let maxWireLen = (XramSlotSize - 8).int
  if tokenWord == 0: return

  let handler = findHandler(tag)
  if reqLen < 0 or reqLen > maxWireLen:
    regWrite(respAddr, tokenWord)
    regWrite(respAddr + 4, IpcRespErrorNoHandler)
  elif handler != nil:
    let respLen = handler(
      tag,
      cast[ptr UncheckedArray[uint8]](reqAddr + 8),
      reqLen,
      cast[ptr UncheckedArray[uint8]](respAddr + 8),
      maxWireLen)
    regWrite(respAddr + 4, respLen.uint32)
    sharedWriteBarrier()
    regWrite(respAddr, tokenWord)
  else:
    regWrite(respAddr + 4, IpcRespErrorNoHandler)
    sharedWriteBarrier()
    regWrite(respAddr, tokenWord)

  regWrite(reqAddr, 0)
  sharedWriteBarrier()
  # Signal back — determine which core sent this
  when defined(bl808m0):
    # M0 receives from D0 and LP — figure out which
    if reqAddr == XramD0toM0Req:
      ipcSendSignal(ipcD0, IpcSignalKernel.IpcSignal)
    elif reqAddr == XramLPtoM0Req:
      ipcSendSignal(ipcLP, IpcSignalKernel.IpcSignal)
  else:
    ipcSendSignal(getRemoteCore(), IpcSignalKernel.IpcSignal)

proc processResponseAt(respAddr: uint) =
  ## Process a response at a specific XRAM slot.
  sharedReadBarrier()
  if respAddr == 0 or regRead(respAddr) == 0: return
  let token = regRead(respAddr)
  let rawRespLen = regRead(respAddr + 4)
  let idx = findPendingCallIndex(token)
  var completionErr: ref CatchableError = nil
  if idx < 0:
    discard
  elif rawRespLen == IpcRespErrorNoHandler:
    completionErr = newException(IOError, "IPC: remote handler missing")
  else:
    let respLen = rawRespLen.int
    let maxWireLen = (XramSlotSize - 8).int
    if respLen < 0 or respLen > maxWireLen:
      completionErr = newException(IOError, "IPC: invalid response length")
    elif idx >= 0 and pendingCalls[idx].u32Future != nil:
      if respLen != 4:
        completionErr = newException(IOError, "IPC: invalid uint32 response length")
      else:
        let val = regRead(respAddr + 8)
        regWrite(respAddr, 0)
        sharedWriteBarrier()
        completePendingCallU32At(idx, val)
        return
    elif idx >= 0 and respLen > pendingCalls[idx].resultBufSize:
      completionErr = newException(IOError, "IPC: response buffer too small")
    elif idx >= 0:
      if pendingCalls[idx].resultPtr != nil and respLen > 0:
        let src = respAddr + 8
        let dst = cast[uint](pendingCalls[idx].resultPtr)
        var off = 0'u
        while off + 3 < respLen.uint:
          let word = regRead(src + off)
          cast[ptr uint32](dst + off)[] = word
          off += 4
        if off < respLen.uint:
          let word = regRead(src + off)
          for j in 0'u ..< (respLen.uint - off):
            cast[ptr uint8](dst + off + j)[] = ((word shr (j * 8)) and 0xFF).uint8
      if pendingCalls[idx].resultLen != nil:
        pendingCalls[idx].resultLen[] = respLen
  regWrite(respAddr, 0)
  sharedWriteBarrier()
  if idx >= 0:
    completePendingCall(token, completionErr)

proc ipcPoll*() =
  ## Poll for incoming IPC requests/responses.
  clearKernelSignal()
  # Check primary request/response slots
  processRequestAt(getIncomingReqAddr(), getOutgoingRespAddr())
  processResponseAt(getIncomingRespAddr())
  # M0 also checks LP slots
  when defined(bl808m0):
    processRequestAt(getIncomingReqAddrLP(), getOutgoingRespAddrLP())
    processResponseAt(getIncomingRespAddrLP())
  drainIpcCompletions()

proc ipcPollKeepAliveTick() =
  ## Periodic wakeup that keeps IPC request/response polling alive even
  ## if IRQ delivery stalls in emulation.
  ipcPoll()
  if ipcPollKeepAliveMs > 0:
    discard addTimerMs(ipcPollKeepAliveMs, ipcPollKeepAliveTick)
  else:
    ipcPollKeepAliveArmed = false

proc armIpcPollKeepAlive() =
  if ipcPollKeepAliveMs == 0 or ipcPollKeepAliveArmed:
    return
  ipcPollKeepAliveArmed = true
  discard addTimerMs(ipcPollKeepAliveMs, ipcPollKeepAliveTick)

proc ipcBridgeInit*() =
  ## Initialize the IPC bridge on this core.
  ## Call after schedulerInit() and ipcInit().
  rpcHandlerCount = 0
  nextToken = 1
  for i in 0 ..< MaxPendingCalls:
    pendingCalls[i].active = false
  for i in 0 ..< MaxIpcCompletions:
    ipcCompletionKinds[i] = ipcCompleteNone
    ipcCompletionVoidFuts[i] = nil
    ipcCompletionU32Futs[i] = nil
    ipcCompletionValues[i] = 0
    ipcCompletionErrors[i] = nil
  ipcCompletionHead = 0
  ipcCompletionTail = 0
  ipcCompletionCount = 0
  ipcCompletionOverflows = 0

  # Note: XRAM kernel region is cleared by QEMU at init (g_malloc0).
  # Don't clear here — the other core may have already written data.

  # Register IPC ISR
  when defined(bl808m0):
    registerTrapHandler(IrqM0Ipc, ipcKernelHandler)
    irqEnable(IrqM0Ipc)
    irqSetLevel(IrqM0Ipc, 1)
    # Also enable LP→M0 IPC interrupt
    registerTrapHandler(IrqM0IpcLp, ipcKernelHandler)
    irqEnable(IrqM0IpcLp)
    irqSetLevel(IrqM0IpcLp, 1)
    let mie = csrReadMie()
    csrWriteMie(mie or (1'u shl 11))
  elif defined(bl808d0):
    registerTrapHandler(IrqD0Ipc, ipcKernelHandler)
    plicEnableIrq(IrqD0Ipc)
    plicSetPriority(IrqD0Ipc, 1)
    let mie = csrReadMie()
    csrWriteMie(mie or (1'u shl 11))
  elif defined(bl808lp):
    # LP uses CLIC, IPC interrupt from M0
    # LP's IPC IRQ number — check irq.nim for the correct value
    # For now, use the generic IPC IRQ (same mechanism as M0)
    registerTrapHandler(IrqM0Ipc, ipcKernelHandler)
    irqEnable(IrqM0Ipc)
    irqSetLevel(IrqM0Ipc, 1)
    let mie = csrReadMie()
    csrWriteMie(mie or (1'u shl 11))

  # Register poll hook for scheduler fallback
  addSchedulerPollHook(proc() = ipcPoll())
  armIpcPollKeepAlive()

  # Initialize HAL-level IPC
  ipcInit()

# =============================================================================
# Client API — send a cross-core RPC call
# =============================================================================

type
  IpcWireSlot = object
    reqAddr: uint
    respAddr: uint
    target: IpcTarget

proc defaultWireSlot(): IpcWireSlot =
  IpcWireSlot(
    reqAddr: getOutgoingReqAddr(),
    respAddr: getIncomingRespAddr(),
    target: getRemoteCore())

proc wireSlotForTarget(target: IpcTarget): IpcWireSlot =
  ## Return the RPC slot for a concrete target core.
  ##
  ## M0 is the routed debug/control core for LP work. Direct D0↔LP RPC would
  ## need additional slot ownership rules before it can be enabled safely.
  when defined(bl808m0):
    case target
    of ipcD0:
      IpcWireSlot(reqAddr: XramM0toD0Req, respAddr: XramM0toD0Resp,
                  target: ipcD0)
    of ipcLP:
      IpcWireSlot(reqAddr: XramM0toLPReq, respAddr: XramM0toLPResp,
                  target: ipcLP)
    of ipcM0:
      IpcWireSlot()
  elif defined(bl808d0):
    case target
    of ipcM0:
      IpcWireSlot(reqAddr: XramD0toM0Req, respAddr: XramD0toM0Resp,
                  target: ipcM0)
    else:
      IpcWireSlot()
  elif defined(bl808lp):
    case target
    of ipcM0:
      IpcWireSlot(reqAddr: XramLPtoM0Req, respAddr: XramLPtoM0Resp,
                  target: ipcM0)
    else:
      IpcWireSlot()
  else:
    discard target
    IpcWireSlot()

proc wireSlotError(reqAddr, respAddr: uint): ref CatchableError =
  ## One XRAM request/response slot pair can carry one in-flight RPC.
  processResponseAt(respAddr)
  sharedReadBarrier()
  if wireSlotActive(reqAddr, respAddr):
    return newException(IOError, "IPC bridge: call already in flight")
  if reqAddr == 0 or respAddr == 0:
    return newException(IOError, "IPC bridge: invalid wire slot")
  if regRead(reqAddr) != 0:
    return newException(IOError, "IPC bridge: request slot busy")
  if regRead(respAddr) != 0:
    return newException(IOError, "IPC bridge: response slot busy")
  nil

proc ipcCallWire(slot: IpcWireSlot, tag: uint16, reqData: openArray[uint8],
                 respBuf: pointer, respBufSize: int,
                 respLen: ptr int,
                 timeoutMs: uint64): CpsVoidFuture =
  let maxWireLen = (XramSlotSize - 8).int
  if reqData.len > maxWireLen:
    return failedLocalVoidFuture(
      newException(IOError, "IPC bridge: request too large"))
  if respBufSize < 0 or respBufSize > maxWireLen:
    return failedLocalVoidFuture(
      newException(IOError, "IPC bridge: invalid response buffer size"))
  if respBufSize > 0 and respBuf == nil:
    return failedLocalVoidFuture(
      newException(IOError, "IPC bridge: response buffer is nil"))

  let slotErr = wireSlotError(slot.reqAddr, slot.respAddr)
  if slotErr != nil:
    return failedLocalVoidFuture(slotErr)

  let fut = newLocalCpsVoidFuture()
  let callIdx = allocPendingCall(fut, nil, respBuf, respBufSize, respLen,
                                 slot.reqAddr, slot.respAddr, timeoutMs)
  if callIdx < 0:
    return failedLocalVoidFuture(
      newException(IOError, "IPC bridge: no pending slots"))
  let token = pendingCalls[callIdx].token

  # Write request metadata/data first; publish token last as ready flag.
  regWrite(slot.reqAddr + 4, tag.uint32 or (reqData.len.uint32 shl 16))

  var off = 8'u
  var i = 0
  while i + 3 < reqData.len:
    let word = reqData[i].uint32 or
               (reqData[i+1].uint32 shl 8) or
               (reqData[i+2].uint32 shl 16) or
               (reqData[i+3].uint32 shl 24)
    regWrite(slot.reqAddr + off, word)
    off += 4
    i += 4
  if i < reqData.len:
    var word = 0'u32
    for j in 0 ..< reqData.len - i:
      word = word or (reqData[i+j].uint32 shl (j * 8))
    regWrite(slot.reqAddr + off, word)

  sharedWriteBarrier()
  regWrite(slot.reqAddr, token)
  sharedWriteBarrier()

  ipcSendSignal(slot.target, IpcSignalKernel.IpcSignal)
  armIpcPollKeepAlive()
  fut

proc ipcCallU32Wire(slot: IpcWireSlot, tag: uint16, arg: uint32,
                    timeoutMs: uint64): CpsFuture[uint32] =
  let slotErr = wireSlotError(slot.reqAddr, slot.respAddr)
  if slotErr != nil:
    return failedLocalFuture[uint32](slotErr)

  let fut = newLocalCpsFuture[uint32]()
  let callIdx = allocPendingCall(nil, fut, nil, 0, nil,
                                 slot.reqAddr, slot.respAddr, timeoutMs)
  if callIdx < 0:
    return failedLocalFuture[uint32](
      newException(IOError, "IPC bridge: no pending slots"))
  let token = pendingCalls[callIdx].token

  regWrite(slot.reqAddr + 4, tag.uint32 or (4'u32 shl 16))
  regWrite(slot.reqAddr + 8, arg)
  sharedWriteBarrier()
  regWrite(slot.reqAddr, token)
  sharedWriteBarrier()

  ipcSendSignal(slot.target, IpcSignalKernel.IpcSignal)
  armIpcPollKeepAlive()
  fut

proc ipcCall*(tag: uint16, reqData: openArray[uint8],
              respBuf: pointer, respBufSize: int,
              respLen: ptr int,
              timeoutMs: uint64 = IpcCallTimeoutMsDefault): CpsVoidFuture =
  ## Send an RPC request to the remote core and return a future
  ## that completes when the response arrives.
  ##
  ## `respBuf`/`respBufSize`: buffer to receive response data
  ## `respLen`: set to actual response length on completion
  ipcCallWire(defaultWireSlot(), tag, reqData, respBuf, respBufSize, respLen,
              timeoutMs)

proc ipcCallTo*(target: IpcTarget, tag: uint16, reqData: openArray[uint8],
                respBuf: pointer, respBufSize: int,
                respLen: ptr int,
                timeoutMs: uint64 = IpcCallTimeoutMsDefault): CpsVoidFuture =
  ## Send an RPC request to a concrete target core.
  ##
  ## Supported routes are M0→D0, M0→LP, D0→M0, and LP→M0.
  ipcCallWire(wireSlotForTarget(target), tag, reqData, respBuf, respBufSize,
              respLen, timeoutMs)

proc ipcCallU32*(tag: uint16, arg: uint32,
                 timeoutMs: uint64 = IpcCallTimeoutMsDefault): CpsFuture[uint32] =
  ## Send a uint32 argument to the default remote core and await a uint32 result.
  ## M0 → D0, D0 → M0, LP → M0.
  ipcCallU32Wire(defaultWireSlot(), tag, arg, timeoutMs)

proc ipcCallU32To*(target: IpcTarget, tag: uint16, arg: uint32,
                   timeoutMs: uint64 = IpcCallTimeoutMsDefault): CpsFuture[uint32] =
  ## Send a uint32 argument to a concrete target core and await a uint32 result.
  ##
  ## Supported routes are M0→D0, M0→LP, D0→M0, and LP→M0.
  ipcCallU32Wire(wireSlotForTarget(target), tag, arg, timeoutMs)

when defined(bl808m0):
  proc ipcCallLP*(tag: uint16, reqData: openArray[uint8],
                  respBuf: pointer, respBufSize: int,
                  respLen: ptr int,
                  timeoutMs: uint64 = IpcCallTimeoutMsDefault): CpsVoidFuture =
    ## Send an RPC request to LP (M0-only) and return a future.
    ipcCallTo(ipcLP, tag, reqData, respBuf, respBufSize, respLen, timeoutMs)

  proc ipcCallU32LP*(tag: uint16, arg: uint32,
                     timeoutMs: uint64 = IpcCallTimeoutMsDefault): CpsFuture[uint32] =
    ## Send a uint32 argument to LP and await a uint32 result (M0-only).
    ipcCallU32To(ipcLP, tag, arg, timeoutMs)
