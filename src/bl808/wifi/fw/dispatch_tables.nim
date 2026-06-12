# ###########################################################################
#  Exported data tables and dispatch tables (rodata/data/bss symbols)
#  These match the blob's exported global data symbols exactly.
# ###########################################################################

# --- Per-task state variables (blob: COMMON symbols in *_task.o) ---
# Each task has a uint16 state variable pointed to by keTaskDescs[task].statePtr.
# Nim names use ke_ prefix to avoid conflict with mmState etc.
var keTaskStateMm* {.exportc: "mm_state".}: uint16 = 0
var keTaskStateScan* {.exportc: "scan_state".}: uint16 = 0
var keTaskStateScanu* {.exportc: "scanu_state".}: uint16 = 0
var keTaskStateMe* {.exportc: "me_state".}: uint16 = 0
var keTaskStateSm* {.exportc: "sm_state".}: uint16 = 0
var keTaskStateApm* {.exportc: "apm_state".}: uint16 = 0
var keTaskStateBam* {.exportc: "bam_state".}: uint16 = 0
var keTaskStateCfg* {.exportc: "cfg_state".}: uint16 = 0

const
  MmStateCount = 4'u16
  ScanStateCount = 4'u16
  ScanuStateCount = 3'u16
  MeStateCount = 2'u16
  SmStateCount = 11'u16
  ApmStateCount = 3'u16
  BamStateCount = 5'u16
  CfgStateCount = 1'u16

# --- KE task dispatch table types ---
# ke_msg_handler_t: {msg_id: uint32, handler: pointer} = 8 bytes per entry
# ke_task_handler_t: {msg_handlers: pointer, count: uint32} = 8 bytes per entry

type
  KeMsgHandler* = object
    msgId*: uint32
    handler*: pointer
  KeTaskHandler* = object
    msgHandlers*: pointer
    count*: uint32

