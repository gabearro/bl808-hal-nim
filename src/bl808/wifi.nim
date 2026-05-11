## BL808 WiFi driver interface.
##
## The BL808 M0 WiFi path has two bring-up modes:
##   - default vendor firmware: src/bl808/libwifi_fw.a
##   - -d:bl808WifiNimFw: src/bl808/wifi_fw.nim replaces that firmware archive
##
## Native firmware mode is the replacement path: src/bl808/wifi_fw.nim owns the
## firmware ABI that would otherwise come from libwifi_fw.a. The remaining SDK C
## pieces in this file are host driver/supplicant scaffolding used while the Nim
## stack catches up; the vendor blob is only a reference/oracle.
##
## WiFi runs on the M0 (E907) core. The D0/LP cores communicate
## with WiFi through IPC if needed.
##
## The WiFi manager integrates with lwIP for TCP/IP networking.
## Call `wifi_mgmr_sta_netif_get()` to get the lwIP netif for the STA interface.

import mmio, memmap

# Iter 2.A.0 step 3: vendor lwIP source compilation. Required because
# wifi_vendor_support.c's lwIP-side bridges (netifapi_netif_add -> netif_add,
# tcpip_input -> ethernet_input, wifi_netif_dhcp_start -> dhcp_start) call
# vendor lwIP functions that otherwise wouldn't be in the link.
when defined(bl808m0) and defined(bl808WifiVendor):
  import bl808/kernel/lwipcore

when defined(bl808m0) and defined(bl808WifiVendor) and defined(bl808WifiNimFw):
  import wifi_fw
  when not defined(bl808WifiVendorCmdMgr):
    import wifi_cmds
  when not defined(bl808WifiVendorDriver):
    import wifi_driver
  import wifi_hosal
  import wifi_ipc_host
  import wifi_irqs
  when not defined(bl808WifiVendorSupport):
    import wifi_support
  when not defined(bl808WifiVendorMain):
    import wifi_main
  when not defined(bl808WifiVendorMsgTx):
    import wifi_msg_tx
  import wifi_mod_params
  import wifi_platform
  when not defined(bl808WifiVendorRx):
    import wifi_rx
  when not defined(bl808WifiVendorTx):
    import wifi_tx
  when not defined(bl808WifiVendorUtils):
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

  WifiConf* = object
    ## WiFi configuration structure.
    countryCode*: array[3, char]

  ApConnectAdv* = object
    ## Advanced AP connection parameters.
    channel*: uint8

