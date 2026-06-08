{.passC: "-DBL808 -DCPU_M0 -DCFG_CHIP_BL808 -DCFG_TXDESC=4 -DCFG_STA_MAX=1 -DCFG_VIRT_DEV_MAX=2".}
{.passC: "-DBL_CHIP_NAME=\"BL808\" -D__FILENAME__=__FILE__ -DBL808_WIFI_VENDOR_FULL_SUPPLICANT -DUSE_MBEDTLS_CRYPTO -include sys/types.h".}
when defined(bl808WifiConnectCfg80211Flags):
  {.passC: "-DBL808_WIFI_CONNECT_CRYPTO_PARAMS -DBL808_WIFI_CONNECT_CFG80211_FLAGS".}
{.passC: "-DBL808_WIFI_NIM_FW".}
when defined(bl808WifiTrace):
  {.passC: "-DBL808_WIFI_TRACE".}
when defined(bl808WifiConnectTrace):
  {.passC: "-DBL808_WIFI_CONNECT_TRACE".}
when defined(bl808WifiConnectTraceRawRx):
  {.passC: "-DBL808_WIFI_CONNECT_TRACE_RAW_RX".}
when defined(bl808WifiConnectCacheHint):
  {.passC: "-DBL808_WIFI_CONNECT_CACHE_HINT".}
when defined(bl808WifiVerboseConnect):
  {.passC: "-DBL808_WIFI_VERBOSE_CONNECT".}
when defined(bl808WifiVerboseScan):
  {.passC: "-DBL808_WIFI_VERBOSE_SCAN".}
# The connection wrapper asks for PMF-capable association by default.
# Keep the supplicant's 802.11w code compiled so WPA3-transition APs can see
# MFPC and the group management cipher in the generated RSN IE. This does not
# force PMF-required or SAE.
{.passC: "-DCONFIG_IEEE80211W".}
when defined(bl808WifiForcePmfCapable):
  # Forces smF |= 0x600 (PMF-cap bits) on every scanned BSS in
  # wifi_fw.nim's scanu path so APs that advertise PMF-required are
  # reachable. Also enables the SAE/SHA256 supplicant code for explicit
  # WPA3 probe builds. Real WPA3-SAE association remains outside this default.
  {.passC: "-DCONFIG_WPA3_SAE -DCONFIG_SHA256".}
when defined(bl808WifiForceAckMode):
  {.passC: "-DBL808_WIFI_FORCE_ACK_MODE".}
when defined(bl808WifiForceMacTiming80MHz):
  {.passC: "-DBL808_WIFI_FORCE_MAC_TIMING_80MHZ".}
when defined(bl808WifiForceVifOwnMac):
  {.passC: "-DBL808_WIFI_FORCE_VIF_OWN_MAC".}
when defined(bl808WifiKeepBcnBit5):
  {.passC: "-DBL808_WIFI_KEEP_BCN_BIT5".}
when defined(bl808WifiForcePtaWlan):
  {.passC: "-DBL808_WIFI_FORCE_PTA_WLAN".}
when defined(bl808WifiValidationLog):
  {.passC: "-DBL808_WIFI_VENDOR_LOG_TO_VALIDATION_BUFFER".}
when defined(bl808WifiOfficialPowerProfile):
  {.passC: "-DBL808_WIFI_VENDOR_OFFICIAL_POWER_PROFILE".}
when defined(bl808WifiUseBl808Rf):
  {.passC: "-DBL808_WIFI_VENDOR_USE_BL808_RF".}
when defined(bl808WifiConnectPassphraseOnly):
  {.passC: "-DBL808_WIFI_CONNECT_PASSPHRASE_ONLY".}
when defined(bl808WifiConnectHexPmkAsPassphrase):
  {.passC: "-DBL808_WIFI_CONNECT_HEX_PMK_AS_PASSPHRASE".}
when defined(bl808WifiConnectDerivePmk):
  {.passC: "-DBL808_WIFI_CONNECT_DERIVE_PMK".}
when defined(bl808WifiForceTxPwr20):
  {.passC: "-DBL808_WIFI_FORCE_TX_POWER=0x20".}
when defined(bl808WifiForceTxPwr30):
  {.passC: "-DBL808_WIFI_FORCE_TX_POWER=0x30".}
when defined(bl808WifiForceTxPwr70):
  {.passC: "-DBL808_WIFI_FORCE_TX_POWER=0x70".}
when defined(bl808WifiForceRespTxPwr70):
  {.passC: "-DBL808_WIFI_FORCE_RESP_TX_POWER=0x70".}
when defined(bl808WifiForceRespTxPwr70All):
  {.passC: "-DBL808_WIFI_FORCE_RESP_TX_POWER=0x70 -DBL808_WIFI_FORCE_RESP_TX_POWER_ALL".}
{.passC: "-fcommon -fshort-enums -Wno-incompatible-pointer-types -Wno-int-conversion -Wno-implicit-function-declaration".}
