proc bl_rx_pkt_cb*(pkt: ptr uint8; len: cint; pktWrap: pointer; info: ptr BlRxInfo) {.exportc, cdecl.} =
  let callbacks = block:
    let saved = callbackIrqSave()
    defer: callbackIrqRestore(saved)
    (basic: snapshotCallback(cbPkt), advanced: snapshotCallback(cbPktAdv))
  if claimCallback(cbPkt, callbacks.basic):
    callbacks.basic.handler(callbacks.basic.context, pkt, len, info)
  if claimCallback(cbPktAdv, callbacks.advanced):
    callbacks.advanced.handler(callbacks.advanced.context, pktWrap, info)

proc bl_rx_pkt_cb_register*(env: pointer; cb: PktCb): cint {.exportc, cdecl.} =
  setCallback(cbPkt, cb, env)
  0

proc bl_rx_pkt_cb_unregister*(env: pointer): cint {.exportc, cdecl.} =
  clearCallback(cbPkt)
  0

proc bl_rx_pkt_adv_cb_register*(env: pointer; cb: PktAdvCb): cint {.exportc, cdecl.} =
  setCallback(cbPktAdv, cb, env)
  0

proc bl_rx_pkt_adv_cb_unregister*(env: pointer): cint {.exportc, cdecl.} =
  clearCallback(cbPktAdv)
  0
