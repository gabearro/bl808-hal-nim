## Nim replacement for the remaining bare-metal WiFi support glue.
##
## This replaces src/bl808/wifi_vendor_support.c for NimFW builds. It owns the
## OS-adapter function table, minimal lwIP/pbuf shims, WiFi manager facade, and
## host/firmware polling loop used by the hardware validation tests.

when defined(bl808m0) and defined(bl808WifiNimFw):
  import sdk_headers
  import ../wifi_fw

  include support/defs
  include support/state
  include support/host_interfaces
  include support/accessors
  include support/forwards

  include support/delay

  include support/vendor_console

  include support/os_adapter
  include support/scan_diag
  include support/wireless_domain
  include support/backend_irq

  include support/backend_startup

  include support/backend_runtime

  include support/platform_exports

  include support/lwip_facade

  include support/runtime_facade
  include support/utils_facade

  include support/mgmr_facade