# --- MM task dispatch (mm_task.o) ---
# mm_default_state: 24 entries mapping MM msg IDs to handler functions
# Blob hex: 02,04,06,08,00,0e,12,10,14,16,18,1a,4a,0a,0c,29,34,2d,2f,1e,1f,39,46,48
var mm_default_state* {.wifiCtrlExport.}: array[24, KeMsgHandler] = [
  KeMsgHandler(msgId: MM_START_REQ, handler: cast[pointer](mm_start_req_handler)),               # 0x02
  KeMsgHandler(msgId: MM_VERSION_REQ, handler: cast[pointer](mm_version_req_handler)),            # 0x04
  KeMsgHandler(msgId: MM_ADD_IF_REQ, handler: cast[pointer](mm_hw_config_handler)),               # 0x06
  KeMsgHandler(msgId: MM_REMOVE_IF_REQ, handler: cast[pointer](mm_hw_config_handler)),            # 0x08
  KeMsgHandler(msgId: MM_RESET_REQ, handler: cast[pointer](mm_reset_req_handler)),                # 0x00
  KeMsgHandler(msgId: MM_SET_CHANNEL_REQ, handler: cast[pointer](mm_hw_config_handler)),          # 0x0E
  KeMsgHandler(msgId: MM_SET_BASIC_RATES_REQ, handler: cast[pointer](mm_hw_config_handler)),      # 0x12
  KeMsgHandler(msgId: MM_SET_BEACON_INT_REQ, handler: cast[pointer](mm_hw_config_handler)),       # 0x10
  KeMsgHandler(msgId: MM_SET_BSSID_REQ, handler: cast[pointer](mm_hw_config_handler)),            # 0x14
  KeMsgHandler(msgId: MM_SET_EDCA_REQ, handler: cast[pointer](mm_hw_config_handler)),             # 0x16
  KeMsgHandler(msgId: MM_SET_VIF_STATE_REQ, handler: cast[pointer](mm_hw_config_handler)),        # 0x18
  KeMsgHandler(msgId: MM_SET_IDLE_REQ, handler: cast[pointer](mm_set_idle_req_handler)),          # 0x1A
  KeMsgHandler(msgId: MM_MONITOR_REQ, handler: cast[pointer](mm_force_idle_req_handler)),         # 0x4A
  KeMsgHandler(msgId: MM_STA_ADD_REQ, handler: cast[pointer](mm_sta_add_req_handler)),            # 0x0A
  KeMsgHandler(msgId: MM_STA_DEL_REQ, handler: cast[pointer](mm_sta_del_req_handler)),            # 0x0C
  KeMsgHandler(msgId: MM_CHAN_CTXT_UNLINK_CFM, handler: cast[pointer](mm_hw_config_handler)),     # 0x29
  KeMsgHandler(msgId: MM_CHANNEL_PRE_SWITCH_IND, handler: cast[pointer](mm_remain_on_channel_req_handler)), # 0x34
  KeMsgHandler(msgId: MM_CHAN_CTXT_SCHED_CFM, handler: cast[pointer](mm_bcn_change_req_handler)), # 0x2D
  KeMsgHandler(msgId: MM_BCN_CHANGE_CFM, handler: cast[pointer](mm_tim_update_req_handler)),      # 0x2F
  KeMsgHandler(msgId: MM_DENOISE_REQ, handler: cast[pointer](mm_set_ps_mode_req_handler)),        # 0x1E
  KeMsgHandler(msgId: MM_SET_PS_MODE_REQ, handler: cast[pointer](mm_set_ps_mode_req_handler)),    # 0x1F
  KeMsgHandler(msgId: MM_SET_PS_OPTIONS_REQ, handler: cast[pointer](mm_set_ps_options_req_handler)), # 0x39
  KeMsgHandler(msgId: MM_CSA_FINISH_IND, handler: cast[pointer](mm_monitor_enable_req_handler)),  # 0x46
  KeMsgHandler(msgId: MM_MU_GROUP_UPDATE_REQ, handler: cast[pointer](mm_monitor_channel_req_handler)), # 0x48
]

var mm_default_handler* {.wifiCtrlExport.}: KeTaskHandler =
  KeTaskHandler(msgHandlers: cast[pointer](addr mm_default_state), count: 24)

# mm_state_handler: 4 states (IDLE, ACTIVE, GOING_TO_IDLE, HOST_BYPASSED), all nil
var mm_state_handler* {.wifiCtrlExport.}: array[4, KeTaskHandler] = [
  KeTaskHandler(msgHandlers: nil, count: 0),
  KeTaskHandler(msgHandlers: nil, count: 0),
  KeTaskHandler(msgHandlers: nil, count: 0),
  KeTaskHandler(msgHandlers: nil, count: 0),
]

# --- SCAN task dispatch (scan_task.o) ---
var scan_default_state* {.wifiCtrlExport.}: array[7, KeMsgHandler] = [
  KeMsgHandler(msgId: SCAN_START_REQ, handler: cast[pointer](scan_start_req_handler)),
  KeMsgHandler(msgId: MM_SCAN_CHANNEL_START_IND, handler: cast[pointer](mm_scan_channel_start_ind_handler)),
  KeMsgHandler(msgId: MM_SCAN_CHANNEL_END_EARLY, handler: cast[pointer](mm_scan_channel_end_early_handler)),
  KeMsgHandler(msgId: MM_SCAN_CHANNEL_END_IND, handler: cast[pointer](mm_scan_channel_end_ind_handler)),
  KeMsgHandler(msgId: SCAN_ABORT_REQ, handler: cast[pointer](scan_abort_req_handler)),
  KeMsgHandler(msgId: SCAN_CANCEL_REQ, handler: cast[pointer](scan_cancel_req_handler)),
  KeMsgHandler(msgId: SCAN_PROBE_TIMER, handler: cast[pointer](scan_probe_req_handler)),
]

