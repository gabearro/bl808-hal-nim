# =============================================================================
# Global firmware state
# =============================================================================
var
  # Kernel event bitmap and handlers
  keEvtField* {.wifiCtrl.}: uint32

  # Kernel message queues: sent, saved, timer
  keMsgQueueSent* {.wifiCtrl.}: CoList
  keMsgQueueSaved* {.wifiCtrl.}: CoList
  keTimerQueue* {.wifiCtrl.}: CoList
  keSavedReschedTask* {.wifiCtrl.}: uint8 = TASK_NONE

  # Task state array (per task)
  keTaskStates* {.wifiCtrl.}: array[TASK_MAX.int, uint16]
  keTaskDescs* {.wifiCtrl.}: array[TASK_MAX.int, KeTaskDesc]

  # Memory allocator function pointers (set by platform at init)
  keAllocFunc* {.wifiCtrl.}: proc(size: uint32): pointer {.cdecl.}
  keFreeFunc* {.wifiCtrl.}: proc(p: pointer) {.cdecl.}
  keScheduleFunc* {.wifiCtrl.}: proc() {.cdecl.}
  keNotifyFunc* {.wifiCtrl.}: proc(ipcBit: uint32) {.cdecl.}
  keWaitFunc* {.wifiCtrl.}: proc(sem: pointer, timeout: int32): int32 {.cdecl.}

  # Platform callback table (from bl_init)
  platformOps* {.wifiCtrl.}: pointer
  platformIpcEnv* {.wifiCtrl.}: pointer
  platformIpcWaitCount* {.wifiCtrl.}: uint32
  # Global IPC wait counter — blob symbol `ipc_emb_counter` (4 bytes BSS).
  ipc_emb_counter* {.exportc.}: uint32

  # MM environment (68-byte struct from mm_env_init memset)
  # Layout from disassembly:
  #   offset 0x00: word 0  (config flags / rx_filter default = 0x7FFFFFDE)
  #   offset 0x04: word 1  (zero)
  #   offset 0x12: half 9  (zero = beacon state)
  #   offset 0x1A: half 13 (0x101 = version/config)
  #   offset 0x1C: word 7  (0x4E20 = 20000 = keep-alive interval in ticks)
  #   offset 0x20: word 8  (10 = keep-alive count limit)
  #   offset 0x34: word 13 (0xFA0 = 4000 = max AMPDU duration)
  mm_env* {.exportc.}: array[17, uint32]  # 68 bytes = 17 words
  mmState*: uint8
  mmBcnInitDone*: bool
  mmActiveVifCount*: uint8
  mmMonitorEnabled*: bool
  mmRxFilterMask*: uint32
  mmKeepAliveEnabled*: bool
  mmKeepAliveTimestamp*: uint32
  mmKeepAliveCounter*: uint32

  # MM timer list (sorted CoList of mm_timer entries)
  # Each entry layout: [0]=next ptr, [4]=callback ptr, [8]=env ptr, [12]=time
  mm_timer_list* {.exportc: "mm_timer_list".}: CoList

  # TX buffer management
  txBufferEnv*: TxBufferDesc

  # TX control environment (92-byte struct from txl_cntrl_init memset)
  # Layout: per-AC struct (16 bytes each) x 5 ACs + global busy flag
  # Per-AC layout:
  #   offset 0: uint32 - first TX descriptor pointer
  #   offset 4: CoList (8 bytes) - pending frame list
  #   offset 12: uint16 - MAC HW descriptor address (half-word)
  #   offset 14: uint8 - busy flag
  #   offset 15: uint8 - padding
  txl_cntrl_env* {.exportc.}: array[23, uint32]  # 92 bytes = 23 words
  txlSeqRetained* {.exportc: "txl_seq_retained".}: uint16
  txlCntrlBusy*: uint16  # Global TX busy flag (from blob)
  txlAcPending*: array[NUM_TX_QUEUES, uint32]
  txlAcBusy*: array[NUM_TX_QUEUES, bool]

  # TX confirm environment (40-byte struct = 5 CoLists)
  txl_cfm_env* {.exportc.}: array[10, uint32]  # 40 bytes = 10 words (5 CoLists of 8 bytes)
  txlCfmList*: CoList

  # Per-AC event bit for TX confirm (matches blob txl_cfm_evt_bit anchor table)
  txl_cfm_evt_bit* {.exportc.}: array[5, uint32] = [
    0x00004000'u32, 0x00008000, 0x00010000, 0x00020000, 0x00040000,
  ]

  # RX environment
  rxSwDescs*: array[RX_BUFFER_POOL_SIZE, RxSwDesc]

  # Blob RX DMA globals — these are what the MAC DMA engine actually reads
  # from. Sizes from `nm`: rx_dma_hdrdesc=0x1004 (41 × 100), rx_swdesc_tab
  # =0x3D8 (41 × 24), rx_payload_desc=0x854 (41 × 52), rx_payload_desc_buffer
  # =0x11608 (41 × 1736). They must be addressable at their blob names so the
  # MAC register writes in rxl_hwdesc_init land at the right physical pages.
  rx_dma_hdrdesc* {.exportc, wifiRxDmaHd.}: array[4100, uint8]
  rx_payload_desc* {.exportc, wifiRxDmaPd.}: array[2132, uint8]
  rx_swdesc_tab* {.exportc, wifiRxDmaSw.}: array[984, uint8]
  rx_payload_desc_buffer* {.exportc, wifiRxDmaBuf.}: array[71176, uint8]

  # RX HW descriptor environment (from rxl_hwdesc.c)
  # Layout (28 bytes):
  #   [0]  ptr   - current RX HW descriptor (first in chain)
  #   [4]  ptr   - last RX HW descriptor
  #   [8]  ptr   - free descriptor head
  #   [12] uint32 - descriptor count
  #   [16] uint32 - flags
  #   [20] uint32 - reserved
  #   [24] uint8  - processing flag (set when ISR is active)
  rxl_hwdesc_env* {.exportc.}: array[7, uint32]  # 28 bytes = 7 words
  # rxl_cntrl_env: RX lower control environment (28 bytes)
  rxl_cntrl_env* {.exportc.}: array[7, uint32]

  # Channel management environment (132-byte struct from chan_init memset).
  # Channel context storage is the separate 140-byte chan_ctxt_pool blob
  # COMMON symbol; chan_env itself holds lists, timers, callbacks, and state.
  chan_env* {.exportc.}: array[33, uint32]  # 132 bytes = 33 words
  chanCtxtCount*: uint8
  chanCtxtFlags*: uint8
  chanCurrentCtxt*: pointer
  chanPendingCtxt*: pointer
  chanConflictCount*: uint32
  chanConflictDetected*: bool
  chanScanPending*: bool

  # Scan lower-MAC environment (exported as "scan_env", 24 bytes)
  # offset 10 (0x0A): abort request flag byte
  scan_env* {.exportc.}: ScanEnvObj
  scanDurationActive*: uint32
  scanDurationPassive*: uint32
  scanDurationJoinActive*: uint32
  scanChanIdx*: uint32
  scanProbeDelay*: uint32

  # Scan probe request IE buffer (236 bytes, COMMON symbol in blob).
  scan_probe_req_ie* {.exportc.}: ScanProbeReqIeObj

  # Scan-upper environment (exported as "scanu_env")
  scanu_env* {.exportc.}: ScanuEnvObj
  scanuCachedSsids: array[SCANU_MAX_RESULT_ENTRIES, ScanuCachedSsid]
  scanuCachedChannels: array[SCANU_MAX_RESULT_ENTRIES, ScanChannelEntry]
  scanuJoinHandler*: pointer  # Function pointer stored during scanu_init
  scanuResults*: array[MAX_SCAN_RESULTS, pointer]
  scanuResultCount*: uint32

  # Power save environment (ps_env is the C-exported 56-byte struct)
  psEnabled*: bool
  psMode*: uint8
  psPollPending*: bool
  psNullPending*: bool
  psTrafficStatus*: uint32

  # Power save environment struct matching blob layout (56 bytes = 14 words)
  # Exported as C symbol "ps_env" for blob ABI compatibility.
  # Layout (from disassembly):
  #   offset 0x00: word 0 (general flags / enabled)
  #   offset 0x04: word 1 (status flags; bit 2 = idle req pending)
  #   offset 0x08: word 2
  #   offset 0x0C: word 3
  #   offset 0x10: word 4 (ptr to ps_uapsd_timer_handle)
  #   ...
  #   offset 0x28: word 10 (ptr to ps_tx_null_timer_handle)
  #   ...up to offset 0x34 (word 13)
  ps_env* {.exportc.}: array[14, uint32]

  # Time domain environment (per-VIF: 44 bytes each, 2 VIFs)
  # td_env is the base; td_reset uses stride=44 to index per-VIF.
  td_env* {.exportc.}: array[22, uint32]  # 88 bytes = 22 words (2 * 44 bytes)
  tdTimerActive*: bool
  tdRecoveryTimerActive*: bool

  # TPC (TX power control)
  tpcPowerTable*: array[38, int8]
  tpcPowerRateTable*: array[24, int8]
  tpcChannelOffsetTable*: array[14, int8]

  # Config elements
  cfgElements*: array[32, uint32]
  cfgElementCount*: uint32

  # ME environment (136-byte struct from me_init memset)
  me_env* {.exportc.}: array[34, uint32]  # 136 bytes = 34 words

  # Rate control stats pool: MAX_STAS entries of RC_STATS_SIZE bytes each.
  # Indexed by sta_info_tab[staIdx].info_idx. Pointed to from sta+324.
  rcStaStatsPool* {.exportc: "rc_ss".}: array[MAX_STAS * RC_STATS_SIZE, uint8]

  # Rate control PRNG state (LCG: next = state * RC_PRNG_MULT + RC_PRNG_INCR)
  rcPrngState* {.exportc: "rc_prng".}: uint32

  # BAM environment
  bamStaIdx*: uint8  # Current BA station index, 0xFF = none

  # IPC environment (20-byte struct from ipc_emb_init memset)
  # Layout:
  #   offset 0x00: word 0  (general)
  #   offset 0x04: word 1  (status flags; bit 0 cleared by dma_int_handler_backup)
  #   offset 0x08: word 2
  #   offset 0x0C: word 3  (ptr callback 1)
  #   offset 0x10: word 4  (ptr callback 2)
  ipcEmbEnvStruct* {.exportc: "ipc_emb_env".}: array[5, uint32]  # 20 bytes = 5 words
  ipcEmbEnv*: pointer
  ipcEmbCallbacks*: array[5, pointer]

  # IPC shared memory: host writes current message fields here and triggers IRQ.
  # Layout (from blob ipc_emb_msg_evt disassembly):
  #   offset 0x04 (u16): msgId
  #   offset 0x06 (u8):  msgDst (task id)
  #   offset 0x07 (u8):  counter slot (embedded writes ipc_emb_env[0] here)
  #   offset 0x08 (u32): paramLen (payload size in bytes)
  #   offset 0x0C+:      payload
  # Total size is 0x24dc = 9436 bytes in blob.
  ipcSharedEnv* {.exportc: "ipc_shared_env".}: array[2359, uint32]  # 9436 bytes

  # HAL MACHW environment (two-word struct from blob)
  halMachwRxCntrlBackup*: uint32   # RX filter mask backup (offset 0 in blob struct)
  halMachwStatusFlags*: uint32     # Status flags: bit 2 = idle req pending (offset 4 in blob struct)

  # Coexistence
  coexPtaAutoControl*: uint32       # PTA state: 0=disabled, 1=enabled, -1=forced
  coexPtaTimestamp*: uint32          # Timestamp of last state change
  coexPtaAccum*: uint32              # Accumulated time in current state

  # SM state
  smConnecting*: bool
  smAuthRetryLimit*: uint8
  smReconnectTrigger*: bool

  # APM (AP Management) environment.
  # Byte-level layout (from disasm):
  #   offset 0:  pointer to current APM connect-info struct
  #   offset 4..15: additional APM state
  #   offset 16: pointer to beacon buffer (used by apm_bcn_set)
  #   offset 90: APM task instance number (set by apm_start_cfm)
  # Sized at 96 bytes to cover all accessed offsets (incl. apm_start_cfm offset 90).
  apm_env* {.exportc.}: array[176, uint8]

  # Hostapd context pointer and enabled flag for embedded AP.
  hostapd_ctx* {.exportc.}: pointer
  hostapd_enabled* {.exportc.}: uint8

  # VIF management environment (20 bytes).
  # Byte-level layout:
  #   offset 0:  pointer to active VIF list head
  #   offset 8:  pointer to VIF list node pool
  #   offset 16: STA-mode VIF count
  #   offset 17: AP-mode VIF count
  #   offset 18: most-recent STA vifIdx
  vif_mgmt_env* {.exportc.}: array[20, uint8]

  # Station info table (7 entries, STA_ENTRY_SIZE=368 bytes each)
  # Exported as C symbol "sta_info_tab" for blob ABI compatibility.
  # Blob sta_info_tab is 2576 bytes = 7 * 368. Entries 0..4 are the normal
  # free STA pool; entries 5 and 6 are the two broadcast STA slots.
  sta_info_tab* {.exportc.}: array[STA_INFO_TAB_ENTRIES * STA_ENTRY_SIZE, uint8]

  # VIF info table (MAX_VIFS=2 entries, VIF_ENTRY_SIZE=1504 bytes each)
  # Exported as C symbol "vif_info_tab" for blob ABI compatibility.
  vif_info_tab* {.exportc.}: array[MAX_VIFS * VIF_ENTRY_SIZE, uint8]

  # SM environment (connection manager state).
  # Byte-level layout (from disasm):
  #   offset 0:  pointer to current connect-info struct
  #   offset 44: uint8  connection state (2 = WPS mode)
  # Sized at 48 bytes to cover all accessed offsets.
  sm_env* {.exportc.}: array[56, uint8]
  assocSecIeStore* {.wifiCtrl.}: array[MAX_VIFS, array[128, uint8]]

  # WPS callback pointer.  Points to callback struct:
  #   [0]=ptr, ..., [8]=wps_sta_add_cb function ptr.
  # NULL when WPS is not active.
  wps_cbs* {.exportc.}: pointer

  # WPA callback pointer.  Points to callback struct:
  #   ..., [12]=key_write_cb function ptr.
  wpa_cbs* {.exportc.}: pointer

  # Platform operations function table (set by bl_init).
  # Byte-level access; offset 204 = log function pointer.
  g_bl_ops_funcs* {.importc: "g_bl_ops_funcs", header: "bl_os_adapter.h".}: BlOpsFuncs

  # Application IE storage for bl_wifi_set_appie_internal.
  # ieType=1: beacon extra IE (max 170 bytes)
  appIeBeaconPtr*: pointer    # IE data pointer for beacon extra IEs
  appIeBeaconLen*: uint16     # IE data length for beacon extra IEs
  # ieType=2: probe response extra IE (max 50 bytes)
  appIeProbeRespPtr*: pointer # IE data pointer for probe response extra IEs
  appIeProbeRespLen*: uint16  # IE data length for probe response extra IEs

  # Nap hook linked list head pointer (each entry: [0]=next, [4]=callback).
  napHookListHead*: pointer

  # Sleep/nap scheduling state.
  napScheduleState*: uint32   # current nap VIF state for sleep scheduling
  napSleepActive*: uint8      # sleep-active flag (non-zero = sleep management active)
  napSleepListPtr*: pointer   # associated list pointer (at napSleepActive+4 in blob)

  # WPS status byte (read/written by bl_wifi_get/set_wps_status_internal)
  wpsStatus*: uint8

  # Debug / assert environment (40 bytes).
  # Layout from blob (base at 0x24b08180 in linked binary):
  #   offset 0:  uint32 - assert type (0=ERR, 1=WARN, 2=REC)
  #   offset 4:  pointer - file/condition string
  #   offset 8:  uint32 - saved register / backtrace word 0
  #   offset 12: uint32 - saved register / backtrace word 1
  #   offset 16: uint32 - saved register / backtrace word 2
  #   offset 20: uint32 - saved register / backtrace word 3
  #   offset 24: uint32 - saved register / backtrace word 4
  #   offset 28: uint32 - saved register / backtrace word 5
  #   offset 32: uint32 - saved register / backtrace word 6
  #   offset 36: uint32 - saved register / backtrace word 7
  dbg_assert_block* {.exportc.}: array[10, uint32]

  # Interrupt controller handler table.
  # Indexed by IRQ source from MAC_PL_IRQ_HANDLER register.
  # Each entry is a function pointer (ISR callback).
  intc_handler_tab* {.exportc.}: array[64, pointer]

  # BL60x firmware MPDU environment.
  # Layout (from disassembly of bl60x_firmwre_mpdu_free):
  #   offset 20: function pointer - pre-free callback (txl notification)
  #   offset 24: function pointer - post-free callback (rxl notification)
  bl60x_fw_env* {.exportc.}: array[8, uint32]  # 32 bytes = 8 words
  bl_env* {.exportc.}: array[2, uint32]  # 8 bytes (bl_env from blob)
  bam_env* {.exportc.}: array[96, uint8]        # blob: 96 bytes
  mm_timer_env* {.exportc.}: array[8, uint8]    # blob: 8 bytes
  rx_hwdesc_env* {.exportc.}: array[8, uint8]   # blob: 8 bytes (distinct from rxl_hwdesc_env)
  # Blob C globals absent from earlier Nim — declared as exportc so that
  # code relocations to these symbols resolve to the right memory:
  chan_ctxt_pool* {.exportc.}: array[140, uint8]  # 5 × 28-byte contexts
  bcn_dwnld_desc* {.exportc.}: array[16, uint8]
  scanu_add_ie* {.exportc.}: array[216, uint8]
  sta_stats* {.exportc.}: array[1000, uint8]      # 5 × 200-byte rc_sta_stats
  # Config TLV scratch storage is not DMA descriptor memory. Keep it out of the
  # uncached WiFi descriptor BSS so TX/RX descriptor anchors match the vendor path.
  cfg_start_req_u_tlv_t* {.wifiCtrlExport.}: array[12, uint8]
  txl_frame_buf_ctrl* {.exportc.}: array[240, uint8]
  txl_frame_hwdesc_cfms* {.exportc.}: array[80, uint8]
  txl_frame_hwdesc_pool* {.exportc.}: array[288, uint8]
  txl_frame_pool* {.exportc.}: array[3440, uint8]
  # Private txl_frame.o descriptor array (.LANCHOR0 in the vendor object):
  # 4 descriptors * 220 bytes. These list nodes are what txl_frame_env holds.
  txl_frame_desc_storage: array[4 * 220, uint8]
  txl_buffer_control_desc* {.exportc.}: array[300, uint8]
  txl_buffer_env* {.exportc.}: array[220, uint8]
  fw_nap_chain* {.exportc.}: array[3, uint32]  # 12 bytes
  fw_nap_chain_ptr {.exportc: "fw_nap_chain_ptr".}: pointer  # BSS pointer to fw_nap_chain

  # RXL environment for MPDU tracking.
  # offset 20: uint32 - pending MPDU count
  rxl_mpdu_env* {.exportc.}: array[8, uint32]  # 32 bytes

  # Channel env timer target (for chan_ctxt_get_remaining_time_ms).
  chanEnvTimerTarget*: uint32

  # Beacon TX descriptor pools (used by mm_bcn_init_vif and mm_bcn_transmit).
  # txl_bcn_pool: main beacon frame descriptor pool (passed to txl_frame_init_desc)
  txl_bcn_pool* {.exportc.}: array[860, uint8]
  # txl_bcn_hwdesc_pool: beacon HW descriptor pool
  txl_bcn_hwdesc_pool* {.exportc.}: array[72, uint8]
  # txl_bcn_hwdesc_cfms: beacon HW descriptor confirmation pool (20 bytes
  # per blob nm output, not a single pointer).
  txl_bcn_hwdesc_cfms* {.exportc.}: array[20, uint8]
  # txl_bcn_buf_ctrl: beacon buffer control descriptor
  txl_bcn_buf_ctrl* {.exportc.}: array[60, uint8]
  # txl_bcn_end_desc: beacon end descriptor (24+ bytes, used as linked list node)
  txl_bcn_end_desc* {.exportc.}: array[20, uint8]
  # txl_tim_desc: TIM update descriptor (20+ bytes)
  txl_tim_desc* {.exportc.}: array[40, uint8]
  # txl_tim_ie_pool: TIM IE data pool (contains TIM IE bytes)
  txl_tim_ie_pool* {.exportc.}: array[6, uint8]
  # txl_tim_bitmap_pool: TIM bitmap buffer (252 bytes for TIM bitmap)
  txl_tim_bitmap_pool* {.exportc.}: array[251, uint8]
  # txl_buffer_control_desc_bcmc: broadcast/multicast TX buffer control descriptor
  txl_buffer_control_desc_bcmc* {.exportc.}: array[120, uint8]
  # txl_buffer_control_24G: 2.4GHz TX buffer control (60 bytes = 0x3C)
  txl_buffer_control_24G* {.exportc.}: array[15, uint32]
  # mm_bcn_env: beacon management environment struct
  # Layout: [0]=ptr(list head), [4]=pending count, [8]=flag, [9]=defer,
  #         [12]=CoList(tim update queue), ...
  mm_bcn_env* {.exportc.}: array[20, uint8]  # blob: 20 bytes (not 32)
  # txl_frame_env: TX frame descriptor environment
  txl_frame_env* {.exportc.}: array[20, uint8]  # blob: 20 bytes
  # sta_info_env: STA info free list (CoList)
  sta_info_env* {.exportc.}: CoList
  # ke_env: kernel event environment (first word = event bitmap, at offset 28 = bcn PS flags)
  ke_env* {.exportc.}: array[36, uint8]  # blob: 36 bytes
  # TBTT aging countdown static variables (used by mm_tbtt_evt)
  mmTbttAgingCount0*: uint8 = 2   # .LANCHOR0: aging period counter
  mmTbttAgingCount1*: uint8 = 10  # .LANCHOR1: second aging counter
