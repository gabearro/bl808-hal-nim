static:
  doAssert sizeof(PbufView) == 12
  doAssert offsetof(PbufView, payload) == 4
  doAssert offsetof(PbufView, totLen) == 8
  doAssert offsetof(PbufView, len) == 10
  doAssert sizeof(EthernetHeaderView) == 14
  doAssert offsetof(EthernetHeaderView, src) == 6
  doAssert offsetof(EthernetHeaderView, ethertype) == 12
  doAssert offsetof(Ipv4HeaderView, protocol) == 9
  doAssert offsetof(Ipv4HeaderView, optionsAndPayload) == 20
  doAssert sizeof(UdpHeaderView) == 8
  doAssert offsetof(UdpHeaderView, dstPort) == 2
  doAssert sizeof(CoListView) == 8
  doAssert offsetof(BlVifView, netifDev) == int(BlVifDevOff)
  doAssert offsetof(BlVifView, isUp) == int(BlVifUpOff)
  doAssert offsetof(BlVifView, vifIdx) == int(BlVifVifIdxOff)
  doAssert offsetof(BlVifView, linksNum) == int(BlVifLinksNumOff)
  doAssert offsetof(BlVifView, fixedStaIdx) == int(BlVifFixedStaIdxOff)
  doAssert offsetof(BlVifView, fcChan) == int(BlVifFcChanOff)
  doAssert offsetof(BlVifView, staPsMode) == int(BlVifStaPsOff)
  doAssert offsetof(BlStaView, waitingList) == int(BlStaWaitingListOff)
  doAssert offsetof(BlStaView, pendingList) == int(BlStaPendingListOff)
  doAssert offsetof(BlStaView, macAddr) == int(BlStaAddrOff)
  doAssert offsetof(BlStaView, isUsed) == int(BlStaIsUsedOff)
  doAssert offsetof(BlStaView, staIdx) == int(BlStaStaIdxOff)
  doAssert offsetof(BlStaView, vifIdx) == int(BlStaVifIdxOff)
  doAssert offsetof(BlStaView, fcPs) == int(BlStaFcPsOff)
  doAssert offsetof(BlStaView, qos) == int(BlStaQosOff)
  doAssert offsetof(BlStaView, rssi) == int(BlStaRssiOff)
  doAssert offsetof(BlStaView, dataRate) == int(BlStaDataRateOff)
  doAssert offsetof(BlStaView, tsfLo) == int(BlStaTsfloOff)
  doAssert offsetof(BlStaView, tsfHi) == int(BlStaTsfhiOff)
  doAssert offsetof(BlHwView, ipcEnv) == int(BlHwIpcEnvOff)
  doAssert offsetof(BlHwView, vifs) == int(BlHwVifTableOff)
  doAssert offsetof(BlHwView, stas) == int(BlHwStaTableOff)
  doAssert offsetof(KeTxFcView, vifBits) == int(KeTxFcVifBitsOff)
  doAssert offsetof(KeTxFcView, apFcChan) == int(KeTxFcApFcChanOff)
  doAssert offsetof(KeTxFcView, apFcPsStaBits) == int(KeTxFcApFcPsStaBitsOff)
  doAssert offsetof(KeTxFcView, staFcChan) == int(KeTxFcStaFcChanOff)
  doAssert offsetof(KeTxFcView, staFcPs) == int(KeTxFcStaFcPsOff)
  doAssert offsetof(TxHdrView, cfmCb) == int(TxHdrCustomCfmOff + TxCfmCbOff)
  doAssert offsetof(TxHdrView, cfmArg) == int(TxHdrCustomCfmOff + TxCfmCbArgOff)
  doAssert offsetof(TxHdrView, status) == int(TxHdrStatusOff)
  doAssert offsetof(TxHdrView, pbuf) == int(TxHdrPbufOff)
  doAssert offsetof(TxHdrView, len) == int(TxHdrLenOff)
  doAssert offsetof(TxHdrView, vifStaRepush) == int(TxHdrVifStaRepushOff)
  doAssert offsetof(TxbufView, hostBuf) == int(TxbufHostBufOff)
  doAssert offsetof(TxdescHostView, hostDescPadding) == int(TxdescHostPadTxdescOff)
  doAssert offsetof(TxdescHostView, upperHost) == int(TxdescHostPadTxdescOff + TxdescUpperHostOff)
  doAssert offsetof(HostTxDescView, pbufAddr) == 0
  doAssert offsetof(HostTxDescView, packetAddr) == 4
  doAssert offsetof(HostTxDescView, packetLen) == 8
  doAssert offsetof(HostTxDescView, statusAddr) == 12
  doAssert offsetof(HostTxDescView, ethDest) == 16
  doAssert offsetof(HostTxDescView, ethSrc) == 22
  doAssert offsetof(HostTxDescView, ethertype) == 28
  doAssert offsetof(HostTxDescView, tid) == 42
  doAssert offsetof(HostTxDescView, vifIdx) == 43
  doAssert offsetof(HostTxDescView, vifType) == 44
  doAssert offsetof(HostTxDescView, staId) == 45
  doAssert offsetof(HostTxDescView, flags) == 46
  doAssert offsetof(HostTxDescView, pbufChainedPtr) == 48
  doAssert offsetof(HostTxDescView, pbufChainedLen) == 64