var scan_default_handler* {.wifiCtrlExport.}: KeTaskHandler =
  KeTaskHandler(msgHandlers: cast[pointer](addr scan_default_state), count: 7)

# --- SCANU task dispatch (scanu_task.o) ---
var scanu_default_state* {.wifiCtrlExport.}: array[3, KeMsgHandler] = [
  KeMsgHandler(msgId: SCANU_START_REQ, handler: cast[pointer](ke_msg_save)),
  KeMsgHandler(msgId: SCANU_JOIN_REQ, handler: cast[pointer](ke_msg_save)),
  KeMsgHandler(msgId: RXU_MGT_IND, handler: cast[pointer](ke_msg_discard)),
]

var scanu_default_handler* {.wifiCtrlExport.}: KeTaskHandler =
  KeTaskHandler(msgHandlers: cast[pointer](addr scanu_default_state), count: 3)

var scanu_idle* {.wifiCtrlExport.}: array[3, KeMsgHandler] = [
  KeMsgHandler(msgId: SCANU_START_REQ, handler: cast[pointer](scanu_start_req_handler)),
  KeMsgHandler(msgId: SCANU_JOIN_REQ, handler: cast[pointer](scanu_join_req_handler)),
  KeMsgHandler(msgId: SCANU_RAW_SEND_REQ, handler: cast[pointer](scanu_raw_send_req_handler)),
]

var scanu_scanning* {.wifiCtrlExport.}: array[3, KeMsgHandler] = [
  KeMsgHandler(msgId: SCAN_START_CFM, handler: cast[pointer](scan_start_cfm_handler)),
  KeMsgHandler(msgId: SCAN_DONE_IND, handler: cast[pointer](scan_done_ind_handler)),
  KeMsgHandler(msgId: RXU_MGT_IND, handler: cast[pointer](rxu_mgt_ind_handler_scanu)),
]

var scanu_joining* {.wifiCtrlExport.}: array[3, KeMsgHandler] = [
  KeMsgHandler(msgId: SCAN_START_CFM, handler: cast[pointer](scan_start_cfm_handler)),
  KeMsgHandler(msgId: SCAN_DONE_IND, handler: cast[pointer](scan_done_ind_handler)),
  KeMsgHandler(msgId: RXU_MGT_IND, handler: cast[pointer](rxu_mgt_ind_handler_scanu)),
]

var scanu_state_handler* {.wifiCtrlExport.}: array[3, KeTaskHandler] = [
  KeTaskHandler(msgHandlers: cast[pointer](addr scanu_idle), count: 3),
  KeTaskHandler(msgHandlers: cast[pointer](addr scanu_scanning), count: 3),
  KeTaskHandler(msgHandlers: cast[pointer](addr scanu_joining), count: 3),
]

