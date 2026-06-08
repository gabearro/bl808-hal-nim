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
