type IpcHostDispatchScope* = object
  previous: ptr IpcHostDispatchScope
  env, shared: pointer
  cancelled, registered: bool

var ipcHostActiveDispatch: ptr IpcHostDispatchScope

template ipcHostIrqSave*(): uint32 =
  block:
    var saved {.gensym.}: uint32
    {.emit: ["asm volatile(\"csrrci %0, mstatus, 8\" : \"=r\"(", saved,
              ") :: \"memory\");"].}
    saved

template ipcHostIrqRestore*(saved: uint32) =
  {.emit: "asm volatile(\"\" ::: \"memory\");".}
  if (saved and 8) != 0:
    {.emit: "asm volatile(\"csrsi mstatus, 8\" ::: \"memory\");".}

proc beginIpcHostDispatch*(scope: var IpcHostDispatchScope; env: pointer): bool =
  let saved = ipcHostIrqSave()
  defer: ipcHostIrqRestore(saved)
  if env == nil or scope.registered:
    return false
  scope = IpcHostDispatchScope(previous: ipcHostActiveDispatch,
    env: env, shared: loadPtr(env, EnvSharedOff), registered: true)
  ipcHostActiveDispatch = addr scope
  true

proc endIpcHostDispatch*(scope: var IpcHostDispatchScope) =
  let saved = ipcHostIrqSave()
  defer: ipcHostIrqRestore(saved)
  if not scope.registered:
    return
  var link = addr ipcHostActiveDispatch
  while link[] != nil:
    if link[] == addr scope:
      link[] = scope.previous
      break
    link = addr link[].previous
  scope.registered = false

proc ipcHostDispatchCurrent*(scope: var IpcHostDispatchScope;
                             env: pointer): bool {.inline.} =
  scope.registered and not scope.cancelled and scope.env == env and
    scope.shared == loadPtr(env, EnvSharedOff)

proc ipcHostInvalidate(env, shared: pointer) =
  # A reset may reuse either the environment or its shared descriptor pool.
  var scope = ipcHostActiveDispatch
  while scope != nil:
    if scope.env == env or scope.shared == shared:
      scope.cancelled = true
    scope = scope.previous
