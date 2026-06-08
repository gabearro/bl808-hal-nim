## Nim replacement for the BL808 WiFi host-driver top-level glue in bl_main.c.
##
## This module owns the global `wifi_hw` object and exports the bl_main_*
## entry points while lower message/TX/RX units are still being ported.

when defined(bl808m0) and defined(bl808WifiNimFw):
  import sdk_headers

  include main/layout
  include main/types

  {.emit: "struct bl_hw wifi_hw;".}
  var wifi_hw {.importc, header: "bl_defs.h".}: BlHw
  var bl_mod_params {.importc, header: "bl_mod_params.h".}: BlModParams

  include main/trace

  include main/host_interfaces

  proc bl_cfg80211_connect*(blHw: ptr BlHw; sme: ptr Cfg80211ConnectParams): cint
      {.exportc, cdecl.}

  include main/accessors

  include main/host_ops
  include main/startup
