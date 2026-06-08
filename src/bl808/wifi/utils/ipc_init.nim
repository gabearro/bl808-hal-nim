proc bl_ipc_init*(blHw: ptr BlHw; ipcSharedMem: ptr IpcSharedEnv): cint
    {.exportc, cdecl.} =
  cfgTrace2("[NIMFW] bl_ipc_init entry\r\n")
  if blHw == nil:
    cfgTrace2("[NIMFW] bl_ipc_init blHw=nil\r\n")
    return -1
  if ipcSharedMem == nil:
    cfgTrace2("[NIMFW] bl_ipc_init ipcSharedMem=nil\r\n")
    return -1

  var cb: array[8, pointer]
  cb[0] = cast[pointer](bl_tx_cfm)
  cb[1] = nil
  cb[2] = cast[pointer](bl_radarind)
  cb[3] = nil
  cb[4] = cast[pointer](bl_msgackind)
  cb[5] = cast[pointer](bl_dbgind)
  cb[6] = cast[pointer](bl_prim_tbtt_ind)
  cb[7] = cast[pointer](bl_sec_tbtt_ind)

  let env = c_malloc(IpcHostEnvSize.csize_t)
  if env == nil:
    cfgTrace2("[NIMFW] bl_ipc_init c_malloc=nil\r\n")
    return -1
  cfgTrace2("[NIMFW] bl_ipc_init malloc ok\r\n")
  discard c_memset(env, 0, IpcHostEnvSize.csize_t)
  storePtr(cast[pointer](blHw), BlHwIpcEnvOff, env)
  ipc_host_init(env, addr cb[0], ipcSharedMem, blHw)
  bl_cmd_mgr_init(blHw)
  cfgTrace2("[NIMFW] bl_ipc_init ok\r\n")
  0
