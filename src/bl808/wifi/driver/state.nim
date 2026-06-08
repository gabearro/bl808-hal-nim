var
  taskHandleOutput: pointer
  bl606a0StaHw: pointer
  wifiMgmr {.importc: "wifiMgmr", header: "wifi_mgmr.h".}: WifiMgmr
  g_bl_ops_funcs {.importc, header: "bl_os_adapter/bl_os_adapter.h".}: BlOpsFuncs
