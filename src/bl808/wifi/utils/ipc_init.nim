proc bl_ipc_init*(blHw: ptr BlHw; ipcSharedMem: ptr IpcSharedEnv): cint
    {.exportc, cdecl.} =
  cfgTrace2("[NIMFW] bl_ipc_init entry\r\n")
  if blHw == nil:
    cfgTrace2("[NIMFW] bl_ipc_init blHw=nil\r\n")
    return -1
  if ipcSharedMem == nil:
    cfgTrace2("[NIMFW] bl_ipc_init ipcSharedMem=nil\r\n")
    return -1

  var ipcCallbacks: array[8, pointer]
  ipcCallbacks[0] = cast[pointer](bl_tx_cfm)
  ipcCallbacks[1] = nil
  ipcCallbacks[2] = cast[pointer](bl_radarind)
  ipcCallbacks[3] = nil
  ipcCallbacks[4] = cast[pointer](bl_msgackind)
  ipcCallbacks[5] = cast[pointer](bl_dbgind)
  ipcCallbacks[6] = cast[pointer](bl_prim_tbtt_ind)
  ipcCallbacks[7] = cast[pointer](bl_sec_tbtt_ind)

  let env = c_malloc(IpcHostEnvSize.csize_t)
  if env == nil:
    cfgTrace2("[NIMFW] bl_ipc_init c_malloc=nil\r\n")
    return -1
  cfgTrace2("[NIMFW] bl_ipc_init malloc ok\r\n")
  discard c_memset(env, 0, IpcHostEnvSize.csize_t)
  storePtr(cast[pointer](blHw), BlHwIpcEnvOff, env)
  ipc_host_init(env, addr ipcCallbacks[0], ipcSharedMem, blHw)
  bl_cmd_mgr_init(blHw)
  cfgTrace2("[NIMFW] bl_ipc_init ok\r\n")
  0
