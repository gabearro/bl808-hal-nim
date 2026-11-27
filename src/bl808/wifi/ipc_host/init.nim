proc ipc_host_init*(env, cb, sharedEnv, pthis: pointer) {.exportc, cdecl.} =
  let saved = ipcHostIrqSave()
  defer: ipcHostIrqRestore(saved)
  ipcHostInvalidate(env, sharedEnv)
  inc ipcHostTxResources.generation
  discard c_memset(sharedEnv, 0, SharedEnvSize.csize_t)
  discard c_memset(env, 0, IpcHostEnvSize.csize_t)
  discard c_memcpy(env, cb, IpcHostCbSize.csize_t)

  storePtr(env, EnvSharedOff, sharedEnv)
  storePtr(env, EnvTxbufOff, ptrAt(sharedEnv, SharedTxbufOff))
  storePtr(env, EnvListFreeOff, ptrAt(sharedEnv, SharedListFreeOff))
  storePtr(env, EnvListOngoingOff, ptrAt(sharedEnv, SharedListOngoingOff))
  storePtr(env, EnvListCfmOff, ptrAt(sharedEnv, SharedListCfmOff))
  storePtr(env, EnvPthisOff, pthis)
  when defined(bl808WifiSplitTxSlots):
    ipcHostTxDmaInit(env)

  let freeList = loadPtr(env, EnvListFreeOff)
  let ongoingList = loadPtr(env, EnvListOngoingOff)
  let cfmList = loadPtr(env, EnvListCfmOff)
  listInit(freeList)
  listInit(ongoingList)
  listInit(cfmList)
  const hostSlots = (when defined(bl808WifiSplitTxSlots): WifiTxHostSlotCount
                     else: NxTxDescCnt.int)
  for sharedTxDescIndex in 0'u ..< min(hostSlots.uint, NxTxDescCnt.uint):
    listPushBack(
      freeList,
      ptrAt(sharedEnv, SharedTxdesc0Off + sharedTxDescIndex * SharedTxdescHostSize))
  when defined(bl808WifiSplitTxSlots):
    for credit in txHostCredits.mitems:
      listPushBack(freeList, addr credit)
