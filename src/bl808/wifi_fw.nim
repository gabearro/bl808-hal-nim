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
from std/volatile import volatileStore, volatileLoad

export radio_phy
export fw_constants
export fw_messages

when not defined(bl808WifiUseBl808Rf) and
    not defined(bl808WifiAllowLegacyBl606pRfFallback):
  {.error: "BL808 WiFi firmware RF/PHY requires bl808WifiUseBl808Rf; define bl808WifiAllowLegacyBl606pRfFallback only for archive comparison builds".}

proc c_memcpy(dst, src: pointer, n: csize_t): pointer
  {.importc: "memcpy", header: "<string.h>".}


include wifi/fw/register_constants
include wifi/fw/layout_types
include wifi/fw/global_state
include wifi/fw/runtime_helpers
include wifi/fw/kernel_mac_channel
include wifi/fw/scan_station_ap_me
include wifi/fw/rate_control
include wifi/fw/tx_layer
include wifi/fw/tx_upper
include wifi/fw/rx_layer
include wifi/fw/rx_upper
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
include wifi/fw/coex_intc_sysctrl
include wifi/fw/task_handlers
include wifi/fw/dispatch_tables
include wifi/fw/task_init_main
