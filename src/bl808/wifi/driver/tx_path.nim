proc blTxNotify(cbArg: pointer; txOk: bool) {.cdecl.} =
  discard cbArg
  discard txOk
  if taskHandleOutput != nil:
    blOsTaskNotify(taskHandleOutput)

proc wifiTx(netif: ptr Netif; txPbuf: ptr Pbuf): ErrT {.cdecl.} =
  trace("wifiTx")
  if txPbuf == nil:
    trace("wifiTx nil")
    return ErrIf
  if txPbuf.tot_len > WifiMtuSize:
    trace("wifiTx mtu")
    return ErrIf
  if taskHandleOutput == nil:
    taskHandleOutput = blOsTaskGetCurrentTask()

  var customCfm = BlTxCfm(cb: blTxNotify, cb_arg: nil)
  let isSta = if netif == wifi_mgmr_sta_netif_get(): 1.cint else: 0.cint
  bl_output(bl606a0StaHw, isSta, txPbuf, addr customCfm)

proc bl_wifi_eth_tx*(txPbuf: ptr Pbuf; isSta: bool; customCfm: ptr BlTxCfm): cint
    {.exportc, cdecl.} =
  {.emit: """
  extern volatile unsigned int nimfw_dbg_eth_tx_eapol;
  extern volatile unsigned int nimfw_dbg_eth_tx_ret;
  nimfw_dbg_eth_tx_eapol++;
  """.}
  trace("bl_wifi_eth_tx")
  let txOutputStatus =
    bl_output(bl606a0StaHw, (if isSta: 1.cint else: 0.cint), txPbuf, customCfm)
  {.emit: ["nimfw_dbg_eth_tx_ret = (unsigned int)", txOutputStatus, ";"].}
  if txOutputStatus == ErrOk:
    arch_delay_us(1000)
    0
  else:
    -1
