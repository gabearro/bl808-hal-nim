proc phy_init*(cfg: pointer)
  {.importc, cdecl.}
  ## Initialize PHY. Called internally by wifi_mgmr_init.

proc rf_init*(xtalfreqHz: uint32)
  {.importc, cdecl.}
  ## Initialize RF. Called internally by wifi_mgmr_init.

proc bl_init*(): cint
  {.importc, cdecl.}
  ## Low-level WiFi firmware init.
