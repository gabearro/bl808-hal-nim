const
  RetryLimitReachedBit = 1'u32 shl 16
  FrameRepushablePsBit = 1'u32 shl 19
  FrameRepushableChanBit = 1'u32 shl 20
  FrameSuccessfulTxBit = 1'u32 shl 23
  DescDoneTxBit = 1'u32 shl 31

  BlVifSta = 0
  BlVifAp = 1
  NxRemoteStaStoreMax = 3
  PbufLinkEncapsulationHlen = 48'u16
  EthAlen = 6'u
  EthHdrSize = 14'u16
  LinkOffsetLen = PbufLinkEncapsulationHlen + EthHdrSize

  ErrOk = 0'i8
  ErrBuf = -2'i8
  ErrConn = -11'i8
  ErrIf = -12'i8

  BlHwIpcEnvOff = 48'u
  BlHwVifTableOff = 60'u
  BlHwStaTableOff = 100'u
  BlVifSize = 20'u
  BlVifVifIdxOff = 13'u
  BlVifLinksNumOff = 14'u
  BlVifFixedStaIdxOff = 15'u
  BlVifFcChanOff = 16'u
  BlStaSize = 40'u
  BlStaWaitingListOff = 0'u
  BlStaPendingListOff = 8'u
  BlStaAddrOff = 16'u
  BlStaIsUsedOff = 22'u
  BlStaStaIdxOff = 23'u
  BlStaVifIdxOff = 24'u
  BlStaFcPsOff = 26'u
  BlStaQosOff = 27'u

  TxCfmCbOff = 0'u
  TxCfmCbArgOff = 4'u
  TxCfmSize = 8'u
  TxHdrSize = 24'u
  TxHdrCustomCfmOff = 4'u
  TxHdrStatusOff = 12'u
  TxHdrPbufOff = 16'u
  TxHdrLenOff = 20'u
  TxHdrVifStaRepushOff = 22'u

  KeTxFcVifBitsOff = 0'u
  KeTxFcApFcChanOff = 1'u
  KeTxFcApFcPsStaBitsOff = 2'u
  KeTxFcStaFcChanOff = 3'u
  KeTxFcStaFcPsOff = 4'u

  TxdescHostPadTxdescOff = 12'u
  TxdescUpperHostOff = 4'u
  TxbufHostBufOff = 4'u
