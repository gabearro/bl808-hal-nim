proc osMutexCreate(): pointer {.inline.} =
  let mutexCreate = cast[MutexCreateProc](opPtr(OpMutexCreateOff))
  if mutexCreate == nil: nil else: mutexCreate()

proc osMutexLock(mutex: pointer) {.inline.} =
  let mutexLock = cast[MutexLockProc](opPtr(OpMutexLockOff))
  if mutexLock != nil:
    discard mutexLock(mutex)

proc osMutexUnlock(mutex: pointer) {.inline.} =
  let mutexUnlock = cast[MutexUnlockProc](opPtr(OpMutexUnlockOff))
  if mutexUnlock != nil:
    discard mutexUnlock(mutex)

proc osEventCreate(): pointer {.inline.} =
  let eventGroupCreate = cast[EventGroupCreateProc](opPtr(OpEventGroupCreateOff))
  if eventGroupCreate == nil: nil else: eventGroupCreate()

proc osEventDelete(event: pointer) {.inline.} =
  let eventGroupDelete = cast[EventGroupDeleteProc](opPtr(OpEventGroupDeleteOff))
  if eventGroupDelete != nil:
    eventGroupDelete(event)

proc osEventSend(event: pointer; bits: uint32) {.inline.} =
  let eventGroupSend = cast[EventGroupSendProc](opPtr(OpEventGroupSendOff))
  if eventGroupSend != nil:
    discard eventGroupSend(event, bits)

proc osEventWait(event: pointer; bits: uint32): uint32 {.inline.} =
  let eventGroupWait = cast[EventGroupWaitProc](opPtr(OpEventGroupWaitOff))
  if eventGroupWait == nil:
    0'u32
  else:
    eventGroupWait(event, bits, 1, 0, 0xffff_ffff'u32)

proc osFree(p: pointer) {.inline.} =
  let freeFn = cast[FreeProc](opPtr(OpFreeOff))
  if freeFn != nil:
    freeFn(p)

proc waitComplete(flags: uint16): bool {.inline.} =
  (flags and (RwnxCmdFlagWaitAck or RwnxCmdFlagWaitCfm)) == 0'u16

proc cmdMgrLock(cmdMgr: pointer) {.inline.} =
  osMutexLock(loadPtr(cmdMgr, MgrLockOff))

proc cmdMgrUnlock(cmdMgr: pointer) {.inline.} =
  osMutexUnlock(loadPtr(cmdMgr, MgrLockOff))
