## Nim replacement for the SDK WiFi driver glue in bl60x_wifi_driver/wifi.c.
##
## This module owns the netif init and TX forwarding ABI used by the remaining
## SDK WiFi manager/supplicant scaffolding.

when defined(bl808m0) and defined(bl808WifiNimFw):
  include driver/sdk_includes
  include driver/layout
  include driver/c_types
  include driver/state

  include driver/host_interfaces

  include driver/ops_accessors

  include driver/tx_path
  include driver/netif
  include driver/hostname
  include driver/init
