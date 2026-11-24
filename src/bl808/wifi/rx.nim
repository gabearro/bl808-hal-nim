## Nim replacement for the BL808 WiFi host RX/event dispatch path in bl_rx.c.

when defined(bl808m0) and defined(bl808WifiNimFw):
  import sdk_headers
  import host_table_layout
  import ../wifi_fw as firmware
  from ../core import csrReadMstatus, disableInterrupts, enableInterrupts

  include rx/layout
  include rx/types
  include rx/callback_runtime

  {.emit: "extern struct bl_hw wifi_hw;".}
  include rx/callback_state

  include rx/host_interfaces

  include rx/accessors
  include rx/station_lifecycle

  include rx/scan_events

  include rx/control_events

  include rx/status_codes

  include rx/station_events

  include rx/ap_events

  include rx/dispatch

  include rx/callback_registers
