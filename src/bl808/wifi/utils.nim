## Nim replacement for the BL808 WiFi host utility glue in bl_utils.c.
##
## This removes the SDK utility translation unit from Nim firmware builds. The
## TCP/IP RX upload defaults to the conservative BL808 mempool path: the lower
## layer keeps ownership of WiFi descriptors and buffers. The experimental lwIP
## pbuf delivery path can be enabled with -d:bl808WifiRxPbufInput.

when defined(bl808m0) and defined(bl808WifiNimFw):
  import sdk_headers

  include utils/layout
  include utils/types
  include utils/host_interfaces
  include utils/accessors

  include utils/ipc_callbacks

  when defined(bl808WifiRxPbufInput):
    include utils/tcpip_pbuf_diag

  include utils/tcpip_diag

  include utils/ipc_init

  proc bl_utils_dump*() {.exportc, cdecl.} =
    discard

  include utils/tcpip_input
