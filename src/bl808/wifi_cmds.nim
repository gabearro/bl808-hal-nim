## Nim replacement for the BL808 WiFi host command manager.

const
  RwnxCmdMaxQueued = 8'u32
  RwnxCmdFlagNonblock = 1'u16 shl 0
  RwnxCmdFlagReqCfm = 1'u16 shl 1
  RwnxCmdFlagWaitPush = 1'u16 shl 2
  RwnxCmdFlagWaitAck = 1'u16 shl 3
  RwnxCmdFlagWaitCfm = 1'u16 shl 4
  RwnxCmdFlagDone = 1'u16 shl 5
  RwnxCmdMgrStateCrashed = 2'u32

  Eintr = 4'i32
  Enomem = 12'i32
  Epipe = 32'i32
  Etimedout = 110'i32

  BlHwIpcEnvOff = 0x30'u

  MgrStateOff = 0'u
  MgrNextTknOff = 4'u
  MgrQueueSzOff = 8'u
  MgrMaxQueueSzOff = 12'u
  MgrCmdsOff = 16'u
  MgrLockOff = 24'u
  MgrQueueOff = 28'u
  MgrLlindOff = 32'u
  MgrMsgindOff = 36'u
  MgrPrintOff = 40'u
  MgrDrainOff = 44'u

  CmdReqidOff = 10'u
  CmdA2eMsgOff = 12'u
  CmdE2aMsgOff = 16'u
  CmdTknOff = 20'u
  CmdFlagsOff = 24'u
  CmdCompleteOff = 28'u
  CmdResultOff = 32'u

  LmacMsgParamLenOff = 4'u
  LmacMsgHeaderLen = 8'u16

  IpcE2aMsgIdOff = 0'u
  IpcE2aMsgParamLenOff = 4'u
  IpcE2aMsgParamOff = 8'u

  OpEventGroupCreateOff = 36'u
  OpEventGroupDeleteOff = 40'u
  OpEventGroupSendOff = 44'u
  OpEventGroupWaitOff = 48'u
  OpMutexCreateOff = 148'u
  OpMutexLockOff = 156'u
  OpMutexUnlockOff = 160'u
  OpFreeOff = 188'u

type
  CmdQueueProc = proc(cmdMgr, cmd: pointer): cint {.cdecl.}
  CmdLlindProc = proc(cmdMgr, cmd: pointer): cint {.cdecl.}
  MsgCbProc = proc(blHw, cmd, msg: pointer): cint {.cdecl.}
  CmdMsgindProc = proc(cmdMgr, msg, cb: pointer): cint {.cdecl.}
  CmdVoidProc = proc(cmdMgr: pointer) {.cdecl.}

  EventGroupCreateProc = proc(): pointer {.cdecl.}
  EventGroupDeleteProc = proc(event: pointer) {.cdecl.}
  EventGroupSendProc = proc(event: pointer; bits: uint32): uint32 {.cdecl.}
  EventGroupWaitProc = proc(event: pointer; bits: uint32; clearOnExit, waitAll: cint;
                            ticks: uint32): uint32 {.cdecl.}
  MutexCreateProc = proc(): pointer {.cdecl.}
  MutexLockProc = proc(mutex: pointer): int32 {.cdecl.}
  MutexUnlockProc = proc(mutex: pointer): int32 {.cdecl.}
  FreeProc = proc(p: pointer) {.cdecl.}

var g_bl_ops_funcs {.importc.}: uint8

proc c_memcpy(dest, src: pointer; n: csize_t): pointer
  {.importc: "memcpy", header: "<string.h>", cdecl.}
proc ipc_host_msg_push(env, msgBuf: pointer; len: uint16): cint {.importc, cdecl.}

when defined(bl808WifiCmdTrace):
  proc c_printf(fmt: cstring): cint
    {.importc: "printf", header: "<stdio.h>", cdecl, varargs, discardable.}

template ptrAt(base: pointer; off: uint): pointer =
  cast[pointer](cast[uint](base) + off)