# --- SM task dispatch (sm_task.o) ---
# Blob hex: 1000,1003,1007,100b,0801,0803,1006,1009,0031,000b,0c0e,0015,0013,0011,0017,0019,0c10,003a,000d,1c00
var sm_default_state* {.wifiCtrlExport.}: array[20, KeMsgHandler] = [
  KeMsgHandler(msgId: SM_CONNECT_REQ, handler: cast[pointer](sm_connect_req_handler)),             # 0x1000
  KeMsgHandler(msgId: SM_DISCONNECT_REQ, handler: cast[pointer](sm_disconnect_req_handler)),       # 0x1003
  KeMsgHandler(msgId: SM_CONNECT_ABORT_REQ, handler: cast[pointer](sm_connect_abort_req_handler)), # 0x1007
  KeMsgHandler(msgId: SM_CONNECT_AUTH_ASSOC_REQ_MSG, handler: cast[pointer](sm_connect_auth_assoc_req)), # 0x100B
  KeMsgHandler(msgId: SCANU_START_CFM, handler: cast[pointer](scanu_start_cfm_handler)),           # 0x0801
  KeMsgHandler(msgId: SCANU_JOIN_CFM, handler: cast[pointer](scanu_join_cfm_handler)),             # 0x0803
  KeMsgHandler(msgId: SM_RSP_TIMEOUT_IND, handler: cast[pointer](sm_rsp_timeout_ind_handler)),     # 0x1006
  KeMsgHandler(msgId: SM_SA_QUERY_TIMEOUT_IND_MSG, handler: cast[pointer](sm_sa_query_timeout_ind_handler)), # 0x1009
  KeMsgHandler(msgId: MM_TIM_UPDATE_CFM, handler: cast[pointer](mm_connection_loss_ind_handler)),   # 0x0031
  KeMsgHandler(msgId: MM_STA_ADD_CFM, handler: cast[pointer](mm_sta_add_cfm_handler)),             # 0x000B
  KeMsgHandler(msgId: ME_SET_ACTIVE_CFM, handler: cast[pointer](me_set_active_cfm_handler_sm)),   # 0x0C0E (SM task)
  KeMsgHandler(msgId: MM_SET_BSSID_CFM, handler: cast[pointer](mm_bss_param_setting_handler)),     # 0x0015
  KeMsgHandler(msgId: MM_SET_BASIC_RATES_CFM, handler: cast[pointer](mm_bss_param_setting_handler)), # 0x0013
  KeMsgHandler(msgId: MM_SET_BEACON_INT_CFM, handler: cast[pointer](mm_bss_param_setting_handler)),  # 0x0011
  KeMsgHandler(msgId: MM_SET_EDCA_CFM, handler: cast[pointer](mm_bss_param_setting_handler)),       # 0x0017
  KeMsgHandler(msgId: MM_SET_VIF_STATE_CFM, handler: cast[pointer](mm_set_vif_state_cfm_handler)), # 0x0019
  KeMsgHandler(msgId: ME_SET_PS_DISABLE_CFM, handler: cast[pointer](me_set_ps_disable_cfm_handler_sm)), # 0x0C10 (SM task)
  KeMsgHandler(msgId: MM_SET_PS_OPTIONS_CFM, handler: cast[pointer](ke_msg_discard)),               # 0x003A
  KeMsgHandler(msgId: MM_STA_DEL_CFM, handler: cast[pointer](ke_msg_discard)),                      # 0x000D
  KeMsgHandler(msgId: RXU_MGT_IND, handler: cast[pointer](rxu_mgt_ind_handler_sm)),                  # 0x1C00
]

var sm_default_handler* {.wifiCtrlExport.}: KeTaskHandler =
  KeTaskHandler(msgHandlers: cast[pointer](addr sm_default_state), count: 20)

