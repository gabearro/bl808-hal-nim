## Nim replacement for the BL808 WiFi host utility glue in bl_utils.c.
##
## This removes the SDK utility translation unit from Nim firmware builds. The
## Raw RX uploads are copied for the monitor callbacks. Ethernet delivery to
## lwIP is enabled with -d:bl808WifiRxPbufInput; lower-layer DMA descriptors
## remain separate from both kinds of copied packet.

when defined(bl808m0) and defined(bl808WifiNimFw):
  import sdk_headers
  import host_table_layout
  import ../wifi_fw as firmware
  from ../core import csrReadMstatus, disableInterrupts, enableInterrupts
  when defined(bl808WifiDiagTcpPath):
    import tcp_path_trace

  include utils/layout
  include utils/types
  include utils/host_interfaces
  include utils/accessors

  include utils/ipc_callbacks

  when defined(bl808WifiRxPbufInput):
    include utils/tcpip_pbuf_diag

  include utils/tcpip_diag
  include utils/monitor_input

  when defined(bl808WifiRxPbufInput):
    when defined(bl808WifiDiagDhcpTxAttempts):
      import dhcp_flow_trace
      from std/volatile import volatileLoad
      include utils/dhcp_rx_trace
    include utils/rx_delivery
    include utils/tcpip_pbuf_alloc_parts/amsdu_input

  include utils/ipc_init

  proc bl_utils_dump*() {.exportc, cdecl.} =
    discard

  include utils/tcpip_input