proc opPtr(off: uint): pointer {.inline.} =
  cast[ptr pointer](cast[uint](addr g_bl_ops_funcs) + off)[]

proc loadPtr(base: pointer; off: uint): pointer {.inline.} =
  cast[ptr pointer](ptrAt(base, off))[]

proc storePtr(base: pointer; off: uint; value: pointer) {.inline.} =
  cast[ptr pointer](ptrAt(base, off))[] = value

proc loadU16(base: pointer; off: uint): uint16 {.inline.} =
  cast[ptr uint16](ptrAt(base, off))[]

proc storeU16(base: pointer; off: uint; value: uint16) {.inline.} =
  cast[ptr uint16](ptrAt(base, off))[] = value

proc loadU32(base: pointer; off: uint): uint32 {.inline.} =
  cast[ptr uint32](ptrAt(base, off))[]

proc storeU32(base: pointer; off: uint; value: uint32) {.inline.} =
  cast[ptr uint32](ptrAt(base, off))[] = value

proc loadI32(base: pointer; off: uint): int32 {.inline.} =
  cast[ptr int32](ptrAt(base, off))[]

proc storeI32(base: pointer; off: uint; value: int32) {.inline.} =
  cast[ptr int32](ptrAt(base, off))[] = value

proc listNext(list: pointer): pointer {.inline.} = loadPtr(list, 0)
proc listPrev(list: pointer): pointer {.inline.} = loadPtr(list, 4)
proc listSetNext(list, value: pointer) {.inline.} = storePtr(list, 0, value)
proc listSetPrev(list, value: pointer) {.inline.} = storePtr(list, 4, value)

proc listInit(head: pointer) {.inline.} =
  listSetNext(head, head)
  listSetPrev(head, head)

proc listEmpty(head: pointer): bool {.inline.} =
  listNext(head) == head

proc listAddTail(node, head: pointer) {.inline.} =
  let prev = listPrev(head)
  listSetNext(node, head)
  listSetPrev(node, prev)
  listSetNext(prev, node)
  listSetPrev(head, node)

proc listDel(node: pointer) {.inline.} =
  let prev = listPrev(node)
  let next = listNext(node)
  listSetNext(prev, next)
  listSetPrev(next, prev)

proc osMutexCreate(): pointer {.inline.} =
  let fn = cast[MutexCreateProc](opPtr(OpMutexCreateOff))
  if fn == nil: nil else: fn()

proc osMutexLock(mutex: pointer) {.inline.} =
  let fn = cast[MutexLockProc](opPtr(OpMutexLockOff))
  if fn != nil:
    discard fn(mutex)

proc osMutexUnlock(mutex: pointer) {.inline.} =
  let fn = cast[MutexUnlockProc](opPtr(OpMutexUnlockOff))
  if fn != nil:
    discard fn(mutex)

proc osEventCreate(): pointer {.inline.} =
  let fn = cast[EventGroupCreateProc](opPtr(OpEventGroupCreateOff))
  if fn == nil: nil else: fn()

proc osEventDelete(event: pointer) {.inline.} =
  let fn = cast[EventGroupDeleteProc](opPtr(OpEventGroupDeleteOff))
  if fn != nil:
    fn(event)

proc osEventSend(event: pointer; bits: uint32) {.inline.} =
  let fn = cast[EventGroupSendProc](opPtr(OpEventGroupSendOff))
  if fn != nil:
    discard fn(event, bits)

proc osEventWait(event: pointer; bits: uint32): uint32 {.inline.} =
  let fn = cast[EventGroupWaitProc](opPtr(OpEventGroupWaitOff))
  if fn == nil: 0'u32 else: fn(event, bits, 1, 0, 0xffff_ffff'u32)

proc osFree(p: pointer) {.inline.} =
  let fn = cast[FreeProc](opPtr(OpFreeOff))
  if fn != nil:
    fn(p)

proc waitComplete(flags: uint16): bool {.inline.} =
  (flags and (RwnxCmdFlagWaitAck or RwnxCmdFlagWaitCfm)) == 0'u16

