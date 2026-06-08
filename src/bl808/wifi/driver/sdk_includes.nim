import ../sdk_headers

when defined(bl808WifiRealLwip):
  {.passC: "-Isrc/bl808/kernel/lwip_wifi_smoke".}
{.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/lwip/src/include".}
{.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/lwip/lwip-port".}
{.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/lwip/lwip-port/config".}