# =============================================================================
# WiFi manager host API (SDK scaffolding plus Nim/vendor firmware backend)
#
# With -d:bl808WifiNimFw, firmware symbols resolve to src/bl808/wifi_fw.nim and
# libwifi_fw.a is not linked. Without it, those symbols resolve to the vendor
# firmware archive plus its PHY/RF companion.
# =============================================================================
when defined(bl808m0):
  when defined(bl808WifiVendor):
    {.passC: "-DBL808 -DCPU_M0 -DCFG_CHIP_BL808 -DCFG_TXDESC=4 -DCFG_STA_MAX=1 -DCFG_VIRT_DEV_MAX=2".}
    {.passC: "-DBL_CHIP_NAME=\"BL808\" -D__FILENAME__=__FILE__ -DBL808_WIFI_VENDOR_FULL_SUPPLICANT -DUSE_MBEDTLS_CRYPTO -include sys/types.h".}
    {.passC: "-DBL808_WIFI_CONNECT_CRYPTO_PARAMS -DBL808_WIFI_CONNECT_CFG80211_FLAGS".}
    when defined(bl808WifiNimFw):
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
    when defined(bl808WifiVendorValidationLog):
      {.passC: "-DBL808_WIFI_VENDOR_LOG_TO_VALIDATION_BUFFER".}
    when defined(bl808WifiOfficialPowerProfile):
      {.passC: "-DBL808_WIFI_VENDOR_OFFICIAL_POWER_PROFILE".}
    when defined(bl808WifiVendorUseBl808Rf):
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
    when not defined(bl808WifiNimFw) or defined(bl808WifiVendorSupport):
      {.compile: "wifi_vendor_support.c".}
    when defined(bl808WifiConnectTrace):
      {.compile: "wifi_connect_trace.c".}
    when defined(bl808WifiTrace) and not defined(bl808WifiNimFw):
      {.compile: "wifi_eapol_trace.c".}
    when not defined(bl808WifiNimFw):
      {.compile: "wifi_ipc_host.c".}
    when not defined(bl808WifiNimFw) or defined(bl808WifiVendorCmdMgr):
      {.compile: "build/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/bl_cmds.c".}
    when not defined(bl808WifiNimFw):
      {.compile: "build/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/bl_irqs.c".}
    when not defined(bl808WifiNimFw) or defined(bl808WifiVendorMain):
      {.compile: "build/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/bl_main.c".}
    when not defined(bl808WifiNimFw):
      {.compile: "build/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/bl_mod_params.c".}
    when not defined(bl808WifiNimFw):
      {.compile: "build/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/bl_msg_rx.c".}
    when not defined(bl808WifiNimFw) or defined(bl808WifiVendorMsgTx):
      {.compile: "build/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/bl_msg_tx.c".}
    when not defined(bl808WifiNimFw):
      {.compile: "build/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/bl_platform.c".}
    when not defined(bl808WifiNimFw) or defined(bl808WifiVendorRx):
      {.compile: "build/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/bl_rx.c".}
    when not defined(bl808WifiNimFw) or defined(bl808WifiVendorTx):
      {.compile: "build/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/bl_tx.c".}
    when not defined(bl808WifiNimFw) or defined(bl808WifiVendorUtils):
      {.compile: "build/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/bl_utils.c".}
    when not defined(bl808WifiNimFw) or defined(bl808WifiVendorDriver):
      {.compile: "build/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/wifi.c".}
    when not defined(bl808WifiNimFw):
      {.compile: "build/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/wifi_pkt_hooks.c".}
    when not defined(bl808WifiNimFw):
      {.compile: "build/bl_iot_sdk_b773b3f/components/network/wifi_hosal/wifi_hosal.c".}
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
    {.compile: "build/bl_iot_sdk_b773b3f/components/security/wpa_supplicant/src/rsn_supp/wpa.c".}
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
    {.passL: "-Wl,--wrap=wpa_set_bss".}
    {.passL: "-Wl,--wrap=wpa3_build_sae_msg".}
    {.passL: "-Wl,--wrap=wpa3_parse_sae_msg".}
    when defined(bl808WifiWrapWaitUs):
      {.passL: "-Wl,--wrap=wait_us".}
    when defined(bl808WifiNimFw):
      when defined(bl808WifiConnectTrace):
        {.passL: "-Wl,--wrap=mm_active -Wl,--wrap=mm_hw_info_set -Wl,--wrap=mm_sec_machwaddr_wr -Wl,--wrap=sm_handle_eapol_input -Wl,--wrap=wpa_sm_rx_eapol -Wl,--wrap=txu_cntrl_push -Wl,--wrap=txl_cntrl_push -Wl,--wrap=txl_frame_push -Wl,--wrap=txl_frame_push_force -Wl,--wrap=txl_frame_cfm -Wl,--wrap=txl_cfm_push -Wl,--wrap=rxu_cntrl_frame_handle".}
      when defined(bl808WifiConnectTraceRawRx):
        {.passL: "-Wl,--wrap=rxl_cntrl_evt".}
      when defined(bl808WifiVendorUseBl808Rf):
        {.passL: "-Wl,--start-group src/bl808/librf_bl808.a -Wl,--end-group".}
      else:
        {.passL: "-Wl,--start-group build/bl_iot_sdk_b773b3f/components/platform/soc/bl606p/bl606p_phyrf/lib/libbl606p_phyrf.a -Wl,--end-group".}
    else:
      when defined(bl808WifiTrace):
        {.passL: "-Wl,--wrap=mm_active -Wl,--wrap=mm_hw_info_set -Wl,--wrap=mm_sec_machwaddr_wr -Wl,--wrap=sm_handle_eapol_input -Wl,--wrap=tcpip_stack_input -Wl,--wrap=rxu_cntrl_frame_handle -Wl,--wrap=rxu_swdesc_upload_evt -Wl,--wrap=txl_frame_push -Wl,--wrap=txl_frame_push_force -Wl,--wrap=txl_frame_cfm -Wl,--wrap=txl_frame_evt -Wl,--wrap=txl_transmit_trigger -Wl,--wrap=txl_cfm_push".}
      when defined(bl808WifiConnectTrace):
        {.passL: "-Wl,--wrap=mm_active -Wl,--wrap=mm_hw_info_set -Wl,--wrap=mm_sec_machwaddr_wr -Wl,--wrap=sm_handle_eapol_input -Wl,--wrap=wpa_sm_rx_eapol -Wl,--wrap=txu_cntrl_push -Wl,--wrap=txl_cntrl_push -Wl,--wrap=txl_frame_push -Wl,--wrap=txl_frame_push_force -Wl,--wrap=txl_frame_cfm -Wl,--wrap=txl_cfm_push -Wl,--wrap=rxu_cntrl_frame_handle".}
      when defined(bl808WifiConnectTraceRawRx):
        {.passL: "-Wl,--wrap=rxl_cntrl_evt".}
      when defined(bl808WifiVendorUseBl808Rf):
        {.passL: "-Wl,--start-group src/bl808/libwifi_fw.a src/bl808/librf_bl808.a -Wl,--end-group".}
      else:
        {.passL: "-Wl,--start-group src/bl808/libwifi_fw.a build/bl_iot_sdk_b773b3f/components/platform/soc/bl606p/bl606p_phyrf/lib/libbl606p_phyrf.a -Wl,--end-group".}

  var
    wifiInitialized: bool
    wifiStaEnabled: bool
    wifiStaConnected: bool
    wifiApEnabled: bool
    wifiStaToken: uint32 = 0x57544153'u32
    wifiNetifToken: uint32 = 0x4E455449'u32

  # --- Initialization ---
  when defined(bl808WifiVendor):
    proc bl808_wifi_vendor_init(conf: ptr WifiConf): cint
      {.importc, cdecl.}
    proc bl808_wifi_vendor_poll*(iterations: uint32)
      {.importc, cdecl.}
    proc bl808_wifi_vendor_connected*(): cint
      {.importc, cdecl.}
    proc bl808_wifi_vendor_connect_done*(): cint
      {.importc, cdecl.}
    proc bl808_wifi_vendor_disconnect_done*(): cint
      {.importc, cdecl.}
    proc bl808_wifi_vendor_last_status*(): cint
      {.importc, cdecl.}
    proc bl808_wifi_vendor_last_reason*(): cint
      {.importc, cdecl.}
    proc bl808_wifi_vendor_scan_count*(): uint32
      {.importc, cdecl.}
    proc bl808_wifi_vendor_scan_done_count*(): uint32
      {.importc, cdecl.}
    proc bl808_wifi_vendor_scan_diag_count*(): uint32
      {.importc, cdecl.}
    proc bl808_wifi_vendor_scan_diag_get*(index: uint32,
                                          ssidLen: ptr uint8,
                                          ssid: ptr uint8,
                                          channel: ptr uint8,
                                          rssi: ptr int8,
                                          auth: ptr uint8,
                                          cipher: ptr uint8,
                                          bssid: ptr uint8): cint
      {.importc, cdecl.}
    proc bl808_wifi_vendor_mac_irq_count*(): uint32
      {.importc, cdecl.}
    proc bl808_wifi_vendor_mac_poll_irq_count*(): uint32
      {.importc, cdecl.}
    proc bl808_wifi_vendor_mac_trap_irq_count*(): uint32
      {.importc, cdecl.}
    proc bl808_wifi_vendor_ipc_trap_irq_count*(): uint32
      {.importc, cdecl.}
    proc bl808_wifi_vendor_ipc_poll_irq_count*(): uint32
      {.importc, cdecl.}
    when defined(bl808WifiNimFw):
      var sm_state {.importc.}: uint16

    proc wifi_mgmr_init*(conf: ptr WifiConf): cint {.cdecl.} =
      let rc = bl808_wifi_vendor_init(conf)
      wifiInitialized = rc == 0
      rc
  else:
    proc wifi_mgmr_init*(conf: ptr WifiConf): cint {.cdecl.} =
      discard conf
      wifiInitialized = true
      0

  when defined(bl808WifiVendor):
    proc wifi_mgmr_sta_enable*(): WifiInterface {.importc, cdecl.}
      ## Enable STA mode. Returns interface handle.
  else:
    proc wifi_mgmr_sta_enable*(): WifiInterface {.cdecl.} =
      ## Enable STA mode. Returns interface handle.
      if not wifiInitialized:
        return nil
      wifiStaEnabled = true
      cast[WifiInterface](addr wifiStaToken)

  # --- Station connect/disconnect ---
  when defined(bl808WifiVendor):
    proc wifi_mgmr_sta_connect*(iface: ptr WifiInterface,
                                ssid: cstring, psk: cstring, pmk: cstring,
                                mac: ptr uint8, band: uint8, chan_id: uint8): cint
      {.importc, cdecl.}

    proc wifi_mgmr_sta_disconnect*(): cint {.importc, cdecl.}
  else:
    proc wifi_mgmr_sta_connect*(iface: ptr WifiInterface,
                                ssid: cstring, psk: cstring, pmk: cstring,
                                mac: ptr uint8, band: uint8, chan_id: uint8): cint {.cdecl.} =
      discard psk
      discard pmk
      discard mac
      discard band
      discard chan_id
      if iface == nil or iface[] == nil or ssid == nil or not wifiStaEnabled:
        return -1
      wifiStaConnected = true
      0

    proc wifi_mgmr_sta_disconnect*(): cint {.cdecl.} =
      wifiStaConnected = false
      if wifiStaEnabled: 0 else: -1

  # --- Scanning ---
  when defined(bl808WifiVendor):
    proc wifi_mgmr_scan*(iface: ptr WifiInterface, cb: pointer): cint
      {.importc, cdecl.}
  else:
    proc wifi_mgmr_scan*(iface: ptr WifiInterface, cb: pointer): cint {.cdecl.} =
      discard cb
      if iface != nil and iface[] != nil and wifiStaEnabled: 0 else: -1

  # --- AP mode ---
  when defined(bl808WifiVendor):
    proc wifi_mgmr_ap_start*(iface: ptr WifiInterface,
                             ssid: cstring, hiddenSsid: cint,
                             passwd: cstring, channel: cint): cint
      {.importc, cdecl.}

    proc wifi_mgmr_ap_stop*(iface: ptr WifiInterface): cint
      {.importc, cdecl.}
  else:
    proc wifi_mgmr_ap_start*(iface: ptr WifiInterface,
                             ssid: cstring, hiddenSsid: cint,
                             passwd: cstring, channel: cint): cint {.cdecl.} =
      discard hiddenSsid
      discard passwd
      if iface == nil or iface[] == nil or ssid == nil or channel <= 0:
        return -1
      wifiApEnabled = true
      0

    proc wifi_mgmr_ap_stop*(iface: ptr WifiInterface): cint {.cdecl.} =
      if iface == nil or iface[] == nil:
        return -1
      wifiApEnabled = false
      0

  # --- Status ---
  when defined(bl808WifiVendor):
    proc wifi_mgmr_sta_netif_get*(): pointer {.importc, cdecl.}
      ## Returns struct netif* (lwIP network interface for STA).
  else:
    proc wifi_mgmr_sta_netif_get*(): pointer {.cdecl.} =
      ## Returns struct netif* (lwIP network interface for STA).
      if wifiStaEnabled: cast[pointer](addr wifiNetifToken) else: nil

  # --- PHY/RF companion archive used by both firmware backends ---
  proc phy_init*(cfg: pointer): cint
    {.importc, cdecl.}
    ## Initialize PHY. Called internally by wifi_mgmr_init.

  proc rf_init*(xtalfreqHz: uint32)
    {.importc, cdecl.}
    ## Initialize RF. Called internally by wifi_mgmr_init.

  # --- WiFi firmware internals (Nim backend or src/bl808/libwifi_fw.a) ---
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
    when defined(bl808WifiVendor):
      if rc != 0:
        return wifiFail
      for _ in 0 ..< 30_000:
        bl808_wifi_vendor_poll(8)
        if bl808_wifi_vendor_connect_done() != 0:
          break
      if bl808_wifi_vendor_connected() != 0: wifiOk else: wifiFail
    else:
      if rc == 0: wifiOk else: wifiFail

  proc wifiDisconnect*(): WifiError =
    when defined(bl808WifiVendor) and defined(bl808WifiNimFw):
      bl808_wifi_vendor_poll(64)
      for _ in 0 ..< 2000:
        if sm_state == 0'u16:
          break
        bl808_wifi_vendor_poll(8)
    let rc = wifi_mgmr_sta_disconnect()
    when defined(bl808WifiVendor) and defined(bl808WifiNimFw):
      if rc != 0:
        return wifiFail
      for _ in 0 ..< 10_000:
        bl808_wifi_vendor_poll(8)
        if bl808_wifi_vendor_disconnect_done() != 0 or sm_state == 0'u16:
          return wifiOk
      return wifiFail
    else:
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
