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
  import wifi_cmds
  import wifi_driver
  import wifi_hosal
  import wifi_ipc_host
  import wifi_irqs
  import wifi_support
  import wifi_main
  import wifi_msg_tx
  import wifi_mod_params
  import wifi_platform
  import wifi_rx
  import wifi_tx
  import wifi_utils

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

# =============================================================================
# WiFi manager host API (SDK scaffolding plus Nim firmware backend)
#
# Firmware symbols resolve to src/bl808/wifi_fw.nim. BL808 M0 builds reject the
# old firmware archive path.
# =============================================================================
when defined(bl808m0):
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
  {.passC: "-Isrc/bl808".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/include".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/wifi/include".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/wifi_hosal/include".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/lwip/src/include".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/lwip/lwip-port".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/lwip/lwip-port/arch".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/lwip/lwip-port/config".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/lwip/lwip-port/FreeRTOS".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/os/freertos_e907/include".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/os/freertos_e907/portable/GCC/RISC-V".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/platform/hosal/include".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/platform/hosal/bl808_e907_hal".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/platform/soc/bl808/bl808_e907_std/bl808_bsp_driver/std_drv/inc".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/platform/soc/bl808/bl808_e907_std/bl808_bsp_driver/regs".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/platform/soc/bl808/bl808_e907_std/bl808_bsp_driver/risc-v/Core/Include".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/os/bl_os_adapter/bl_os_adapter/include".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/os/bl_os_adapter/bl_os_adapter/include/bl_os_adapter".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/stage/yloop/include".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/include".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/include/bl_supplicant".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/include/utils".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/port/include".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/security/blcrypto_suite/inc".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/security/blcrypto_suite/priv_inc".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/security/mbedtls_lts/mbedtls/include".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/utils/include".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/dns_server/include".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/netutils/include".}
  when defined(bl808WifiConnectTrace):
    {.compile: "wifi_connect_trace.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/ap/ap_config.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/ap/wpa_auth_ie.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/ap/wpa_auth_rsn_ccmp_only.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/bl_supplicant/bl_hostap.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/bl_supplicant/bl_wpa3.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/bl_supplicant/bl_wpa_main.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/bl_supplicant/bl_wpas_glue.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/common/sae.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/common/wpa_common.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/aes-cbc.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/aes-internal-bl.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/aes-omac1.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/aes-unwrap.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/aes-wrap.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/crypto_internal-modexp.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/dh_group5.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/dh_groups.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/md5-internal.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/md5.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/rc4.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/sha1-internal.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/sha1-pbkdf2-bl.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/sha1.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/sha256-internal.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/sha256-prf.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/crypto/sha256.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/eap_peer/eap_common.c".}
  {.compile: "wifi_supplicant_wpa_overlay.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/rsn_supp/wpa_ie.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/utils/common.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/utils/wpa_debug.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/utils/wpabuf.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/blcrypto_suite/src/blcrypto_suite_aes.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/blcrypto_suite/src/blcrypto_suite_bignum.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/blcrypto_suite/src/blcrypto_suite_ecp.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/blcrypto_suite/src/blcrypto_suite_ecp_curves.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/blcrypto_suite/src/blcrypto_suite_hacc.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/blcrypto_suite/src/blcrypto_suite_hacc_glue.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/blcrypto_suite/src/blcrypto_suite_hacc_secp256r1_mul.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/blcrypto_suite/src/blcrypto_suite_platform_util.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/blcrypto_suite/src/blcrypto_suite_porting.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/blcrypto_suite/src/blcrypto_suite_supplicant_api.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/mbedtls_lts/mbedtls/library/aes.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/mbedtls_lts/mbedtls/library/md.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/mbedtls_lts/mbedtls/library/md5.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/mbedtls_lts/mbedtls/library/pkcs5.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/mbedtls_lts/mbedtls/library/ripemd160.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/mbedtls_lts/mbedtls/library/sha1.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/mbedtls_lts/mbedtls/library/sha256.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/mbedtls_lts/mbedtls/library/sha512.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/mbedtls_lts/mbedtls/library/platform.c".}
  {.compile: "build/bl_iot_sdk_b773b3f/components/security/mbedtls_lts/mbedtls/library/platform_util.c".}
  {.passL: "-Lsrc/bl808".}
  when defined(bl808WifiWrapWaitUs):
    {.passL: "-Wl,--wrap=wait_us".}
  when defined(bl808WifiConnectTrace):
    {.passL: "-Wl,--wrap=mm_active -Wl,--wrap=mm_hw_info_set -Wl,--wrap=mm_sec_machwaddr_wr -Wl,--wrap=sm_handle_eapol_input -Wl,--wrap=wpa_sm_rx_eapol -Wl,--wrap=txu_cntrl_push -Wl,--wrap=txl_cntrl_push -Wl,--wrap=txl_frame_push -Wl,--wrap=txl_frame_push_force -Wl,--wrap=txl_frame_cfm -Wl,--wrap=txl_cfm_push -Wl,--wrap=rxu_cntrl_frame_handle".}
  when defined(bl808WifiConnectTraceRawRx):
    {.passL: "-Wl,--wrap=rxl_cntrl_evt".}
  when defined(bl808WifiUseBl808Rf):
    {.passL: "-Wl,--start-group src/bl808/librf_bl808.a -Wl,--end-group".}
  else:
    {.passL: "-Wl,--start-group build/bl_iot_sdk_b773b3f/components/platform/soc/bl606p/bl606p_phyrf/lib/libbl606p_phyrf.a -Wl,--end-group".}

  var
    wifiInitialized: bool
    wifiApEnabled: bool

  # --- Initialization ---
  proc bl808_wifi_backend_init(conf: ptr WifiConf): cint
    {.importc: "bl808_wifi_backend_init", cdecl.}
  proc bl808_wifi_backend_poll*(iterations: uint32)
    {.importc: "bl808_wifi_backend_poll", cdecl.}
  proc bl808_wifi_backend_connected*(): cint
    {.importc: "bl808_wifi_backend_connected", cdecl.}
  proc bl808_wifi_backend_connect_done*(): cint
    {.importc: "bl808_wifi_backend_connect_done", cdecl.}
  proc bl808_wifi_backend_disconnect_done*(): cint
    {.importc: "bl808_wifi_backend_disconnect_done", cdecl.}
  proc bl808_wifi_backend_last_status*(): cint
    {.importc: "bl808_wifi_backend_last_status", cdecl.}
  proc bl808_wifi_backend_last_reason*(): cint
    {.importc: "bl808_wifi_backend_last_reason", cdecl.}
  proc bl808_wifi_backend_scan_count*(): uint32
    {.importc: "bl808_wifi_backend_scan_count", cdecl.}
  proc bl808_wifi_backend_scan_done_count*(): uint32
    {.importc: "bl808_wifi_backend_scan_done_count", cdecl.}
  proc bl808_wifi_backend_scan_diag_count*(): uint32
    {.importc: "bl808_wifi_backend_scan_diag_count", cdecl.}
  proc bl808_wifi_backend_scan_diag_get*(index: uint32,
                                         ssidLen: ptr uint8,
                                         ssid: ptr uint8,
                                         channel: ptr uint8,
                                         rssi: ptr int8,
                                         auth: ptr uint8,
                                         cipher: ptr uint8,
                                         bssid: ptr uint8): cint
    {.importc: "bl808_wifi_backend_scan_diag_get", cdecl.}
  proc bl808_wifi_backend_mac_irq_count*(): uint32
    {.importc: "bl808_wifi_backend_mac_irq_count", cdecl.}
  proc bl808_wifi_backend_mac_poll_irq_count*(): uint32
    {.importc: "bl808_wifi_backend_mac_poll_irq_count", cdecl.}
  proc bl808_wifi_backend_mac_trap_irq_count*(): uint32
    {.importc: "bl808_wifi_backend_mac_trap_irq_count", cdecl.}
  proc bl808_wifi_backend_ipc_trap_irq_count*(): uint32
    {.importc: "bl808_wifi_backend_ipc_trap_irq_count", cdecl.}
  proc bl808_wifi_backend_ipc_poll_irq_count*(): uint32
    {.importc: "bl808_wifi_backend_ipc_poll_irq_count", cdecl.}
  var sm_state {.importc.}: uint16
  proc txl_transmit_trigger*() {.importc, cdecl.}
  proc txl_frame_evt*() {.importc, cdecl.}
  proc wifi_nimfw_prune_scan_raw_cache_for_ssid*(ssid: cstring,
                                                 ssidLen: uint32)
    {.importc, cdecl.}
  proc wifi_nimfw_set_sta_tx_channel_prepare_enabled*(enabled: uint32)
    {.importc, cdecl.}
  proc wifi_nimfw_prepare_sta_tx_channel*() {.importc, cdecl.}
  proc wifi_nimfw_set_ble_wifi_role_window_enabled*(enabled: uint32)
    {.importc, cdecl.}
  proc wifi_nimfw_set_keepalive_qosnull_enabled*(enabled: uint32)
    {.importc, cdecl.}
  proc rwip_wlcoex_set*(enabled: bool) {.importc, cdecl.}

  proc wifi_mgmr_init*(conf: ptr WifiConf): cint {.cdecl.} =
    let rc = bl808_wifi_backend_init(conf)
    wifiInitialized = rc == 0
    rc

  proc wifi_mgmr_sta_enable*(): WifiInterface {.importc, cdecl.}
    ## Enable STA mode. Returns interface handle.

  # --- Station connect/disconnect ---
  proc wifi_mgmr_sta_connect*(iface: ptr WifiInterface,
                              ssid: cstring, psk: cstring, pmk: cstring,
                              mac: ptr uint8, band: uint8, chan_id: uint8): cint
    {.importc, cdecl.}

  proc wifi_mgmr_sta_disconnect*(): cint {.importc, cdecl.}
  proc bl_main_disconnect*(): cint {.importc, cdecl.}

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
  proc wifi_mgmr_sta_netif_get*(): pointer {.importc, cdecl.}
    ## Returns struct netif* (lwIP network interface for STA).

  # --- PHY/RF companion archive used by the Nim firmware backend ---
  proc phy_init*(cfg: pointer): cint
    {.importc, cdecl.}
    ## Initialize PHY. Called internally by wifi_mgmr_init.

  proc rf_init*(xtalfreqHz: uint32)
    {.importc, cdecl.}
    ## Initialize RF. Called internally by wifi_mgmr_init.

  # --- WiFi firmware internals (Nim backend) ---
  proc bl_init*(): cint
    {.importc, cdecl.}
    ## Low-level WiFi firmware init.

