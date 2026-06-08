# =============================================================================
# RF configuration registers (documented subset at MIX_BASE 0x20001000)
# =============================================================================
const
  RfRevId*          = MixBase + 0x000'u  # RF revision ID
  RfCtrl0*          = MixBase + 0x004'u  # RF control 0
  RfCtrl1*          = MixBase + 0x008'u  # RF control 1
  RfPaCtrl*         = MixBase + 0x100'u  # PA control
  RfTrxGainCtrl*    = MixBase + 0x104'u  # TRX gain control

# =============================================================================
# WiFi event types
# =============================================================================
type
  WifiEvent* = enum
    wifiEventConnected
    wifiEventDisconnected
    wifiEventScanDone
    wifiEventGotIp
    wifiEventApStarted
    wifiEventApStaJoined
    wifiEventApStaLeft

  WifiAuthMode* = enum
    wifiAuthOpen      = 0
    wifiAuthWep       = 1
    wifiAuthWpaPsk    = 2
    wifiAuthWpa2Psk   = 3
    wifiAuthWpaWpa2Psk = 4

  WifiError* = enum
    wifiOk            = 0
    wifiFail          = -1
    wifiTimeout       = -2
    wifiNotInit       = -3
    wifiBusy          = -4

  WifiScanResult* = object
    ssid*: array[33, char]
    bssid*: array[6, uint8]
    channel*: uint8
    rssi*: int8
    authMode*: WifiAuthMode

const
  wifiBleCoexWifiAlwaysOn* = 0'u32
  wifiBleCoexWifiPriority* = 1'u32
  wifiBleCoexBtPriority* = 2'u32

# =============================================================================
# WiFi C opaque types
# =============================================================================
type
  WifiInterface* = pointer  ## Opaque wifi_interface_t from SDK

  WifiConf* = object
    ## WiFi configuration structure.
    countryCode*: array[3, char]

  ApConnectAdv* = object
    ## Advanced AP connection parameters.
    channel*: uint8
