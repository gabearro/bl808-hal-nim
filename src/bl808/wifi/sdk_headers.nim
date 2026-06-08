## C header search paths needed by pure-Nim WiFi HAL replacements.
##
## The implementation is Nim, but many entry points still use importc C
## structs/prototypes to preserve the SDK ABI while the HAL is being split.

when defined(bl808m0) and defined(bl808WifiNimFw):
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/include".}
