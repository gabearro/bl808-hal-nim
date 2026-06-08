proc bl_rx_pkt_cb*(pkt: ptr uint8; len: cint; pktWrap: pointer; info: ptr BlRxInfo) {.exportc, cdecl.} =
  if cbPkt != nil:
    cbPkt(cbPktEnv, pkt, len, info)
  if cbPktAdv != nil:
    cbPktAdv(cbPktEnv, pktWrap, info)

proc bl_rx_pkt_cb_register*(env: pointer; cb: PktCb): cint {.exportc, cdecl.} =
  cbPkt = cb
  cbPktEnv = env
  0

proc bl_rx_pkt_cb_unregister*(env: pointer): cint {.exportc, cdecl.} =
  cbPkt = nil
  cbPktEnv = nil
  0

proc bl_rx_pkt_adv_cb_register*(env: pointer; cb: PktAdvCb): cint {.exportc, cdecl.} =
  cbPktAdv = cb
  cbPktEnv = env
  0

proc bl_rx_pkt_adv_cb_unregister*(env: pointer): cint {.exportc, cdecl.} =
  cbPktAdv = nil
  cbPktEnv = nil
  0