# --- APM task dispatch (apm_task.o) ---
# Blob hex: 1400,1402,1409,0c0e,002e,0015,0013,0011,0c10,0019,1407,0c06,1c00,1406
var apm_default_state* {.wifiCtrlExport.}: array[14, KeMsgHandler] = [
  KeMsgHandler(msgId: APM_START_REQ, handler: cast[pointer](apm_start_req_handler)),               # 0x1400
  KeMsgHandler(msgId: APM_STOP_REQ, handler: cast[pointer](apm_stop_req_handler)),                 # 0x1402
  KeMsgHandler(msgId: APM_CONF_MAX_STA_REQ, handler: cast[pointer](apm_conf_max_sta_req_handler)), # 0x1409
  KeMsgHandler(msgId: ME_SET_ACTIVE_CFM, handler: cast[pointer](me_set_active_cfm_handler_apm)),  # 0x0C0E (APM task)
  KeMsgHandler(msgId: MM_BCN_CHANGE_CFM, handler: cast[pointer](mm_bcn_change_cfm_handler)),       # 0x002E
  KeMsgHandler(msgId: MM_SET_BSSID_CFM, handler: cast[pointer](mm_bss_param_setting_handler_apm)),     # 0x0015
  KeMsgHandler(msgId: MM_SET_BASIC_RATES_CFM, handler: cast[pointer](mm_bss_param_setting_handler_apm)), # 0x0013
  KeMsgHandler(msgId: MM_SET_BEACON_INT_CFM, handler: cast[pointer](mm_bss_param_setting_handler_apm)),  # 0x0011
  KeMsgHandler(msgId: ME_SET_PS_DISABLE_CFM, handler: cast[pointer](me_set_ps_disable_cfm_handler_apm)), # 0x0C10 (APM task)
  KeMsgHandler(msgId: MM_SET_VIF_STATE_CFM, handler: cast[pointer](ke_msg_discard)),                # 0x0019
  KeMsgHandler(msgId: APM_STA_DEL_REQ, handler: cast[pointer](apm_sta_del_req_handler)),            # 0x1407
  KeMsgHandler(msgId: ME_STA_ADD_CFM, handler: cast[pointer](apm_sta_add_cfm_handler)),             # 0x0C06
  KeMsgHandler(msgId: RXU_MGT_IND, handler: cast[pointer](rxu_mgt_ind_handler_apm)),                 # 0x1C00
  KeMsgHandler(msgId: APM_STA_CONNECT_TIMEOUT_IND, handler: cast[pointer](apm_sta_connect_timeout_ind_handler)), # 0x1406
]

var apm_default_handler* {.wifiCtrlExport.}: KeTaskHandler =
  KeTaskHandler(msgHandlers: cast[pointer](addr apm_default_state), count: 14)

# --- BAM task dispatch (bam_task.o) ---
var bam_default_state* {.wifiCtrlExport.}: array[1, KeMsgHandler] = [
  KeMsgHandler(msgId: RXU_MGT_IND, handler: cast[pointer](rxu_mgt_ind_handler_bam)),
]

var bam_default_handler* {.wifiCtrlExport.}: KeTaskHandler =
  KeTaskHandler(msgHandlers: cast[pointer](addr bam_default_state), count: 1)

# --- ME task dispatch (me_task.o) ---
# Blob hex: 0c00,0c02,0c05,0c07,0c0d,0c0f,0c0a,001b,0020,000d,002a,0030,0c0c
var me_default_state* {.wifiCtrlExport.}: array[13, KeMsgHandler] = [
  KeMsgHandler(msgId: ME_CONFIG_REQ, handler: cast[pointer](me_config_req_handler)),               # 0x0C00
  KeMsgHandler(msgId: ME_CHAN_CONFIG_REQ, handler: cast[pointer](me_chan_config_req_handler)),       # 0x0C02
  KeMsgHandler(msgId: ME_STA_ADD_REQ, handler: cast[pointer](me_sta_add_req_handler)),             # 0x0C05
  KeMsgHandler(msgId: ME_STA_DEL_REQ, handler: cast[pointer](me_sta_del_req_handler)),             # 0x0C07
  KeMsgHandler(msgId: ME_SET_ACTIVE_REQ, handler: cast[pointer](me_set_active_req_handler)),       # 0x0C0D
  KeMsgHandler(msgId: ME_SET_PS_DISABLE_REQ, handler: cast[pointer](me_set_ps_disable_req_handler)), # 0x0C0F
  KeMsgHandler(msgId: ME_TRAFFIC_IND_REQ, handler: cast[pointer](me_traffic_ind_req_handler)),     # 0x0C0A
  KeMsgHandler(msgId: MM_SET_IDLE_CFM, handler: cast[pointer](mm_set_idle_cfm_handler)),           # 0x001B
  KeMsgHandler(msgId: MM_SET_PS_OFF_INTERNAL_REQ, handler: cast[pointer](mm_set_ps_mode_cfm_handler)), # 0x0020
  KeMsgHandler(msgId: MM_STA_DEL_CFM, handler: cast[pointer](ke_msg_discard)),                      # 0x000D
  KeMsgHandler(msgId: MM_CHAN_CTXT_UPDATE_REQ, handler: cast[pointer](ke_msg_discard)),              # 0x002A
  KeMsgHandler(msgId: MM_TIM_UPDATE_CFM, handler: cast[pointer](ke_msg_discard)),                    # 0x0030
  KeMsgHandler(msgId: ME_RC_SET_RATE_REQ, handler: cast[pointer](me_rc_set_rate_req_handler)),     # 0x0C0C
]

