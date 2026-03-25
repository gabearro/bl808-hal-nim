## BL808 WiFi driver interface (WiFi4 stack).
##
## The BL808 M0 core uses the WiFi4 stack (shared with BL602).
## The radio MAC/PHY is provided as precompiled binary blobs:
##   - libfirmware.a (WiFi4 LMAC/UMAC)
##   - libbl602_phyrf.a (PHY/RF radio control)
##
## Link flags: --passL:"-lfirmware -lbl602_phyrf"
##
## WiFi runs on the M0 (E907) core. The D0/LP cores communicate
## with WiFi through IPC if needed.
##
## The WiFi manager integrates with lwIP for TCP/IP networking.
## Call `wifi_mgmr_sta_netif_get()` to get the lwIP netif for the STA interface.

import mmio, memmap

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

  WifiScanResult* = object
    ssid*: array[33, char]
    bssid*: array[6, uint8]
    channel*: uint8
    rssi*: int8
    authMode*: WifiAuthMode

# =============================================================================
# WiFi C opaque types
# =============================================================================
type
  WifiInterface* = pointer  ## Opaque wifi_interface_t from SDK

  WifiConf* {.importc: "wifi_conf_t", header: "wifi_mgmr_ext.h".} = object
    ## WiFi configuration structure.

  ApConnectAdv* {.importc: "ap_connect_adv_t", header: "wifi_mgmr_ext.h".} = object
    ## Advanced AP connection parameters.

# =============================================================================
# WiFi4 Manager C API (from wifi_mgmr_ext.h, libfirmware.a)
#
# These resolve at link time against libfirmware.a + libbl602_phyrf.a
# =============================================================================
when defined(bl808m0):

  # --- Initialization ---
  proc wifi_mgmr_init*(conf: ptr WifiConf): cint
    {.importc, cdecl.}

  proc wifi_mgmr_sta_enable*(): WifiInterface
    {.importc, cdecl.}
    ## Enable STA mode. Returns interface handle.

  # --- Station connect/disconnect ---
  proc wifi_mgmr_sta_connect*(iface: ptr WifiInterface,
                               ssid: cstring, psk: cstring, pmk: cstring,
                               mac: ptr uint8, band: uint8, chan_id: uint8): cint
    {.importc, cdecl.}

  proc wifi_mgmr_sta_disconnect*(): cint
    {.importc, cdecl.}

  # --- Scanning ---
  proc wifi_mgmr_scan*(iface: ptr WifiInterface, cb: pointer): cint
    {.importc, cdecl.}

  # --- AP mode ---
  proc wifi_mgmr_ap_start*(iface: ptr WifiInterface,
                            ssid: cstring, hiddenSsid: cint,
                            passwd: cstring, channel: cint): cint
    {.importc, cdecl.}

  proc wifi_mgmr_ap_stop*(iface: ptr WifiInterface): cint
    {.importc, cdecl.}

  # --- Status ---
  proc wifi_mgmr_sta_netif_get*(): pointer
    {.importc, cdecl.}
    ## Returns struct netif* (lwIP network interface for STA).

  # --- PHY/RF (from libbl602_phyrf.a) ---
  proc phy_init*(cfg: pointer): cint
    {.importc, cdecl.}
    ## Initialize PHY. Called internally by wifi_mgmr_init.

  proc rf_init*(): cint
    {.importc, cdecl.}
    ## Initialize RF. Called internally by wifi_mgmr_init.

  # --- WiFi4 firmware internals (from libfirmware.a) ---
  proc bl_init*(): cint
    {.importc, cdecl.}
    ## Low-level WiFi firmware init.

# =============================================================================
# Higher-level Nim WiFi API (M0 only)
# =============================================================================
when defined(bl808m0):

  var staIface: WifiInterface

  proc wifiInit*(): WifiError =
    ## Initialize WiFi subsystem. Call once at startup.
    var conf: WifiConf
    let rc = wifi_mgmr_init(addr conf)
    if rc != 0: return wifiFail
    staIface = wifi_mgmr_sta_enable()
    if staIface == nil: return wifiFail
    wifiOk

  proc wifiConnect*(ssid, password: string, channel: uint8 = 0): WifiError =
    ## Connect to a WiFi AP.
    let rc = wifi_mgmr_sta_connect(
      addr staIface, ssid.cstring, password.cstring,
      nil, nil, 0, channel)
    if rc == 0: wifiOk else: wifiFail

  proc wifiDisconnect*(): WifiError =
    let rc = wifi_mgmr_sta_disconnect()
    if rc == 0: wifiOk else: wifiFail

  proc wifiStartAp*(ssid, password: string, channel: int = 1): WifiError =
    let rc = wifi_mgmr_ap_start(addr staIface, ssid.cstring,
                                 0, password.cstring, channel.cint)
    if rc == 0: wifiOk else: wifiFail

  proc wifiStopAp*(): WifiError =
    let rc = wifi_mgmr_ap_stop(addr staIface)
    if rc == 0: wifiOk else: wifiFail

  proc wifiGetNetif*(): pointer =
    ## Get the lwIP netif for the STA interface.
    ## Cast to `ptr NetIf` in your lwIP bindings.
    wifi_mgmr_sta_netif_get()

# =============================================================================
# RF register access
# =============================================================================
proc rfReadRevision*(): uint32 =
  regRead(RfRevId)
