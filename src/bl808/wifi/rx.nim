## Nim replacement for the BL808 WiFi host RX/event dispatch path in bl_rx.c.

when defined(bl808m0) and defined(bl808WifiNimFw):
  import sdk_headers

  include rx/layout
  include rx/types

  {.emit: "extern struct bl_hw wifi_hw;".}
  include rx/callback_state

  include rx/host_interfaces

  include rx/accessors

  include rx/scan_events

  include rx/control_events

  include rx/status_codes

  include rx/station_events

  include rx/ap_events

  include rx/dispatch

  include rx/callback_registers