proc cmdMgrLock(cmdMgr: pointer) {.inline.} =
  osMutexLock(loadPtr(cmdMgr, MgrLockOff))

proc cmdMgrUnlock(cmdMgr: pointer) {.inline.} =
  osMutexUnlock(loadPtr(cmdMgr, MgrLockOff))

proc cmdComplete(cmdMgr, cmd: pointer) =
  when defined(bl808WifiCmdTrace):
    c_printf("[WIFI-CMD] complete cmd=%p id=0x%x req=0x%x flags=0x%x result=%d q=%u\r\n",
             cmd, loadU16(cmd, CmdReqidOff - 2'u).cuint, loadU16(cmd, CmdReqidOff).cuint,
             loadU16(cmd, CmdFlagsOff).cuint, loadI32(cmd, CmdResultOff).cint,
             loadU32(cmdMgr, MgrQueueSzOff).cuint)
  storeU32(cmdMgr, MgrQueueSzOff, loadU32(cmdMgr, MgrQueueSzOff) - 1'u32)
  listDel(cmd)
  let flags = loadU16(cmd, CmdFlagsOff) or RwnxCmdFlagDone
  storeU16(cmd, CmdFlagsOff, flags)
  if (flags and RwnxCmdFlagNonblock) != 0'u16:
    osFree(cmd)
  elif waitComplete(flags):
    storeI32(cmd, CmdResultOff, 0'i32)
    osEventSend(loadPtr(cmd, CmdCompleteOff), 1'u32)

proc pushCmdToFirmware(cmdMgr, cmd: pointer) =
  let blHw = cmdMgr
  let a2e = loadPtr(cmd, CmdA2eMsgOff)
  if a2e == nil:
    return
  let len = LmacMsgHeaderLen + loadU32(a2e, LmacMsgParamLenOff).uint16
  when defined(bl808WifiCmdTrace):
    c_printf("[WIFI-CMD] push cmd=%p id=0x%x req=0x%x tkn=%u flags=0x%x len=%u env=%p\r\n",
             cmd, loadU16(cmd, CmdReqidOff - 2'u).cuint, loadU16(cmd, CmdReqidOff).cuint,
             loadU32(cmd, CmdTknOff).cuint, loadU16(cmd, CmdFlagsOff).cuint,
             len.cuint, loadPtr(blHw, BlHwIpcEnvOff))
  let rc = ipc_host_msg_push(loadPtr(blHw, BlHwIpcEnvOff), cmd, len)
  when defined(bl808WifiCmdTrace):
    c_printf("[WIFI-CMD] push rc=%d cmd=%p\r\n", rc.cint, cmd)
  osFree(a2e)

proc cmdMgrQueue(cmdMgr, cmd: pointer): cint {.cdecl.} =
  var deferPush = false
  when defined(bl808WifiCmdTrace):
    c_printf("[WIFI-CMD] queue enter cmd=%p id=0x%x req=0x%x flags=0x%x q=%u\r\n",
             cmd, loadU16(cmd, CmdReqidOff - 2'u).cuint, loadU16(cmd, CmdReqidOff).cuint,
             loadU16(cmd, CmdFlagsOff).cuint, loadU32(cmdMgr, MgrQueueSzOff).cuint)
  cmdMgrLock(cmdMgr)

  if loadU32(cmdMgr, MgrStateOff) == RwnxCmdMgrStateCrashed:
    storeI32(cmd, CmdResultOff, Epipe)
    cmdMgrUnlock(cmdMgr)
    return -Epipe

  let head = ptrAt(cmdMgr, MgrCmdsOff)
  if not listEmpty(head):
    if loadU32(cmdMgr, MgrQueueSzOff) == loadU32(cmdMgr, MgrMaxQueueSzOff):
      storeI32(cmd, CmdResultOff, Enomem)
      cmdMgrUnlock(cmdMgr)
      return -Enomem
    let last = listPrev(head)
    if (loadU16(last, CmdFlagsOff) and (RwnxCmdFlagWaitAck or RwnxCmdFlagWaitPush)) != 0'u16:
      storeU16(cmd, CmdFlagsOff, loadU16(cmd, CmdFlagsOff) or RwnxCmdFlagWaitPush)
      deferPush = true

  var flags = loadU16(cmd, CmdFlagsOff) or RwnxCmdFlagWaitAck
  if (flags and RwnxCmdFlagReqCfm) != 0'u16:
    flags = flags or RwnxCmdFlagWaitCfm
  storeU16(cmd, CmdFlagsOff, flags)
  storeU32(cmd, CmdTknOff, loadU32(cmdMgr, MgrNextTknOff))
  storeU32(cmdMgr, MgrNextTknOff, loadU32(cmdMgr, MgrNextTknOff) + 1'u32)
  storeI32(cmd, CmdResultOff, Eintr)
  if (flags and RwnxCmdFlagNonblock) == 0'u16:
    storePtr(cmd, CmdCompleteOff, osEventCreate())

  listAddTail(cmd, head)
  storeU32(cmdMgr, MgrQueueSzOff, loadU32(cmdMgr, MgrQueueSzOff) + 1'u32)
  cmdMgrUnlock(cmdMgr)

  if not deferPush:
    pushCmdToFirmware(cmdMgr, cmd)

  if (loadU16(cmd, CmdFlagsOff) and RwnxCmdFlagNonblock) == 0'u16:
    let bits = osEventWait(loadPtr(cmd, CmdCompleteOff), 1'u32)
    when defined(bl808WifiCmdTrace):
      c_printf("[WIFI-CMD] wait done cmd=%p bits=0x%x flags=0x%x result=%d\r\n",
               cmd, bits.cuint, loadU16(cmd, CmdFlagsOff).cuint,
               loadI32(cmd, CmdResultOff).cint)
    if (bits and 1'u32) == 0'u32:
      cmdMgrLock(cmdMgr)
      storeU32(cmdMgr, MgrStateOff, RwnxCmdMgrStateCrashed)
      if (loadU16(cmd, CmdFlagsOff) and RwnxCmdFlagDone) == 0'u16:
        storeI32(cmd, CmdResultOff, Etimedout)
        cmdComplete(cmdMgr, cmd)
      cmdMgrUnlock(cmdMgr)
    osEventDelete(loadPtr(cmd, CmdCompleteOff))
  else:
    storeI32(cmd, CmdResultOff, 0'i32)
  0

proc cmdMgrPrint(cmdMgr: pointer) {.cdecl.} =
  discard cmdMgr

proc cmdMgrDrain(cmdMgr: pointer) {.cdecl.} =
  cmdMgrLock(cmdMgr)
  let head = ptrAt(cmdMgr, MgrCmdsOff)
  var node = listNext(head)
  while node != head:
    let next = listNext(node)
    listDel(node)
    storeU32(cmdMgr, MgrQueueSzOff, loadU32(cmdMgr, MgrQueueSzOff) - 1'u32)
    if (loadU16(node, CmdFlagsOff) and RwnxCmdFlagNonblock) == 0'u16:
      osEventSend(loadPtr(node, CmdCompleteOff), 1'u32)
    node = next
  cmdMgrUnlock(cmdMgr)

proc cmdMgrLlind(cmdMgr, cmd: pointer): cint {.cdecl.} =
  var acked: pointer = nil
  var nextCmd: pointer = nil
  when defined(bl808WifiCmdTrace):
    c_printf("[WIFI-CMD] ack enter hostid=%p tkn=%u flags=0x%x\r\n",
             cmd, loadU32(cmd, CmdTknOff).cuint, loadU16(cmd, CmdFlagsOff).cuint)
  cmdMgrLock(cmdMgr)
  let head = ptrAt(cmdMgr, MgrCmdsOff)
  var cur = listNext(head)
  while cur != head:
    if acked == nil:
      if loadU32(cur, CmdTknOff) == loadU32(cmd, CmdTknOff):
        acked = cur
        cur = listNext(cur)
        continue
    if (loadU16(cur, CmdFlagsOff) and RwnxCmdFlagWaitPush) != 0'u16:
      nextCmd = cur
      break
    cur = listNext(cur)

  if acked != nil:
    when defined(bl808WifiCmdTrace):
      c_printf("[WIFI-CMD] ack found acked=%p hostid=%p tkn=%u\r\n",
               acked, cmd, loadU32(cmd, CmdTknOff).cuint)
    let flags = loadU16(cmd, CmdFlagsOff) and not RwnxCmdFlagWaitAck
    storeU16(cmd, CmdFlagsOff, flags)
    if waitComplete(flags):
      cmdComplete(cmdMgr, cmd)

  if nextCmd != nil:
    storeU16(nextCmd, CmdFlagsOff, loadU16(nextCmd, CmdFlagsOff) and not RwnxCmdFlagWaitPush)
    pushCmdToFirmware(cmdMgr, nextCmd)
  cmdMgrUnlock(cmdMgr)
  0

proc cmdMgrMsgind(cmdMgr, msg, cbPtr: pointer): cint {.cdecl.} =
  let cb = cast[MsgCbProc](cbPtr)
  let blHw = cmdMgr
  var found = false
  when defined(bl808WifiCmdTrace):
    c_printf("[WIFI-CMD] msg enter msg=%p id=0x%x len=%u cb=%p\r\n",
             msg, loadU16(msg, IpcE2aMsgIdOff).cuint,
             loadU32(msg, IpcE2aMsgParamLenOff).cuint, cbPtr)

  cmdMgrLock(cmdMgr)
  let head = ptrAt(cmdMgr, MgrCmdsOff)
  var cmd = listNext(head)
  while cmd != head:
    if loadU16(cmd, CmdReqidOff) == loadU16(msg, IpcE2aMsgIdOff) and
        (loadU16(cmd, CmdFlagsOff) and RwnxCmdFlagWaitCfm) != 0'u16:
      if cb == nil or cb(blHw, cmd, msg) == 0:
        found = true
        when defined(bl808WifiCmdTrace):
          c_printf("[WIFI-CMD] msg found cmd=%p msgid=0x%x flags=0x%x\r\n",
                   cmd, loadU16(msg, IpcE2aMsgIdOff).cuint,
                   loadU16(cmd, CmdFlagsOff).cuint)
        let flags = loadU16(cmd, CmdFlagsOff) and not RwnxCmdFlagWaitCfm
        storeU16(cmd, CmdFlagsOff, flags)
        let e2a = loadPtr(cmd, CmdE2aMsgOff)
        let paramLen = loadU32(msg, IpcE2aMsgParamLenOff)
        if e2a != nil and paramLen != 0'u32:
          discard c_memcpy(e2a, ptrAt(msg, IpcE2aMsgParamOff), paramLen.csize_t)
        if waitComplete(flags):
          cmdComplete(cmdMgr, cmd)
        break
    cmd = listNext(cmd)
  cmdMgrUnlock(cmdMgr)

  if not found and cb != nil:
    discard cb(blHw, nil, msg)
  0

proc bl_cmd_mgr_init*(cmdMgr: pointer) {.exportc, cdecl.} =
  if cmdMgr == nil:
    return
  listInit(ptrAt(cmdMgr, MgrCmdsOff))
  storePtr(cmdMgr, MgrLockOff, osMutexCreate())
  storeU32(cmdMgr, MgrMaxQueueSzOff, RwnxCmdMaxQueued)
  storePtr(cmdMgr, MgrQueueOff, cast[pointer](cmdMgrQueue))
  storePtr(cmdMgr, MgrPrintOff, cast[pointer](cmdMgrPrint))
  storePtr(cmdMgr, MgrDrainOff, cast[pointer](cmdMgrDrain))
  storePtr(cmdMgr, MgrLlindOff, cast[pointer](cmdMgrLlind))
  storePtr(cmdMgr, MgrMsgindOff, cast[pointer](cmdMgrMsgind))
