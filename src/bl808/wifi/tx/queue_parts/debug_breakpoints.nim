proc nimFwDbgDhcpTxBreakpoint*() {.exportc: "nimfw_dbg_dhcp_tx_breakpoint",
    cdecl, noinline.} =
  inc nimFwDbgDhcpTxBreakHits

proc nimFwDbgDhcpRequestTxBreakpoint*()
    {.exportc: "nimfw_dbg_dhcp_request_tx_breakpoint", cdecl, noinline.} =
  inc nimFwDbgDhcpRequestTxBreakHits