# =============================================================================
# Higher-level Nim WiFi API (M0 only)
# =============================================================================
when defined(bl808m0):

  var staIface: WifiInterface
  var
    wifiScanFuture: CpsFuture[uint32]
    wifiScanTimer: TimerId
    wifiConnectFuture: CpsFuture[WifiError]
    wifiConnectTimer: TimerId
    wifiStaIdleFuture: CpsFuture[WifiError]
    wifiStaIdleTimer: TimerId
    wifiDisconnectFuture: CpsFuture[WifiError]
    wifiDisconnectTimer: TimerId
    wifiDisconnectIssuePending: bool
    wifiDisconnectIssueTimeoutMs: uint32

  proc wifiBackendPoll(count: uint32) {.inline.} =
    bl808_wifi_backend_poll(count)

  proc wifiBackendConnected(): bool {.inline.} =
    bl808_wifi_backend_connected() != 0

  proc wifiBackendScanDone(): bool {.inline.} =
    bl808_wifi_backend_scan_done_count() > 0'u32

  proc wifiBackendScanCount(): uint32 {.inline.} =
    bl808_wifi_backend_scan_count()

  proc wifiBackendConnectDone(): bool {.inline.} =
    bl808_wifi_backend_connect_done() != 0

  proc wifiBackendDisconnectDone(): bool {.inline.} =
    bl808_wifi_backend_disconnect_done() != 0

  proc wifiBackendUsesEventFutures(): bool {.inline.} =
    true

  proc wifiNimFirmwareStaIdle(): bool {.inline.} =
    sm_state == 0'u16

  proc wifiNimFirmwareIssueDisconnect(): cint {.inline.} =
    bl_main_disconnect()

  proc wifiBackendStaDisconnect(): cint {.inline.} =
    wifi_mgmr_sta_disconnect()

  proc wifiNimFirmwareDisconnectNeedsDrain(): bool {.inline.} =
    true

  proc wifiNimFirmwarePruneScanCache(ssid: string) {.inline.} =
    wifi_nimfw_prune_scan_raw_cache_for_ssid(ssid.cstring, ssid.len.uint32)

  proc wifiNimFirmwareServiceTx(count: uint32) {.inline.} =
    discard wifi_nimfw_service_sta_postponed(count)
    for _ in 0'u32 ..< count:
      txl_transmit_trigger()
      txl_frame_evt()

  proc wifiNimFirmwareSetBleCoexMode(mode: uint32) {.inline.} =
    coex_pta_force_autocontrol_set(mode)
    rwip_wlcoex_set(mode != wifiBleCoexWifiAlwaysOn)
    wifi_nimfw_set_sta_tx_channel_prepare_enabled(
      if mode == wifiBleCoexWifiPriority: 1'u32 else: 0'u32)
    wifi_nimfw_set_ble_wifi_role_window_enabled(
      if mode == wifiBleCoexWifiPriority: 1'u32 else: 0'u32)

  proc wifiNimFirmwareReclaimStaTxChannel() {.inline.} =
    wifi_nimfw_prepare_sta_tx_channel()

  proc wifiNimFirmwareSendStaKeepaliveFrame(): WifiError {.inline.} =
    case wifi_nimfw_send_sta_null_frame()
    of 0'u8: wifiOk
    of 2'u8: wifiBusy
    else: wifiFail

  proc wifiNimFirmwareSetKeepaliveQosNull(enabled: bool) {.inline.} =
    wifi_nimfw_set_keepalive_qosnull_enabled(
      if enabled: 1'u32 else: 0'u32)

  proc wifiNimFirmwareKeepaliveAckOkCount(): uint32 {.inline.} =
    wifi_nimfw_null_frame_ack_ok_count()

  proc wifiNimFirmwareKeepaliveConfirmCount(): uint32 {.inline.} =
    wifi_nimfw_null_frame_cfm_count()

  proc wifiNimFirmwareKeepaliveFailCount(): uint32 {.inline.} =
    wifi_nimfw_null_frame_fail_count()

  when defined(bl808WifiNimFwDiag):
    proc dcTrace(s: cstring) {.importc: "cfg_trace", cdecl.}
    proc dcTraceRc(s: cstring; v: cint) {.importc: "cfg_trace_rc", cdecl.}

  proc wifiDisconnectTrace(message: cstring) {.inline.} =
    when defined(bl808WifiNimFwDiag):
      dcTrace(message)
    else:
      discard message

  proc wifiDisconnectTraceRc(message: cstring; value: cint) {.inline.} =
    when defined(bl808WifiNimFwDiag):
      dcTraceRc(message, value)
    else:
      discard message
      discard value

  proc cancelWifiTimer(timerId: var TimerId) =
    if timerId != 0'u32:
      cancelTimer(timerId)
      timerId = 0'u32

  proc completeWifiScan(value: uint32) =
    if wifiScanFuture != nil and not wifiScanFuture.finished:
      complete(wifiScanFuture, value)
    cancelWifiTimer(wifiScanTimer)
    wifiScanFuture = nil

  proc completeWifiConnect(value: WifiError) =
    if wifiConnectFuture != nil and not wifiConnectFuture.finished:
      complete(wifiConnectFuture, value)
    cancelWifiTimer(wifiConnectTimer)
    wifiConnectFuture = nil

  proc completeWifiStaIdle(value: WifiError) =
    if wifiStaIdleFuture != nil and not wifiStaIdleFuture.finished:
      complete(wifiStaIdleFuture, value)
    cancelWifiTimer(wifiStaIdleTimer)
    wifiStaIdleFuture = nil

  proc completeWifiDisconnect(value: WifiError) =
    if wifiDisconnectFuture != nil and not wifiDisconnectFuture.finished:
      complete(wifiDisconnectFuture, value)
    cancelWifiTimer(wifiDisconnectTimer)
    wifiDisconnectFuture = nil
    wifiDisconnectIssuePending = false
    wifiDisconnectIssueTimeoutMs = 0'u32

  proc wifiCompletePendingEvents() =
    if wifiScanFuture != nil and not wifiScanFuture.finished and
        wifiBackendScanDone():
      completeWifiScan(wifiBackendScanCount())
    if wifiConnectFuture != nil and not wifiConnectFuture.finished and
        wifiBackendConnectDone():
      completeWifiConnect(if wifiBackendConnected(): wifiOk else: wifiFail)
    if wifiStaIdleFuture != nil and not wifiStaIdleFuture.finished and
        wifiNimFirmwareStaIdle():
      completeWifiStaIdle(wifiOk)
    if wifiDisconnectIssuePending and wifiDisconnectFuture != nil and
        not wifiDisconnectFuture.finished:
      wifiDisconnectIssuePending = false
      let rc = wifiNimFirmwareIssueDisconnect()
      if rc != 0:
        completeWifiDisconnect(wifiFail)
      elif wifiDisconnectIssueTimeoutMs != 0'u32:
        wifiDisconnectTimer = addTimerMs(
          wifiDisconnectIssueTimeoutMs.uint64,
          proc() = completeWifiDisconnect(wifiFail))
    if wifiDisconnectFuture != nil and not wifiDisconnectFuture.finished:
      if wifiBackendDisconnectDone() or wifiNimFirmwareStaIdle():
        completeWifiDisconnect(wifiOk)

  proc wifiBeginScanWait(timeoutMs: uint32): CpsFuture[uint32] =
    if not wifiBackendUsesEventFutures():
      return completedLocalFuture(0'u32)
    wifiScanFuture = newLocalCpsFuture[uint32]()
    if timeoutMs != 0'u32:
      wifiScanTimer = addTimerMs(timeoutMs.uint64, proc() =
        completeWifiScan(0'u32)
      )
    wifiCompletePendingEvents()
    return wifiScanFuture

  proc wifiBeginConnectWait(timeoutMs: uint32): CpsFuture[WifiError] =
    if not wifiBackendUsesEventFutures():
      return completedLocalFuture(if wifiBackendConnected(): wifiOk else: wifiFail)
    wifiConnectFuture = newLocalCpsFuture[WifiError]()
    if timeoutMs != 0'u32:
      wifiConnectTimer = addTimerMs(timeoutMs.uint64, proc() =
        completeWifiConnect(wifiFail)
      )
    wifiCompletePendingEvents()
    return wifiConnectFuture

  proc wifiServicePump*(iterations: uint32 = 8'u32) {.cdecl.} =
    ## One bounded WiFi control-plane service step. The MAC/firmware timing
    ## remains below this layer; CPS callers use this instead of ad hoc polls.
    let hasPending =
      (wifiScanFuture != nil and not wifiScanFuture.finished) or
      (wifiConnectFuture != nil and not wifiConnectFuture.finished) or
      (wifiStaIdleFuture != nil and not wifiStaIdleFuture.finished) or
      (wifiDisconnectFuture != nil and not wifiDisconnectFuture.finished) or
      wifiDisconnectIssuePending
    if not hasPending and not wifiApEnabled and not wifiBackendConnected():
      return
    let count = if iterations == 0'u32: 1'u32 else: iterations
    wifiBackendPoll(count)
    wifiNimFirmwareServiceTx(count)
    wifiCompletePendingEvents()

  proc wifiServiceTask*(periodUs: uint32 = 1000'u32,
                        iterations: uint32 = 8'u32): CpsVoidFuture {.cps.} =
    let delay = if periodUs == 0'u32: 1'u32 else: periodUs
    while true:
      wifiServicePump(iterations)
      await sleepUs(delay.uint64)

  var
    wifiServiceHookInstalled: bool
    wifiServiceHookPeriodTicks: uint64 = usToTicks(1000'u64)
    wifiServiceHookIterations: uint32 = 8'u32

  proc wifiServicePollHook(now: uint64): uint64 =
    wifiServicePump(wifiServiceHookIterations)
    now + wifiServiceHookPeriodTicks

  proc wifiConfigureServiceHook*(periodUs: uint32 = 1000'u32,
                                 iterations: uint32 = 8'u32) =
    ## Configure the scheduler-owned WiFi pump cadence without allocating a CPS
    ## sleep future on every service tick.
    wifiServiceHookPeriodTicks =
      if periodUs == 0'u32: 1'u64 else: usToTicks(periodUs.uint64)
    wifiServiceHookIterations =
      if iterations == 0'u32: 1'u32 else: iterations

  proc wifiInstallServiceHook*(periodUs: uint32 = 1000'u32,
                               iterations: uint32 = 8'u32) =
    ## Install the high-frequency WiFi control-plane pump as a scheduler poll
    ## hook. Timed scheduler hooks wake from WFI only when service is due.
    wifiConfigureServiceHook(periodUs, iterations)
    if not wifiServiceHookInstalled:
      wifiServiceHookInstalled =
        addSchedulerTimedPollHook(wifiServicePollHook, readTick())

  proc wifiSetBleCoexistenceMode*(mode: uint32) =
    ## Configure WiFi/BLE PTA priority while STA WiFi remains active.
    ## Use wifiBleCoexWifiPriority when WiFi must actively transmit during BLE
    ## activity; use wifiBleCoexBtPriority for BLE-preferred windows.
    wifiNimFirmwareSetBleCoexMode(mode)

  proc wifiReclaimStaTxChannel*() =
    ## Restore the STA TX RF/channel programming after another radio user, such
    ## as BLE, has borrowed the shared RF path.
    wifiNimFirmwareReclaimStaTxChannel()

  proc wifiSendStaKeepaliveFrame*(): WifiError =
    ## Transmit one STA null-data keepalive frame when the Nim WiFi firmware is
    ## associated. This is a WiFi MAC TX primitive for coexistence validation,
    ## not a replacement for the lwIP data path.
    wifiNimFirmwareSendStaKeepaliveFrame()

  proc wifiSetStaKeepaliveQosNull*(enabled: bool) =
    ## Select QoS-null framing for the STA keepalive TX primitive. Normal WiFi
    ## keepalive validation uses legacy null-data by default; coexistence tests
    ## enable QoS-null because it follows the SDK U-APSD/control path.
    wifiNimFirmwareSetKeepaliveQosNull(enabled)

  proc wifiStaKeepaliveAckOkCount*(): uint32 =
    wifiNimFirmwareKeepaliveAckOkCount()

  proc wifiStaKeepaliveConfirmCount*(): uint32 =
    wifiNimFirmwareKeepaliveConfirmCount()

  proc wifiStaKeepaliveFailCount*(): uint32 =
    wifiNimFirmwareKeepaliveFailCount()

  type
    WifiKeepaliveStats* = object
      frames*: uint32
      failures*: uint32
      attempts*: uint32
      busy*: uint32
      ackDelta*: uint32
      failDelta*: uint32
      cfmDelta*: uint32

  proc wifiSendStaKeepaliveUntilAckAsync*(
      targetAck, attemptBudget: uint32,
      periodMs: uint32 = 50'u32,
      busyRetryMs: uint32 = 10'u32,
      confirmDrainMs: uint32 = 500'u32,
      serviceIterations: uint32 = 1'u32): CpsFuture[WifiKeepaliveStats] {.cps.} =
    ## Send STA keepalive frames until the requested ACK count is observed or
    ## the attempt budget is exhausted. This is the CPS orchestration layer for
    ## coexistence tests; the TX primitive and bounded service pump stay sync.
    let ackBefore = wifiStaKeepaliveAckOkCount()
    let failBefore = wifiStaKeepaliveFailCount()
    let cfmBefore = wifiStaKeepaliveConfirmCount()
    let txPeriodUs =
      if periodMs == 0'u32: 1'u64 else: periodMs.uint64 * 1000'u64
    let busyPeriodUs =
      if busyRetryMs == 0'u32: 1'u64 else: busyRetryMs.uint64 * 1000'u64
    let count =
      if serviceIterations == 0'u32: 1'u32 else: serviceIterations
    var stats: WifiKeepaliveStats
    while wifiStaKeepaliveAckOkCount() - ackBefore < targetAck and
        stats.attempts < attemptBudget:
      inc stats.attempts
      wifiServicePump(count)
      var nextDelayUs = txPeriodUs
      case wifiSendStaKeepaliveFrame()
      of wifiOk:
        inc stats.frames
      of wifiBusy:
        inc stats.busy
        nextDelayUs = busyPeriodUs
      else:
        inc stats.failures
      wifiServicePump(count)
      await sleepUs(nextDelayUs)

    let confirmDeadline = readTick() + usToTicks(confirmDrainMs.uint64 * 1000'u64)
    while wifiStaKeepaliveConfirmCount() - cfmBefore < stats.frames and
        readTick() < confirmDeadline:
      wifiServicePump(count)
      await sleepUs(1000'u64)

    stats.ackDelta = wifiStaKeepaliveAckOkCount() - ackBefore
    stats.failDelta = wifiStaKeepaliveFailCount() - failBefore
    stats.cfmDelta = wifiStaKeepaliveConfirmCount() - cfmBefore
    return stats

  proc wifiInit*(): WifiError =
    ## Initialize WiFi subsystem. Call once at startup.
    var conf: WifiConf
    let rc = wifi_mgmr_init(addr conf)
    if rc != 0: return wifiFail
    staIface = wifi_mgmr_sta_enable()
    if staIface == nil: return wifiFail
    wifiOk

  proc wifiInitAsync*(): CpsFuture[WifiError] {.cps.} =
    return wifiInit()

  proc wifiScanAsync*(timeoutMs: uint32 = 30_000): CpsFuture[uint32] =
    if staIface == nil:
      return completedLocalFuture(0'u32)
    if wifiScanFuture != nil and not wifiScanFuture.finished:
      return failedLocalFuture[uint32](
        newException(CatchableError, "WiFi scan already pending"))
    let rc = wifi_mgmr_scan(addr staIface, nil)
    if rc != 0:
      return completedLocalFuture(0'u32)
    return wifiBeginScanWait(timeoutMs)

  proc wifiConnect*(ssid, password: string, channel: uint8 = 0): WifiError =
    ## Connect to a WiFi AP.
    wifiNimFirmwarePruneScanCache(ssid)
    let rc = wifi_mgmr_sta_connect(
      addr staIface, ssid.cstring, password.cstring,
      nil, nil, 0, channel)
    if rc != 0:
      return wifiFail
    if wifiBackendUsesEventFutures():
      for _ in 0 ..< 30_000:
        wifiBackendPoll(8)
        if wifiBackendConnectDone():
          break
    return if wifiBackendConnected(): wifiOk else: wifiFail

  proc wifiConnectAsync*(ssid, password: string,
                         channel: uint8 = 0,
                         timeoutMs: uint32 = 30_000): CpsFuture[WifiError] =
    if wifiConnectFuture != nil and not wifiConnectFuture.finished:
      return failedLocalFuture[WifiError](
        newException(CatchableError, "WiFi connect already pending"))
    wifiNimFirmwarePruneScanCache(ssid)
    let rc = wifi_mgmr_sta_connect(
      addr staIface, ssid.cstring, password.cstring,
      nil, nil, 0, channel)
    if rc != 0:
      return completedLocalFuture(wifiFail)
    return wifiBeginConnectWait(timeoutMs)

  proc wifiWaitStaIdleAsync(timeoutMs: uint32 = 2_000): CpsFuture[WifiError] =
    if wifiNimFirmwareStaIdle():
      return completedLocalFuture(wifiOk)
    if wifiStaIdleFuture != nil and not wifiStaIdleFuture.finished:
      return wifiStaIdleFuture
    wifiStaIdleFuture = newLocalCpsFuture[WifiError]()
    if timeoutMs != 0'u32:
      wifiStaIdleTimer = addTimerMs(timeoutMs.uint64, proc() =
        completeWifiStaIdle(wifiFail)
      )
    wifiCompletePendingEvents()
    return wifiStaIdleFuture

  proc wifiIssueDisconnectAsync(timeoutMs: uint32 = 10_000): CpsFuture[WifiError] =
    if not wifiBackendUsesEventFutures():
      let rc = wifiNimFirmwareIssueDisconnect()
      return completedLocalFuture(if rc == 0: wifiOk else: wifiFail)
    wifiDisconnectFuture = newLocalCpsFuture[WifiError]()
    wifiDisconnectIssuePending = true
    wifiDisconnectIssueTimeoutMs = timeoutMs
    return wifiDisconnectFuture

  proc wifiDisconnect*(): WifiError =
    wifiBackendPoll(8)
    if not wifiBackendConnected():
      return wifiOk
    if wifiNimFirmwareDisconnectNeedsDrain():
      wifiDisconnectTrace("[DC] enter\n")
      wifiBackendPoll(64)
      wifiDisconnectTrace("[DC] poll64 done\n")
      for _ in 0 ..< 2000:
        if wifiNimFirmwareStaIdle():
          break
        wifiBackendPoll(8)
      wifiDisconnectTrace("[DC] pre-loop done\n")
    let rc = wifiBackendStaDisconnect()
    if wifiNimFirmwareDisconnectNeedsDrain():
      wifiDisconnectTraceRc("[DC] sta_disconnect rc=", rc.cint)
      if rc != 0:
        return wifiFail
      var loopIter: int = 0
      for _ in 0 ..< 10_000:
        wifiBackendPoll(8)
        if wifiBackendDisconnectDone() or wifiNimFirmwareStaIdle():
          return wifiOk
        inc loopIter
        if (loopIter mod 500) == 0:
          wifiDisconnectTraceRc("[DC-poll] iter=", loopIter.cint)
          wifiDisconnectTraceRc("[DC-poll] sm_state=",
                                if wifiNimFirmwareStaIdle(): 0.cint else: 1.cint)
          wifiDisconnectTraceRc("[DC-poll] disc_done=",
                                if wifiBackendDisconnectDone(): 1.cint else: 0.cint)
      return wifiFail
    else:
      if rc == 0: wifiOk else: wifiFail

  proc wifiDisconnectAsync*(timeoutMs: uint32 = 10_000): CpsFuture[WifiError] =
    if wifiDisconnectFuture != nil and not wifiDisconnectFuture.finished:
      return failedLocalFuture[WifiError](
        newException(CatchableError, "WiFi disconnect already pending"))
    wifiServicePump()
    if not wifiBackendConnected():
      return completedLocalFuture(wifiOk)
    if wifiBackendUsesEventFutures():
      if wifiStaIdleFuture != nil and not wifiStaIdleFuture.finished:
        return failedLocalFuture[WifiError](
          newException(CatchableError, "WiFi disconnect already pending"))
      wifiServicePump(64)
    return wifiIssueDisconnectAsync(timeoutMs)

  proc wifiStartAp*(ssid, password: string, channel: int = 1): WifiError =
    let rc = wifi_mgmr_ap_start(addr staIface, ssid.cstring,
                                 0, password.cstring, channel.cint)
    if rc == 0:
      wifiApEnabled = true
      wifiOk
    else:
      wifiFail

  proc wifiStartApAsync*(ssid, password: string,
                         channel: int = 1): CpsFuture[WifiError] {.cps.} =
    return wifiStartAp(ssid, password, channel)

  proc wifiStopAp*(): WifiError =
    let rc = wifi_mgmr_ap_stop(addr staIface)
    if rc == 0:
      wifiApEnabled = false
      wifiOk
    else:
      wifiFail

  proc wifiStopApAsync*(): CpsFuture[WifiError] {.cps.} =
    return wifiStopAp()

  proc wifiGetNetif*(): pointer =
    ## Get the lwIP netif for the STA interface.
    ## Cast to `ptr NetIf` in your lwIP bindings.
    wifi_mgmr_sta_netif_get()

# =============================================================================
# RF register access
# =============================================================================
proc rfReadRevision*(): uint32 =
  regRead(RfRevId)
