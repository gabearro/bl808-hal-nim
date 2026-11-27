## BL808 WiFi4 firmware reimplementation (libfirmware.a).
##
## Replaces the precompiled binary blob with native Nim code.
## All 484 exported functions match the original ABI exactly.
##
## Module layout (matching the original firmware):
##   co_*       -- common list/pool utilities
##   ke_*       -- kernel: events, messages, tasks, timers
##   mm_*       -- MAC management
##   scan_*     -- lower-MAC scanning
##   scanu_*    -- upper-MAC scanning
##   sm_*       -- station-mode state machine
##   apm_*      -- AP mode management
##   me_*       -- management entity (IE building, rate control bridge)
##   rc_*       -- rate control (Minstrel-like)
##   txl_*      -- TX layer (buffer, frame, confirm, control)
##   txu_*      -- TX upper (frame build, push, security)
##   rxl_*      -- RX layer (DMA, descriptor, control)
##   rxu_*      -- RX upper (frame handling, upload)
##   hal_machw_* -- MAC HW abstraction
##   chan_*     -- channel management
##   vif_mgmt_* -- virtual interface management
##   sta_mgmt_* -- station management
##   tpc_*      -- TX power control
##   bam_*      -- block ACK management
##   td_*       -- time domain (traffic detection)
##   ps_*       -- power save
##   ipc_emb_*  -- IPC embedded (host communication)
##   bl_*       -- platform integration
##   mfp_*      -- management frame protection
##   hsu_*      -- hardware security unit
##   cfg_*      -- configuration
##   coex_*     -- coexistence (WiFi/BLE PTA)
##   notifier_* -- notifier chains
##   assert_*   -- assertion handlers
##   bugkiller_* -- debug dump
##   mac_*      -- MAC utilities (IE find, paid/gid)

import mmio, memmap
import radio_phy
import wifi/fw_constants
import wifi/fw_messages
import wifi/rx_ring_config
when defined(bl808WifiSplitTxSlots):
  import wifi/ipc_host as hostIpc
when defined(radioDiag):
  import kernel/clock
when defined(bl808m0) and defined(radioProfiler):
  import kernel/profiler
from std/volatile import volatileStore, volatileLoad
when defined(bl808WifiDiagTcpFallbackAb) or defined(bl808WifiDiagTcpDmaTiming):
  import wifi/tcp_path_trace
  from wifi/ipc_host/layout import SharedTxbufOff, SharedTxbufSize
  static:
    doAssert defined(bl808m0) and defined(bl808WifiDiagTcpPath)
when defined(bl808WifiDiagTcpFallbackAb):
  static:
    doAssert not defined(bl808WifiBootstrapRetryWorkaround)
when defined(bl808WifiDiagTcpDmaShape):
  static: doAssert defined(bl808WifiDiagTcpDmaTiming)
when defined(bl808WifiMbedTlsSha1Lease):
  from wifi/mbedtls_sha1_alt import beginShaApKeySetup, finishShaApKeySetup

export radio_phy
export fw_constants
export fw_messages

proc c_memcpy(dst, src: pointer, n: csize_t): pointer
  {.importc: "memcpy", header: "<string.h>".}
proc bl808WpaStaConnectResult(callback, params: pointer): cint
  {.importc: "bl808_wpa_sta_connect_result", cdecl.}
when defined(bl808m0):
  proc bl808_wifi_backend_signal_work() {.importc, cdecl.}


include wifi/fw/register_constants
include wifi/fw/layout_types
include wifi/fw/global_state
include wifi/fw/runtime_helpers
when defined(bl808m0):
  include wifi/fw/postponed_tx_work
include wifi/fw/op
when defined(bl808WifiDiagDhcpTxAttempts) or defined(bl808WifiDiagTcpPath):
  include wifi/fw/tx_policy_trace
when defined(bl808WifiDiagMacState):
  include wifi/fw/mac_state_trace
include wifi/fw/rsn_parse
when defined(bl808WifiApDiscoveryDiag):
  include wifi/fw/ap_probe_trace
include wifi/fw/kernel_mac_channel
include wifi/fw/channel_home_wake
include wifi/fw/channel_timer
include wifi/fw/channel_beacon_request
include wifi/fw/channel_update
include wifi/fw/channel_switch
include wifi/fw/channel_protection
include wifi/fw/station_sa_query
include wifi/fw/scan_machine
include wifi/fw/station_sm
include wifi/fw/scan_station_ap_me
include wifi/fw/rate_control
include wifi/fw/tx_layer
include wifi/fw/station_tx_build
include wifi/fw/station_scan
include wifi/fw/station_registration
include wifi/fw/station_bss
include wifi/fw/station_activation
include wifi/fw/tx_upper
include wifi/fw/rx_layer
include wifi/fw/rx_host_delivery
include wifi/fw/deferred_auth
include wifi/fw/station_abort
include wifi/fw/station_cleanup
proc nim_ccmp_decrypt*(tk: pointer; hdr: pointer; data: pointer;
                       dataLen: uint32; outPlain: pointer;
                       outLen: ptr uint32): bool
include wifi/fw/rx_upper
include wifi/fw/key_install_policy
include wifi/fw/vif_management
include wifi/fw/sta_management
include wifi/fw/tx_power_control
include wifi/fw/block_ack
include wifi/fw/traffic_detection
include wifi/fw/power_save
include wifi/fw/ipc_embedded
include wifi/fw/platform_bl
include wifi/fw/crypto_mfp_hsu
include wifi/fw/mac_config_debug
include wifi/fw/mac_config_entries
include wifi/fw/coex_intc_sysctrl
include wifi/fw/task_handlers
include wifi/fw/tx_security
include wifi/fw/tx_security_update
include wifi/fw/dispatch_tables
include wifi/fw/task_init_main
