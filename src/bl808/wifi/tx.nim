## Nim replacement for the BL808 WiFi host TX path in bl_tx.c.

when defined(bl808m0) and defined(bl808WifiNimFw):
  import sdk_headers

  include tx/layout
  include tx/types

  {.emit: "extern struct bl_hw wifi_hw;".}
  include tx/debug_state

  include tx/host_interfaces

  include tx/views

  include tx/packet_helpers

  include tx/layout_asserts

  include tx/queue

  include tx/confirm

  include tx/flush

  include tx/output

  proc bl_tx_cntrl_link_up*(sta: ptr BlSta) {.exportc, cdecl.} =
    txCntrlPurgeCheck(cast[pointer](sta), 1)

  proc bl_tx_cntrl_link_down*(sta: ptr BlSta) {.exportc, cdecl.} =
    txCntrlPurgeCheck(cast[pointer](sta), 0)