var me_default_handler* {.wifiCtrlExport.}: KeTaskHandler =
  KeTaskHandler(msgHandlers: cast[pointer](addr me_default_state), count: 13)

# --- CFG task dispatch (cfg_task.o) ---
var cfg_default_state* {.wifiCtrlExport.}: array[1, KeMsgHandler] = [
  KeMsgHandler(msgId: CFG_START_REQ, handler: cast[pointer](cfg_start_req_handler)),
]

var cfg_default_handler* {.wifiCtrlExport.}: KeTaskHandler =
  KeTaskHandler(msgHandlers: cast[pointer](addr cfg_default_state), count: 1)

# --- MAC lookup tables (mac.o) ---
# mac_tid2ac: TID to Access Category mapping (9 entries)
# Blob hex: 01 00 00 01 02 02 03 03 03
var mac_tid2ac* {.exportc.}: array[9, uint8] = [
  1'u8, 0, 0, 1, 2, 2, 3, 3, 3
]

# mac_ac2uapsd: AC to UAPSD bit mapping (4 entries)
# Blob hex: 04 08 02 01
var mac_ac2uapsd* {.exportc.}: array[4, uint8] = [
  0x04'u8, 0x08, 0x02, 0x01
]

# mac_addr_bcst: Broadcast MAC address
# Blob hex: ff ff ff ff ff ff
var mac_addr_bcst* {.exportc.}: array[6, uint8] = [
  0xFF'u8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
]

# --- TX timeout table (txl_cntrl.o) ---
# TX_TIMEOUT: 5 uint32 entries (microseconds per AC)
# Blob hex: 400d0300 801a0600 (swapped) -> 0x00030d40=200000, 0x001e8480=2000000, ...
var TX_TIMEOUT* {.exportc.}: array[5, uint32] = [
  200000'u32,   # AC_BK: 200ms
  2000000'u32,  # AC_BE: 2000ms
  400000'u32,   # AC_VI: 400ms
  200000'u32,   # AC_VO: 200ms
  50000'u32,    # BCN: 50ms
]

# --- VHT NDBPS table (txl_cntrl.o) ---
# VHT_NDBPS: 40 uint16 entries (NDBPS for VHT MCS/BW combinations)
# Blob hex (LE uint16): 1a00 3400 4e00 6800 9c00 d000 ea00 0401
#   3801 1004 3600 6c00 a200 d800 4401 b001
#   e601 1c02 8802 d002 7500 ea00 5f01 d401
#   be02 a803 1d04 9204 7c05 1806 ea00 d401
#   be02 a803 7c05 5007 3a08 2409 f80a 300c
var VHT_NDBPS* {.exportc.}: array[40, uint16] = [
  26'u16, 52, 78, 104, 156, 208, 234, 260,
  312, 1040, 54, 108, 162, 216, 324, 432,
  486, 540, 648, 720, 117, 234, 351, 468,
  702, 936, 1053, 1170, 1404, 1560, 234, 468,
  702, 936, 1404, 1872, 2106, 2340, 2808, 3120,
]

# nx_txdesc_cnt_msk: TX descriptor count mask (ipc_emb.o)
# Blob hex: 03000000
var nx_txdesc_cnt_msk* {.exportc.}: uint32 = 3

