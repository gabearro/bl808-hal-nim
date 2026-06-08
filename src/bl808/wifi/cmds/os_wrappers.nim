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
