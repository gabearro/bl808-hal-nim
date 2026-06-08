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
