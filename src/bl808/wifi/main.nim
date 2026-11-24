## Nim replacement for the BL808 WiFi host-driver top-level glue in bl_main.c.
##
## This module owns the global `wifi_hw` object and exports the bl_main_*
## entry points while lower message/TX/RX units are still being ported.

when defined(bl808m0) and defined(bl808WifiNimFw):
  import sdk_headers
  import host_table_layout
  when defined(bl808WifiApHttpSmoke):
    from ../memmap import ClicMtimeBase
    from ../mmio import regRead
  include main/layout
  include main/types

  {.emit: "struct bl_hw wifi_hw;".}
  const hostTableChecks = """
#include <stddef.h>
_Static_assert(NX_VIRT_DEV_MAX == $1, "BL808 host VIF count");
_Static_assert(NX_REMOTE_STA_MAX == $2, "BL808 host peer count");
_Static_assert(NX_REMOTE_STA_STORE_MAX == $3, "BL808 host station table count");
_Static_assert(sizeof(struct bl_sta) == $4, "BL808 host station entry size");
_Static_assert(offsetof(struct bl_hw, sta_table) == $5, "BL808 host station table offset");
_Static_assert(offsetof(struct bl_hw, mod_params) == $6, "BL808 host mod_params offset");
_Static_assert(offsetof(struct bl_hw, ht_cap) == $7, "BL808 host ht_cap offset");
"""
  from std/strutils import `%`
  {.emit: hostTableChecks % [$WifiHostVifCount, $WifiHostPeerCount, $WifiHostStaTableCount,
    $WifiHostStaEntrySize, $WifiHostStaTableOffset, $WifiHostModParamsOffset, $WifiHostHtCapOffset].}
  var wifi_hw {.importc, header: "bl_defs.h".}: BlHw
  var bl_mod_params {.importc, header: "bl_mod_params.h".}: BlModParams

  include main/trace

  include main/host_interfaces

  proc bl_cfg80211_connect*(blHw: ptr BlHw; sme: ptr Cfg80211ConnectParams): cint
      {.exportc, cdecl.}

  include main/accessors

  include main/host_ops
  include main/startup
