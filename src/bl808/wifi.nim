## BL808 WiFi driver interface.
##
## The BL808 M0 WiFi path uses src/bl808/wifi_fw.nim as its firmware.
##
## Native firmware mode is the replacement path: src/bl808/wifi_fw.nim owns the
## firmware ABI. The remaining SDK C pieces in this file are host
## driver/supplicant scaffolding used while the Nim stack catches up.
##
## WiFi runs on the M0 (E907) core. The D0/LP cores communicate
## with WiFi through IPC if needed.
##
## The WiFi manager integrates with lwIP for TCP/IP networking.
## Call `wifi_mgmr_sta_netif_get()` to get the lwIP netif for the STA interface.

import mmio, memmap

when defined(bl808m0):
  import kernel/cps

when defined(bl808m0) and not defined(bl808WifiNimFw):
  {.error: "BL808 M0 WiFi now requires -d:bl808WifiNimFw; vendor firmware is no longer supported.".}

when defined(bl808m0):
  import wifi_fw
  import wifi/cmds
  import wifi/driver
  import wifi/hosal
  import wifi/ipc_host
  import wifi/irqs
  import wifi/support
  import wifi/main
  import wifi/msg_tx
  import wifi/mod_params
  import wifi/platform
  import wifi/rx
  import wifi/tx
  import wifi/utils

include wifi/facade_parts/public_types
include wifi/facade_parts/sdk_build_config
include wifi/facade_parts/backend_imports

# =============================================================================
# Higher-level Nim WiFi API (M0 only)
# =============================================================================
when defined(bl808m0):
  include wifi/facade_parts/runtime_wrappers
  include wifi/facade_parts/service_futures
  include wifi/facade_parts/coexistence_keepalive
  include wifi/facade_parts/station_api
  include wifi/facade_parts/ap_netif

# =============================================================================
# RF register access
# =============================================================================
proc rfReadRevision*(): uint32 =
  regRead(RfRevId)