# --- AES round constants for MFP BIP (mfp_bip.o) ---
# rcon_t: 10 uint32 entries (AES Rcon table)
var rcon_t* {.exportc.}: array[10, uint32] = [
  0x01'u32, 0x02, 0x04, 0x08, 0x10,
  0x20, 0x40, 0x80, 0x1B, 0x36,
]

# --- RX vector to MAC rate mapping (hal_machw.o) ---
# rxv2macrate: 16 uint8 entries mapping RX vector format_mod+mcs to rate index
# Blob hex: 00 01 02 03 ff ff ff ff 0a 08 06 04 0b 09 07 05
var rxv2macrate* {.exportc.}: array[16, uint8] = [
  0x00'u8, 0x01, 0x02, 0x03, 0xFF, 0xFF, 0xFF, 0xFF,
  0x0A, 0x08, 0x06, 0x04, 0x0B, 0x09, 0x07, 0x05,
]

# --- IPC embedded event bit table (ipc_emb.o) ---
# ipc_emb_evt_bit: 5 uint32 entries (bit masks for IPC TX events per AC)
# Blob hex: 00020000 00040000 00080000 00100000 00200000
var ipc_emb_evt_bit* {.exportc.}: array[5, uint32] = [
  0x00000200'u32, 0x00000400, 0x00000800, 0x00001000, 0x00002000,
]

# --- TX CFM event bit table (moved to earlier block so txl_cfm_push can reference it) ---

# --- Platform PS params (ps.o) ---
# bl_ps_params: 5 uint32 entries (power save configuration defaults)
# Blob hex: 40420f00 409c0000 02000000 06000000 10270000
var bl_ps_params* {.exportc.}: array[5, uint32] = [
  1000000'u32,  # 0x000F4240: PS wakeup interval (1s in us)
  40000'u32,    # 0x00009C40: PS listen interval
  2'u32,        # PS mode
  6'u32,        # PS DTIM period
  10000'u32,    # 0x00002710: PS timeout
]

# --- TX descriptor calc size (ipc_emb.o) ---
# internel_cal_size_tx_desc: size of TX descriptor (208 = 0xD0)
var internel_cal_size_tx_desc* {.exportc.}: uint32 = 0xD0

# --- BSS variables ---
# cde_evt_tmr_msg: channel delay event timer message flag (chan.o)
var cde_evt_tmr_msg* {.exportc.}: uint8 = 0

# pds_slept_time: PDS sleep time accumulator (arch_main.o)
var pds_slept_time* {.exportc.}: uint32 = 0

# pds_woken_time: PDS woken time accumulator (arch_main.o)
var pds_woken_time* {.exportc.}: uint32 = 0

# sm_reconn_dominant_flag: station reconnect dominant channel flag (sm.o)
var sm_reconn_dominant_flag* {.exportc.}: uint32 = 0

# Note: dbg_assert_block is already defined in global state (line ~902)
# as array[10, uint32] with {.exportc.}. The blob's .data symbol is only
# 4 bytes with initial value 1, but the full array is the actual runtime storage.
# The first element should be initialized to 1 (assert block enabled).

proc configureKeTaskDesc(taskId: uint8, stateTable: pointer,
                         defaultHandler: pointer, statePtr: ptr uint16,
                         stateCount: uint16) {.inline.} =
  let desc = addr keTaskDescs[taskId.int]
  desc.stateTable = stateTable
  desc.defaultHandler = defaultHandler
  desc.statePtr = statePtr
  desc.stateCountPadding = 0
  desc.stateCount = stateCount

type
  KeTaskInitSpec = object
    taskId: uint8
    stateTable: pointer
    defaultHandler: pointer
    statePtr: ptr uint16
    stateCount: uint16

proc configureKeTaskDesc(spec: KeTaskInitSpec) {.inline.} =
  configureKeTaskDesc(spec.taskId, spec.stateTable, spec.defaultHandler,
                      spec.statePtr, spec.stateCount)
