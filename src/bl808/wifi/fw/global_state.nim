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

# Type alias for the platform log function used throughout the firmware.
# Calling convention: log(level, severity, file_str, line_num, ...)
type
  PlatformLogFunc* = proc(level: uint32, sev: uint32, file: pointer,
                           line: uint32) {.cdecl, varargs.}

# Helper: get the log function pointer from g_bl_ops_funcs at byte offset.
proc blOpsFunc(offset: int): pointer {.inline.} =
  cast[ptr pointer](cast[uint](addr g_bl_ops_funcs) + offset.uint)[]

proc getLogFunc(offset: int): PlatformLogFunc {.inline.} =
  cast[PlatformLogFunc](blOpsFunc(offset))

# Forward declare memset for zero-init
proc c_memset(s: pointer, c: cint, n: csize_t): pointer {.importc: "memset", header: "<string.h>".}
proc c_memmove(dst, src: pointer, n: csize_t): pointer {.importc: "memmove", header: "<string.h>".}
proc c_strlen(s: pointer): csize_t {.importc: "strlen", header: "<string.h>".}
proc c_snprintf(buf: pointer, size: csize_t, fmt: cstring): cint {.importc: "snprintf", header: "<stdio.h>", varargs.}
proc c_sprintf(buf: pointer, fmt: cstring): cint {.importc: "sprintf", header: "<stdio.h>", varargs, discardable.}

proc copyIeBytes(dst: pointer; src: pointer; n: uint): pointer {.inline.} =
  if n != 0:
    discard c_memcpy(dst, src, n.csize_t)
  ieCursorAfter(dst, n)

when not isMainModule:
  {.emit: "void NimMain(void);".}

var nimFwDbgFrameTraceCount {.wifiCtrl.}: uint32
var nimFwDbgIpcTxTraceCount {.wifiCtrl.}: uint32
var nimFwDbgCfmTraceCount {.wifiCtrl.}: uint32
var nimFwDbgEapolTraceCount {.wifiCtrl.}: uint32
# TX-path investigation counters (iter 261). Read after test via UART dump.
var nimFwDbgPayBackupEntry* {.wifiCtrl, exportc: "nimfw_dbg_pay_backup".}: uint32
var nimFwDbgPayDescFound*   {.wifiCtrl, exportc: "nimfw_dbg_pay_desc".}: uint32
var nimFwDbgPayHasPayload*  {.wifiCtrl, exportc: "nimfw_dbg_pay_payload".}: uint32
var nimFwDbgPayEmptyList*   {.wifiCtrl, exportc: "nimfw_dbg_pay_empty".}: uint32
var nimFwDbgPayNonEmpty*    {.wifiCtrl, exportc: "nimfw_dbg_pay_nonempty".}: uint32
var nimFwDbgPayTriggerLast* {.wifiCtrl, exportc: "nimfw_dbg_pay_trig".}: uint32
var nimFwDbgPayTxStatus* {.wifiCtrl, exportc: "nimfw_dbg_pay_tx_status".}: uint32
var nimFwDbgPayTxAgg* {.wifiCtrl, exportc: "nimfw_dbg_pay_tx_agg".}: uint32
var nimFwDbgPayTxDma* {.wifiCtrl, exportc: "nimfw_dbg_pay_tx_dma".}: uint32
var nimFwDbgPayTxCurrent* {.wifiCtrl, exportc: "nimfw_dbg_pay_tx_current".}: uint32
var nimFwDbgPayTxThd* {.wifiCtrl, exportc: "nimfw_dbg_pay_tx_thd".}: uint32
var nimFwDbgPayTxHead* {.wifiCtrl, exportc: "nimfw_dbg_pay_tx_head".}: uint32
var nimFwDbgProbePayMeta* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_meta".}: uint32
var nimFwDbgProbePayDesc* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_desc".}: uint32
var nimFwDbgProbePayLink* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_link".}: uint32
var nimFwDbgProbePayHw* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw".}: uint32
var nimFwDbgProbePayThd* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_thd".}: uint32
var nimFwDbgProbePayLen* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_len".}: uint32
var nimFwDbgProbePayHw0* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw0".}: uint32
var nimFwDbgProbePayHw1* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw1".}: uint32
var nimFwDbgProbePayHw2* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw2".}: uint32
var nimFwDbgProbePayHw3* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw3".}: uint32
var nimFwDbgProbePayLink0* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_link0".}: uint32
var nimFwDbgProbePayLink1* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_link1".}: uint32
var nimFwDbgProbePayHwStart* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw_start".}: uint32
var nimFwDbgProbePayHwEnd* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw_end".}: uint32
var nimFwDbgProbePayHwFrameLen* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw_frame_len".}: uint32
var nimFwDbgProbePayHwStatus* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw_status".}: uint32
var nimFwDbgProbePayHwCtrl* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw_ctrl".}: uint32
var nimFwDbgProbePayHwChain* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw_chain".}: uint32
var nimFwDbgProbePayHwRetryLimitControl* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw_retry_limit_control".}: uint32
var nimFwDbgProbePayHwAckPolicyControl* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw_ack_policy_control".}: uint32
var nimFwDbgProbePayHwCompatRetryLimitControl* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw_word36".}: uint32
var nimFwDbgProbePayHwCompatAckPolicyControl* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_hw_word56".}: uint32
var nimFwDbgProbePayRaw* {.wifiCtrl, exportc: "nimfw_dbg_probe_pay_raw".}: array[96, uint8]
var nimFwDbgProbeIeLen* {.wifiCtrl, exportc: "nimfw_dbg_probe_ie_len".}: uint32
var nimFwDbgProbeIeRaw* {.wifiCtrl, exportc: "nimfw_dbg_probe_ie_raw".}: array[64, uint8]
var nimFwDbgTxTrigEntry*    {.wifiCtrl, exportc: "nimfw_dbg_txtrig_entry".}: uint32
var nimFwDbgFrameGet*       {.wifiCtrl, exportc: "nimfw_dbg_frame_get".}: uint32
var nimFwDbgFrameGetInvalid* {.wifiCtrl, exportc: "nimfw_dbg_frame_get_invalid".}: uint32
var nimFwDbgFrameGetInvalidPtr* {.wifiCtrl, exportc: "nimfw_dbg_frame_get_invalid_ptr".}: uint32
var nimFwDbgFrameGetInvalidNext* {.wifiCtrl, exportc: "nimfw_dbg_frame_get_invalid_next".}: uint32
var nimFwDbgFrameFreeRebuild* {.wifiCtrl, exportc: "nimfw_dbg_frame_free_rebuild".}: uint32
var nimFwDbgFrameFreeReclaimed* {.wifiCtrl, exportc: "nimfw_dbg_frame_free_reclaimed".}: uint32
var nimFwDbgFrameFreePushInvalid* {.wifiCtrl, exportc: "nimfw_dbg_frame_free_push_invalid".}: uint32
var nimFwDbgTxPendingInvalid* {.wifiCtrl, exportc: "nimfw_dbg_tx_pending_invalid".}: uint32
var nimFwDbgTxPendingInvalidPtr* {.wifiCtrl, exportc: "nimfw_dbg_tx_pending_invalid_ptr".}: uint32
var nimFwDbgTxThdNoBuffer* {.wifiCtrl, exportc: "nimfw_dbg_tx_thd_nobuf".}: uint32
var nimFwDbgTxThdNoBufferDesc* {.wifiCtrl, exportc: "nimfw_dbg_tx_thd_nobuf_desc".}: uint32
var nimFwDbgApmStaAddNoSlot* {.wifiCtrl, exportc: "nimfw_dbg_apm_sta_add_noslot".}: uint32
var nimFwDbgApmStaAddNoSlotSta* {.wifiCtrl, exportc: "nimfw_dbg_apm_sta_add_noslot_sta".}: uint32
var nimFwDbgKeTimerYield* {.wifiCtrl, exportc: "nimfw_dbg_ke_timer_yield".}: uint32
var nimFwDbgKeTimerYieldHead* {.wifiCtrl, exportc: "nimfw_dbg_ke_timer_yield_head".}: uint32
var nimFwDbgMmTimerYield* {.wifiCtrl, exportc: "nimfw_dbg_mm_timer_yield".}: uint32
var nimFwDbgMmTimerYieldHead* {.wifiCtrl, exportc: "nimfw_dbg_mm_timer_yield_head".}: uint32
var nimFwDbgIpcMsgYield* {.wifiCtrl, exportc: "nimfw_dbg_ipc_msg_yield".}: uint32
var nimFwDbgIpcMsgYieldStatus* {.wifiCtrl, exportc: "nimfw_dbg_ipc_msg_yield_status".}: uint32
var nimFwDbgIpcTxYield* {.wifiCtrl, exportc: "nimfw_dbg_ipc_tx_yield".}: uint32
var nimFwDbgIpcTxYieldAc* {.wifiCtrl, exportc: "nimfw_dbg_ipc_tx_yield_ac".}: uint32
var nimFwDbgIpcTxYieldHead* {.wifiCtrl, exportc: "nimfw_dbg_ipc_tx_yield_head".}: uint32
var nimFwDbgSavedMsgYield* {.wifiCtrl, exportc: "nimfw_dbg_saved_msg_yield".}: uint32
var nimFwDbgSavedMsgYieldTask* {.wifiCtrl, exportc: "nimfw_dbg_saved_msg_yield_task".}: uint32
var nimFwDbgCfmEvtYield* {.wifiCtrl, exportc: "nimfw_dbg_cfm_evt_yield".}: uint32
var nimFwDbgCfmEvtYieldAc* {.wifiCtrl, exportc: "nimfw_dbg_cfm_evt_yield_ac".}: uint32
var nimFwDbgTxTrigYield* {.wifiCtrl, exportc: "nimfw_dbg_txtrig_yield".}: uint32
var nimFwDbgTxTrigYieldAc* {.wifiCtrl, exportc: "nimfw_dbg_txtrig_yield_ac".}: uint32
var nimFwDbgTxTrigYieldHead* {.wifiCtrl, exportc: "nimfw_dbg_txtrig_yield_head".}: uint32
var nimFwDbgTxTrigLastDesc* {.wifiCtrl, exportc: "nimfw_dbg_txtrig_desc".}: uint32
var nimFwDbgTxTrigLastStatus* {.wifiCtrl, exportc: "nimfw_dbg_txtrig_status".}: uint32
var nimFwDbgTxTrigNotReady* {.wifiCtrl, exportc: "nimfw_dbg_txtrig_notready".}: uint32
var nimFwDbgTxTrigNoDesc* {.wifiCtrl, exportc: "nimfw_dbg_txtrig_nodesc".}: uint32
var nimFwDbgFrameEvtYield* {.wifiCtrl, exportc: "nimfw_dbg_frame_evt_yield".}: uint32
var nimFwDbgFrameEvtYieldHead* {.wifiCtrl, exportc: "nimfw_dbg_frame_evt_yield_head".}: uint32
var nimFwDbgRxTimerYield* {.wifiCtrl, exportc: "nimfw_dbg_rx_timer_yield".}: uint32
var nimFwDbgRxTimerYieldHead* {.wifiCtrl, exportc: "nimfw_dbg_rx_timer_yield_head".}: uint32
var nimFwDbgMacIrq* {.wifiCtrl, exportc: "nimfw_dbg_mac_irq".}: uint32
var nimFwDbgMacIrqLast* {.wifiCtrl, exportc: "nimfw_dbg_mac_irq_last".}: uint32
var nimFwDbgMacIrqSlot50* {.wifiCtrl, exportc: "nimfw_dbg_mac_irq_slot50".}: uint32
var nimFwDbgMacIrqSlot52* {.wifiCtrl, exportc: "nimfw_dbg_mac_irq_slot52".}: uint32
var nimFwDbgMacIrqSlot53* {.wifiCtrl, exportc: "nimfw_dbg_mac_irq_slot53".}: uint32
var nimFwDbgMacIrqSlot54* {.wifiCtrl, exportc: "nimfw_dbg_mac_irq_slot54".}: uint32
var nimFwDbgMacIrqSlotOther* {.wifiCtrl, exportc: "nimfw_dbg_mac_irq_slot_other".}: uint32
var nimFwDbgMacIrqLastHandler* {.wifiCtrl, exportc: "nimfw_dbg_mac_irq_last_handler".}: uint32
var nimFwDbgMacIrqLastIntRaw* {.wifiCtrl, exportc: "nimfw_dbg_mac_irq_last_int_raw".}: uint32
var nimFwDbgMacIrqLastGenRaw* {.wifiCtrl, exportc: "nimfw_dbg_mac_irq_last_gen_raw".}: uint32
var nimFwDbgMacIrqLastRxCtrl* {.wifiCtrl, exportc: "nimfw_dbg_mac_irq_last_rxctrl".}: uint32
var nimFwDbgMacIrqLastHd* {.wifiCtrl, exportc: "nimfw_dbg_mac_irq_last_hd".}: uint32
var nimFwDbgMacIrqLastPd* {.wifiCtrl, exportc: "nimfw_dbg_mac_irq_last_pd".}: uint32
var nimFwDbgMachwGen* {.wifiCtrl, exportc: "nimfw_dbg_machw_gen".}: uint32
var nimFwDbgMachwStatus* {.wifiCtrl, exportc: "nimfw_dbg_machw_status".}: uint32
var nimFwDbgMachwGenStatus* {.wifiCtrl, exportc: "nimfw_dbg_machw_gen_status".}: uint32
var nimFwDbgRxlTimerEvt* {.wifiCtrl, exportc: "nimfw_dbg_rxl_timer_evt".}: uint32
var nimFwDbgRxlTimerReady* {.wifiCtrl, exportc: "nimfw_dbg_rxl_timer_ready".}: uint32
var nimFwDbgRxlTimerHead* {.wifiCtrl, exportc: "nimfw_dbg_rxl_timer_head".}: uint32
var nimFwDbgRxlCntrlEvt* {.wifiCtrl, exportc: "nimfw_dbg_rxl_cntrl_evt".}: uint32
var nimFwDbgRxlCntrlHead* {.wifiCtrl, exportc: "nimfw_dbg_rxl_cntrl_head".}: uint32
var nimFwDbgRxlDmaEvt* {.wifiCtrl, exportc: "nimfw_dbg_rxl_dma_evt".}: uint32
var nimFwDbgRxlSnapHd* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_hd".}: uint32
var nimFwDbgRxlSnapPd* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_pd".}: uint32
var nimFwDbgRxlSnapHwHd* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_hw_hd".}: uint32
var nimFwDbgRxlSnapHwPd* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_hw_pd".}: uint32
var nimFwDbgRxlSnapMask* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_mask".}: uint32
var nimFwDbgRxlSnapRxCtrl* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_rxctrl".}: uint32
var nimFwDbgRxlSnapIntUnmask* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_int_unmask".}: uint32
var nimFwDbgRxlSnapGenUnmask* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_gen_unmask".}: uint32
var nimFwDbgRxlSnapRxCtrlRaw* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_rxctrl_raw".}: uint32
var nimFwDbgRxlSnapStatusRaw* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_status_raw".}: uint32
var nimFwDbgRxlSnapIrqRaw* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_irq_raw".}: uint32
var nimFwDbgRxlSnapGenRaw* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_gen_raw".}: uint32
var nimFwDbgRxlSnapHdStatus* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_hd_status".}: uint32
var nimFwDbgRxlSnapPdStatus* {.wifiCtrl, exportc: "nimfw_dbg_rxl_snap_pd_status".}: uint32
var nimFwDbgScanStartRxCtrl* {.wifiCtrl, exportc: "nimfw_dbg_scan_start_rxctrl".}: uint32
var nimFwDbgScanStartIrqRaw* {.wifiCtrl, exportc: "nimfw_dbg_scan_start_irq_raw".}: uint32
var nimFwDbgScanStartGenRaw* {.wifiCtrl, exportc: "nimfw_dbg_scan_start_gen_raw".}: uint32
var nimFwDbgScanEndRxCtrl* {.wifiCtrl, exportc: "nimfw_dbg_scan_end_rxctrl".}: uint32
var nimFwDbgScanEndIrqRaw* {.wifiCtrl, exportc: "nimfw_dbg_scan_end_irq_raw".}: uint32
var nimFwDbgScanEndGenRaw* {.wifiCtrl, exportc: "nimfw_dbg_scan_end_gen_raw".}: uint32
var nimFwDbgScanReqChanMeta* {.wifiCtrl, exportc: "nimfw_dbg_scan_req_chan_meta".}: uint32
var nimFwDbgScanReqChanFreq* {.wifiCtrl, exportc: "nimfw_dbg_scan_req_chan_freq".}: uint32
var nimFwDbgChanScanChanMeta* {.wifiCtrl, exportc: "nimfw_dbg_chan_scan_chan_meta".}: uint32
var nimFwDbgChanScanChanFreq* {.wifiCtrl, exportc: "nimfw_dbg_chan_scan_chan_freq".}: uint32
var nimFwDbgChanPreChanMeta* {.wifiCtrl, exportc: "nimfw_dbg_chan_pre_chan_meta".}: uint32
var nimFwDbgChanPreChanFreq* {.wifiCtrl, exportc: "nimfw_dbg_chan_pre_chan_freq".}: uint32
var nimFwDbgMacTimingE8* {.wifiCtrl, exportc: "nimfw_dbg_mac_timing_e8".}: uint32
var nimFwDbgMacTimingF0* {.wifiCtrl, exportc: "nimfw_dbg_mac_timing_f0".}: uint32
var nimFwDbgMacTimingF4* {.wifiCtrl, exportc: "nimfw_dbg_mac_timing_f4".}: uint32
var nimFwDbgMacTimingF8* {.wifiCtrl, exportc: "nimfw_dbg_mac_timing_f8".}: uint32
var nimFwDbgMacTiming104* {.wifiCtrl, exportc: "nimfw_dbg_mac_timing_104".}: uint32
var nimFwDbgScanStartPhyRaw* {.wifiCtrl, exportc: "nimfw_dbg_scan_start_phy_raw".}: array[4, uint32]
var nimFwDbgScanEndPhyRaw* {.wifiCtrl, exportc: "nimfw_dbg_scan_end_phy_raw".}: array[4, uint32]
const NimFwDbgRfPhyTraceLen {.intdefine.} = 8
var nimFwDbgRfPhyTraceCount* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_count".}: uint32
var nimFwDbgRfPhyTracePhase* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_phase".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceDevice* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_device".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceChanMeta* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_chan_meta".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceChanFreq* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_chan_freq".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf70* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf70".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf74* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf74".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf2c* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf2c".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf04* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf04".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf34* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf34".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf40* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf40".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf4c* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf4c".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf88* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf88".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf90* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf90".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRfa0* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rfa0".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRfa4* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rfa4".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRfbc* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rfbc".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRfd0* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rfd0".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf80* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf80".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf84* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf84".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf8c* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf8c".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRfb4* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rfb4".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf1600* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf1600".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf1614* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf1614".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf1618* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf1618".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf162c* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf162c".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf1680* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf1680".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRf113c* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rf113c".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTracePhy820* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_phy820".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTracePhy824* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_phy824".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTracePhy830* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_phy830".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTracePhy874* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_phy874".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceRxCtrl* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_rxctrl".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceIrqRaw* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_irqraw".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceGenRaw* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_genraw".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceHd* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_hd".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTracePd* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_pd".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceHwHd* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_hwhd".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfPhyTraceHwPd* {.wifiCtrl, exportc: "nimfw_dbg_rf_phy_trace_hwpd".}: array[NimFwDbgRfPhyTraceLen, uint32]
var nimFwDbgRfCalSaveCount* {.wifiCtrl, exportc: "nimfw_dbg_rf_cal_save_count".}: uint32
var nimFwDbgRfCalRestoreCount* {.wifiCtrl, exportc: "nimfw_dbg_rf_cal_restore_count".}: uint32
var nimFwDbgRfCalSaveRf88* {.wifiCtrl, exportc: "nimfw_dbg_rf_cal_save_rf88".}: uint32
var nimFwDbgRfCalRestoreRf88* {.wifiCtrl, exportc: "nimfw_dbg_rf_cal_restore_rf88".}: uint32
var nimFwDbgRfCalRestoreReadbackRf88* {.wifiCtrl, exportc: "nimfw_dbg_rf_cal_restore_readback_rf88".}: uint32
var nimFwDbgRfCalRestoreRf8c* {.wifiCtrl, exportc: "nimfw_dbg_rf_cal_restore_rf8c".}: uint32
var nimFwDbgRfCalSaveRf2c* {.wifiCtrl, exportc: "nimfw_dbg_rf_cal_save_rf2c".}: uint32
var nimFwDbgRfCalRestoreRf2c* {.wifiCtrl, exportc: "nimfw_dbg_rf_cal_restore_rf2c".}: uint32
var nimFwDbgRfCalRestoreReadbackRf2c* {.wifiCtrl, exportc: "nimfw_dbg_rf_cal_restore_readback_rf2c".}: uint32
var nimFwDbgRfPhase* {.wifiCtrl, exportc: "nimfw_dbg_rf_phase".}: uint32
var nimFwDbgRfRestore* {.wifiCtrl, exportc: "nimfw_dbg_rf_restore".}: uint32
var nimFwDbgRfApiMode* {.wifiCtrl, exportc: "nimfw_dbg_rf_api_mode".}: uint32
var nimFwDbgPhyInitCount* {.wifiCtrl, exportc: "nimfw_dbg_phy_init_count".}: uint32
var nimFwDbgPhyInitPhase* {.wifiCtrl, exportc: "nimfw_dbg_phy_init_phase".}: uint32
var nimFwDbgPhyModemVersion* {.wifiCtrl, exportc: "nimfw_dbg_phy_modem_version".}: uint32
var nimFwDbgPhyClockCount* {.wifiCtrl, exportc: "nimfw_dbg_phy_clock_count".}: uint32
var nimFwDbgPhyAgcCopyCount* {.wifiCtrl, exportc: "nimfw_dbg_phy_agc_copy_count".}: uint32
var nimFwDbgPhyAgcSourceFirst* {.wifiCtrl, exportc: "nimfw_dbg_phy_agc_source_first".}: uint32
var nimFwDbgPhyAgcSourceLast* {.wifiCtrl, exportc: "nimfw_dbg_phy_agc_source_last".}: uint32
var nimFwDbgPhyAgcDestFirst* {.wifiCtrl, exportc: "nimfw_dbg_phy_agc_dest_first".}: uint32
var nimFwDbgPhyAgcDestLast* {.wifiCtrl, exportc: "nimfw_dbg_phy_agc_dest_last".}: uint32
var nimFwDbgPhyWifiLdpcAbsent* {.wifiCtrl, exportc: "nimfw_dbg_phy_wifi_ldpc_absent".}: uint32
var nimFwDbgRfAssertCount* {.wifiCtrl, exportc: "nimfw_dbg_rf_assert_count".}: uint32
var nimFwDbgRfAssertLine* {.wifiCtrl, exportc: "nimfw_dbg_rf_assert_line".}: uint32
var nimFwDbgRfAssertReg3c* {.wifiCtrl, exportc: "nimfw_dbg_rf_assert_reg3c".}: uint32
var nimFwDbgRfCalPtr* {.wifiCtrl, exportc: "nimfw_dbg_rf_cal_ptr".}: uint32
var nimFwDbgRfCalWords* {.wifiCtrl, exportc: "nimfw_dbg_rf_cal_words".}: array[8, uint32]
var nimFwDbgRxuDescPrepare* {.wifiCtrl, exportc: "nimfw_dbg_rxu_desc_prepare".}: uint32
var nimFwDbgRxuUploadEvt* {.wifiCtrl, exportc: "nimfw_dbg_rxu_upload_evt".}: uint32
var nimFwDbgRxuUploadEntry* {.wifiCtrl, exportc: "nimfw_dbg_rxu_upload_entry".}: uint32
var nimFwDbgRxuUploadTcpipOk* {.wifiCtrl, exportc: "nimfw_dbg_rxu_upload_tcpip_ok".}: uint32
var nimFwDbgRxuUploadTcpipFail* {.wifiCtrl, exportc: "nimfw_dbg_rxu_upload_tcpip_fail".}: uint32
var nimFwDbgRxuUploadFrame* {.wifiCtrl, exportc: "nimfw_dbg_rxu_upload_frame".}: uint32
var nimFwDbgRxuFrameValid* {.wifiCtrl, exportc: "nimfw_dbg_rxu_frame_valid".}: uint32
var nimFwDbgRxuAssocData* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_data".}: uint32
var nimFwDbgRxuAssocEapol* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_eapol".}: uint32
var nimFwDbgRxuAssocUploadReady* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_upload_ready".}: uint32
var nimFwDbgRxuAssocMgmt* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_mgmt".}: uint32
var nimFwDbgRxuNonassocData* {.wifiCtrl, exportc: "nimfw_dbg_rxu_nonassoc_data".}: uint32
var nimFwDbgRxuDropInvalid* {.wifiCtrl, exportc: "nimfw_dbg_rxu_drop_invalid".}: uint32
var nimFwDbgRxuDropStaInactive* {.wifiCtrl, exportc: "nimfw_dbg_rxu_drop_sta_inactive".}: uint32
var nimFwDbgRxuDropFtype* {.wifiCtrl, exportc: "nimfw_dbg_rxu_drop_ftype".}: uint32
var nimFwDbgRxuDropNull* {.wifiCtrl, exportc: "nimfw_dbg_rxu_drop_null".}: uint32
var nimFwDbgRxuDropDup* {.wifiCtrl, exportc: "nimfw_dbg_rxu_drop_dup".}: uint32
var nimFwDbgRxuDropPn* {.wifiCtrl, exportc: "nimfw_dbg_rxu_drop_pn".}: uint32
var nimFwDbgRxuProtType* {.wifiCtrl, exportc: "nimfw_dbg_rxu_prot_type".}: uint32
var nimFwDbgRxuProtKey* {.wifiCtrl, exportc: "nimfw_dbg_rxu_prot_key".}: uint32
var nimFwDbgRxuProtPnLo* {.wifiCtrl, exportc: "nimfw_dbg_rxu_prot_pn_lo".}: uint32
var nimFwDbgRxuProtPnHi* {.wifiCtrl, exportc: "nimfw_dbg_rxu_prot_pn_hi".}: uint32
var nimFwDbgRxuPnMeta* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_meta".}: uint32
var nimFwDbgRxuPnStoredLo* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_stored_lo".}: uint32
var nimFwDbgRxuPnStoredHi* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_stored_hi".}: uint32
var nimFwDbgRxuPnNextLo* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_next_lo".}: uint32
var nimFwDbgRxuPnNextHi* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_next_hi".}: uint32
var nimFwDbgRxuDataFc* {.wifiCtrl, exportc: "nimfw_dbg_rxu_data_fc".}: uint32
var nimFwDbgRxuDataSeq* {.wifiCtrl, exportc: "nimfw_dbg_rxu_data_seq".}: uint32
var nimFwDbgRxuLastHwFlags* {.wifiCtrl, exportc: "nimfw_dbg_rxu_last_hwflags".}: uint32
var nimFwDbgRxuLastStatus* {.wifiCtrl, exportc: "nimfw_dbg_rxu_last_status".}: uint32
var nimFwDbgRxuLastLen* {.wifiCtrl, exportc: "nimfw_dbg_rxu_last_len".}: uint32
var nimFwDbgRxuSnapLo* {.wifiCtrl, exportc: "nimfw_dbg_rxu_snap_lo".}: uint32
var nimFwDbgRxuSnapHi* {.wifiCtrl, exportc: "nimfw_dbg_rxu_snap_hi".}: uint32
var nimFwDbgRxuAssocSnap* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_snap".}: uint32
var nimFwDbgRxuAssocIp* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_ip".}: uint32
var nimFwDbgRxuAssocArp* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_arp".}: uint32
var nimFwDbgRxuAssocOther* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_other".}: uint32
var nimFwDbgRxuAssocUdp* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_udp".}: uint32
var nimFwDbgRxuAssocTcp* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_tcp".}: uint32
var nimFwDbgRxuAssocTcp80* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_tcp80".}: uint32
var nimFwDbgRxuAssocLastIpProto* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_last_ip_proto".}: uint32
var nimFwDbgRxuAssocLastTcpPorts* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_last_tcp_ports".}: uint32
var nimFwDbgRxuAssocLastTcpFlags* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_last_tcp_flags".}: uint32
var nimFwDbgRxuAssocTcpMeta* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_tcp_meta".}: uint32
var nimFwDbgRxuAssocTcpRaw* {.wifiCtrl, exportc: "nimfw_dbg_rxu_assoc_tcp_raw".}: array[64, uint8]
var nimFwDbgRxuDropNullFc* {.wifiCtrl, exportc: "nimfw_dbg_rxu_drop_null_fc".}: uint32
var nimFwDbgRxuDropNullSeq* {.wifiCtrl, exportc: "nimfw_dbg_rxu_drop_null_seq".}: uint32
var nimFwDbgRxuDropDupFc* {.wifiCtrl, exportc: "nimfw_dbg_rxu_drop_dup_fc".}: uint32
var nimFwDbgRxuDropDupSeq* {.wifiCtrl, exportc: "nimfw_dbg_rxu_drop_dup_seq".}: uint32
const RxuDupTraceEntries = 8
var nimFwDbgRxuDupTraceCount* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_count".}: uint32
var nimFwDbgRxuDupTraceFc* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_fc".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupTraceSeq* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_seq".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupTraceCache* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_cache".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupTraceSnapLo* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_snap_lo".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupTraceSnapHi* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_snap_hi".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupTraceAddr0* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_addr0".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupTraceAddr1* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_addr1".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupTraceIp0* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_ip0".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupTraceUdp0* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_udp0".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupTraceBootp0* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_bootp0".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupTraceBootp1* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_bootp1".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupTraceBootpYiaddr* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_bootp_yiaddr".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupTraceDhcpMsg* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_dhcp_msg".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupTraceDhcpServer* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_trace_dhcp_server".}: array[RxuDupTraceEntries, uint32]
var nimFwDbgRxuDupBreakHits* {.wifiCtrl, exportc: "nimfw_dbg_rxu_dup_break_hits".}: uint32
const RxuPnDropTraceEntries = 8
var nimFwDbgRxuPnDropTraceCount* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_drop_trace_count".}: uint32
var nimFwDbgRxuPnDropTraceFc* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_drop_trace_fc".}: array[RxuPnDropTraceEntries, uint32]
var nimFwDbgRxuPnDropTraceSeq* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_drop_trace_seq".}: array[RxuPnDropTraceEntries, uint32]
var nimFwDbgRxuPnDropTracePnLo* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_drop_trace_pn_lo".}: array[RxuPnDropTraceEntries, uint32]
var nimFwDbgRxuPnDropTracePnHi* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_drop_trace_pn_hi".}: array[RxuPnDropTraceEntries, uint32]
var nimFwDbgRxuPnDropTraceStoredLo* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_drop_trace_stored_lo".}: array[RxuPnDropTraceEntries, uint32]
var nimFwDbgRxuPnDropTraceStoredHi* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_drop_trace_stored_hi".}: array[RxuPnDropTraceEntries, uint32]
var nimFwDbgRxuPnDropTraceSnapLo* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_drop_trace_snap_lo".}: array[RxuPnDropTraceEntries, uint32]
var nimFwDbgRxuPnDropTraceSnapHi* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_drop_trace_snap_hi".}: array[RxuPnDropTraceEntries, uint32]
var nimFwDbgRxuPnDropTraceUdp0* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_drop_trace_udp0".}: array[RxuPnDropTraceEntries, uint32]
var nimFwDbgRxuPnDropTraceBootpYiaddr* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_drop_trace_bootp_yiaddr".}: array[RxuPnDropTraceEntries, uint32]
var nimFwDbgRxuPnDropTraceDhcpMsg* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_drop_trace_dhcp_msg".}: array[RxuPnDropTraceEntries, uint32]
var nimFwDbgRxuPnDropTraceDhcpServer* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_drop_trace_dhcp_server".}: array[RxuPnDropTraceEntries, uint32]
const RxuPnAcceptTraceEntries = 8
var nimFwDbgRxuPnAcceptTraceCount* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_count".}: uint32
var nimFwDbgRxuPnAcceptTraceStage* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_stage".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTraceFc* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_fc".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTraceSeq* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_seq".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTracePnLo* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_pn_lo".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTracePnHi* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_pn_hi".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTraceStoredLo* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_stored_lo".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTraceStoredHi* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_stored_hi".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTraceNextLo* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_next_lo".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTraceNextHi* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_next_hi".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTraceSnapLo* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_snap_lo".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTraceSnapHi* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_snap_hi".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTraceUdp0* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_udp0".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTraceBootpYiaddr* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_bootp_yiaddr".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTraceDhcpMsg* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_dhcp_msg".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgRxuPnAcceptTraceDhcpServer* {.wifiCtrl, exportc: "nimfw_dbg_rxu_pn_accept_trace_dhcp_server".}: array[RxuPnAcceptTraceEntries, uint32]
var nimFwDbgSetKey0* {.wifiCtrl, exportc: "nimfw_dbg_setkey0".}: uint32
var nimFwDbgSetKey1* {.wifiCtrl, exportc: "nimfw_dbg_setkey1".}: uint32
var nimFwDbgSetKey2* {.wifiCtrl, exportc: "nimfw_dbg_setkey2".}: uint32
var nimFwDbgSetKey3* {.wifiCtrl, exportc: "nimfw_dbg_setkey3".}: uint32
var nimFwDbgMachwKeyWrCalls* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_calls".}: uint32
var nimFwDbgMachwKeyWrGroup* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_group".}: uint32
var nimFwDbgMachwKeyWrPair* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_pair".}: uint32
var nimFwDbgMachwKeyWrLast0* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_last0".}: uint32
var nimFwDbgMachwKeyWrLast1* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_last1".}: uint32
var nimFwDbgMachwKeyWrPair0* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_pair0".}: uint32
var nimFwDbgMachwKeyWrPair1* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_pair1".}: uint32
var nimFwDbgMachwKeyWrPair2* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_pair2".}: uint32
var nimFwDbgMachwKeyWrPair3* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_pair3".}: uint32
var nimFwDbgMachwKeyWrPair4* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_pair4".}: uint32
var nimFwDbgMachwKeyWrPair5* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_pair5".}: uint32
var nimFwDbgMachwKeyWrPairCtrl* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_pair_ctrl".}: uint32
var nimFwDbgMachwKeyWrRead0* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_read0".}: uint32
var nimFwDbgMachwKeyWrRead1* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_read1".}: uint32
var nimFwDbgMachwKeyWrRead2* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_read2".}: uint32
var nimFwDbgMachwKeyWrRead3* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_read3".}: uint32
var nimFwDbgMachwKeyWrReadCtrl* {.wifiCtrl, exportc: "nimfw_dbg_machwkey_wr_read_ctrl".}: uint32
var nimFwDbgStaAddKeyCalls* {.wifiCtrl, exportc: "nimfw_dbg_sta_add_key_calls".}: uint32
var nimFwDbgStaAddKeyMeta* {.wifiCtrl, exportc: "nimfw_dbg_sta_add_key_meta".}: uint32
var nimFwDbgStaAddKeyPtrs0* {.wifiCtrl, exportc: "nimfw_dbg_sta_add_key_ptrs0".}: uint32
var nimFwDbgStaAddKeyPtrs1* {.wifiCtrl, exportc: "nimfw_dbg_sta_add_key_ptrs1".}: uint32
var nimFwDbgStaAddKeyPtrs2* {.wifiCtrl, exportc: "nimfw_dbg_sta_add_key_ptrs2".}: uint32
var nimFwDbgTxSecHdrStaKey0* {.wifiCtrl, exportc: "nimfw_dbg_tx_sec_hdr_sta_key0".}: uint32
var nimFwDbgTxSecHdrStaKey1* {.wifiCtrl, exportc: "nimfw_dbg_tx_sec_hdr_sta_key1".}: uint32
var nimFwDbgTxSecHdrStaKey2* {.wifiCtrl, exportc: "nimfw_dbg_tx_sec_hdr_sta_key2".}: uint32
var nimFwDbgRcUpdateCalls* {.wifiCtrl, exportc: "nimfw_dbg_rc_update_calls".}: uint32
var nimFwDbgRcUpdateMeta* {.wifiCtrl, exportc: "nimfw_dbg_rc_update_meta".}: uint32
var nimFwDbgRcUpdateArgs* {.wifiCtrl, exportc: "nimfw_dbg_rc_update_args".}: uint32
var nimFwDbgRcUpdateSlot* {.wifiCtrl, exportc: "nimfw_dbg_rc_update_slot".}: uint32
var nimFwDbgRcUpdateEntry* {.wifiCtrl, exportc: "nimfw_dbg_rc_update_entry".}: uint32
var nimFwDbgRcUpdateCounts* {.wifiCtrl, exportc: "nimfw_dbg_rc_update_counts".}: uint32
var nimFwDbgRcUpdateFail* {.wifiCtrl, exportc: "nimfw_dbg_rc_update_fail".}: uint32
# Recycle / CFM path counters (iter 261 follow-up)
var nimFwDbgCfmPush*        {.wifiCtrl, exportc: "nimfw_dbg_cfm_push".}: uint32
var nimFwDbgCfmEvt*         {.wifiCtrl, exportc: "nimfw_dbg_cfm_evt".}: uint32
var nimFwDbgFrameCfm*       {.wifiCtrl, exportc: "nimfw_dbg_frame_cfm".}: uint32
var nimFwDbgFrameRelease*   {.wifiCtrl, exportc: "nimfw_dbg_frame_release".}: uint32
var nimFwDbgTxTrigAcReady*  {.wifiCtrl, exportc: "nimfw_dbg_txtrig_acready".}: uint32  # last acReady seen
var nimFwDbgTxTrigZeroExit* {.wifiCtrl, exportc: "nimfw_dbg_txtrig_zero".}: uint32     # entered & acReady==0
var nimFwDbgTxTrigLoops*    {.wifiCtrl, exportc: "nimfw_dbg_txtrig_loops".}: uint32    # inner loop iters
var nimFwDbgFrameEvtEnter*  {.wifiCtrl, exportc: "nimfw_dbg_frame_evt_enter".}: uint32
var nimFwDbgFrameEvtPop*    {.wifiCtrl, exportc: "nimfw_dbg_frame_evt_pop".}: uint32
var nimFwDbgFrameEvtFreeRet* {.wifiCtrl, exportc: "nimfw_dbg_frame_evt_free".}: uint32
var nimFwDbgFrameEvtUsedSkip* {.wifiCtrl, exportc: "nimfw_dbg_frame_evt_usedskip".}: uint32
var nimFwDbgFrameEvtCallback* {.wifiCtrl, exportc: "nimfw_dbg_frame_evt_cb".}: uint32
var nimFwDbgFrameGetFails*    {.wifiCtrl, exportc: "nimfw_dbg_frame_get_fails".}: uint32
var nimFwDbgNullFrameCalls*   {.wifiCtrl, exportc: "nimfw_dbg_nullframe_calls".}: uint32
var nimFwDbgNullFrameCallerRA* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_caller_ra".}: uint32
var nimFwDbgTxRouteInternal*  {.wifiCtrl, exportc: "nimfw_dbg_tx_route_internal".}: uint32
var nimFwDbgTxRouteHost*      {.wifiCtrl, exportc: "nimfw_dbg_tx_route_host".}: uint32
var nimFwDbgTxRouteUsedFlag*  {.wifiCtrl, exportc: "nimfw_dbg_tx_route_usedflag".}: uint32
var nimFwDbgFrameGetUsedBefore* {.wifiCtrl, exportc: "nimfw_dbg_frame_get_used_before".}: uint32
var nimFwDbgNullFrameCfm*     {.wifiCtrl, exportc: "nimfw_dbg_nullframe_cfm".}: uint32
var nimFwDbgNullFrameAckOk*   {.wifiCtrl, exportc: "nimfw_dbg_nullframe_ack_ok".}: uint32
var nimFwDbgNullFrameAckFail* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_ack_fail".}: uint32
var nimFwDbgNullFrameLastStatus* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_status".}: uint32
var nimFwDbgNullFrameDescLast* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_desc".}: uint32
var nimFwDbgNullFrameBufLast* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_buf".}: uint32
var nimFwDbgNullFrameFcLast* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_fc".}: uint32
var nimFwDbgNullFramePushRc* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_push_rc".}: uint32
var nimFwDbgNullFrameReturn* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_return".}: uint32
var nimFwDbgNullFrameVifSta* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_vif_sta".}: uint32
var nimFwDbgNullFrameCbSet*   {.wifiCtrl, exportc: "nimfw_dbg_nullframe_cb_set".}: uint32
var nimFwDbgNullFrameCbSetPtr* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_cb_set_ptr".}: uint32
var nimFwDbgNullFrameEvtSeen* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_evt_seen".}: uint32
var nimFwDbgNullFrameEvtCbNil* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_evt_cb_nil".}: uint32
var nimFwDbgNullFrameEvtCbPtr* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_evt_cb_ptr".}: uint32
var nimFwDbgNullFrameEvtDesc* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_evt_desc".}: uint32
var nimFwDbgNullFrameTxTrigSeen* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_txtrig_seen".}: uint32
var nimFwDbgNullFrameTxTrigHost* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_txtrig_host".}: uint32
var nimFwDbgNullFrameTxTrigInternal* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_txtrig_internal".}: uint32
var nimFwDbgNullFrameTxTrigUsedFlag* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_txtrig_usedflag".}: uint32
var nimFwDbgNullFrameBusyTxCheck* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_busy_txcheck".}: uint32
var nimFwDbgNullFrameBusyPsCheck* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_busy_pscheck".}: uint32
var nimFwDbgNullFramePaySeen* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_pay_seen".}: uint32
var nimFwDbgNullFramePayHasPayload* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_pay_payload".}: uint32
var nimFwDbgNullFramePayEmpty* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_pay_empty".}: uint32
var nimFwDbgNullFramePayNonEmpty* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_pay_nonempty".}: uint32
var nimFwDbgNullFramePayAc* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_pay_ac".}: uint32
var nimFwDbgNullFramePayTrigger* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_pay_trig".}: uint32
var nimFwDbgNullFramePayCurrent* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_pay_current".}: uint32
var nimFwDbgNullFramePayPending* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_pay_pending".}: uint32
var nimFwDbgNullFramePayThdStatus* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_pay_thd_status".}: uint32
var nimFwDbgNullFramePostponed* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_postponed".}: uint32
var nimFwDbgNullFrameQueued* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_queued".}: uint32
var nimFwDbgPostponedServiceCalls* {.wifiCtrl, exportc: "nimfw_dbg_postponed_service_calls".}: uint32
var nimFwDbgPostponedServiceSent* {.wifiCtrl, exportc: "nimfw_dbg_postponed_service_sent".}: uint32
var nimFwDbgNullFrameTxIntSeen* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_txint_seen".}: uint32
var nimFwDbgNullFrameTxIntFc* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_txint_fc".}: uint32
var nimFwDbgNullFrameTxIntBuf* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_txint_buf".}: uint32
var nimFwDbgNullFrameFakeSeen* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_fake_seen".}: uint32
var nimFwDbgNullFrameFakeQidx* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_fake_qidx".}: uint32
var nimFwDbgNullFrameFakeHeadBefore* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_fake_head_before".}: uint32
var nimFwDbgNullFrameFakeTailBefore* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_fake_tail_before".}: uint32
var nimFwDbgNullFrameFakeHeadAfter* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_fake_head_after".}: uint32
var nimFwDbgNullFrameFakeTailAfter* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_fake_tail_after".}: uint32
var nimFwDbgNullFrameFakeLink* {.wifiCtrl, exportc: "nimfw_dbg_nullframe_fake_link".}: uint32
var nimFwDbgPostponedRelease* {.wifiCtrl, exportc: "nimfw_dbg_postponed_release".}: uint32
var nimFwDbgPostponedReleaseCb* {.wifiCtrl, exportc: "nimfw_dbg_postponed_release_cb".}: uint32
var nimFwDbgPostponedReleaseDesc* {.wifiCtrl, exportc: "nimfw_dbg_postponed_release_desc".}: uint32
var nimFwDbgPostponedReleaseFc* {.wifiCtrl, exportc: "nimfw_dbg_postponed_release_fc".}: uint32
var nimFwDbgPostponedReleaseFlags* {.wifiCtrl, exportc: "nimfw_dbg_postponed_release_flags".}: uint32
var nimFwDbgPostponedReconcile* {.wifiCtrl, exportc: "nimfw_dbg_postponed_reconcile".}: uint32
var nimFwDbgPostponedReconcileOld* {.wifiCtrl, exportc: "nimfw_dbg_postponed_reconcile_old".}: uint32
var nimFwDbgPostponedReconcileNew* {.wifiCtrl, exportc: "nimfw_dbg_postponed_reconcile_new".}: uint32
var nimFwDbgAutoNullSkipped* {.wifiCtrl, exportc: "nimfw_dbg_auto_null_skipped".}: uint32
var nimFwDbgTxStalledInternalRecover* {.wifiCtrl, exportc: "nimfw_dbg_tx_stalled_internal_recover".}: uint32
var nimFwDbgTxRecoverAc* {.wifiCtrl, exportc: "nimfw_dbg_tx_recover_ac".}: uint32
var nimFwDbgTxRecoverPending* {.wifiCtrl, exportc: "nimfw_dbg_tx_recover_pending".}: uint32
var nimFwDbgTxRecoverCurrentBefore* {.wifiCtrl, exportc: "nimfw_dbg_tx_recover_current_before".}: uint32
var nimFwDbgTxRecoverCurrentAfter* {.wifiCtrl, exportc: "nimfw_dbg_tx_recover_current_after".}: uint32
var nimFwDbgTxRecoverBackupBefore* {.wifiCtrl, exportc: "nimfw_dbg_tx_recover_backup_before".}: uint32
var nimFwDbgTxRecoverBackupAfterFake* {.wifiCtrl, exportc: "nimfw_dbg_tx_recover_backup_after_fake".}: uint32
var nimFwDbgTxRecoverBackupAfterPay* {.wifiCtrl, exportc: "nimfw_dbg_tx_recover_backup_after_pay".}: uint32
var nimFwDbgTxRecoverDescBuf* {.wifiCtrl, exportc: "nimfw_dbg_tx_recover_desc_buf".}: uint32
var nimFwDbgTxRecoverDescCb* {.wifiCtrl, exportc: "nimfw_dbg_tx_recover_desc_cb".}: uint32
var nimFwStaTxChannelPrepareEnabled* {.wifiCtrl, exportc: "nimfw_sta_tx_channel_prepare_enabled".}: uint32
var nimFwBleWifiRoleWindowEnabled* {.wifiCtrl, exportc: "nimfw_ble_wifi_role_window_enabled".}: uint32
var nimFwBleWifiRoleWindowActive* {.wifiCtrl, exportc: "nimfw_ble_wifi_role_window_active".}: uint32
var nimFwDbgBleWifiRoleEnter* {.wifiCtrl, exportc: "nimfw_dbg_ble_wifi_role_enter".}: uint32
var nimFwDbgBleWifiRoleLeave* {.wifiCtrl, exportc: "nimfw_dbg_ble_wifi_role_leave".}: uint32
var nimFwDbgBleWifiRoleLastCtrl* {.wifiCtrl, exportc: "nimfw_dbg_ble_wifi_role_last_ctrl".}: uint32
var nimFwDbgBleWifiRoleLastCtrl2* {.wifiCtrl, exportc: "nimfw_dbg_ble_wifi_role_last_ctrl2".}: uint32
var nimFwDbgBleWifiRoleLastMirror* {.wifiCtrl, exportc: "nimfw_dbg_ble_wifi_role_last_mirror".}: uint32
var nimFwDbgBleWifiTxPreBcn* {.wifiCtrl, exportc: "nimfw_dbg_ble_wifi_tx_pre_bcn".}: uint32
var nimFwDbgBleWifiTxPrePti* {.wifiCtrl, exportc: "nimfw_dbg_ble_wifi_tx_pre_pti".}: uint32
var nimFwDbgBleWifiTxPreStat* {.wifiCtrl, exportc: "nimfw_dbg_ble_wifi_tx_pre_stat".}: uint32
var nimFwDbgBleWifiTxTrigStat* {.wifiCtrl, exportc: "nimfw_dbg_ble_wifi_tx_trig_stat".}: uint32
var nimFwDbgBleWifiTxTrigAgg* {.wifiCtrl, exportc: "nimfw_dbg_ble_wifi_tx_trig_agg".}: uint32
var nimFwDbgBleWifiTxCfmBcn* {.wifiCtrl, exportc: "nimfw_dbg_ble_wifi_tx_cfm_bcn".}: uint32
var nimFwDbgBleWifiTxCfmPti* {.wifiCtrl, exportc: "nimfw_dbg_ble_wifi_tx_cfm_pti".}: uint32
var nimFwDbgStaTxRfRestore* {.wifiCtrl, exportc: "nimfw_dbg_sta_tx_rf_restore".}: uint32
var nimFwDbgStaTxRfFullRestore* {.wifiCtrl, exportc: "nimfw_dbg_sta_tx_rf_full_restore".}: uint32
var nimFwDbgStaTxRfLatch* {.wifiCtrl, exportc: "nimfw_dbg_sta_tx_rf_latch".}: uint32
var nimFwKeepaliveInFlight* {.wifiCtrl, exportc: "nimfw_keepalive_inflight".}: uint32
var nimFwKeepaliveTargetCfm* {.wifiCtrl, exportc: "nimfw_keepalive_target_cfm".}: uint32
var nimFwKeepaliveStartedAt* {.wifiCtrl, exportc: "nimfw_keepalive_started_at".}: uint32
var nimFwDbgKeepaliveRc* {.wifiCtrl, exportc: "nimfw_dbg_keepalive_rc".}: uint32
var nimFwDbgKeepalivePostBefore* {.wifiCtrl, exportc: "nimfw_dbg_keepalive_post_before".}: uint32
var nimFwDbgKeepalivePostAfter* {.wifiCtrl, exportc: "nimfw_dbg_keepalive_post_after".}: uint32
var nimFwDbgKeepaliveTxintBefore* {.wifiCtrl, exportc: "nimfw_dbg_keepalive_txint_before".}: uint32
var nimFwDbgKeepaliveTxintAfter* {.wifiCtrl, exportc: "nimfw_dbg_keepalive_txint_after".}: uint32
var nimFwDbgKeepaliveFakeBefore* {.wifiCtrl, exportc: "nimfw_dbg_keepalive_fake_before".}: uint32
var nimFwDbgKeepaliveFakeAfter* {.wifiCtrl, exportc: "nimfw_dbg_keepalive_fake_after".}: uint32
var nimFwDbgKeepalivePayBefore* {.wifiCtrl, exportc: "nimfw_dbg_keepalive_pay_before".}: uint32
var nimFwDbgKeepalivePayAfter* {.wifiCtrl, exportc: "nimfw_dbg_keepalive_pay_after".}: uint32
var nimFwDbgKeepaliveCbBefore* {.wifiCtrl, exportc: "nimfw_dbg_keepalive_cb_before".}: uint32
var nimFwDbgKeepaliveCbAfter* {.wifiCtrl, exportc: "nimfw_dbg_keepalive_cb_after".}: uint32
var nimFwKeepaliveQosNullEnabled* {.wifiCtrl, exportc: "nimfw_keepalive_qosnull_enabled".}: uint32
var nimFwDbgTxIntEnter* {.wifiCtrl, exportc: "nimfw_dbg_txint_enter".}: uint32
var nimFwDbgTxIntLastCb* {.wifiCtrl, exportc: "nimfw_dbg_txint_last_cb".}: uint32
var nimFwDbgTxIntLastFc* {.wifiCtrl, exportc: "nimfw_dbg_txint_last_fc".}: uint32
var nimFwDbgTxIntReady* {.wifiCtrl, exportc: "nimfw_dbg_txint_ready".}: uint32
var nimFwDbgTxIntPsOk* {.wifiCtrl, exportc: "nimfw_dbg_txint_psok".}: uint32
var nimFwDbgTxIntPush* {.wifiCtrl, exportc: "nimfw_dbg_txint_push".}: uint32
var nimFwDbgTxIntRelease* {.wifiCtrl, exportc: "nimfw_dbg_txint_release".}: uint32
var nimFwDbgTxIntPostpone* {.wifiCtrl, exportc: "nimfw_dbg_txint_postpone".}: uint32
var nimFwDbgTxIntLastMeta* {.wifiCtrl, exportc: "nimfw_dbg_txint_meta".}: uint32
var nimFwDbgTxIntLastChan* {.wifiCtrl, exportc: "nimfw_dbg_txint_chan".}: uint32
var nimFwDbgTxIntLastQueue* {.wifiCtrl, exportc: "nimfw_dbg_txint_queue".}: uint32
var nimFwDbgTxIntLastHw* {.wifiCtrl, exportc: "nimfw_dbg_txint_hw".}: uint32
var nimFwDbgStaTbttEnter*     {.wifiCtrl, exportc: "nimfw_dbg_sta_tbtt_enter".}: uint32
var nimFwDbgStaTbttAssoc*     {.wifiCtrl, exportc: "nimfw_dbg_sta_tbtt_assoc".}: uint32
var nimFwDbgStaTbttOnChan*    {.wifiCtrl, exportc: "nimfw_dbg_sta_tbtt_onchan".}: uint32
var nimFwDbgStaTbttPC100*     {.wifiCtrl, exportc: "nimfw_dbg_sta_tbtt_pc100".}: uint32
var nimFwDbgStaTbttPCMax*     {.wifiCtrl, exportc: "nimfw_dbg_sta_tbtt_pcmax".}: uint32
var nimFwDbgSetVifState*      {.wifiCtrl, exportc: "nimfw_dbg_set_vif_state".}: uint32   # entries
var nimFwDbgSetVifStateNew*   {.wifiCtrl, exportc: "nimfw_dbg_set_vif_state_new".}: uint32  # last newState
var nimFwDbgSetVifStateAct*   {.wifiCtrl, exportc: "nimfw_dbg_set_vif_state_act".}: uint32  # activating=true count
var nimFwDbgAssocDone*        {.wifiCtrl, exportc: "nimfw_dbg_assoc_done".}: uint32
var nimFwDbgAuthOpenSuccess*  {.wifiCtrl, exportc: "nimfw_dbg_auth_open_success".}: uint32
var nimFwDbgAssocReqSend*     {.wifiCtrl, exportc: "nimfw_dbg_assoc_req_send".}: uint32
var nimFwDbgAssocReqMeta*     {.wifiCtrl, exportc: "nimfw_dbg_assoc_req_meta".}: uint32
var nimFwDbgAssocCfmPush*     {.wifiCtrl, exportc: "nimfw_dbg_assoc_cfm_push".}: uint32
var nimFwDbgAssocCfmFrame*    {.wifiCtrl, exportc: "nimfw_dbg_assoc_cfm_frame".}: uint32
var nimFwDbgAssocCfmEvt*      {.wifiCtrl, exportc: "nimfw_dbg_assoc_cfm_evt".}: uint32
var nimFwDbgAssocCfmStatus*   {.wifiCtrl, exportc: "nimfw_dbg_assoc_cfm_status".}: uint32
var nimFwDbgAssocCfmHwStatus* {.wifiCtrl, exportc: "nimfw_dbg_assoc_cfm_hw_status".}: uint32
var nimFwDbgAssocCfmDesc*     {.wifiCtrl, exportc: "nimfw_dbg_assoc_cfm_desc".}: uint32
var nimFwDbgAssocCfmMeta*     {.wifiCtrl, exportc: "nimfw_dbg_assoc_cfm_meta".}: uint32
var nimFwDbgAssocCfmFc*       {.wifiCtrl, exportc: "nimfw_dbg_assoc_cfm_fc".}: uint32
var nimFwDbgAssocRspStatus*   {.wifiCtrl, exportc: "nimfw_dbg_assoc_rsp_status".}: uint32  # last assoc rsp statusCode
var nimFwDbgAssocRspCount*    {.wifiCtrl, exportc: "nimfw_dbg_assoc_rsp_count".}: uint32
var nimFwDbgAssocRspLen*      {.wifiCtrl, exportc: "nimfw_dbg_assoc_rsp_len".}: uint32
var nimFwDbgAssocRspBody0*    {.wifiCtrl, exportc: "nimfw_dbg_assoc_rsp_b0".}: uint32  # first 4 bytes of body
var nimFwDbgAssocRspBody4*    {.wifiCtrl, exportc: "nimfw_dbg_assoc_rsp_b4".}: uint32  # next 4 bytes
var nimFwDbgDeauthHandler*    {.wifiCtrl, exportc: "nimfw_dbg_deauth".}: uint32
var nimFwDbgConnLossInd*      {.wifiCtrl, exportc: "nimfw_dbg_connloss".}: uint32
var nimFwDbgWpaRsnIeSet*      {.wifiCtrl, exportc: "nimfw_dbg_wparsn_set".}: uint32
var nimFwDbgWpaRsnIeLen*      {.wifiCtrl, exportc: "nimfw_dbg_wparsn_len".}: uint32
var nimFwDbgWpaRsnIePtr*      {.wifiCtrl, exportc: "nimfw_dbg_wparsn_ptr".}: uint32
var nimFwDbgVifSecType*       {.wifiCtrl, exportc: "nimfw_dbg_vif_sectype".}: uint32  # vif+497 at vif_state_cfm
var nimFwDbgConnectIndPrePath* {.wifiCtrl, exportc: "nimfw_dbg_conn_ind_prepath".}: uint32  # path-1 (open) fired
var nimFwDbgVifIeLenAtAssoc*  {.wifiCtrl, exportc: "nimfw_dbg_vif_ielen_assoc".}: uint32  # vif+496 at AssocReq build
var nimFwDbgPtkInitDone*      {.wifiCtrl, exportc: "nimfw_dbg_ptk_init_done".}: uint32
var nimFwDbgKeyDataDecryptCalls* {.wifiCtrl, exportc: "nimfw_dbg_keydata_decrypt_calls".}: uint32
var nimFwDbgKeyDataDecryptLen* {.wifiCtrl, exportc: "nimfw_dbg_keydata_decrypt_len".}: uint32
var nimFwDbgKeyDataDecryptOutLen* {.wifiCtrl, exportc: "nimfw_dbg_keydata_decrypt_out_len".}: uint32
var nimFwDbgKeyDataDecryptOk* {.wifiCtrl, exportc: "nimfw_dbg_keydata_decrypt_ok".}: uint32
var nimFwDbgKeyDataDecryptFail* {.wifiCtrl, exportc: "nimfw_dbg_keydata_decrypt_fail".}: uint32
# Per-VIF WPA-handshake-pending tracking. Set when sm_assoc_done runs on a
# WPA-protected VIF (sectype>=2); cleared on PTK-init-done or disconnect.
# mm_sta_tbtt uses this to suppress the null-frame keep-alive loop while
# waiting for WPA, and to time out the wait into a connection_loss_ind.
var nimFwWpaPendingMask* {.wifiCtrl, exportc: "nimfw_wpa_pending_mask".}: uint32
var nimFwDbgStaTbttSkip* {.wifiCtrl, exportc: "nimfw_dbg_sta_tbtt_skip".}: uint32
var nimFwDbgStaTbttGiveup* {.wifiCtrl, exportc: "nimfw_dbg_sta_tbtt_giveup".}: uint32
var nimFwDbgEapolIn*       {.wifiCtrl, exportc: "nimfw_dbg_eapol_in".}: uint32
var nimFwDbgEapolDropped*  {.wifiCtrl, exportc: "nimfw_dbg_eapol_dropped".}: uint32
var nimFwDbgEapolForwarded* {.wifiCtrl, exportc: "nimfw_dbg_eapol_fwd".}: uint32
var nimFwDbgVifWpaState*   {.wifiCtrl, exportc: "nimfw_dbg_vif_wpastate".}: uint32
var nimFwDbgEapolCbInv*    {.wifiCtrl, exportc: "nimfw_dbg_eapol_cb_inv".}: uint32
var nimFwDbgEapolCbNull*   {.wifiCtrl, exportc: "nimfw_dbg_eapol_cb_null".}: uint32
var nimFwDbgSmStateAtEapol* {.wifiCtrl, exportc: "nimfw_dbg_sm_state_eapol".}: uint32
# Supplicant-side counters (incremented from C files in wpa_supplicant/ and wifi driver)
var nimFwDbgSuppRxEapol*   {.wifiCtrl, exportc: "nimfw_dbg_supp_rx_eapol".}: uint32
var nimFwDbgSuppTxEapol*   {.wifiCtrl, exportc: "nimfw_dbg_supp_tx_eapol".}: uint32
var nimFwDbgEthTxEapol*    {.wifiCtrl, exportc: "nimfw_dbg_eth_tx_eapol".}: uint32
var nimFwDbgBlOutputEapol* {.wifiCtrl, exportc: "nimfw_dbg_bl_output_eapol".}: uint32
var nimFwDbgEapolTxCb*     {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_cb".}: uint32
var nimFwDbgWpaDeauth*     {.wifiCtrl, exportc: "nimfw_dbg_wpa_deauth".}: uint32
var nimFwDbgEthTxRet*      {.wifiCtrl, exportc: "nimfw_dbg_eth_tx_ret".}: uint32  # last return code
var nimFwDbgBlOutputDrop*  {.wifiCtrl, exportc: "nimfw_dbg_bl_output_drop".}: uint32  # bl_output dropped (sta_id<0)
var nimFwDbgPbufAllocFail* {.wifiCtrl, exportc: "nimfw_dbg_pbuf_alloc_fail".}: uint32
var nimFwDbgPbufTakeFail*  {.wifiCtrl, exportc: "nimfw_dbg_pbuf_take_fail".}: uint32
var nimFwDbgSuppTxLen*     {.wifiCtrl, exportc: "nimfw_dbg_supp_tx_len".}: uint32  # last EAPOL TX len
var nimFwDbgTxFlushEnter*  {.wifiCtrl, exportc: "nimfw_dbg_tx_flush_enter".}: uint32
var nimFwDbgTxPushCalls*   {.wifiCtrl, exportc: "nimfw_dbg_tx_push_calls".}: uint32
var nimFwDbgTxNoDesc*      {.wifiCtrl, exportc: "nimfw_dbg_tx_nodesc".}: uint32
var nimFwDbgTxNoBuf*       {.wifiCtrl, exportc: "nimfw_dbg_tx_nobuf".}: uint32
var nimFwDbgBlTxCfm*       {.wifiCtrl, exportc: "nimfw_dbg_bl_tx_cfm".}: uint32  # bl_tx_cfm calls
var nimFwDbgBlTxCfmCb*     {.wifiCtrl, exportc: "nimfw_dbg_bl_tx_cfm_cb".}: uint32  # bl_tx_cfm cb != nil
var nimFwDbgBlTxCfmEapol*  {.wifiCtrl, exportc: "nimfw_dbg_bl_tx_cfm_eapol".}: uint32  # cfm for EAPOL ethertype
var nimFwDbgTxSecHdrCalls* {.wifiCtrl, exportc: "nimfw_dbg_tx_sec_hdr_calls".}: uint32
var nimFwDbgTxSecHdrNoKeyMat* {.wifiCtrl, exportc: "nimfw_dbg_tx_sec_hdr_no_keymat".}: uint32
var nimFwDbgTxSecHdrNoKeySlot* {.wifiCtrl, exportc: "nimfw_dbg_tx_sec_hdr_no_keyslot".}: uint32
var nimFwDbgTxSecHdrCipher* {.wifiCtrl, exportc: "nimfw_dbg_tx_sec_hdr_cipher".}: uint32
var nimFwDbgTxSecHdrLen* {.wifiCtrl, exportc: "nimfw_dbg_tx_sec_hdr_len".}: uint32
var nimFwDbgTxSecHdrAppend* {.wifiCtrl, exportc: "nimfw_dbg_tx_sec_hdr_append".}: uint32
var nimFwDbgTxSecHdrMissMeta* {.wifiCtrl, exportc: "nimfw_dbg_tx_sec_hdr_miss_meta".}: uint32
var nimFwDbgTxSecHdrMissLen* {.wifiCtrl, exportc: "nimfw_dbg_tx_sec_hdr_miss_len".}: uint32
var nimFwDbgTxSecHdrMissKeyMat* {.wifiCtrl, exportc: "nimfw_dbg_tx_sec_hdr_miss_keymat".}: uint32
var nimFwDbgDhcpTxDescBytes* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_desc_bytes".}: uint32
var nimFwDbgDhcpTxHdr0* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_hdr0".}: uint32
var nimFwDbgDhcpTxHdr1* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_hdr1".}: uint32
var nimFwDbgDhcpTxHdr2* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_hdr2".}: uint32
var nimFwDbgDhcpTxSec* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_sec".}: uint32
var nimFwDbgDhcpTxSecHdr0* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_sec_hdr0".}: uint32
var nimFwDbgDhcpTxSecHdr1* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_sec_hdr1".}: uint32
var nimFwDbgDhcpTxSecKey* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_sec_key".}: uint32
var nimFwDbgDhcpTxSecCtl* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_sec_ctl".}: uint32
var nimFwDbgDhcpTxPolicy* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_policy".}: uint32
var nimFwDbgDhcpTxBufDesc* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_buf_desc".}: uint32
var nimFwDbgDhcpTxHwDesc* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_hw_desc".}: uint32
var nimFwDbgDhcpTxRate0* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_rate0".}: uint32
var nimFwDbgDhcpTxRate1* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_rate1".}: uint32
var nimFwDbgDhcpTxRate2* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_rate2".}: uint32
var nimFwDbgDhcpTxRate3* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_rate3".}: uint32
var nimFwDbgDhcpTxRateRaw* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_rate_raw".}: array[13, uint32]
var nimFwDbgDhcpTxLink0* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_link0".}: uint32
var nimFwDbgDhcpTxLink1* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_link1".}: uint32
var nimFwDbgDhcpTxThd0* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_thd0".}: uint32
var nimFwDbgDhcpTxThd1* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_thd1".}: uint32
var nimFwDbgDhcpTxThd2* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_thd2".}: uint32
var nimFwDbgDhcpTxLayout* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_layout".}: array[8, uint32]
var nimFwDbgDhcpTxFinalBreakHits* {.wifiCtrl,
  exportc: "nimfw_dbg_dhcp_tx_final_break_hits".}: uint32
var nimFwDbgDhcpTxFinalDesc0* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_desc0".}: uint32
var nimFwDbgDhcpTxFinalDesc1* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_desc1".}: uint32
var nimFwDbgDhcpTxFinalBuf0* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_buf0".}: uint32
var nimFwDbgDhcpTxFinalLen0* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_len0".}: uint32
var nimFwDbgDhcpTxFinalHwStart* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_hw_start".}: uint32
var nimFwDbgDhcpTxFinalHwEnd* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_hw_end".}: uint32
var nimFwDbgDhcpTxFinalHwLen* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_hw_len".}: uint32
var nimFwDbgDhcpTxFinalHwFlags* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_hw_flags".}: uint32
var nimFwDbgDhcpTxFinalHthdStart* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_hthd_start".}: uint32
var nimFwDbgDhcpTxFinalHthdEnd* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_hthd_end".}: uint32
var nimFwDbgDhcpTxFinalHthdNext* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_hthd_next".}: uint32
var nimFwDbgDhcpTxFinalHthdFlags* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_hthd_flags".}: uint32
var nimFwDbgDhcpTxFinalPthdStart* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_pthd_start".}: uint32
var nimFwDbgDhcpTxFinalPthdEnd* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_pthd_end".}: uint32
var nimFwDbgDhcpTxFinalPthdNext* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_pthd_next".}: uint32
var nimFwDbgDhcpTxFinalPthdFlags* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_tx_final_pthd_flags".}: uint32
var nimFwDbgEapolTxDescBytes* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_desc_bytes".}: uint32
var nimFwDbgEapolTxHdr0* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_hdr0".}: uint32
var nimFwDbgEapolTxHdr1* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_hdr1".}: uint32
var nimFwDbgEapolTxHdr2* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_hdr2".}: uint32
var nimFwDbgEapolTxHdr3* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_hdr3".}: uint32
var nimFwDbgEapolTxAddrHi* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_addr_hi".}: uint32
var nimFwDbgEapolTxPolicy* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_policy".}: uint32
var nimFwDbgEapolTxBufDesc* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_buf_desc".}: uint32
var nimFwDbgEapolTxHwDesc* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_hw_desc".}: uint32
var nimFwDbgEapolTxRate0* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_rate0".}: uint32
var nimFwDbgEapolTxRate1* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_rate1".}: uint32
var nimFwDbgEapolTxRate2* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_rate2".}: uint32
var nimFwDbgEapolTxRate3* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_rate3".}: uint32
var nimFwDbgEapolTxLink0* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_link0".}: uint32
var nimFwDbgEapolTxLink1* {.wifiCtrl, exportc: "nimfw_dbg_eapol_tx_link1".}: uint32
var nimFwDbgDhcpMacRawLen* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_mac_raw_len".}: uint32
var nimFwDbgDhcpMacRaw* {.wifiCtrl, exportc: "nimfw_dbg_dhcp_mac_raw".}: array[96, uint8]
var nimFwDbgWpaState*      {.wifiCtrl, exportc: "nimfw_dbg_wpa_state".}: uint32  # latest WPA_SM_STATE
var nimFwDbgWpaTxState*    {.wifiCtrl, exportc: "nimfw_dbg_wpa_tx_state".}: uint32  # WPA state at TX time
var nimFwDbgWpaRxState*    {.wifiCtrl, exportc: "nimfw_dbg_wpa_rx_state".}: uint32  # WPA state at RX time
var nimFwDbgWpaPtkInstalled* {.wifiCtrl, exportc: "nimfw_dbg_wpa_ptk_installed".}: uint32
# Crypto-derivation snapshot for offline verification.
# Filled by C side at wpa_derive_ptk entry/exit; dumped via UART at end of test.
var nimFwDbgCryptoCaptured*  {.wifiCtrl, exportc: "nimfw_dbg_crypto_captured".}: uint32
var nimFwDbgCryptoPmk*       {.wifiCtrl, exportc: "nimfw_dbg_crypto_pmk".}: array[32, uint8]
var nimFwDbgCryptoOwnAddr*   {.wifiCtrl, exportc: "nimfw_dbg_crypto_own".}: array[6, uint8]
var nimFwDbgCryptoBssid*     {.wifiCtrl, exportc: "nimfw_dbg_crypto_bssid".}: array[6, uint8]
var nimFwDbgCryptoSNonce*    {.wifiCtrl, exportc: "nimfw_dbg_crypto_snonce".}: array[32, uint8]
var nimFwDbgCryptoANonce*    {.wifiCtrl, exportc: "nimfw_dbg_crypto_anonce".}: array[32, uint8]
var nimFwDbgCryptoKck*       {.wifiCtrl, exportc: "nimfw_dbg_crypto_kck".}: array[16, uint8]
var nimFwDbgCryptoPmkLen*    {.wifiCtrl, exportc: "nimfw_dbg_crypto_pmk_len".}: uint32
var nimFwDbgCryptoPtkLen*    {.wifiCtrl, exportc: "nimfw_dbg_crypto_ptk_len".}: uint32
var nimFwDbgCryptoUseSha256* {.wifiCtrl, exportc: "nimfw_dbg_crypto_sha256".}: uint32
var nimFwDbgCryptoKeyMgmt*   {.wifiCtrl, exportc: "nimfw_dbg_crypto_keymgmt".}: uint32
var nimFwDbgCryptoPairwise*  {.wifiCtrl, exportc: "nimfw_dbg_crypto_pairwise".}: uint32
var nimFwDbgCryptoPrfData*   {.wifiCtrl, exportc: "nimfw_dbg_crypto_prf_data".}: array[76, uint8]
# Self-test of SHA1/HMAC primitive: HMAC-SHA1(key="Jefe", data="what do ya want for nothing?")
# Expected output: effcdf6ae5eb2fa2d27416d5f184df9c259a7c79 (RFC 2202 test case 2)
var nimFwDbgSelftestHmac*    {.wifiCtrl, exportc: "nimfw_dbg_selftest_hmac".}: array[20, uint8]
var nimFwDbgSelftestRan*     {.wifiCtrl, exportc: "nimfw_dbg_selftest_ran".}: uint32
# Comparison: the source MAC actually placed in 802.11 frames (vif+80) vs sm->own_addr.
var nimFwDbgVifMac*          {.wifiCtrl, exportc: "nimfw_dbg_vif_mac".}: array[6, uint8]
var nimFwDbgMacHwLo*         {.wifiCtrl, exportc: "nimfw_dbg_mac_hw_lo".}: uint32
var nimFwDbgMacHwHi*         {.wifiCtrl, exportc: "nimfw_dbg_mac_hw_hi".}: uint32
# M2 EAPOL frame snapshot — Ethernet + EAPOL key bytes as sent by supplicant.
var nimFwDbgM2Len*           {.wifiCtrl, exportc: "nimfw_dbg_m2_len".}: uint32
var nimFwDbgM2Buf*           {.wifiCtrl, exportc: "nimfw_dbg_m2_buf".}: array[160, uint8]
# KCK as seen at MIC computation site (wpa_eapol_key_mic).
var nimFwDbgMicKck*          {.wifiCtrl, exportc: "nimfw_dbg_mic_kck".}: array[16, uint8]
var nimFwDbgMicComputed*     {.wifiCtrl, exportc: "nimfw_dbg_mic_computed".}: array[16, uint8]
var nimFwDbgMicFrameLen*     {.wifiCtrl, exportc: "nimfw_dbg_mic_frame_len".}: uint32
var nimFwDbgMicVer*          {.wifiCtrl, exportc: "nimfw_dbg_mic_ver".}: uint32
# SAE path tracking.
var nimFwDbgSaeBuildMsg*     {.wifiCtrl, exportc: "nimfw_dbg_sae_build".}: uint32
var nimFwDbgSaeParseMsg*     {.wifiCtrl, exportc: "nimfw_dbg_sae_parse".}: uint32
var nimFwDbgSaeAuthAlgo*     {.wifiCtrl, exportc: "nimfw_dbg_sae_auth_algo".}: uint32  # auth_algo read in sm_auth_send
var nimFwDbgAuthMgtSeen*     {.wifiCtrl, exportc: "nimfw_dbg_auth_mgt_seen".}: uint32
var nimFwDbgAuthMgtAccepted* {.wifiCtrl, exportc: "nimfw_dbg_auth_mgt_accept".}: uint32
var nimFwDbgAuthMgtRejected* {.wifiCtrl, exportc: "nimfw_dbg_auth_mgt_reject".}: uint32
var nimFwDbgAuthMgtMsgSent*  {.wifiCtrl, exportc: "nimfw_dbg_auth_mgt_msg".}: uint32
var nimFwDbgAuthMgtLast0*    {.wifiCtrl, exportc: "nimfw_dbg_auth_mgt_last0".}: uint32
var nimFwDbgAuthMgtLast1*    {.wifiCtrl, exportc: "nimfw_dbg_auth_mgt_last1".}: uint32
var nimFwDbgMgtSeen*         {.wifiCtrl, exportc: "nimfw_dbg_mgt_seen".}: uint32
var nimFwDbgMgtAccepted*     {.wifiCtrl, exportc: "nimfw_dbg_mgt_accept".}: uint32
var nimFwDbgMgtRejected*     {.wifiCtrl, exportc: "nimfw_dbg_mgt_reject".}: uint32
var nimFwDbgMgtMsgSent*      {.wifiCtrl, exportc: "nimfw_dbg_mgt_msg".}: uint32
var nimFwDbgMgtLastFc*       {.wifiCtrl, exportc: "nimfw_dbg_mgt_last_fc".}: uint32
var nimFwDbgMgtLast0*        {.wifiCtrl, exportc: "nimfw_dbg_mgt_last0".}: uint32
var nimFwDbgMgtLast1*        {.wifiCtrl, exportc: "nimfw_dbg_mgt_last1".}: uint32
var nimFwDbgMgtDropReason*   {.wifiCtrl, exportc: "nimfw_dbg_mgt_drop_reason".}: uint32
var nimFwDbgAuthSmDispatch*  {.wifiCtrl, exportc: "nimfw_dbg_auth_sm_dispatch".}: uint32
var nimFwDbgAuthSmState*     {.wifiCtrl, exportc: "nimfw_dbg_auth_sm_state".}: uint32
var nimFwDbgAuthHandler*     {.wifiCtrl, exportc: "nimfw_dbg_auth_handler".}: uint32
var nimFwDbgAuthHandlerLast* {.wifiCtrl, exportc: "nimfw_dbg_auth_handler_last".}: uint32
var nimFwDbgAuthTxLen*       {.wifiCtrl, exportc: "nimfw_dbg_auth_tx_len".}: uint32
var nimFwDbgAuthTxMeta*      {.wifiCtrl, exportc: "nimfw_dbg_auth_tx_meta".}: uint32
var nimFwDbgAuthTxDesc*      {.wifiCtrl, exportc: "nimfw_dbg_auth_tx_desc".}: uint32
var nimFwDbgAuthTxRaw*       {.wifiCtrl, exportc: "nimfw_dbg_auth_tx_raw".}: array[96, uint8]
var nimFwDbgAuthRfPrePush*   {.wifiCtrl, exportc: "nimfw_dbg_auth_rf_pre_push".}: array[8, uint32]
var nimFwDbgAuthHwPrePush*   {.wifiCtrl, exportc: "nimfw_dbg_auth_hw_pre_push".}: array[32, uint32]
var nimFwDbgAuthCfmPush*     {.wifiCtrl, exportc: "nimfw_dbg_auth_cfm_push".}: uint32
var nimFwDbgAuthCfmFrame*    {.wifiCtrl, exportc: "nimfw_dbg_auth_cfm_frame".}: uint32
var nimFwDbgAuthCfmEvt*      {.wifiCtrl, exportc: "nimfw_dbg_auth_cfm_evt".}: uint32
var nimFwDbgAuthCfmStatus*   {.wifiCtrl, exportc: "nimfw_dbg_auth_cfm_status".}: uint32
var nimFwDbgAuthCfmHwStatus* {.wifiCtrl, exportc: "nimfw_dbg_auth_cfm_hw_status".}: uint32
var nimFwDbgAuthCfmDesc*     {.wifiCtrl, exportc: "nimfw_dbg_auth_cfm_desc".}: uint32
var nimFwDbgAuthCfmMeta*     {.wifiCtrl, exportc: "nimfw_dbg_auth_cfm_meta".}: uint32
var nimFwDbgAuthCfmFc*       {.wifiCtrl, exportc: "nimfw_dbg_auth_cfm_fc".}: uint32
var nimFwDbgScanFrameSeen*   {.wifiCtrl, exportc: "nimfw_dbg_scan_frame_seen".}: uint32
var nimFwDbgScanFrameAccepted* {.wifiCtrl, exportc: "nimfw_dbg_scan_frame_accept".}: uint32
var nimFwDbgScanFrameLast*   {.wifiCtrl, exportc: "nimfw_dbg_scan_frame_last".}: uint32
var nimFwDbgScanSsidLast*    {.wifiCtrl, exportc: "nimfw_dbg_scan_ssid_last".}: uint32
var nimFwDbgBssIn*           {.wifiCtrl, exportc: "nimfw_dbg_bss_in".}: uint32
var nimFwDbgBssSsidResult*   {.wifiCtrl, exportc: "nimfw_dbg_bss_ssid_result".}: uint32
var nimFwDbgBssDirected*     {.wifiCtrl, exportc: "nimfw_dbg_bss_directed".}: uint32
var nimFwDbgBssOut*          {.wifiCtrl, exportc: "nimfw_dbg_bss_out".}: uint32
var nimFwDbgSsidSearch*      {.wifiCtrl, exportc: "nimfw_dbg_ssid_search".}: uint32
var nimFwDbgSsidEntries*     {.wifiCtrl, exportc: "nimfw_dbg_ssid_entries".}: uint32
var nimFwDbgSsidHits*        {.wifiCtrl, exportc: "nimfw_dbg_ssid_hits".}: uint32
var nimFwDbgScanKeyMgmt*     {.wifiCtrl, exportc: "nimfw_dbg_scan_key_mgmt".}: uint32  # lf (parsed key_mgmt LE 16-bit)
var nimFwDbgScanAT*          {.wifiCtrl, exportc: "nimfw_dbg_scan_at".}: uint32  # computed aT
var nimFwDbgScanSmF*         {.wifiCtrl, exportc: "nimfw_dbg_scan_smf".}: uint32  # smF flags
var nimFwDbgScanCaps*        {.wifiCtrl, exportc: "nimfw_dbg_scan_caps".}: uint32  # lS[16] (capabilities)
# M4 path tracking — debug why PTK never gets installed.
var nimFwDbgM4TxState*       {.wifiCtrl, exportc: "nimfw_dbg_m4_tx_state".}: uint32  # WPA state at M4 TX
var nimFwDbgM4CbPtr*         {.wifiCtrl, exportc: "nimfw_dbg_m4_cb_ptr".}: uint32    # custom_cfm.cb at M4 TX
var nimFwDbgCfmCbPtrLast*    {.wifiCtrl, exportc: "nimfw_dbg_cfm_cb_ptr_last".}: uint32  # what bl_tx_cfm read
var nimFwDbgSendCfmLastEthertype* {.wifiCtrl, exportc: "nimfw_dbg_cfm_last_ethertype".}: uint32
var nimFwDbgSend4of4Tx*      {.wifiCtrl, exportc: "nimfw_dbg_send_4of4_tx".}: uint32  # M4 send invocations
var nimFwDbgSend4of4Cb*      {.wifiCtrl, exportc: "nimfw_dbg_send_4of4_cb".}: uint32  # wpa_supplicant_send_4_of_4_txcallback invocations
var nimFwDbgInstallPtk*      {.wifiCtrl, exportc: "nimfw_dbg_install_ptk".}: uint32  # wpa_supplicant_install_ptk invocations
# Per-EAPOL bl_tx_cfm details — status (THD[16]) for last EAPOL frame.
var nimFwDbgEapolCfmStatus*  {.wifiCtrl, exportc: "nimfw_dbg_eapol_cfm_status".}: uint32
var nimFwDbgEapolCfmCount*   {.wifiCtrl, exportc: "nimfw_dbg_eapol_cfm_count".}: uint32
var nimFwDbgEapolCfmAckOk*   {.wifiCtrl, exportc: "nimfw_dbg_eapol_cfm_ack_ok".}: uint32
var nimFwDbgEapolCfmAckFail* {.wifiCtrl, exportc: "nimfw_dbg_eapol_cfm_ack_fail".}: uint32
var nimFwDbgEapolCfmRingIdx* {.wifiCtrl, exportc: "nimfw_dbg_eapol_cfm_ring_idx".}: uint32
var nimFwDbgEapolCfmStatusLog* {.wifiCtrl, exportc: "nimfw_dbg_eapol_cfm_status_log".}: array[4, uint32]
var nimFwDbgEapolCfmMetaLog* {.wifiCtrl, exportc: "nimfw_dbg_eapol_cfm_meta_log".}: array[4, uint32]
var nimFwDbgEapolCfmKeyLog* {.wifiCtrl, exportc: "nimfw_dbg_eapol_cfm_key_log".}: array[4, uint32]
var nimFwDbgEapolCfmReplayLog* {.wifiCtrl, exportc: "nimfw_dbg_eapol_cfm_replay_log".}: array[4, uint32]
var nimFwDbgEapolCfmCbLog* {.wifiCtrl, exportc: "nimfw_dbg_eapol_cfm_cb_log".}: array[4, uint32]
# Disconnect-path counters.
var nimFwDbgDisconnectReq*   {.wifiCtrl, exportc: "nimfw_dbg_disconnect_req".}: uint32
var nimFwDbgDisconnectReqState* {.wifiCtrl, exportc: "nimfw_dbg_disconnect_req_state".}: uint32
var nimFwDbgDisconnectProcess* {.wifiCtrl, exportc: "nimfw_dbg_disconnect_process".}: uint32
var nimFwDbgDisconnectInd*   {.wifiCtrl, exportc: "nimfw_dbg_disconnect_ind".}: uint32
var nimFwDbgSmStateFinal*    {.wifiCtrl, exportc: "nimfw_dbg_sm_state_final".}: uint32

const NimFwTraceEnabled =
  defined(bl808WifiNimFwTrace) or
  defined(bl808WifiScanTrace) or
  defined(bl808WifiVerboseConnect)

when NimFwTraceEnabled:
  proc c_puts(s: cstring): cint {.importc: "puts", header: "<stdio.h>", cdecl, discardable.}
  proc c_printf(fmt: cstring): cint {.importc: "printf", header: "<stdio.h>", cdecl, varargs, discardable.}

  proc nimFwTrace(s: cstring) {.inline.} =
    discard c_puts(s)

  proc nimFwTraceU32(prefix: cstring, value: uint32) {.inline.} =
    c_printf("%s0x%x\r\n", prefix, value)

  proc nimFwTrace2U32(prefix: cstring, a, b: uint32) {.inline.} =
    c_printf("%s0x%x 0x%x\r\n", prefix, a, b)
else:
  proc nimFwTrace(s: cstring) {.inline.} =
    discard s
  proc nimFwTraceU32(prefix: cstring, value: uint32) {.inline.} =
    discard prefix
    discard value
  proc nimFwTrace2U32(prefix: cstring, a, b: uint32) {.inline.} =
    discard prefix
    discard a
    discard b

when defined(bl808WifiConnectTrace):
  proc hwValidationLogByte(b: uint8) {.importc: "hw_validation_log_byte", cdecl.}

  proc nimFwConnectTraceText(s: cstring) {.inline.} =
    if s == nil: return
    let p = cast[ptr UncheckedArray[char]](s)
    var i = 0
    while p[i] != '\0':
      hwValidationLogByte(ord(p[i]).uint8)
      inc i

  proc nimFwConnectTraceHex(value: uint32) {.inline.} =
    const hexChars = "0123456789ABCDEF"
    nimFwConnectTraceText("0x")
    var started = false
    for shift in countdown(28, 0, 4):
      let nibble = (value shr shift) and 0xF'u32
      if nibble != 0 or started or shift == 0:
        hwValidationLogByte(ord(hexChars[nibble.int]).uint8)
        started = true

  proc nimFwConnectTraceHexByte(value: uint8) {.inline.} =
    const hexChars = "0123456789ABCDEF"
    hwValidationLogByte(ord(hexChars[(value shr 4).int and 0xF]).uint8)
    hwValidationLogByte(ord(hexChars[(value and 0xF'u8).int]).uint8)

  proc nimFwConnectTrace2U32(prefix: cstring, a, b: uint32) {.inline.} =
    nimFwConnectTraceText(prefix)
    nimFwConnectTraceHex(a)
    hwValidationLogByte(ord(' ').uint8)
    nimFwConnectTraceHex(b)
    hwValidationLogByte(ord('\r').uint8)
    hwValidationLogByte(ord('\n').uint8)

  proc nimFwConnectTraceBytes(prefix: cstring; data: pointer; length, limit: uint32) {.inline.} =
    if data == nil: return
    let bytes = cast[ptr UncheckedArray[uint8]](data)
    var count = length
    if count > limit:
      count = limit
    nimFwConnectTraceText(prefix)
    nimFwConnectTraceHex(length)
    hwValidationLogByte(ord(' ').uint8)
    var i = 0'u32
    while i < count:
      if i != 0:
        hwValidationLogByte(ord(' ').uint8)
      nimFwConnectTraceHexByte(bytes[i])
      inc i
    hwValidationLogByte(ord('\r').uint8)
    hwValidationLogByte(ord('\n').uint8)

  proc nimFwConnectTraceHw(prefix: cstring) {.inline.} =
    nimFwConnectTrace2U32(prefix, regRead(MACHW_BASE + 0x10'u), regRead(MACHW_BASE + 0x14'u))
    nimFwConnectTrace2U32("[WIFI-CT] hw_bss ", regRead(MACHW_BASE + 0x20'u), regRead(MACHW_BASE + 0x24'u))
    nimFwConnectTrace2U32("[WIFI-CT] hw_rx ", regRead(MACHW_BASE + 0x60'u), regRead(MACHW_BASE + 0x4C'u))
    nimFwConnectTrace2U32("[WIFI-CT] hw_state ", regRead(MACHW_BASE + 0x38'u), regRead(MACHW_BASE + 0xC4'u))
else:
  proc nimFwConnectTrace2U32(prefix: cstring, a, b: uint32) {.inline.} =
    discard prefix
    discard a
    discard b
  proc nimFwConnectTraceBytes(prefix: cstring; data: pointer; length, limit: uint32) {.inline.} =
    discard prefix
    discard data
    discard length
    discard limit
  proc nimFwConnectTraceHw(prefix: cstring) {.inline.} =
    discard prefix

template nimFwMgmtFcTrace(fc: uint8): bool =
  ## Management frames have type bits [3:2] clear in the first FC byte.
  (fc and 0x0C'u8) == 0'u8

# Forward declarations for functions used before their definition
proc ipc_emb_msg_push*(msgDescPtr: pointer) {.exportc, cdecl.}
proc assert_rec*(cond: cstring, file: cstring, line: cint) {.exportc, cdecl.}
proc blmac_soft_reset_getf*(): uint8 {.exportc, cdecl, noinline.}
when defined(bl808WifiUseBl808Rf):
  proc crm_get_mac_freq(): uint32 {.exportc, cdecl.}
  proc phy_get_mac_freq*(): uint32 {.exportc, cdecl.} =
    crm_get_mac_freq()
elif defined(bl808WifiAllowLegacyBl606pRfFallback):
  proc phy_get_mac_freq*(): uint32 {.importc, cdecl.}
proc rxl_timeout_int_handler*() {.exportc, cdecl.}
proc mm_sec_machwaddr_wr*(vifIdx: uint8, addr_ptr: pointer, idx: uint8): uint8 {.exportc, cdecl, discardable.}
proc mm_sec_machwkey_wr*(param: pointer) {.exportc, cdecl.}
proc sta_mgmt_register*(param: pointer, staIdxOut: ptr uint8): uint8 {.exportc, cdecl.}
proc sta_mgmt_unregister*(staIdx: uint8) {.exportc, cdecl.}
proc txl_cntrl_push_int*(param: pointer, ac: uint8): uint8 {.exportc, cdecl.}
proc mm_ap_probe_cfm*(param: pointer) {.exportc, cdecl.}
proc mm_ap_traffic_probe_cfm*(vifEntry: pointer, status: uint32) {.exportc, cdecl.}
proc mm_bcn_update*(vifEntry: pointer): pointer {.exportc, cdecl, noinline.}
proc rxu_cntrl_frame_handle*(param: pointer): uint32 {.exportc, cdecl.}
proc rxu_cntrl_desc_prepare*(swdesc: pointer) {.exportc, cdecl, noinline.}
proc rxu_mpdu_upload_and_indicate*(param: pointer) {.exportc, cdecl.}

## rxu_cntrl_env: static context structure used by the RX upper control path.
## Declared before RX lower reset so typed overlays can reference uploadList.
var rxu_cntrl_env* {.exportc.}: array[96, uint8]

proc txl_buffer_alloc*(param: pointer, queueIdx: uint32, flags: uint32): pointer {.exportc, cdecl.}
proc txu_cntrl_frame_build*(desc: pointer, bufPtr: pointer) {.exportc, cdecl.}
proc txl_cfm_flush_desc*(desc: pointer) {.exportc, cdecl.}
proc ipc_emb_tx_evt*(ac: uint32) {.exportc, cdecl.}
proc rxl_mpdu_transfer*(desc: pointer) {.exportc, cdecl.}
proc rxu_mgt_frame_check*(param: pointer, vifIdxArg: uint8): uint32 {.exportc, cdecl.}
proc me_build_associate_req_impl(buf: pointer, assocInfo: pointer,
    reassocBssid: pointer, capParam: pointer, cursorOut: pointer,
    bodyLenOut: pointer, connInfo: pointer): uint32 {.exportc: "me_build_associate_req", cdecl.}
# Nim-side wrapper so existing Nim callers (single pointer) still compile:
template me_build_associate_req*(frame: pointer): uint32 =
  me_build_associate_req_impl(frame, nil, nil, nil, nil, nil, nil)
proc me_build_add_ba_req*(buf: pointer, param: pointer): uint32 {.exportc, cdecl.}
proc txl_frame_push*(param: pointer, ac: uint8): uint8 {.exportc, cdecl, noinline, discardable.}
proc txl_frame_get*(length: uint32): pointer {.exportc, cdecl.}
proc txl_tx_desc_pointer_plausible(p: pointer): bool
proc txl_frame_rebuild_free_list(): uint32
proc txl_get_seq_ctrl*(): uint16 {.exportc, cdecl.}
proc tpc_update_frame_tx_power*(env: pointer, frameDesc: pointer) {.exportc, cdecl.}
proc txu_cntrl_protect_mgmt_frame*(param: pointer, hdrPtr: pointer, extraLen: uint32) {.exportc, cdecl.}
proc txu_cntrl_sechdr_len_compute*(txDesc: pointer, lenOut: ptr uint32): uint32 {.exportc, cdecl.}
proc txu_cntrl_sec_hdr_append*(txDesc: pointer, secHdr: pointer,
                               updateCurrentDesc: uint32): pointer {.exportc, cdecl.}
proc td_pck_ind*(vifIdx: uint8, direction: uint32) {.exportc, cdecl.}
proc sm_disconnect_process*(param: pointer, statusCode: uint16 = 0, reasonCode: uint16 = 0) {.exportc, cdecl.}
proc sm_connect_abort_process*(param: pointer, statusCode: uint16 = 0, reasonCode: uint16 = 0) {.exportc, cdecl.}
proc hsu_aes_cmac*(key: pointer, msg: pointer, msgLen: uint32, mac: pointer) {.exportc, cdecl.}
proc mm_sec_macrx_ind*(staIdx: uint8, payload: pointer, length: uint16) {.exportc, cdecl.}
proc chan_bcn_detect_start*(vifEntry: pointer) {.exportc, cdecl.}
proc chan_ctxt_trigger*(ctxt: pointer) {.exportc, cdecl.}
proc scanu_confirm*(status: uint8) {.exportc, cdecl.}

proc nimFwDbgDhcpTxFinalBreakpoint*() {.exportc: "nimfw_dbg_dhcp_tx_final_breakpoint",
    cdecl, noinline.} =
  inc nimFwDbgDhcpTxFinalBreakHits

proc nimFwDbgRxuDupDropBreakpoint*() {.exportc: "nimfw_dbg_rxu_dup_drop_breakpoint",
    cdecl, noinline.} =
  inc nimFwDbgRxuDupBreakHits

proc nimFwDbgRxuIpv4Preupload(frame: ptr MacDataFrameHeaderView;
                              machdrLen, tid: uint8;
                              frameLen: uint16) {.noinline.} =
  if frameLen.uint32 < machdrLen.uint32 + sizeof(LlcSnapHeaderView).uint32 + 20'u32:
    return
  let msduView = rxMsduView(frame, machdrLen)
  let msdu = addr msduView.snap
  if not rxSnapIsRfc1042(msdu) or msdu.ethertype != 0x0008'u16:
    return
  let msduLen = frameLen.uint32 - machdrLen.uint32
  let ipPayload = cast[ptr UncheckedArray[uint8]](rxMsduPayload(msduView))
  let version = ipPayload[0] shr 4
  let ihl = (ipPayload[0].uint32 and 0x0F'u32) shl 2
  if version != 4'u8 or ihl < 20'u32 or
      msduLen < sizeof(LlcSnapHeaderView).uint32 + ihl:
    return
  let proto = ipPayload[9].uint32
  nimFwDbgRxuAssocLastIpProto = proto or
    (frameLen.uint32 shl 8) or (machdrLen.uint32 shl 24)
  if proto == 17'u32:
    inc nimFwDbgRxuAssocUdp
  elif proto == 6'u32 and
      msduLen >= sizeof(LlcSnapHeaderView).uint32 + ihl + 20'u32:
    inc nimFwDbgRxuAssocTcp
    let tcp = cast[ptr UncheckedArray[uint8]](
      cast[pointer](cast[uint](ipPayload) + ihl.uint))
    let srcPort = (tcp[0].uint32 shl 8) or tcp[1].uint32
    let dstPort = (tcp[2].uint32 shl 8) or tcp[3].uint32
    let flags = tcp[13].uint32
    nimFwDbgRxuAssocLastTcpPorts = (srcPort shl 16) or dstPort
    nimFwDbgRxuAssocLastTcpFlags = flags
    if srcPort == 80'u32 or dstPort == 80'u32:
      inc nimFwDbgRxuAssocTcp80
      nimFwDbgRxuAssocTcpMeta = frameLen.uint32 or
        (machdrLen.uint32 shl 16) or (tid.uint32 shl 24)
      let copyLen =
        if msduLen - sizeof(LlcSnapHeaderView).uint32 < 64'u32:
          msduLen - sizeof(LlcSnapHeaderView).uint32
        else:
          64'u32
      for i in 0 ..< 64:
        nimFwDbgRxuAssocTcpRaw[i] = 0
      for i in 0'u32 ..< copyLen:
        nimFwDbgRxuAssocTcpRaw[i.int] = ipPayload[i]

proc nimFwDbgRxuDhcpMsg(frame: ptr MacDataFrameHeaderView; machdrLen: uint8;
                        frameLen: uint16): uint32 {.noinline.} =
  if frameLen.uint32 < machdrLen.uint32 + sizeof(LlcSnapHeaderView).uint32:
    return 0
  let msduView = rxMsduView(frame, machdrLen)
  let msdu = addr msduView.snap
  let msduLen = frameLen.uint32 - machdrLen.uint32
  let ipPayload = cast[ptr UncheckedArray[uint8]](rxMsduPayload(msduView))
  if not rxSnapIsRfc1042(msdu) or msdu.ethertype != 0x0008'u16 or
      msduLen < 28'u32:
    return 0
  let ihl = (ipPayload[0].uint32 and 0x0F'u32) shl 2
  if ihl < 20'u32 or msduLen < sizeof(LlcSnapHeaderView).uint32 + ihl + 8'u32:
    return 0
  let udp = cast[pointer](cast[uint](ipPayload) + ihl.uint)
  if debugLoadLe32(udp) != 0x44004300'u32:
    return 0
  if msduLen < sizeof(LlcSnapHeaderView).uint32 + ihl + 8'u32 + 240'u32:
    return 0
  let bootp = cast[pointer](cast[uint](udp) + 8'u)
  var optOff = cast[uint](bootp) + 240'u
  let optEnd = cast[uint](ipPayload) + msduLen.uint
  var guard = 0
  while optOff < optEnd and guard < 64:
    inc guard
    let code = cast[ptr uint8](optOff)[]
    inc optOff
    if code == 0'u8:
      continue
    if code == 255'u8 or optOff >= optEnd:
      break
    let optLen = cast[ptr uint8](optOff)[]
    inc optOff
    if optOff + optLen.uint > optEnd:
      break
    if code == 53'u8 and optLen >= 1'u8:
      return cast[ptr uint8](optOff)[].uint32
    optOff += optLen.uint
  0

proc nimFwDbgRecordRxuDupDrop(frame: ptr MacDataFrameHeaderView; hwFlags: uint32;
                              envSeq: uint16; tid, machdrLen: uint8;
                              cachedSeq: uint16; frameLen: uint16) {.noinline.} =
  let idx = int(nimFwDbgRxuDupTraceCount mod RxuDupTraceEntries.uint32)
  inc nimFwDbgRxuDupTraceCount
  let msduView = rxMsduView(frame, machdrLen)
  let msdu = addr msduView.snap
  nimFwDbgRxuDupTraceFc[idx] = frame.frameControl.uint32 or
    (hwFlags and 0xFFFF0000'u32)
  nimFwDbgRxuDupTraceSeq[idx] = envSeq.uint32 or
    (tid.uint32 shl 16) or (machdrLen.uint32 shl 24)
  nimFwDbgRxuDupTraceCache[idx] = cachedSeq.uint32
  nimFwDbgRxuDupTraceSnapLo[idx] = rxSnapTraceLo(msdu)
  nimFwDbgRxuDupTraceSnapHi[idx] = rxSnapTraceHi(msdu)
  nimFwDbgRxuDupTraceAddr0[idx] = debugLoadLe32(addr frame.addr1[0])
  nimFwDbgRxuDupTraceAddr1[idx] = debugLoadLe32(addr frame.addr2[0])
  nimFwDbgRxuDupTraceIp0[idx] = 0
  nimFwDbgRxuDupTraceUdp0[idx] = 0
  nimFwDbgRxuDupTraceBootp0[idx] = 0
  nimFwDbgRxuDupTraceBootp1[idx] = 0
  nimFwDbgRxuDupTraceBootpYiaddr[idx] = 0
  nimFwDbgRxuDupTraceDhcpMsg[idx] = 0
  nimFwDbgRxuDupTraceDhcpServer[idx] = 0
  if frameLen.uint32 >= machdrLen.uint32 + sizeof(LlcSnapHeaderView).uint32:
    let msduLen = frameLen.uint32 - machdrLen.uint32
    let ipPayload = cast[ptr UncheckedArray[uint8]](rxMsduPayload(msduView))
    if rxSnapIsRfc1042(msdu) and msdu.ethertype == 0x0008'u16 and msduLen >= 28'u32:
      nimFwDbgRxuDupTraceIp0[idx] = debugLoadLe32(cast[pointer](ipPayload))
      let ihl = (ipPayload[0].uint32 and 0x0F'u32) shl 2
      if ihl >= 20'u32 and msduLen >= sizeof(LlcSnapHeaderView).uint32 + ihl + 8'u32:
        let udp = cast[pointer](cast[uint](ipPayload) + ihl.uint)
        nimFwDbgRxuDupTraceUdp0[idx] = debugLoadLe32(udp)
        if msduLen >= sizeof(LlcSnapHeaderView).uint32 + ihl + 16'u32:
          let bootp = cast[pointer](cast[uint](udp) + 8'u)
          nimFwDbgRxuDupTraceBootp0[idx] = debugLoadLe32(bootp)
          nimFwDbgRxuDupTraceBootp1[idx] =
            debugLoadLe32(cast[pointer](cast[uint](udp) + 12'u))
          if msduLen >= sizeof(LlcSnapHeaderView).uint32 + ihl + 32'u32:
            nimFwDbgRxuDupTraceBootpYiaddr[idx] =
              debugLoadLe32(cast[pointer](cast[uint](bootp) + 16'u))
          if msduLen >= sizeof(LlcSnapHeaderView).uint32 + ihl + 8'u32 + 240'u32:
            var optOff = cast[uint](bootp) + 240'u
            let optEnd = cast[uint](ipPayload) + msduLen.uint
            var guard = 0
            while optOff < optEnd and guard < 64:
              inc guard
              let code = cast[ptr uint8](optOff)[]
              inc optOff
              if code == 0'u8:
                continue
              if code == 255'u8 or optOff >= optEnd:
                break
              let optLen = cast[ptr uint8](optOff)[]
              inc optOff
              if optOff + optLen.uint > optEnd:
                break
              if code == 53'u8 and optLen >= 1'u8:
                nimFwDbgRxuDupTraceDhcpMsg[idx] =
                  cast[ptr uint8](optOff)[].uint32
              elif code == 54'u8 and optLen >= 4'u8:
                nimFwDbgRxuDupTraceDhcpServer[idx] =
                  debugLoadLe32(cast[pointer](optOff))
              optOff += optLen.uint
  nimFwDbgRxuDupDropBreakpoint()

proc nimFwDbgRecordRxuPnDrop(frame: ptr MacDataFrameHeaderView; hwFlags: uint32;
                             envSeq: uint16; tid, machdrLen: uint8;
                             frameLen: uint16) {.noinline.} =
  let idx = int(nimFwDbgRxuPnDropTraceCount mod RxuPnDropTraceEntries.uint32)
  inc nimFwDbgRxuPnDropTraceCount
  let env = rxuCntrlEnvView()
  let msduView = rxMsduView(frame, machdrLen)
  let msdu = addr msduView.snap
  nimFwDbgRxuPnDropTraceFc[idx] = frame.frameControl.uint32 or
    (hwFlags and 0xFFFF0000'u32)
  nimFwDbgRxuPnDropTraceSeq[idx] = envSeq.uint32 or
    (tid.uint32 shl 16) or (machdrLen.uint32 shl 24)
  nimFwDbgRxuPnDropTracePnLo[idx] = env.secInfo0
  nimFwDbgRxuPnDropTracePnHi[idx] = env.secInfo1
  nimFwDbgRxuPnDropTraceStoredLo[idx] = nimFwDbgRxuPnStoredLo
  nimFwDbgRxuPnDropTraceStoredHi[idx] = nimFwDbgRxuPnStoredHi
  nimFwDbgRxuPnDropTraceSnapLo[idx] = rxSnapTraceLo(msdu)
  nimFwDbgRxuPnDropTraceSnapHi[idx] = rxSnapTraceHi(msdu)
  nimFwDbgRxuPnDropTraceUdp0[idx] = 0
  nimFwDbgRxuPnDropTraceBootpYiaddr[idx] = 0
  nimFwDbgRxuPnDropTraceDhcpMsg[idx] = 0
  nimFwDbgRxuPnDropTraceDhcpServer[idx] = 0
  if frameLen.uint32 >= machdrLen.uint32 + sizeof(LlcSnapHeaderView).uint32:
    let msduLen = frameLen.uint32 - machdrLen.uint32
    let ipPayload = cast[ptr UncheckedArray[uint8]](rxMsduPayload(msduView))
    if rxSnapIsRfc1042(msdu) and msdu.ethertype == 0x0008'u16 and msduLen >= 28'u32:
      let ihl = (ipPayload[0].uint32 and 0x0F'u32) shl 2
      if ihl >= 20'u32 and msduLen >= sizeof(LlcSnapHeaderView).uint32 + ihl + 8'u32:
        let udp = cast[pointer](cast[uint](ipPayload) + ihl.uint)
        nimFwDbgRxuPnDropTraceUdp0[idx] = debugLoadLe32(udp)
        if msduLen >= sizeof(LlcSnapHeaderView).uint32 + ihl + 32'u32:
          let bootp = cast[pointer](cast[uint](udp) + 8'u)
          nimFwDbgRxuPnDropTraceBootpYiaddr[idx] =
            debugLoadLe32(cast[pointer](cast[uint](bootp) + 16'u))
          if msduLen >= sizeof(LlcSnapHeaderView).uint32 + ihl + 8'u32 + 240'u32:
            var optOff = cast[uint](bootp) + 240'u
            let optEnd = cast[uint](ipPayload) + msduLen.uint
            var guard = 0
            while optOff < optEnd and guard < 64:
              inc guard
              let code = cast[ptr uint8](optOff)[]
              inc optOff
              if code == 0'u8:
                continue
              if code == 255'u8 or optOff >= optEnd:
                break
              let optLen = cast[ptr uint8](optOff)[]
              inc optOff
              if optOff + optLen.uint > optEnd:
                break
              if code == 53'u8 and optLen >= 1'u8:
                nimFwDbgRxuPnDropTraceDhcpMsg[idx] =
                  cast[ptr uint8](optOff)[].uint32
              elif code == 54'u8 and optLen >= 4'u8:
                nimFwDbgRxuPnDropTraceDhcpServer[idx] =
                  debugLoadLe32(cast[pointer](optOff))
              optOff += optLen.uint

proc nimFwDbgRecordRxuPnAccept(stage: uint32; frame: ptr MacDataFrameHeaderView;
                               hwFlags: uint32; envSeq: uint16;
                               tid, machdrLen: uint8; frameLen: uint16) {.noinline.} =
  let idx = int(nimFwDbgRxuPnAcceptTraceCount mod RxuPnAcceptTraceEntries.uint32)
  inc nimFwDbgRxuPnAcceptTraceCount
  let env = rxuCntrlEnvView()
  let msduView = rxMsduView(frame, machdrLen)
  let msdu = addr msduView.snap
  nimFwDbgRxuPnAcceptTraceStage[idx] = stage
  nimFwDbgRxuPnAcceptTraceFc[idx] = frame.frameControl.uint32 or
    (hwFlags and 0xFFFF0000'u32)
  nimFwDbgRxuPnAcceptTraceSeq[idx] = envSeq.uint32 or
    (tid.uint32 shl 16) or (machdrLen.uint32 shl 24)
  nimFwDbgRxuPnAcceptTracePnLo[idx] = env.secInfo0
  nimFwDbgRxuPnAcceptTracePnHi[idx] = env.secInfo1
  nimFwDbgRxuPnAcceptTraceStoredLo[idx] = nimFwDbgRxuPnStoredLo
  nimFwDbgRxuPnAcceptTraceStoredHi[idx] = nimFwDbgRxuPnStoredHi
  nimFwDbgRxuPnAcceptTraceNextLo[idx] = nimFwDbgRxuPnNextLo
  nimFwDbgRxuPnAcceptTraceNextHi[idx] = nimFwDbgRxuPnNextHi
  nimFwDbgRxuPnAcceptTraceSnapLo[idx] = rxSnapTraceLo(msdu)
  nimFwDbgRxuPnAcceptTraceSnapHi[idx] = rxSnapTraceHi(msdu)
  nimFwDbgRxuPnAcceptTraceUdp0[idx] = 0
  nimFwDbgRxuPnAcceptTraceBootpYiaddr[idx] = 0
  nimFwDbgRxuPnAcceptTraceDhcpMsg[idx] = 0
  nimFwDbgRxuPnAcceptTraceDhcpServer[idx] = 0
  if frameLen.uint32 >= machdrLen.uint32 + sizeof(LlcSnapHeaderView).uint32:
    let msduLen = frameLen.uint32 - machdrLen.uint32
    let ipPayload = cast[ptr UncheckedArray[uint8]](rxMsduPayload(msduView))
    if rxSnapIsRfc1042(msdu) and msdu.ethertype == 0x0008'u16 and msduLen >= 28'u32:
      let ihl = (ipPayload[0].uint32 and 0x0F'u32) shl 2
      if ihl >= 20'u32 and msduLen >= sizeof(LlcSnapHeaderView).uint32 + ihl + 8'u32:
        let udp = cast[pointer](cast[uint](ipPayload) + ihl.uint)
        nimFwDbgRxuPnAcceptTraceUdp0[idx] = debugLoadLe32(udp)
        if msduLen >= sizeof(LlcSnapHeaderView).uint32 + ihl + 32'u32:
          let bootp = cast[pointer](cast[uint](udp) + 8'u)
          nimFwDbgRxuPnAcceptTraceBootpYiaddr[idx] =
            debugLoadLe32(cast[pointer](cast[uint](bootp) + 16'u))
          if msduLen >= sizeof(LlcSnapHeaderView).uint32 + ihl + 8'u32 + 240'u32:
            var optOff = cast[uint](bootp) + 240'u
            let optEnd = cast[uint](ipPayload) + msduLen.uint
            var guard = 0
            while optOff < optEnd and guard < 64:
              inc guard
              let code = cast[ptr uint8](optOff)[]
              inc optOff
              if code == 0'u8:
                continue
              if code == 255'u8 or optOff >= optEnd:
                break
              let optLen = cast[ptr uint8](optOff)[]
              inc optOff
              if optOff + optLen.uint > optEnd:
                break
              if code == 53'u8 and optLen >= 1'u8:
                nimFwDbgRxuPnAcceptTraceDhcpMsg[idx] =
                  cast[ptr uint8](optOff)[].uint32
              elif code == 54'u8 and optLen >= 4'u8:
                nimFwDbgRxuPnAcceptTraceDhcpServer[idx] =
                  debugLoadLe32(cast[pointer](optOff))
              optOff += optLen.uint
proc sm_assoc_req_send_pre*(param: pointer) {.exportc, cdecl.}
proc sm_send_next_bss_param*(param: pointer) {.exportc, cdecl.}
proc me_build_capability*(param: pointer): uint16 {.exportc, cdecl.}
proc txl_frame_push_force*(param: pointer, ac: uint8) {.exportc, cdecl.}
proc txl_transmit_trigger*() {.exportc, cdecl.}
proc txl_cntrl_clear_ac*(ac: uint8) {.exportc, cdecl.}
proc apm_send_next_bss_param*(param: pointer) {.exportc, cdecl.}
proc apm_embedded_enabled*(vifEntry: pointer): bool {.exportc, cdecl, noinline.}
proc me_add_ie_customer*(buf: pointer, ieData: pointer = nil,
                         length: uint32 = 0): uint32 {.exportc, cdecl.}
proc apm_bcn_set*(param: pointer) {.exportc, cdecl.}
proc vif_mgmt_get_first_ap_inf*(): pointer {.exportc, cdecl.}
proc sm_handle_connection*(vifIdxOrFlag: uint32, status: uint32, callbackCtx: pointer, failureFn: pointer) {.exportc, cdecl.}
proc sm_connect_ind*(statusCode: uint16, reasonCode: uint16) {.exportc, cdecl, noinline.}
proc sm_deauth_send*(param: pointer, reason: uint16) {.exportc, cdecl.}
proc sm_get_bss_params*(resultOut: ptr pointer, chanPtrOut: ptr pointer): bool {.exportc, cdecl.}
proc sm_scan_bss*(bssid: pointer, ssid: pointer, chanInfo: pointer) {.exportc, cdecl.}
proc sm_join_bss*(bssid: pointer, ssid: pointer, joinInfo: pointer, flag: uint32) {.exportc, cdecl.}
proc me_beacon_check*(vifIdx: uint8, frameDesc: pointer, iesBase: pointer) {.exportc, cdecl.}
proc rc_update_bw_nss_max*(staIdx: uint8, nss: uint8, groupCnt: uint8) {.exportc, cdecl.}
proc me_build_deauthenticate*(buf: pointer, reason: uint16): uint32 {.exportc, cdecl, noinline.}
proc me_build_beacon*(buf: pointer, vifIdx: uint8, lenOut: ptr uint16,
                     flagsOut: ptr uint8, hiddenSsid: uint8): uint32 {.exportc, cdecl.}
proc me_build_authenticate*(buf: pointer, authAlgo: uint16, authSeq: uint16,
    statusCode: uint16, challengeText: pointer): uint32 {.exportc, cdecl, noinline.}
proc me_build_associate_rsp_impl(buf: pointer, staEntry: pointer,
    statusCode: uint16, aid: uint16): uint32 {.exportc: "me_build_associate_rsp", cdecl.}
# Nim-side proc alias so existing callers that cast the function pointer still work:
proc me_build_associate_rsp*(buf: pointer, p1: pointer = nil, p2: uint16 = 0, p3: uint16 = 0): uint32 {.inline.} =
  me_build_associate_rsp_impl(buf, p1, p2, p3)
proc me_build_sae_authenticate*(buf: pointer, authAlgo: uint16, authSeq: uint16, statusCode: uint16, vifIdx: uint32): uint32 {.exportc, cdecl.}
proc me_build_probe_rsp*(buf: pointer, vifIdx: uint8,
    lenOut: ptr uint16): uint32 {.exportc, cdecl.}
proc vif_mgmt_entry_init*(vifEntry: pointer) {.exportc, cdecl.}
proc vif_mgmt_add_to_list*(vifEntry: pointer) {.exportc, cdecl.}
proc vif_mgmt_bcn_to_prog*(vifEntry: pointer) {.exportc, cdecl.}
proc vif_mgmt_bcn_to_evt*(vifEntry: pointer) {.exportc, cdecl.}

# Forward declarations for channel management helpers
proc chan_distribute_slots*() {.exportc, cdecl.}
proc chan_tbtt_insert*(tbttNode: pointer) {.exportc, cdecl.}
proc scanu_cached_scanresult_clear*() {.exportc, cdecl.}
proc chan_update_tx_power*(ctxt: pointer) {.exportc, cdecl.}
proc vif_mgmt_send_postponed_frame*(vifEntry: pointer) {.exportc, cdecl.}
proc rxl_timer_int_handler*() {.exportc, cdecl.}
proc rxl_cntrl_evt*() {.exportc, cdecl.}
proc scanu_scan_next*() {.exportc, cdecl.}
proc chan_tbtt_schedule*(tbttEntry: pointer) {.exportc, cdecl.}
proc chan_send_scanning_stop*(chanEnvPtr: pointer) {.exportc, cdecl.}
proc chan_upd_ctxt_status*(chanCtxtPtr: pointer, newStatus: uint8) {.exportc, cdecl.}
proc scan_send_cancel_cfm*(status: uint8) {.exportc, cdecl, noinline.}
proc chan_goto_idle_cb*() {.exportc, cdecl.}
proc chan_sta_tx_cfm*(param: pointer) {.exportc, cdecl.}
proc chan_ap_tx_cfm*(param: pointer) {.exportc, cdecl.}
proc chan_switch_start*(chanCtxt: pointer) {.exportc, cdecl.}
proc chan_get_next_chan*(): pointer {.exportc, cdecl.}
proc chan_conn_less_delay_prog*() {.exportc, cdecl.}
proc mm_force_idle_req*() {.exportc, cdecl.}
proc mm_back_to_host_idle*() {.exportc, cdecl.}
when defined(bl808WifiUseBl808Rf):
  proc phy_mdm_isr*() {.exportc, cdecl.}
  proc phy_rc_isr*() {.exportc, cdecl.}
elif defined(bl808WifiAllowLegacyBl606pRfFallback):
  proc phy_mdm_isr*() {.importc, cdecl.}
  proc phy_rc_isr*() {.importc, cdecl.}
proc intc_spurious*() {.exportc, cdecl.}

# Forward declarations for security/station management helpers called before definition
proc mm_sec_machwkey_del*(keyIdx: uint8) {.exportc, cdecl.}
proc mm_sec_machwaddr_del*(idx: uint8) {.exportc, cdecl.}
proc apm_tx_int_ps_clear*(vifEntry: pointer, staIdx: uint8) {.exportc, cdecl.}
proc vif_mgmt_del_key*(vifEntry: pointer, keySlot: uint8) {.exportc, cdecl, noinline.}
proc sta_mgmt_del_key*(staIdx: uint8, keyIdx: uint8) {.exportc, cdecl.}
proc apm_send_mlme*(vifEntry: pointer, frameType: uint16, destAddr: pointer, callback: pointer, callbackArg: pointer, extraParam: pointer) {.exportc, cdecl.}
proc apm_sta_add*(param: pointer): uint8 {.exportc, cdecl.}
proc apm_sta_fw_delete*(staIdx: uint8, vifIdx: uint8, reason: uint16) {.exportc, cdecl.}
proc bl_wifi_set_sta_key_internal*(vifIdx: uint8, staIdx: uint8, alg: uint32,
    keyIdx: int32, setTx: int32, seqData: pointer, seqLen: csize_t,
    keyData: pointer, keyLen: csize_t, pairwise: bool): cint {.exportc, cdecl.}
# Forward declarations for station/beacon management helpers
proc sta_mgmt_entry_init*(staEntry: pointer) {.exportc, cdecl.}
proc sta_mgmt_postponed_desc_release*(staEntry: pointer, flag: uint32): uint32 {.exportc, cdecl.}
proc sta_mgmt_aging_postponed_desc*(staEntry: pointer, maxCount: uint32): uint32 {.exportc, cdecl.}
proc sta_mgmt_send_postponed_frame*(vifEntry: pointer, staEntry: pointer, maxCount: uint32): uint32 {.exportc, cdecl.}
proc vif_mgmt_bcn_recv*(vifEntry: pointer) {.exportc, cdecl.}
proc ps_check_beacon*(rxHdr: pointer, unused: uint32, vifEntry: pointer) {.exportc, cdecl.}
proc mm_bcn_transmitted*(vifEntry: pointer) {.exportc, cdecl.}
proc mm_active*() {.exportc, cdecl.}
proc td_start*(vifIdx: uint8) {.exportc, cdecl.}
proc mm_bcn_init_vif*(vifEntry: pointer) {.exportc, cdecl.}
proc mm_hw_ap_info_set*(vifIdx: uint8) {.exportc, cdecl.}
proc mm_hw_info_set*(macAddr: pointer) {.exportc, cdecl.}
proc txl_cntrl_halt_ac*(ac: uint8) {.exportc, cdecl.}
proc txl_cntrl_flush_ac*(ac: uint8) {.exportc, cdecl.}
proc txl_cntrl_tx_check*(vifEntry: pointer): bool {.exportc, cdecl.}
proc rxl_reset*() {.exportc, cdecl.}
proc txl_reset*() {.exportc, cdecl.}
proc chan_tbtt_switch_update*(vifEntry: pointer, tbttTime: uint32) {.exportc, cdecl.}
proc chan_is_on_channel*(vifEntry: pointer): bool {.exportc, cdecl, noinline.}
proc chan_get_dominant_chan*(): pointer {.exportc, cdecl, noinline.}
proc chan_pre_switch_channel*(ctxt: pointer) {.exportc, cdecl.}
proc ps_check_tbtt*(vifEntry: pointer) {.exportc, cdecl.}
proc mm_bcn_transmit*(vifIdx: uint8) {.exportc, cdecl.}
proc chan_is_on_operational_channel*(vifEntry: pointer): bool {.exportc, cdecl, noinline.}
when defined(bl808WifiUseBl808Rf):
  proc phy_get_channel_raw*(info: pointer, index: uint8)
      {.exportc: "phy_get_channel", cdecl.}
elif defined(bl808WifiAllowLegacyBl606pRfFallback):
  proc phy_get_channel_raw*(info: pointer, index: uint8)
      {.importc: "phy_get_channel", cdecl.}
proc mm_rx_filter_set*() {.exportc, cdecl.}
proc apm_tx_int_ps_check*(txDesc: pointer): bool {.exportc, cdecl.}
proc apm_tx_int_ps_get_postpone*(vifEntry: pointer, staEntry: pointer, postponeFlag: ptr uint32): pointer {.exportc, cdecl.}
proc txl_frame_send_null_frame*(staIdx: uint8, cfmCallback: pointer, cfmArg: uint32): uint8 {.exportc, cdecl, discardable.}
proc txl_frame_send_qosnull_frame*(staIdx: uint8, qosCtrl: uint16,
  cfmCallback: pointer, cfmArg: uint32): uint8 {.exportc, cdecl, discardable.}
proc txl_frame_release*(param: pointer) {.exportc, cdecl.}
proc txl_int_fake_transfer*(txDesc: pointer, queueIdx: uint32) {.exportc, cdecl.}
proc txl_payload_handle_backup*(param: pointer) {.exportc, cdecl.}
proc txl_machdr_format*(param: pointer) {.exportc, cdecl.}
proc txu_cntrl_tkip_mic_append*(txdesc: pointer) {.exportc, cdecl.}
proc txl_frame_init_desc*(desc: pointer, linkDesc: pointer, hwDesc: pointer, payloadDesc: pointer) {.exportc, cdecl.}
proc txl_frame_cfm*(param: pointer) {.exportc, cdecl.}
proc txl_frame_evt*() {.exportc, cdecl.}
proc ps_check_tx_frame*(vifIdx: uint8, staIdx: uint8): bool {.exportc, cdecl.}

# Forward declarations for init sub-functions called from mm_init and others
proc ke_task_init*() {.exportc, cdecl.}
proc mm_env_init*() {.exportc, cdecl.}
proc mm_env_max_ampdu_duration_set*(duration: uint32) {.exportc, cdecl.}
proc vif_mgmt_init*() {.exportc, cdecl.}
proc td_init*() {.exportc, cdecl.}
proc ps_init*() {.exportc, cdecl.}
proc chan_init*() {.exportc, cdecl.}
proc scan_init*() {.exportc, cdecl.}
proc sta_mgmt_init*() {.exportc, cdecl.}
proc mm_bcn_init*() {.exportc, cdecl.}
proc mm_timer_init*() {.exportc, cdecl.}
proc mm_timer_set*(timer: pointer, targetTime: uint32) {.exportc, cdecl.}
proc mm_timer_clear*(timer: pointer) {.exportc, cdecl.}
proc mm_timer_schedule*() {.exportc, cdecl.}
proc txl_frame_init*() {.exportc, cdecl.}
proc txu_cntrl_cfm*(param: pointer) {.exportc, cdecl.}
proc ipc_emb_txcfm*(desc: pointer) {.exportc, cdecl.}
proc ipc_emb_txcfm_ind*(acBit: uint32 = 0) {.exportc, cdecl, noinline.}
proc txl_cntrl_init*() {.exportc, cdecl.}
proc txl_cntrl_env_dump*() {.exportc, cdecl, noinline.}
proc txl_frame_dump*() {.exportc, cdecl, noinline.}
proc rxl_hwdesc_dump*() {.exportc, cdecl, noinline.}
proc txl_cfm_dump*() {.exportc, cdecl, noinline.}
proc rxl_cntrl_dump*() {.exportc, cdecl, noinline.}
proc ipc_emb_dump*() {.exportc, cdecl, noinline.}
proc coex_dump_wifi*() {.exportc, cdecl.}
proc coex_dump_pta*() {.exportc, cdecl.}
proc bugkiller_fw_task_dump*() {.exportc, cdecl.}
proc puts_space*(buf: pointer, count: cint): pointer {.exportc: "_puts_space", cdecl, discardable.}
proc txl_cfm_init*() {.exportc, cdecl.}
proc txl_buffer_reinit*() {.exportc, cdecl.}
proc txl_hwdesc_reset*() {.exportc, cdecl, noinline.}
proc txl_buffer_init*() {.exportc, cdecl.}
proc txl_hwdesc_init*() {.exportc, cdecl, noinline.}
proc rxl_init*() {.exportc, cdecl.}
proc rxu_cntrl_init*() {.exportc, cdecl.}
proc hal_machw_init*() {.exportc, cdecl.}
proc hal_machw_reset*() {.exportc, cdecl.}
proc td_reset*(vifIdx: uint8) {.exportc, cdecl.}
# CRC utility functions (external, used by mm_check_beacon for beacon change detection)
proc utils_crc32_stream_init*(state: pointer) {.importc, cdecl.}
proc utils_crc32_stream_feed_block*(state: pointer, data: pointer, len: uint32) {.importc, cdecl.}
proc utils_crc32_stream_results*(state: pointer): uint32 {.importc, cdecl.}
# External host message handler (called by ke_msg_send for API tasks)
proc bl_rx_e2a_handler*(msgPtr: pointer) {.importc, cdecl.}
# Platform PM functions (external, called by bl_sleep_schedule)
proc wifi_hosal_pm_state_run*(): uint32 {.importc, cdecl.}
proc arch_delay_us*(us: uint32) {.importc, cdecl.}
proc nim_wifi_rf_latch_service_enable*(enable: uint32) {.importc, cdecl.}
proc wifi_hosal_pm_post_event*(typ: uint32, sev: uint32, resultPtr: pointer) {.importc, cdecl.}
proc utils_list_pop_front*(list: ptr CoList): ptr CoListHdr {.importc, cdecl.}
  ## External list pop (host-provided), used by ipc_emb_tx_evt instead of co_list_pop_front.
proc utils_list_push_back*(list: ptr CoList, elem: ptr CoListHdr) {.importc, cdecl.}
  ## External list push (host-provided), used by ipc_emb_txcfm instead of co_list_push_back.
# External IPC host function (called by bl_irq_handler to disable E2A IRQs)
proc ipc_host_disable_irq_e2a*() {.importc, cdecl.}
# External TRPC power control functions (called by bl_tpc_* wrappers)
when defined(bl808WifiUseBl808Rf):
  proc trpc_power_get*(powerTable: pointer) {.exportc, cdecl.}
  proc trpc_update_power*(powerTable: pointer) {.exportc, cdecl.}
  proc trpc_update_power_11b*(powerTable: pointer) {.exportc, cdecl.}
  proc trpc_update_power_11g*(powerTable: pointer) {.exportc, cdecl.}
  proc trpc_update_power_11n*(powerTable: pointer) {.exportc, cdecl.}
elif defined(bl808WifiAllowLegacyBl606pRfFallback):
  proc trpc_power_get*(powerTable: pointer) {.importc, cdecl.}
  proc trpc_update_power*(powerTable: pointer) {.importc, cdecl.}
  proc trpc_update_power_11b*(powerTable: pointer) {.importc, cdecl.}
  proc trpc_update_power_11g*(powerTable: pointer) {.importc, cdecl.}
  proc trpc_update_power_11n*(powerTable: pointer) {.importc, cdecl.}
when defined(bl808WifiUseBl808Rf):
  proc phy_get_ntx*(): uint8 {.exportc, cdecl.}
  proc phy_get_nss*(): uint8 {.exportc, cdecl.}
  proc phy_ldpc_tx_supported*(): bool {.exportc, cdecl.}
  proc phy_get_rf_gain_idx*(txPowerElem: pointer, rateParam: pointer)
      {.exportc, cdecl.}
  proc rf_pri_input_xtalfreq(xtalfreqHz: uint32) {.exportc, cdecl.}
  proc rf_pri_get_xtalfreq(): uint32 {.exportc, cdecl.}
  proc rf_pri_xtalfreq() {.exportc, cdecl.}
  proc rf_pri_init_calib_mem() {.exportc, cdecl.}
  proc rf_pri_init(coldInit, mode: uint32) {.exportc, cdecl.}
  proc rf_pri_config_mode(mode: uint32) {.exportc, cdecl.}
  proc rf_pri_cfg_init() {.exportc, cdecl.}
  proc rf_pri_input_device_info(deviceInfo: uint32) {.exportc, cdecl.}
  proc rf_pri_input_chip_ver(chipVersion: uint32) {.exportc, cdecl.}
  proc rf_pri_get_wl_cfg(): uint32 {.exportc, cdecl.}
  proc rf_pri_get_txgain_max(): int32 {.exportc, cdecl.}
  proc rf_pri_get_txgain_min(): int32 {.exportc, cdecl.}
  proc rf_pri_roscal() {.exportc, cdecl.}
  proc rf_pri_rccal() {.exportc, cdecl.}
  proc rf_pri_manual_incremental_cal_start() {.exportc, cdecl.}
  proc rf_pri_manual_incremental_cal_stop() {.exportc, cdecl.}
  proc rf_pri_set_rcal_code(code0, code1: uint32) {.exportc, cdecl.}
  proc rf_pri_save_state_before_cal() {.exportc, cdecl.}
  proc rf_pri_restore_state_after_cal() {.exportc, cdecl.}
  proc rf_pri_cw_start(targetPowerDbm: int32; channelMhz: uint32)
      {.exportc, cdecl.}
  proc rf_pri_cw_stop() {.exportc, cdecl.}
  proc rf_pri_lo_fcal() {.exportc, cdecl.}
  proc rf_pri_lo_acal() {.exportc, cdecl.}
  proc rf_pri_txcal() {.exportc, cdecl.}
  proc rf_pri_bz_txcal() {.exportc, cdecl.}
  proc rf_pri_rxcal() {.exportc, cdecl.}
  proc rf_pri_full_cal() {.exportc, cdecl.}
  proc rf_pri_restore_cal_reg() {.exportc, cdecl.}
  proc rf_pri_update_param(channelMhz: uint32) {.exportc, cdecl.}
  proc rf_pri_read(reg: ptr uint32): uint32 {.exportc, cdecl.}
  proc rf_pri_optimize(channelMhz: uint32) {.exportc, cdecl.}
  proc rf_pri_bz_optimize(channelMhz: uint32) {.exportc, cdecl.}
  proc rf_pri_bz_optimize_restore() {.exportc, cdecl.}
  proc rf_pri_input_channel_pwr_comp(comp: pointer) {.exportc, cdecl.}
  proc rf_pri_input_channel_lp_pwr_comp(comp: pointer) {.exportc, cdecl.}
  proc rf_pri_set_channel_lp_pwr_comp(channelIndex: uint32) {.exportc, cdecl.}
  proc rf_pri_input_temp_comp_param(channels: pointer; highOffsets: pointer;
                                    lowOffsets: pointer; roomOffset: int16;
                                    enable: uint8) {.exportc, cdecl.}
  proc rf_pri_set_temp_comp(sensorTemperatureC: int32) {.exportc, cdecl.}
  proc rf_pri_input_bz_channel_pwr_comp(comp: pointer) {.exportc, cdecl.}
  proc rf_pri_set_bz_channel_pwr_comp() {.exportc, cdecl.}
  proc rf_pri_set_bz_temp_comp(sensorTemperatureC: int32) {.exportc, cdecl.}
  proc rf_pri_get_bz_temp_mp_comp() {.exportc, cdecl.}
  proc rf_pri_input_bz_target_power(targetPowerDbm: int32) {.exportc, cdecl.}
  proc rf_pri_set_channel_pwr_comp(channelIndex: uint32) {.exportc, cdecl.}
  proc rf_pri_set_bandwidth(bandwidthMhz: uint32) {.exportc, cdecl.}
  proc rf_pri_get_vco_freq_cw(channelMhz: uint32): uint32 {.exportc, cdecl.}
  proc rf_pri_get_vco_idac_cw(channelMhz: uint32): uint32 {.exportc, cdecl.}
  proc rfc_config_bandwidth*(bandwidth: uint32) {.exportc, cdecl.}
  proc rfc_config_channel*(channelMhz: uint32) {.exportc, cdecl.}
  proc rfc_get_power_level*(rateClass: uint32; requestedPowerTenths: int32): uint32
      {.exportc, cdecl.}
  proc rfc_power_meas*(clockSelect: uint32; offsetHz: int32;
                       sampleCount: uint32; measureFlags: uint32;
                       iOut, qOut: ptr int32) {.exportc, cdecl.}
  proc rfc_sg_start*(frequencyHz: int32; amplitude: uint32;
                     signedQuadraturePath: uint32) {.exportc, cdecl.}
  proc rfc_sg_stop*() {.exportc, cdecl.}
  proc rfc_rf_fsm_force*(mode: uint32) {.exportc, cdecl.}
  proc rfc_rc_fsm_force*(mode: uint32) {.exportc, cdecl.}
proc td_timer_evt*(env: pointer) {.exportc, cdecl.}
proc ps_uapsd_timer_handle*() {.exportc, cdecl.}
proc ps_tx_null_timer_handle*() {.exportc, cdecl.}
proc mm_ps_change_ind*(staIdx: uint8, psState: uint8) {.exportc, cdecl.}
proc ps_disable_cfm*(vifEntry: pointer, statusFlags: uint32) {.exportc, cdecl.}
  ## PS disable confirmation (sends MM_SET_PS_MODE_CFM).
  ## Forward declaration - implementation at PS section.
proc ps_enable_cfm*(vifEntry: pointer, status: uint32) {.exportc, cdecl.}
  ## PS enable confirmation. Forward declaration — impl at PS section.
proc ps_enable_cfm_handle*(vifEntry: pointer) {.exportc, cdecl, noinline.}
proc ps_disable_cfm_handle*(vifEntry: pointer): uint32 {.exportc, cdecl.}
proc sta_mgmt_add_key*(param: pointer, hwKeyIdx: uint8) {.exportc, cdecl.}
proc vif_mgmt_add_key*(param: pointer, hwKeyIdx: uint8) {.exportc, cdecl.}
proc replay_counter_validate*(param: pointer): bool {.exportc, cdecl.}
proc mm_tim_update_proceed*(param: pointer) {.exportc, cdecl, noinline.}
proc sm_disconnect*(param: pointer) {.exportc, cdecl.}
proc sm_issue_sa_query_request*() {.exportc, cdecl.}
proc coex_pta_force_autocontrol_set*(mode: uint32) {.exportc, cdecl.}
proc sm_delete_resources*(param: pointer = nil) {.exportc, cdecl.}
proc sm_auth_assoc_send_according_chan*(nextState: uint16 = 0, param1: uint16 = 0, param2: uint32 = 0) {.exportc, cdecl.}
proc apm_sta_delete*(param: pointer) {.exportc, cdecl.}
proc apm_tx_cfm_handler*(param: pointer) {.exportc, cdecl.}
proc cfm_raw_send*(param: pointer) {.exportc, cdecl.}
proc sm_supplicant_deauth_cfm*(param: pointer) {.exportc, cdecl.}
proc ps_check_frame*(rxHdr: pointer, frameFlags: uint32, vifEntry: pointer) {.exportc, cdecl.}
proc ps_send_pspoll*(vifEntry: pointer): uint8 {.exportc, cdecl, noinline.}
when defined(bl808WifiUseBl808Rf):
  proc phy_set_channel*(channel: ptr ChanCtxtDefView, force: uint32)
      {.exportc, cdecl.}
    ## BL808 RF blob ABI: a0 points at the packed channel descriptor and a1 must
    ## be zero to apply it. Non-zero a1 returns without changing the PHY channel.
elif defined(bl808WifiAllowLegacyBl606pRfFallback):
  proc phy_set_channel_scalar*(band, chanType, primFreq, centerFreq1: uint32)
      {.importc: "phy_set_channel", cdecl.}
    ## BL606P PHY/RF archive ABI: channel fields are passed as scalar register
    ## arguments instead of a pointer to the packed descriptor overlay.

proc phySetChannel*(channel: ptr ChanCtxtDefView) {.inline.} =
  when defined(bl808WifiUseBl808Rf):
    phy_set_channel(channel, 0'u32)
  elif defined(bl808WifiAllowLegacyBl606pRfFallback):
    phy_set_channel_scalar(
      channel.band.uint32,
      channel.chanType.uint32,
      channel.primFreq.uint32,
      channel.centerFreq1.uint32)

proc phySetChannel*(band: uint8, chanType: uint8, primFreq: uint16,
                    centerFreq1: uint16, centerFreq2: uint16,
                    txPower: uint8) {.inline.} =
  var channel = ChanCtxtDefView(
    band: band,
    chanType: chanType,
    primFreq: primFreq,
    centerFreq1: centerFreq1,
    centerFreq2: centerFreq2,
    txPower: txPower,
    reserved: 0'u8)
  phySetChannel(addr channel)

proc packChannelMeta(channel: ptr ChanCtxtDefView): uint32 {.inline.} =
  channel.band.uint32 or
    (channel.chanType.uint32 shl 8) or
    (channel.txPower.uint8.uint32 shl 16)

proc packChannelFreq(channel: ptr ChanCtxtDefView): uint32 {.inline.} =
  channel.primFreq.uint32 or (channel.centerFreq1.uint32 shl 16)

proc snapshotPhyChannel(dst: var array[4, uint32]) {.inline.} =
  phy_get_channel_raw(cast[pointer](addr dst[0]), 0)
# External RF/PHY functions called from wifi_main (platform-provided)
when defined(bl808WifiUseBl808Rf):
  proc phy_init*(cfg: pointer) {.exportc, cdecl.}
  proc phy_get_version*(versionOut: pointer, buf: pointer) {.exportc, cdecl.}
elif defined(bl808WifiAllowLegacyBl606pRfFallback):
  proc phy_init*(cfg: pointer) {.importc, cdecl.}
  ## External PHY version query (host-provided): writes 4-byte version string
  ## at versionOut, reads scratch buf. Called by mm_version_req_handler.
  proc phy_get_version*(versionOut: pointer, buf: pointer) {.importc, cdecl.}
proc wifi_hosal_rf_turn_on*() {.importc, cdecl.}
when defined(bl808WifiUseBl808Rf):
  type
    RfRegBlock {.packed.} = object
      baseCtrl0: uint32
      baseCtrl1: uint32
      reserved008: array[3, uint32]
      calMode14: uint32
      reserved018: uint32
      calCtrl1c: uint32
      capability20: uint32
      reserved024: array[2, uint32]
      synthCtrl2c: uint32
      priModeCtrl30: uint32
      scanSynthLatch34: uint32
      reserved038: array[2, uint32]
      scanSynthLatch40: uint32
      reserved044: uint32
      rccalTone48: uint32
      scanRxLatch4c: uint32
      reserved050: array[2, uint32]
      txcalBias58: uint32
      xtalCapTrim5c: uint32
      rxcalPrep60: uint32
      txcalGain64: uint32
      txcalGain68: uint32
      txcalDc6c: uint32
      txcalParam70: uint32
      txcalParam74: uint32
      rxModeCalibrationGate78: uint32
      roscalCtrl7c: uint32
      rbbRccalCtrl80: uint32
      rccalReplay84: uint32
      txcalDfe88: uint32
      calPathConfig8c: uint32
      calPathCtrl90: uint32
      bandwidthCtrl94: uint32
      reserved098: array[2, uint32]
      fcalCtrlA0: uint32
      acalCtrlA4: uint32
      calResultA8: uint32
      fcalAc: uint32
      channelCalStrobeB0: uint32
      channelCalStatusB4: uint32
      txcalCtrlB8: uint32
      channelFcalConfigBc: uint32
      sdmCtrlC0: uint32
      sdmDivC4: uint32
      sdmFractionalHighC8: uint32
      rfPriBiasTrimCc: uint32
      optimizeCtrlD0: uint32
      rfBiasTrimD4: uint32
      reserved0d8: array[6, uint32]
      calMixerStateF0: uint32
      reserved0f4: array[6, uint32]
      rfCodeConfig110c: uint32
      reserved110: array[6, uint32]
      txcalDefaultProfile128: uint32
      txcalDefaultProfile12c: uint32
      txcalDefaultProfile130: uint32
      reserved134: uint32
      calModeDefault138: uint32
      vcoPairTable13c: array[10, uint32]
      vcoPair2484Mhz164: uint32
      roscalCal0: uint32
      roscalCal1: uint32
      rxcalReplay: array[4, uint32]
      reserved180: array[16, uint32]
      xtalControlCode1c0: uint32
      xtalDividerConfig1c4: uint32
      xtalCountWindowMin1c8: uint32
      xtalCountWindowMax1cc: uint32
      reserved1d0: array[15, uint32]
      calSingenCtrl20c: uint32
      reserved210: uint32
      calSingenAmpLo214: uint32
      calSingenAmpHi218: uint32
      calSingenMeasurePrep21c: uint32
      rxMode220: uint32
      rxModeDumpReadback224: uint32
      channelTuneGate228: uint32
      reserved22c: array[4, uint32]
      calDfeGate23c: uint32
      calDfeState240: uint32
      calDfeState244: uint32
      reserved248: array[6, uint32]
      channelSequencer260: uint32
      channelFreqMhz264: uint32
      channelTuneStrobe268: uint32
      channelTuneCtrl26c: uint32
      reserved270: array[21, uint32]
      channelSequencer2c4: uint32
      reserved2c8: array[78, uint32]
      rfcSequencerBias400: uint32
      reserved404: array[64, uint32]
      modemPathEnable504: uint32
      reserved508: uint32
      pdCompLatchCtrl50c: uint32
      reserved510: uint32
      modemPathEnable514: uint32
      reserved518: array[58, uint32]
      txcalTosdac600: uint32
      reserved604: uint32
      scanSynthControl608: uint32
      calMeasurePrep60c: uint32
      reserved610: uint32
      rxcalSearch614: uint32
      measureCtrl618: uint32
      measureMode61c: uint32
      measureI620: uint32
      measureQ624: uint32
      reserved628: uint32
      scanTxMeasureControl62c: uint32
      reserved630: array[3, uint32]
      synthDfePathControl63c: uint32
      reserved640: array[16, uint32]
      notchCtrl680: uint32
      reserved684: array[32, uint32]
      txPowerComp704: uint32
      reserved708: array[21, uint32]
      rfGainTable75c: uint32
      rfGainTable760: uint32
      rfGainTable764: uint32
      reserved768: uint32
      rfGainTable76c: uint32
      reserved770: uint32
      rfGainTable774: uint32
      reserved778: uint32
      rfGainTable77c: uint32
      bzChannelPowerComp780: uint32
      rfGainOrBzTempComp784: uint32
      reserved788: uint32
      rfGainTable78c: uint32
      reserved790: uint32
      rfGainTable794: uint32
      reserved798: uint32
      rfGainTable79c: uint32
      reserved7a0: array[3, uint32]
      txPowerComp7ac: uint32
      reserved7b0: uint32
      bzChannelPowerComp7b4: uint32
      bzTemperatureComp7b8: uint32
      txPowerCompTail7bc: uint32
      txPowerCompTail7c0: uint32
      txPowerCompTail7c4: uint32
      txPowerCompTail7c8: uint32
      txPowerCompTail7cc: uint32
      txPowerCompTail7d0: uint32
      txPowerCompTail7d4: uint32
      txPowerCompTail7d8: uint32

    WifiModemBlock {.packed.} = object
      versionWord: uint32
      reserved004: array[6, uint32]
      versionDfeCaps1c: uint32
      reserved020: uint32
      versionDfeCaps24: uint32
      versionDfeCaps28: uint32
      reserved02c: array[4, uint32]
      versionScratch3c: uint32
      reserved040: array[185, uint32]
      preAgcCtrl324: uint32
      reserved328: array[37, uint32]
      basebandDfeTimeout3bc: uint32
      reserved3c0: array[21, uint32]
      basebandDfeEnable414: uint32
      reserved418: array[250, uint32]
      versionFeatureCtrl800: uint32
      reserved804: array[4, uint32]
      bandwidth20MGuard814: uint32
      reserved818: array[2, uint32]
      bandwidth20MProfile820: uint32
      channelTypeCtrl824: uint32
      reserved828: array[2, uint32]
      bandwidth20MProfile830: uint32
      bandwidth20MEnable834: uint32
      reserved838: uint32
      bandwidth20MSignal83c: uint32
      bandwidth20MSignal840: uint32
      preAgcSignal844: uint32
      preAgcSignal848: uint32
      channelCenterRatio84c: uint32
      reserved850: array[4, uint32]
      bandwidth20MFilter860: uint32
      reserved864: array[4, uint32]
      bandwidth20MGate874: uint32
      reserved878: array[4, uint32]
      phyChannelPulse888: uint32
      reserved88c: array[2, uint32]
      preAgcDetect894: uint32
      reserved898: array[4, uint32]
      groupMembership0: uint32
      groupMembership1: uint32
      userPosition: array[4, uint32]
      aid: uint32
      aidMaskLo: uint32
      aidMaskHi: uint32
      reserved8cc: array[2, uint32]
      preAgcTiming8d4: uint32
      preAgcTiming8d8: uint32
      reserved8dc: uint32
      preAgcTiming8e0: uint32
      preAgcTiming8e4: uint32
      reserved8e8: array[18, uint32]
      channelModeCtrl930: uint32
      reserved934: array[195, uint32]
      basebandRxPathCtrlC40: uint32
      basebandRxPathCtrlC44: uint32
      reservedC48: array[10741, uint32]
      intStatusB41c: uint32
      intAckB420: uint32
      reservedB424: array[765, uint32]
      rxGainTailCtrlC018: uint32
      reservedC01c: array[9, uint32]
      rxGainInitC040: uint32
      rxGainTimingC044: uint32
      reservedC048: array[14, uint32]
      rxGainTable0C080: uint32
      rxGainTable1C084: uint32
      rxGainTable2C088: uint32
      reservedC08c: array[482, uint32]
      lowPowerRxPathCtrlC814: uint32

    PhyAgcBlock {.packed.} = object
      reserved000: array[34, uint32]
      sharedCopyWindow88: uint32
      sharedCopyWindow8c: uint32
      reserved090: array[6, uint32]
      rfcSettlingTimerA8: uint32

    RfAuxCtrlBlock {.packed.} = object
      reserved000: array[16, uint32]
      rfcAuxPathSelect540: uint32
      rfcAuxPathGate544: uint32

    MacPhyCtrlBlock {.packed.} = object
      reserved000: array[196, uint32]
      channelBandwidthCtrl310: uint32

    CrmPhyClockBlock {.packed.} = object
      reserved000: array[2, uint32]
      phyClockSelect8: uint32
      reserved00c: uint32
      rfClockMux10: uint32
      reserved014: uint32
      modemReset18: uint32

    RfPllBlock {.packed.} = object
      reserved000: array[4, uint32]
      pllReset10: uint32
      refdivCtrl14: uint32
      loopFilter18: uint32
      fractionalCtrl1c: uint32
      reserved020: array[2, uint32]
      fractionalWord28: uint32
      modeCtrl2c: uint32
      enableCtrl30: uint32
      reserved034: array[20, uint32]
      pllFixedDefault84: uint32

    RfDfeInitBlock {.packed.} = object
      reserved000: array[12, uint32]
      hbnCtrl30: uint32
      reserved034: array[504, uint32]
      dfeRfFixedCtrl814: uint32
      reserved818: array[2, uint32]
      dfeStaticCtrl820: uint32
      dfeTrim824: uint32
      reserved828: array[23, uint32]
      dfeRfFixedDefault884: uint32

    BbaAgcBlock {.packed.} = object
      reserved000: uint32
      agcCoreEnable004: uint32
      reserved008: array[62, uint32]
      agcCoreCtrl100: uint32
      reserved104: array[128, uint32]
      agcCoreLowPowerThreshold304: uint32
      reserved308: array[14, uint32]
      macActiveB340: uint32
      macActiveB344: uint32
      reserved348: array[7, uint32]
      agcCoreProfile364: uint32
      macActiveB368: uint32
      pdComp36c: uint32
      agcCoreProfile370: uint32
      reserved374: array[3, uint32]
      agcCoreStage0B380: uint32
      macActiveB384: uint32
      agcCoreStage2B388: uint32
      macActiveB38c: uint32
      pdGain390: uint32
      agcCoreDetect394: uint32
      agcCoreDetect398: uint32
      reserved39c: uint32
      macActiveB3a0: uint32
      agcCoreWindow3a4: uint32
      reserved3a8: uint32
      pdTiming3ac: uint32
      reserved3b0: array[3, uint32]
      macActiveB3bc: uint32
      pdSlope3c0: uint32
      macActiveB3c4: uint32
      reserved3c8: array[19, uint32]
      agcCoreTimeout414: uint32
      reserved418: array[769, uint32]
      macActiveC01c: uint32
      macActiveC020: uint32
      reservedC024: array[2, uint32]
      macActiveC02c: uint32
      reservedC030: array[5, uint32]
      lowPowerPdThresholdC044: uint32
      reservedC048: array[497, uint32]
      agcCoreTableC80c: uint32
      reservedC810: array[8, uint32]
      pdCompC830: uint32
      lowPowerPdCompC834: uint32
      pdCompRampC838: uint32
      pdCompRampC83c: uint32
      pdCompRampC840: uint32
      reservedC844: array[8, uint32]
      lowPowerPdCompC864: uint32

    BbaRuntimeState {.packed.} = object
      ceLoopScratch0: uint32
      ceLoopScratch4: uint32
      pdRssiState: uint8
      pdGainCode: uint8
      pdCompCurrent: uint8
      pdCompLatch: uint8
      pdLoopReserved12: uint8
      pdLoopReserved13: uint8
      cePpmAccumulator: uint16
      ceUpdateInterval: uint8
      ceUpdateCount: uint8
      ceCapcodeHoldoff: uint8
      ceLoopReserved19: uint8

    BbaRxVectorView {.packed.} = object
      rxFormatWord0: uint32
      rxFormatWord1Rate: uint8
      rssiDbm: uint8
      rxFormatWord1Mcs: uint8
      rxFormatWord1Flags: uint8
      reserved008: array[14, uint8]
      carrierFreqOffset: uint16

    RfTxPowerCompTableBlock {.packed.} = object
      reserved000: array[0x700 div 4, uint32]
      txPowerCompWords700: array[43, uint32]

    RfcXtalConfig = object
      xtalHz: uint32
      xtalCountWindowMin: uint32
      xtalCountWindowMax: uint32
      xtalDividerConfig: uint32
      xtalControlCode: uint32

    RfcLpXtalConfig {.packed.} = object
      xtalCountWindowMin: uint32
      xtalCountWindowMax: uint32
      xtalDividerConfig: uint32
      xtalControlCode: uint32

    RfPriTxPowerTableRow = array[9, int16]

    WlRfConfig {.packed.} = object
      status: uint32
      apiMode: uint8
      enableParamLoadCallback: uint8
      requestFullCalibration: uint8
      enableCapcodeSetCallback: uint8
      xtalfreqHz: uint32
      xtalCapCodes: uint16
      xtalCapPadding: array[2, uint8]
      channelFreqSeedPair0: uint32
      channelFreqSeedPair1: uint32
      channelFreqSeedPair2: uint32
      channelFreqSeedPadding: array[5, uint32]
      ratePowerTablePreamble: uint16
      ratePowerTable: array[106, uint8]
      ratePowerLimitDbm: uint8
      ratePowerTablePostamble: array[4, uint8]
      channelPowerComp: array[14, uint8]
      channelLowPowerComp: array[14, uint8]
      temperaturePowerComp: uint8
      temperaturePowerCompPadding: uint16
      efuseTrimControl: uint32
      efuseTxGainComp: uint8
      efuseXtalCapCode0: uint8
      efuseXtalCapCode1: uint8
      efuseDfeTrim: uint8
      paramLoadCallback: pointer
      capcodeSetCallback: pointer
      capcodeGetCallback: pointer

    WlRfMemoryOverlay {.packed.} = object
      config: WlRfConfig
      calib: array[320, uint8]
      env: array[12, uint8]

    WlLowPowerStatusEnv {.packed.} = object
      lastStatusCode: int8
      reserved1: uint8
      inactiveUpdateCount: uint16
      lastUpdateContext: uint32
      lowPowerActiveLatch: uint8
      statusValid: uint8
      reserved10: array[2, uint8]

    PhyEnvView {.packed.} = object
      initCfgWords: array[9, uint32]
      channelBandType: uint16
      primaryFreq: uint16
      centerFreq1: uint16
      centerFreq2OrTxPower: uint16
      txPowerAndReserved: uint16
      reserved046: array[2, uint8]

    WifiAgcMemoryRam {.packed.} = object
      words: array[512, uint32]

  static:
    doAssert sizeof(RfRegBlock) >= 0x84
    doAssert offsetof(RfRegBlock, baseCtrl1) == 0x04
    doAssert offsetof(RfRegBlock, calMode14) == 0x14
    doAssert offsetof(RfRegBlock, calCtrl1c) == 0x1C
    doAssert offsetof(RfRegBlock, capability20) == 0x20
    doAssert offsetof(RfRegBlock, synthCtrl2c) == 0x2C
    doAssert offsetof(RfRegBlock, priModeCtrl30) == 0x30
    doAssert offsetof(RfRegBlock, scanSynthLatch34) == 0x34
    doAssert offsetof(RfRegBlock, scanSynthLatch40) == 0x40
    doAssert offsetof(RfRegBlock, rccalTone48) == 0x48
    doAssert offsetof(RfRegBlock, scanRxLatch4c) == 0x4C
    doAssert offsetof(RfRegBlock, txcalBias58) == 0x58
    doAssert offsetof(RfRegBlock, xtalCapTrim5c) == 0x5C
    doAssert offsetof(RfRegBlock, rxcalPrep60) == 0x60
    doAssert offsetof(RfRegBlock, txcalGain64) == 0x64
    doAssert offsetof(RfRegBlock, txcalGain68) == 0x68
    doAssert offsetof(RfRegBlock, txcalDc6c) == 0x6C
    doAssert offsetof(RfRegBlock, txcalParam70) == 0x70
    doAssert offsetof(RfRegBlock, txcalParam74) == 0x74
    doAssert offsetof(RfRegBlock, rxModeCalibrationGate78) == 0x78
    doAssert offsetof(RfRegBlock, roscalCtrl7c) == 0x7C
    doAssert offsetof(RfRegBlock, rbbRccalCtrl80) == 0x80
    doAssert offsetof(RfRegBlock, rccalReplay84) == 0x84
    doAssert offsetof(RfRegBlock, txcalDfe88) == 0x88
    doAssert offsetof(RfRegBlock, calPathConfig8c) == 0x8C
    doAssert offsetof(RfRegBlock, calPathCtrl90) == 0x90
    doAssert offsetof(RfRegBlock, bandwidthCtrl94) == 0x94
    doAssert offsetof(RfRegBlock, fcalCtrlA0) == 0xA0
    doAssert offsetof(RfRegBlock, acalCtrlA4) == 0xA4
    doAssert offsetof(RfRegBlock, calResultA8) == 0xA8
    doAssert offsetof(RfRegBlock, fcalAc) == 0xAC
    doAssert offsetof(RfRegBlock, channelCalStrobeB0) == 0xB0
    doAssert offsetof(RfRegBlock, channelCalStatusB4) == 0xB4
    doAssert offsetof(RfRegBlock, txcalCtrlB8) == 0xB8
    doAssert offsetof(RfRegBlock, channelFcalConfigBc) == 0xBC
    doAssert offsetof(RfRegBlock, sdmCtrlC0) == 0xC0
    doAssert offsetof(RfRegBlock, sdmDivC4) == 0xC4
    doAssert offsetof(RfRegBlock, sdmFractionalHighC8) == 0xC8
    doAssert offsetof(RfRegBlock, rfPriBiasTrimCc) == 0xCC
    doAssert offsetof(RfRegBlock, optimizeCtrlD0) == 0xD0
    doAssert offsetof(RfRegBlock, rfBiasTrimD4) == 0xD4
    doAssert offsetof(RfRegBlock, calMixerStateF0) == 0xF0
    doAssert offsetof(RfRegBlock, rfCodeConfig110c) == 0x10C
    doAssert offsetof(RfRegBlock, txcalDefaultProfile128) == 0x128
    doAssert offsetof(RfRegBlock, txcalDefaultProfile12c) == 0x12C
    doAssert offsetof(RfRegBlock, txcalDefaultProfile130) == 0x130
    doAssert offsetof(RfRegBlock, calModeDefault138) == 0x138
    doAssert offsetof(RfRegBlock, vcoPairTable13c) == 0x13C
    doAssert offsetof(RfRegBlock, vcoPair2484Mhz164) == 0x164
    doAssert offsetof(RfRegBlock, roscalCal0) == 0x168
    doAssert offsetof(RfRegBlock, roscalCal1) == 0x16C
    doAssert offsetof(RfRegBlock, rxcalReplay) == 0x170
    doAssert offsetof(RfRegBlock, channelTuneGate228) == 0x228
    doAssert offsetof(RfRegBlock, channelFreqMhz264) == 0x264
    doAssert offsetof(RfRegBlock, channelTuneStrobe268) == 0x268
    doAssert offsetof(RfRegBlock, channelTuneCtrl26c) == 0x26C
    doAssert offsetof(RfRegBlock, xtalControlCode1c0) == 0x1C0
    doAssert offsetof(RfRegBlock, xtalDividerConfig1c4) == 0x1C4
    doAssert offsetof(RfRegBlock, xtalCountWindowMin1c8) == 0x1C8
    doAssert offsetof(RfRegBlock, xtalCountWindowMax1cc) == 0x1CC
    doAssert offsetof(RfRegBlock, calSingenCtrl20c) == 0x20C
    doAssert offsetof(RfRegBlock, calSingenAmpLo214) == 0x214
    doAssert offsetof(RfRegBlock, calSingenAmpHi218) == 0x218
    doAssert offsetof(RfRegBlock, calSingenMeasurePrep21c) == 0x21C
    doAssert offsetof(RfRegBlock, rxMode220) == 0x220
    doAssert offsetof(RfRegBlock, rxModeDumpReadback224) == 0x224
    doAssert offsetof(RfRegBlock, modemPathEnable504) == 0x504
    doAssert offsetof(RfRegBlock, calDfeGate23c) == 0x23C
    doAssert offsetof(RfRegBlock, calDfeState240) == 0x240
    doAssert offsetof(RfRegBlock, calDfeState244) == 0x244
    doAssert offsetof(RfRegBlock, channelSequencer260) == 0x260
    doAssert offsetof(RfRegBlock, pdCompLatchCtrl50c) == 0x50C
    doAssert offsetof(RfRegBlock, channelSequencer2c4) == 0x2C4
    doAssert offsetof(RfRegBlock, rfcSequencerBias400) == 0x400
    doAssert offsetof(RfRegBlock, modemPathEnable514) == 0x514
    doAssert offsetof(RfRegBlock, txcalTosdac600) == 0x600
    doAssert offsetof(RfRegBlock, scanSynthControl608) == 0x608
    doAssert offsetof(RfRegBlock, calMeasurePrep60c) == 0x60C
    doAssert offsetof(RfRegBlock, rxcalSearch614) == 0x614
    doAssert offsetof(RfRegBlock, measureCtrl618) == 0x618
    doAssert offsetof(RfRegBlock, measureMode61c) == 0x61C
    doAssert offsetof(RfRegBlock, measureI620) == 0x620
    doAssert offsetof(RfRegBlock, measureQ624) == 0x624
    doAssert offsetof(RfRegBlock, scanTxMeasureControl62c) == 0x62C
    doAssert offsetof(RfRegBlock, synthDfePathControl63c) == 0x63C
    doAssert offsetof(RfRegBlock, notchCtrl680) == 0x680
    doAssert offsetof(RfRegBlock, txPowerComp704) == 0x704
    doAssert offsetof(RfRegBlock, rfGainTable75c) == 0x75C
    doAssert offsetof(RfRegBlock, rfGainTable760) == 0x760
    doAssert offsetof(RfRegBlock, rfGainTable764) == 0x764
    doAssert offsetof(RfRegBlock, rfGainTable76c) == 0x76C
    doAssert offsetof(RfRegBlock, rfGainTable774) == 0x774
    doAssert offsetof(RfRegBlock, rfGainTable77c) == 0x77C
    doAssert offsetof(RfRegBlock, bzChannelPowerComp780) == 0x780
    doAssert offsetof(RfRegBlock, rfGainOrBzTempComp784) == 0x784
    doAssert offsetof(RfRegBlock, rfGainTable78c) == 0x78C
    doAssert offsetof(RfRegBlock, rfGainTable794) == 0x794
    doAssert offsetof(RfRegBlock, rfGainTable79c) == 0x79C
    doAssert offsetof(RfRegBlock, txPowerComp7ac) == 0x7AC
    doAssert offsetof(RfRegBlock, bzChannelPowerComp7b4) == 0x7B4
    doAssert offsetof(RfRegBlock, bzTemperatureComp7b8) == 0x7B8
    doAssert offsetof(RfRegBlock, txPowerCompTail7bc) == 0x7BC
    doAssert offsetof(RfRegBlock, txPowerCompTail7c0) == 0x7C0
    doAssert offsetof(RfRegBlock, txPowerCompTail7c4) == 0x7C4
    doAssert offsetof(RfRegBlock, txPowerCompTail7c8) == 0x7C8
    doAssert offsetof(RfRegBlock, txPowerCompTail7cc) == 0x7CC
    doAssert offsetof(RfRegBlock, txPowerCompTail7d0) == 0x7D0
    doAssert offsetof(RfRegBlock, txPowerCompTail7d4) == 0x7D4
    doAssert offsetof(RfRegBlock, txPowerCompTail7d8) == 0x7D8
    doAssert offsetof(WifiModemBlock, versionWord) == 0x0
    doAssert offsetof(WifiModemBlock, versionDfeCaps1c) == 0x1C
    doAssert offsetof(WifiModemBlock, versionDfeCaps24) == 0x24
    doAssert offsetof(WifiModemBlock, versionDfeCaps28) == 0x28
    doAssert offsetof(WifiModemBlock, versionScratch3c) == 0x3C
    doAssert offsetof(WifiModemBlock, preAgcCtrl324) == 0x324
    doAssert offsetof(WifiModemBlock, basebandDfeTimeout3bc) == 0x3BC
    doAssert offsetof(WifiModemBlock, basebandDfeEnable414) == 0x414
    doAssert offsetof(WifiModemBlock, versionFeatureCtrl800) == 0x800
    doAssert offsetof(WifiModemBlock, bandwidth20MGuard814) == 0x814
    doAssert offsetof(WifiModemBlock, bandwidth20MProfile820) == 0x820
    doAssert offsetof(WifiModemBlock, channelTypeCtrl824) == 0x824
    doAssert offsetof(WifiModemBlock, bandwidth20MProfile830) == 0x830
    doAssert offsetof(WifiModemBlock, bandwidth20MEnable834) == 0x834
    doAssert offsetof(WifiModemBlock, bandwidth20MSignal83c) == 0x83C
    doAssert offsetof(WifiModemBlock, bandwidth20MSignal840) == 0x840
    doAssert offsetof(WifiModemBlock, preAgcSignal844) == 0x844
    doAssert offsetof(WifiModemBlock, preAgcSignal848) == 0x848
    doAssert offsetof(WifiModemBlock, channelCenterRatio84c) == 0x84C
    doAssert offsetof(WifiModemBlock, bandwidth20MFilter860) == 0x860
    doAssert offsetof(WifiModemBlock, bandwidth20MGate874) == 0x874
    doAssert offsetof(WifiModemBlock, phyChannelPulse888) == 0x888
    doAssert offsetof(WifiModemBlock, preAgcDetect894) == 0x894
    doAssert offsetof(WifiModemBlock, groupMembership0) == 0x8A8
    doAssert offsetof(WifiModemBlock, groupMembership1) == 0x8AC
    doAssert offsetof(WifiModemBlock, userPosition) == 0x8B0
    doAssert offsetof(WifiModemBlock, aid) == 0x8C0
    doAssert offsetof(WifiModemBlock, aidMaskLo) == 0x8C4
    doAssert offsetof(WifiModemBlock, aidMaskHi) == 0x8C8
    doAssert offsetof(WifiModemBlock, preAgcTiming8d4) == 0x8D4
    doAssert offsetof(WifiModemBlock, preAgcTiming8d8) == 0x8D8
    doAssert offsetof(WifiModemBlock, preAgcTiming8e0) == 0x8E0
    doAssert offsetof(WifiModemBlock, preAgcTiming8e4) == 0x8E4
    doAssert offsetof(WifiModemBlock, channelModeCtrl930) == 0x930
    doAssert offsetof(WifiModemBlock, basebandRxPathCtrlC40) == 0xC40
    doAssert offsetof(WifiModemBlock, basebandRxPathCtrlC44) == 0xC44
    doAssert offsetof(WifiModemBlock, intStatusB41c) == 0xB41C
    doAssert offsetof(WifiModemBlock, intAckB420) == 0xB420
    doAssert offsetof(WifiModemBlock, rxGainTailCtrlC018) == 0xC018
    doAssert offsetof(WifiModemBlock, rxGainInitC040) == 0xC040
    doAssert offsetof(WifiModemBlock, rxGainTimingC044) == 0xC044
    doAssert offsetof(WifiModemBlock, rxGainTable0C080) == 0xC080
    doAssert offsetof(WifiModemBlock, rxGainTable1C084) == 0xC084
    doAssert offsetof(WifiModemBlock, rxGainTable2C088) == 0xC088
    doAssert offsetof(WifiModemBlock, lowPowerRxPathCtrlC814) == 0xC814
    doAssert offsetof(PhyAgcBlock, sharedCopyWindow88) == 0x88
    doAssert offsetof(PhyAgcBlock, sharedCopyWindow8c) == 0x8C
    doAssert offsetof(PhyAgcBlock, rfcSettlingTimerA8) == 0xA8
    doAssert offsetof(RfAuxCtrlBlock, rfcAuxPathSelect540) == 0x40
    doAssert offsetof(RfAuxCtrlBlock, rfcAuxPathGate544) == 0x44
    doAssert offsetof(MacPhyCtrlBlock, channelBandwidthCtrl310) == 0x310
    doAssert offsetof(CrmPhyClockBlock, phyClockSelect8) == 0x08
    doAssert offsetof(CrmPhyClockBlock, rfClockMux10) == 0x10
    doAssert offsetof(CrmPhyClockBlock, modemReset18) == 0x18
    doAssert offsetof(RfPllBlock, pllReset10) == 0x10
    doAssert offsetof(RfPllBlock, refdivCtrl14) == 0x14
    doAssert offsetof(RfPllBlock, loopFilter18) == 0x18
    doAssert offsetof(RfPllBlock, fractionalCtrl1c) == 0x1C
    doAssert offsetof(RfPllBlock, fractionalWord28) == 0x28
    doAssert offsetof(RfPllBlock, modeCtrl2c) == 0x2C
    doAssert offsetof(RfPllBlock, enableCtrl30) == 0x30
    doAssert offsetof(RfPllBlock, pllFixedDefault84) == 0x84
    doAssert offsetof(RfDfeInitBlock, hbnCtrl30) == 0x30
    doAssert offsetof(RfDfeInitBlock, dfeRfFixedCtrl814) == 0x814
    doAssert offsetof(RfDfeInitBlock, dfeStaticCtrl820) == 0x820
    doAssert offsetof(RfDfeInitBlock, dfeTrim824) == 0x824
    doAssert offsetof(RfDfeInitBlock, dfeRfFixedDefault884) == 0x884
    doAssert offsetof(BbaAgcBlock, agcCoreEnable004) == 0x004
    doAssert offsetof(BbaAgcBlock, agcCoreCtrl100) == 0x100
    doAssert offsetof(BbaAgcBlock, agcCoreLowPowerThreshold304) == 0x304
    doAssert offsetof(BbaAgcBlock, macActiveB340) == 0x340
    doAssert offsetof(BbaAgcBlock, macActiveB344) == 0x344
    doAssert offsetof(BbaAgcBlock, agcCoreProfile364) == 0x364
    doAssert offsetof(BbaAgcBlock, macActiveB368) == 0x368
    doAssert offsetof(BbaAgcBlock, pdComp36c) == 0x36C
    doAssert offsetof(BbaAgcBlock, agcCoreProfile370) == 0x370
    doAssert offsetof(BbaAgcBlock, agcCoreStage0B380) == 0x380
    doAssert offsetof(BbaAgcBlock, macActiveB384) == 0x384
    doAssert offsetof(BbaAgcBlock, agcCoreStage2B388) == 0x388
    doAssert offsetof(BbaAgcBlock, macActiveB38c) == 0x38C
    doAssert offsetof(BbaAgcBlock, pdGain390) == 0x390
    doAssert offsetof(BbaAgcBlock, agcCoreDetect394) == 0x394
    doAssert offsetof(BbaAgcBlock, agcCoreDetect398) == 0x398
    doAssert offsetof(BbaAgcBlock, macActiveB3a0) == 0x3A0
    doAssert offsetof(BbaAgcBlock, agcCoreWindow3a4) == 0x3A4
    doAssert offsetof(BbaAgcBlock, pdTiming3ac) == 0x3AC
    doAssert offsetof(BbaAgcBlock, macActiveB3bc) == 0x3BC
    doAssert offsetof(BbaAgcBlock, pdSlope3c0) == 0x3C0
    doAssert offsetof(BbaAgcBlock, macActiveB3c4) == 0x3C4
    doAssert offsetof(BbaAgcBlock, agcCoreTimeout414) == 0x414
    doAssert offsetof(BbaAgcBlock, macActiveC01c) == 0x101C
    doAssert offsetof(BbaAgcBlock, macActiveC020) == 0x1020
    doAssert offsetof(BbaAgcBlock, macActiveC02c) == 0x102C
    doAssert offsetof(BbaAgcBlock, lowPowerPdThresholdC044) == 0x1044
    doAssert offsetof(BbaAgcBlock, agcCoreTableC80c) == 0x180C
    doAssert offsetof(BbaAgcBlock, pdCompC830) == 0x1830
    doAssert offsetof(BbaAgcBlock, lowPowerPdCompC834) == 0x1834
    doAssert offsetof(BbaAgcBlock, pdCompRampC838) == 0x1838
    doAssert offsetof(BbaAgcBlock, pdCompRampC83c) == 0x183C
    doAssert offsetof(BbaAgcBlock, pdCompRampC840) == 0x1840
    doAssert offsetof(BbaAgcBlock, lowPowerPdCompC864) == 0x1864
    doAssert offsetof(RfTxPowerCompTableBlock, txPowerCompWords700) == 0x700
    doAssert sizeof(BbaRuntimeState) == 20
    doAssert offsetof(BbaRuntimeState, pdRssiState) == 8
    doAssert offsetof(BbaRuntimeState, pdGainCode) == 9
    doAssert offsetof(BbaRuntimeState, pdCompCurrent) == 10
    doAssert offsetof(BbaRuntimeState, pdCompLatch) == 11
    doAssert offsetof(BbaRuntimeState, cePpmAccumulator) == 14
    doAssert offsetof(BbaRuntimeState, ceUpdateInterval) == 16
    doAssert offsetof(BbaRuntimeState, ceUpdateCount) == 17
    doAssert offsetof(BbaRuntimeState, ceCapcodeHoldoff) == 18
    doAssert sizeof(BbaRxVectorView) == 24
    doAssert offsetof(BbaRxVectorView, rxFormatWord0) == 0
    doAssert offsetof(BbaRxVectorView, rxFormatWord1Rate) == 4
    doAssert offsetof(BbaRxVectorView, rssiDbm) == 5
    doAssert offsetof(BbaRxVectorView, carrierFreqOffset) == 0x16
    doAssert sizeof(WlRfConfig) == 212
    doAssert offsetof(WlRfConfig, apiMode) == 4
    doAssert offsetof(WlRfConfig, xtalfreqHz) == 8
    doAssert offsetof(WlRfConfig, xtalCapCodes) == 12
    doAssert offsetof(WlRfConfig, channelFreqSeedPair0) == 16
    doAssert offsetof(WlRfConfig, ratePowerTable) == 50
    doAssert offsetof(WlRfConfig, ratePowerLimitDbm) == 156
    doAssert offsetof(WlRfConfig, channelPowerComp) == 161
    doAssert offsetof(WlRfConfig, channelLowPowerComp) == 175
    doAssert offsetof(WlRfConfig, temperaturePowerComp) == 189
    doAssert offsetof(WlRfConfig, temperaturePowerCompPadding) == 190
    doAssert offsetof(WlRfConfig, efuseTrimControl) == 192
    doAssert offsetof(WlRfConfig, efuseTxGainComp) == 196
    doAssert offsetof(WlRfConfig, efuseXtalCapCode0) == 197
    doAssert offsetof(WlRfConfig, efuseXtalCapCode1) == 198
    doAssert offsetof(WlRfConfig, efuseDfeTrim) == 199
    doAssert offsetof(WlRfConfig, paramLoadCallback) == 200
    doAssert offsetof(WlRfConfig, capcodeSetCallback) == 204
    doAssert offsetof(WlRfConfig, capcodeGetCallback) == 208
    doAssert sizeof(WlRfMemoryOverlay) == 544
    doAssert offsetof(WlRfMemoryOverlay, config) == 0
    doAssert offsetof(WlRfMemoryOverlay, calib) == 212
    doAssert offsetof(WlRfMemoryOverlay, env) == 532
    doAssert sizeof(WlLowPowerStatusEnv) == 12
    doAssert offsetof(WlLowPowerStatusEnv, lastStatusCode) == 0
    doAssert offsetof(WlLowPowerStatusEnv, inactiveUpdateCount) == 2
    doAssert offsetof(WlLowPowerStatusEnv, lastUpdateContext) == 4
    doAssert offsetof(WlLowPowerStatusEnv, lowPowerActiveLatch) == 8
    doAssert offsetof(WlLowPowerStatusEnv, statusValid) == 9
    doAssert sizeof(PhyEnvView) == 48
    doAssert offsetof(PhyEnvView, initCfgWords) == 0
    doAssert offsetof(PhyEnvView, channelBandType) == 36
    doAssert offsetof(PhyEnvView, primaryFreq) == 38
    doAssert offsetof(PhyEnvView, centerFreq1) == 40
    doAssert offsetof(PhyEnvView, centerFreq2OrTxPower) == 42
    doAssert offsetof(PhyEnvView, txPowerAndReserved) == 44
    doAssert sizeof(WifiAgcMemoryRam) == 2048
    doAssert offsetof(WifiAgcMemoryRam, words) == 0
    doAssert sizeof(RfcXtalConfig) == 20
    doAssert sizeof(RfcLpXtalConfig) == 16
    doAssert offsetof(RfcLpXtalConfig, xtalCountWindowMin) == 0
    doAssert offsetof(RfcLpXtalConfig, xtalCountWindowMax) == 4
    doAssert offsetof(RfcLpXtalConfig, xtalDividerConfig) == 8
    doAssert offsetof(RfcLpXtalConfig, xtalControlCode) == 12

  const
    WlRfConfigMagic = 0x0000ACDE'u32
    WlRfCfgRxcalA8Offset = 0xA8
    WlRfCfgRxcalAcOffset = 0xAC
    WlRfCfgWb03RxcalA8Default = 0x00001825'u32
    WlRfCfgWb03RxcalAcDefault = 0x000003F7'u32
    WlRfCfgPower11bOffset = 0x32
    WlRfCfgPower11gOffset = 0x36
    WlRfCfgPower11n20Offset = 0x3E
    WlRfCfgPower11nAltOffset = 0x46
    WlRfCfgPower11ac20Offset = 0x6C
    WlRfCfgPower11acAltOffset = 0x78
    WlRfCfgDefaultRatePower = 0x1C'u8
    RfPriWb03Rf70ColdSeed = 0x25181222'u32
    RfPriWb03Rf70ScanSeed = 0x24181222'u32
    RfPriWb03MacActiveRf70Seed = 0x23171222'u32
    RfPriTxcalRf70InitialSearchSeedNibble = 0xB'u32
    RfPriRf70ReplayNotApplicable = 0xFFFF_FFFF'u32
    RfPriRf70ReplayFieldsSeededAtReplay = 0x00000001'u32
    RfPriRf70ReplayFieldsUnexpected = 0x00000002'u32
    RfPriRf70ReplayFieldsPopulatedByTxcal = 0x00000003'u32
    RfPriRf70ReplayFieldsMeasuredByTxcal = 0x00000004'u32
    RfPriRf70ReplayFieldsMeasuredFallback = 0x00000005'u32
    RfPriTxPowerReplayBaseOnly = 0x00000000'u32
    RfPriTxPowerReplayCalRecords = 0x00000001'u32
    RfPriTxPowerReplayWb03RestoreBaseline = 0x00000002'u32
    RfPriTxPowerReplayWb03CompleteRecords = 0x00000003'u32
    RfPriTxPowerSkipNone = 0x00000000'u32
    RfPriTxPowerSkipNoCalData = 0x00000001'u32
    RfPriTxPowerSkipWb03TxcalIncomplete = 0x00000002'u32
    RfPriTxPowerSkipWb03BzTxcalIncomplete = 0x00000003'u32
    RfPriTxPowerSkipWb03OptInDisabled = 0x00000004'u32
    RfPriWb03MacActiveRf7cSeed = 0x24222422'u32
    RfPriWb03RccalRf80Seed = 0x1B1B1B1B'u32
    RfPriWb03RccalRf84Seed = 0x02324020'u32
    RfPriWb03ScanRf88Seed = 0x00011005'u32
    RfPriWb03ScanRf8cSeed = 0x12202112'u32
    RfPriWb03ScanRfb4Seed = 0x0002A222'u32
    RfPriWb03RfcEntryRfb4Seed = 0x0102A222'u32
    RfPriWb03ScanRfbcSeed = 0x10911100'u32
    RfPriWb03ScanRf80ListenSeed = 0x1C1C1C1C'u32
    RfPriWb03ScanRf80ActiveSeed = 0x1B1B1B1B'u32
    RfPriWb03MacActiveRf80Seed = 0x1A1A1A1A'u32
    RfPriWb03ScanRf40Seed = 0x01F00B00'u32
    RfPriWb03ScanRf4cSeed = 0x00763237'u32
    RfPriWb03RfcEntryRfa0Seed = 0x0D0CA296'u32
    RfPriWb03MacActiveRfa0Seed = 0x0C0C9F96'u32
    RfPriWb03ScanRf1600Seed = 0x00BF27F7'u32
    RfPriWb03ScanRf1600ListenSeed = 0x00BF37F6'u32
    RfPriWb03ScanRf1600ActiveSeed = 0x00BEC7F6'u32
    RfPriWb03ScanRf1600BaselineSeed = 0x00BE87F4'u32
    RfPriWb03RfcEntryRf1600Seed = 0x00BEF7F7'u32
    RfPriWb03MacActiveRf1600Seed = 0x00BF27F3'u32
    RfPriWb03ScanRf1608Seed = 0x10000000'u32
    RfPriWb03ScanRf1618Seed = 0x80000000'u32
    RfPriWb03ScanRf162cSeed = 0x000F0002'u32
    WifiAgcMemoryBase = 0x24C0A000'u
    WifiAgcMemoryWords = 512
    Bl808RfDeviceInfoBl616 = 0'u32
    Bl808RfDeviceInfoWb03 = 1'u32
    Bl808RfDeviceInfoBl618m = 2'u32
    Bl808WifiRfDeviceInfo {.intdefine.}: int = 1
    ## WB03/40M needs the scan/MAC-active RF latch replay before auth/assoc TX.
    ## Hardware evidence: without this pulse, m0_wifi_nimfw_hal_test times out
    ## at connect with RF88 falling back to 0x00010005; with it, connect passes.
    bl808WifiRfWb03ForceAuthTxLatches* {.booldefine.}: bool = true
    bl808WifiRfWb03AuthTxSettleUs* {.intdefine.}: int = 0
    bl808WifiRfWb03AuthTxPulseLatch* {.booldefine.}: bool = true
    ## Keep the recovered RF70 strongest-candidate search as diagnostics by
    ## default. A 2026-06-06 hardware run showed measured replay windows
    ## w0=A,w1=E,w2=9 regressed auth/connect, so applying them remains opt-in
    ## until the full vendor TXCAL measurement setup is recovered.
    bl808WifiRfWb03ApplyMeasuredRf70Replay* {.booldefine.}: bool = false
    ## Keep WB03/40M TX power table replay on the hardware-validated restore
    ## baseline unless a run explicitly opts into complete calibration records.
    bl808WifiRfWb03ReplayCompleteTxPowerCal* {.booldefine.}: bool = false
    WlXtal24M = 24_000_000'u32
    WlXtal26M = 26_000_000'u32
    WlXtal32M = 32_000_000'u32
    WlXtal38P4M = 38_400_000'u32
    WlXtal40M = 40_000_000'u32
    WlXtal52M = 52_000_000'u32
    RfBase = 0x20001000'u
    RfPllBase = 0x20000800'u
    RfAuxCtrlBase = 0x20000500'u
    PhyBase = 0x20002800'u
    AgcBase = 0x20002C00'u
    WifiModemBase = 0x24C00000'u
    MacPhyCtrlBase = 0x24B00000'u
    CrmPhyClockBase = 0x24940000'u
    RfDfeInitBase = 0x2000F000'u
    BbaAgcBase = 0x24C0B000'u
    RfOptimizeMidBandMask = 0x00000001'u32
    RfOptimizeMidBandFirstMhz = 2452'u32
    RfOptimizeMidBandLastMhz = 2472'u32
    RfOptimizeTxcalFirstMhz = 2462'u32
    RfOptimizeTxcalLastMhz = 2484'u32
    RfOptimizeWb03PllEdge0Mhz = 2452'u32
    RfOptimizeWb03PllEdge1Mhz = 2472'u32
    RfCtrlTuneEnableMask = 0x00000002'u32
    RfMeasureTriggerClearMask = 0x20100000'u32
    RfMeasureModeKeepMask = 0x0000FFFF'u32
    RfMeasureRoscalMode = 0x04000000'u32
    RfMeasureFrequencyShift = 9
    RfMeasureStartMask = 0x20000000'u32
    RfMeasureReadyMask = 0x10000000'u32
    RfMeasureRccalTriggerMask = 0x20100000'u32
    RfFcalStartMask = 0x00000010'u32
    RfFcalReadyMask = 0x00100000'u32
    RfFcalCodeMask = 0x000000FF'u32
    RfAcalCodeMask = 0x003F0000'u32
    RfAcalComparatorMask = 0x00001000'u32
    RfRoscalCapabilityMask = 0x00000100'u32
    RfRoscalModeMask = 0x0000C000'u32
    RfRoscalStartMode = 0x00004000'u32
    RfRoscalDoneMode = 0x0000C000'u32
    RfRoscalCodeMask = 0x0000003F'u32
    RfRoscalIRegMask = 0x00003F00'u32
    RfRoscalQRegMask = 0x0000003F'u32
    RfRoscalRegisterKeepMask = 0xC0C0C0C0'u32
    RfRccalCapabilityMask = 0x00000400'u32
    RfRccalModeMask = 0x000C0000'u32
    RfRccalStartMode = 0x00040000'u32
    RfRccalDoneMode = 0x000C0000'u32
    RfRccalFailMode = 0x00080000'u32
    RfRccalCodeMask = 0x0000003F'u32
    RfRccalRegisterKeepMask = 0xC0C0C0C0'u32
    RfRccalBaselineCode = 0x20'u32
    RfRccalTargetNumerator = 81'u64
    RfRccalTargetDenominator = 100'u64
    RfRccalFallbackTargetNumerator = 5'u64
    RfRccalFallbackTargetDenominator = 3'u64
    RfRccalMinReferencePower = 64'u32
    RfRccalReferenceMeasureCtrl = 0x00001000'u32
    RfRccalToneMeasureCtrl = 0x0002D400'u32
    RfTxcalModeMask = 0x00F00000'u32
    RfTxcalStartMode = 0x00500000'u32
    RfTxcalDoneMode = 0x00F00000'u32
    RfRxcalModeMask = 0x03000000'u32
    RfRxcalStartMode = 0x01000000'u32
    RfRxcalDoneMode = 0x03000000'u32
    RfRxcalSearchLowMask = 0x000003FF'u32
    RfRxcalSearchHighMask = 0x007FF000'u32
    RfRxcalSearchHighEnable = 0x00800000'u32
    RfRxcalMeasureClearMask = 0x20100000'u32
    RfRxcalMeasureSetupMask = 0x000F0000'u32
    RfTxcalParam0Mask = 0x3F000000'u32
    RfTxcalParam1Mask = 0x003F0000'u32
    RfTxcalParam2Mask = 0x007FF000'u32
    RfTxcalParam2EnableBit = 0x00800000'u32
    RfTxcalParam3Mask = 0x000003FF'u32
    RfTxcalParam3SignBit = 0x00000400'u32
    RfPriWb03RxcalTosdacReplayMask =
      RfTxcalParam2Mask or RfTxcalParam2EnableBit or
      RfTxcalParam3Mask or RfTxcalParam3SignBit
    RfPriWb03RxcalTosdacSeed = 0x00BEC7F7'u32
    RfTxcalSingenAmplitudeMask = 0x000007FF'u32
    RfTxcalMixerCsMask = 0x00000007'u32
    RfTxcalAverageMeasureMode = 0x04000000'u32
    RfTxcalInitialAmp = 128'u32
    RfTxcalInitialAdcMax = 128'i32
    RfTxcalInitialAdcMin = 96'i32
    RfTxcalGainAmp = 192'u32
    RfTxcalGainAdcMax = 256'i32
    RfTxcalGainAdcMin = 128'i32
    RfTxcalSearchFreqIq = 0x3D'u32
    RfTxcalSearchFreqOsdac = 0x7A'u32
    RfBzTxcalSearchFreqIq = 0x49'u32
    RfBzTxcalSearchFreqOsdac = 0x92'u32
    RfTxcalMixerCsCount = 8
    RfTxcalSampleTraceEntries = 48
    RfLoChannelCount = 21
    RfFcalWaitLimit = 5000
    RfRoscalWaitLimit = 10000
    RfRccalWaitLimit = 10000
    RfTxcalWaitLimit = 10000
    RfRxcalWaitLimit = 10000
    RfConfigChannelWaitLimit = 5000
    RfLoFcalLowCount = 0xA6A0'u16
    RfLoFcalHighCount = 0xA6E0'u16
    RfLoFcalStopCount = 0xACE0'u16
    RfLoFcalDiv = 0x0855'u16
    RfCalibRccalReplayWordIndex = 2
    RfCalibRf70ReplayLowBandWordIndex = 3
    RfCalibRf70ReplayHighBandWordIndex = 4
    RfCalibLoVcoHalfwordBase = 14
    RfCalibTxcalRecordBaseWord = 26
    RfCalibBzTxcalRecordBaseByte = 0xF8
    RfCalibBzTxcalRecordStrideBytes = 8

    RfPriDefaultVcoCal40M: array[21, uint16] = [
      ## Fallback for zeroed wl_cal VCO halfwords, recovered from passing
      ## BL808 40 MHz RF logs (`lo_vco_freq_cw`, `vco_idac_cw`). Vendor
      ## full-cal data overwrites this range when available.
      0xA20D'u16, 0xA10D'u16, 0x9F0C'u16, 0x9E0C'u16, 0x9D0C'u16,
      0x9B0C'u16, 0x9A0C'u16, 0x990C'u16, 0x970C'u16, 0x960C'u16,
      0x950C'u16, 0x930C'u16, 0x920C'u16, 0x910C'u16, 0x8F0B'u16,
      0x8E0B'u16, 0x8D0B'u16, 0x8C0C'u16, 0x8A0C'u16, 0x890C'u16,
      0x880C'u16
    ]
    RfPriTxcalSearchRecords = 18
    RfPriBzTxcalSearchRecords = 9
    RfPriTxcalReplayRecordIds: array[13, int] = [
      ## librf_bl808.a:rf_pri.c.o .data.tx_pwr_table_idx:
      ## 0000 0100 0200 0300 0400 0500 0600 0900 0a00 0b00 0c00 0d00 0e00.
      0, 1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14
    ]

    RfChannelDivTable40M: array[RfLoChannelCount, uint32] = [
      0x14088889'u32, 0x14111111'u32, 0x1419999A'u32, 0x14222222'u32,
      0x142AAAAB'u32, 0x14333333'u32, 0x143BBBBC'u32, 0x14444444'u32,
      0x144CCCCD'u32, 0x14555555'u32, 0x145DDDDE'u32, 0x14666666'u32,
      0x146EEEEF'u32, 0x14777777'u32, 0x14800000'u32, 0x14888889'u32,
      0x14911111'u32, 0x1499999A'u32, 0x14A22222'u32, 0x14AAAAAB'u32,
      0x14B33333'u32
    ]

    RfChannelCntTable40M: array[RfLoChannelCount, uint16] = [
      0xA6EB'u16, 0xA732'u16, 0xA779'u16, 0xA7C0'u16, 0xA808'u16,
      0xA84F'u16, 0xA896'u16, 0xA8DD'u16, 0xA924'u16, 0xA96B'u16,
      0xA9B2'u16, 0xA9F9'u16, 0xAA40'u16, 0xAA87'u16, 0xAACF'u16,
      0xAB16'u16, 0xAB5D'u16, 0xABA4'u16, 0xABEB'u16, 0xAC32'u16,
      0xAC79'u16
    ]
    RfPriCwPowerAmplitudeTable: array[31, uint16] = [
      ## librf_bl808.a:rf_pri.c.o .rodata.cw_pwr_table, used by
      ## rf_pri_cw_start for the signal-generator amplitude code.
      0x0020'u16, 0x0024'u16, 0x0028'u16, 0x002D'u16, 0x0033'u16,
      0x0039'u16, 0x0040'u16, 0x0048'u16, 0x0051'u16, 0x005B'u16,
      0x0066'u16, 0x0072'u16, 0x0080'u16, 0x0090'u16, 0x00A1'u16,
      0x00B5'u16, 0x00CC'u16, 0x00E5'u16, 0x0100'u16, 0x0120'u16,
      0x0143'u16, 0x016A'u16, 0x0197'u16, 0x01C8'u16, 0x0200'u16,
      0x023F'u16, 0x0285'u16, 0x02D4'u16, 0x032C'u16, 0x038F'u16,
      0x03FF'u16
    ]
    PhyRxGainTable: array[9, int8] = [
      0x08'i8, 0x0F'i8, 0x16'i8, 0x1D'i8, 0x23'i8,
      0x2A'i8, 0x30'i8, 0x36'i8, 0x3C'i8
    ]

    RfcXtalConfigTable: array[6, RfcXtalConfig] = [
      ## librf_bl808.a:rfc.c.o .rodata.rfc_xtal_cfg, indexed by xtalIndex().
      RfcXtalConfig(xtalHz: WlXtal24M,
                    xtalCountWindowMin: 0x00038E39'u32,
                    xtalCountWindowMax: 0x000471C7'u32,
                    xtalDividerConfig: 0x22000000'u32,
                    xtalControlCode: 0x00000990'u32),
      RfcXtalConfig(xtalHz: WlXtal26M,
                    xtalCountWindowMin: 0x00034835'u32,
                    xtalCountWindowMax: 0x00041A42'u32,
                    xtalDividerConfig: 0x1F627627'u32,
                    xtalControlCode: 0x00000990'u32),
      RfcXtalConfig(xtalHz: WlXtal32M,
                    xtalCountWindowMin: 0x0002AAAB'u32,
                    xtalCountWindowMax: 0x00035555'u32,
                    xtalDividerConfig: 0x19800000'u32,
                    xtalControlCode: 0x00000990'u32),
      RfcXtalConfig(xtalHz: WlXtal38P4M,
                    xtalCountWindowMin: 0x000238E4'u32,
                    xtalCountWindowMax: 0x0002C71C'u32,
                    xtalDividerConfig: 0x15400000'u32,
                    xtalControlCode: 0x00000990'u32),
      RfcXtalConfig(xtalHz: WlXtal40M,
                    xtalCountWindowMin: 0x00022222'u32,
                    xtalCountWindowMax: 0x0002AAAB'u32,
                    xtalDividerConfig: 0x14400000'u32,
                    xtalControlCode: 0x0000097E'u32),
      RfcXtalConfig(xtalHz: WlXtal52M,
                    xtalCountWindowMin: 0x0001A41A'u32,
                    xtalCountWindowMax: 0x00020D21'u32,
                    xtalDividerConfig: 0x0FB13B14'u32,
                    xtalControlCode: 0x00000990'u32)
    ]

  var rfcXtalCfg* {.align: 4, exportc: "rfc_xtal_cfg".}: array[6, RfcLpXtalConfig] = [
    ## Exact data export for librf_bl808.a:lp_phy.c.o .data.rfc_xtal_cfg.
    ## This low-power PHY table omits the xtalHz selector present in the RFC
    ## modem table above; each row is 16 bytes.
    RfcLpXtalConfig(xtalCountWindowMin: 0x00038E39'u32,
                    xtalCountWindowMax: 0x000471C7'u32,
                    xtalDividerConfig: 0x22000000'u32,
                    xtalControlCode: 0x00000990'u32),
    RfcLpXtalConfig(xtalCountWindowMin: 0x00034835'u32,
                    xtalCountWindowMax: 0x00041A42'u32,
                    xtalDividerConfig: 0x1F627627'u32,
                    xtalControlCode: 0x00000990'u32),
    RfcLpXtalConfig(xtalCountWindowMin: 0x0002AAAB'u32,
                    xtalCountWindowMax: 0x00035555'u32,
                    xtalDividerConfig: 0x19800000'u32,
                    xtalControlCode: 0x00000990'u32),
    RfcLpXtalConfig(xtalCountWindowMin: 0x000238E4'u32,
                    xtalCountWindowMax: 0x0002C71C'u32,
                    xtalDividerConfig: 0x15400000'u32,
                    xtalControlCode: 0x00000990'u32),
    RfcLpXtalConfig(xtalCountWindowMin: 0x00022222'u32,
                    xtalCountWindowMax: 0x0002AAAB'u32,
                    xtalDividerConfig: 0x14400000'u32,
                    xtalControlCode: 0x0000097E'u32),
    RfcLpXtalConfig(xtalCountWindowMin: 0x0001A41A'u32,
                    xtalCountWindowMax: 0x00020D21'u32,
                    xtalDividerConfig: 0x0FB13B14'u32,
                    xtalControlCode: 0x00000990'u32)
  ]

  static:
    doAssert sizeof(rfcXtalCfg) == 0x60

  const
    RfPriTxPowerRowTxGainTenthsIndex = 6
    RfPriTxPowerRowPowerThresholdTenthsIndex = 8
    RfPriTxPowerTableDefault: array[18, RfPriTxPowerTableRow] = [
      [3'i16, 1'i16, 7'i16, 23'i16, 0'i16, 7'i16, 0'i16, -1'i16, 240'i16],
      [0'i16, 1'i16, 7'i16, 25'i16, 0'i16, 7'i16, 0'i16, 0'i16, 210'i16],
      [0'i16, 1'i16, 7'i16, 17'i16, 0'i16, 7'i16, 0'i16, 0'i16, 180'i16],
      [0'i16, 1'i16, 7'i16, 12'i16, 0'i16, 7'i16, 0'i16, -1'i16, 150'i16],
      [0'i16, 1'i16, 7'i16, 8'i16, 0'i16, 7'i16, 0'i16, -1'i16, 120'i16],
      [0'i16, 1'i16, 5'i16, 8'i16, 0'i16, 7'i16, 0'i16, -2'i16, 90'i16],
      [0'i16, 1'i16, 4'i16, 6'i16, 0'i16, 7'i16, 0'i16, 0'i16, 60'i16],
      [0'i16, 1'i16, 7'i16, 27'i16, 3'i16, 7'i16, 1'i16, 0'i16, 90'i16],
      [0'i16, 1'i16, 7'i16, 18'i16, 3'i16, 7'i16, 1'i16, 0'i16, 60'i16],
      [0'i16, 1'i16, 7'i16, 12'i16, 3'i16, 7'i16, 1'i16, 1'i16, 30'i16],
      [0'i16, 1'i16, 7'i16, 9'i16, 3'i16, 7'i16, 1'i16, -2'i16, 0'i16],
      [0'i16, 1'i16, 6'i16, 7'i16, 3'i16, 7'i16, 1'i16, -1'i16, -30'i16],
      [0'i16, 1'i16, 4'i16, 7'i16, 3'i16, 7'i16, 1'i16, -1'i16, -60'i16],
      [0'i16, 1'i16, 3'i16, 6'i16, 3'i16, 7'i16, 1'i16, -1'i16, -90'i16],
      [0'i16, 1'i16, 1'i16, 9'i16, 3'i16, 7'i16, 1'i16, -1'i16, -120'i16],
      [0'i16, 1'i16, 1'i16, 7'i16, 3'i16, 7'i16, 1'i16, -3'i16, -150'i16],
      [0'i16, 1'i16, 0'i16, 9'i16, 3'i16, 7'i16, 1'i16, 0'i16, -180'i16],
      [0'i16, 1'i16, 0'i16, 6'i16, 3'i16, 7'i16, 1'i16, 0'i16, -210'i16]
    ]
    RfPriTxPowerTableIndexDefault: array[13, int16] = [
      0'i16, 1'i16, 2'i16, 3'i16, 4'i16, 5'i16, 6'i16,
      9'i16, 10'i16, 11'i16, 12'i16, 13'i16, 14'i16
    ]

    RfPriTxPowerRegisterBase: array[43, uint32] = [
      0x004524D4'u32, 0x0028E3D0'u32, 0x135FC000'u32, 0x00000000'u32,
      0x12DFC000'u32, 0x00000000'u32, 0x123FE000'u32, 0x00000000'u32,
      0x123FC000'u32, 0x00000000'u32, 0x119FF000'u32, 0x00000000'u32,
      0x119FD000'u32, 0x00000000'u32, 0x113FF000'u32, 0x00000000'u32,
      0x10FBD000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32,
      0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x0030F495'u32,
      0x00003189'u32, 0x11FC0000'u32, 0x00000000'u32, 0x115C0000'u32,
      0x00000000'u32, 0x11180000'u32, 0x00000000'u32, 0x109C0000'u32,
      0x00000000'u32, 0x10940000'u32, 0x0014A3D4'u32, 0x1077E000'u32,
      0x00000000'u32, 0x106FF000'u32, 0x00000000'u32, 0x1037D000'u32,
      0x00000000'u32, 0x000420FC'u32, 0x04030201'u32
    ]
    RfPriWb03TxPowerRegisterBaseline: array[43, uint32] = [
      ## Vendor WB03/40M restore output at nimFwScanRxFilterProbe.
      ## librf_bl808.a:rf_pri_restore_cal_reg calls rf_pri_txcal_w2reg and
      ## rf_pri_bz_txcal_w2reg before RXCAL replay; the current pure TXCAL
      ## records are not yet bit-for-bit and were overwriting 0x1700..0x17a8
      ## with low fallback values.
      0x004524D4'u32, 0x1128E3D0'u32, 0x135FC408'u32, 0x00FB206C'u32,
      0x12DFC3F9'u32, 0x00FEDD78'u32, 0x123FE3EC'u32, 0x00FDE360'u32,
      0x123FC3EB'u32, 0x00FD6460'u32, 0x119FF3F8'u32, 0x00FD9E70'u32,
      0x119FD3EE'u32, 0x00FE5E78'u32, 0x113FF3E8'u32, 0x00FE967C'u32,
      0x10FBD3FC'u32, 0x00FC1A80'u32, 0x00000000'u32, 0x00000000'u32,
      0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x0030F495'u32,
      0x00003189'u32, 0x11FC0408'u32, 0x00FB206C'u32, 0x115C03F9'u32,
      0x00FEDD78'u32, 0x111803EC'u32, 0x00FDE360'u32, 0x109C03EB'u32,
      0x00FD6460'u32, 0x109403F8'u32, 0x00FD9E70'u32, 0x1077E3EE'u32,
      0x00FE5E78'u32, 0x106FF3E8'u32, 0x00FE967C'u32, 0x1037D3FC'u32,
      0x00FC1A80'u32, 0x000700D8'u32, 0x04030201'u32
    ]
    RfPriBzTargetPowerDefaultRecords: array[4, int] = [1, 2, 3, 6]
    RfPriBzTargetPowerLowRecords: array[4, int] = [5, 6, 7, 8]
    RfPriBzTargetPowerMidRecords: array[4, int] = [1, 2, 3, 4]
    RfPriBzTargetPowerHighRecords: array[4, int] = [0, 1, 2, 3]
    RfPriBzTxcalTableStarts: array[4, int] = [
      ## librf_bl808.a:rf_pri.c.o .data.bz_tx_pwr_table_idx:
      ## 0100 0200 0300 0600, replayed into RF[0x178c..0x17a8].
      35, 37, 39, 41
    ]

    RfPriBzTxcalParams: array[RfPriBzTxcalSearchRecords, array[7, uint32]] = [
      [2'u32, 4'u32, 7'u32, 3'u32, 0x00010000'u32, 7'u32, 3'u32],
      [2'u32, 4'u32, 7'u32, 3'u32, 0x00015000'u32, 7'u32, 5'u32],
      [2'u32, 4'u32, 7'u32, 3'u32, 0x00019000'u32, 7'u32, 7'u32],
      [0'u32, 4'u32, 7'u32, 3'u32, 0x0001A000'u32, 6'u32, 7'u32],
      [0'u32, 4'u32, 7'u32, 3'u32, 0x00020000'u32, 5'u32, 7'u32],
      [2'u32, 4'u32, 7'u32, 3'u32, 0x00015000'u32, 7'u32, 5'u32],
      [2'u32, 4'u32, 7'u32, 3'u32, 0x00018000'u32, 7'u32, 7'u32],
      [0'u32, 4'u32, 7'u32, 3'u32, 0x0001A000'u32, 6'u32, 7'u32],
      [0'u32, 4'u32, 7'u32, 3'u32, 0x0001B000'u32, 5'u32, 7'u32]
    ]

    RfPriTxcalParams: array[RfPriTxcalSearchRecords, array[7, uint32]] = [
      [2'u32, 4'u32, 7'u32, 3'u32, 0x00010000'u32, 7'u32, 2'u32],
      [2'u32, 4'u32, 7'u32, 3'u32, 0x00010000'u32, 7'u32, 4'u32],
      [2'u32, 4'u32, 7'u32, 3'u32, 0x00010100'u32, 7'u32, 5'u32],
      [2'u32, 4'u32, 7'u32, 3'u32, 0x00017000'u32, 7'u32, 6'u32],
      [2'u32, 4'u32, 7'u32, 3'u32, 0x0001B000'u32, 7'u32, 7'u32],
      [0'u32, 4'u32, 7'u32, 3'u32, 0x00019000'u32, 5'u32, 7'u32],
      [0'u32, 4'u32, 7'u32, 3'u32, 0x00020000'u32, 4'u32, 7'u32],
      [2'u32, 4'u32, 7'u32, 3'u32, 0x00010000'u32, 7'u32, 4'u32],
      [2'u32, 4'u32, 7'u32, 3'u32, 0x00010100'u32, 7'u32, 5'u32],
      [2'u32, 4'u32, 7'u32, 3'u32, 0x00017000'u32, 7'u32, 5'u32],
      [2'u32, 4'u32, 7'u32, 3'u32, 0x00018000'u32, 7'u32, 7'u32],
      [0'u32, 4'u32, 7'u32, 3'u32, 0x00016000'u32, 6'u32, 7'u32],
      [0'u32, 4'u32, 7'u32, 3'u32, 0x0001C000'u32, 4'u32, 7'u32],
      [0'u32, 4'u32, 7'u32, 3'u32, 0x0001D000'u32, 5'u32, 7'u32],
      [0'u32, 4'u32, 7'u32, 3'u32, 0x0001D000'u32, 4'u32, 7'u32],
      [0'u32, 4'u32, 7'u32, 3'u32, 0x0001D000'u32, 5'u32, 7'u32],
      [0'u32, 4'u32, 7'u32, 3'u32, 0x0001D000'u32, 3'u32, 7'u32],
      [0'u32, 4'u32, 7'u32, 3'u32, 0x0001D000'u32, 5'u32, 7'u32]
    ]

    RfPriTxcalPowerSetup: array[RfPriTxcalSearchRecords, array[9, uint16]] = [
      [0x0003'u16, 0x0001'u16, 0x0007'u16, 0x0017'u16, 0x0000'u16, 0x0007'u16, 0x0000'u16, 0xFFFF'u16, 0x00F0'u16],
      [0x0000'u16, 0x0001'u16, 0x0007'u16, 0x0019'u16, 0x0000'u16, 0x0007'u16, 0x0000'u16, 0x0000'u16, 0x00D2'u16],
      [0x0000'u16, 0x0001'u16, 0x0007'u16, 0x0011'u16, 0x0000'u16, 0x0007'u16, 0x0000'u16, 0x0000'u16, 0x00B4'u16],
      [0x0000'u16, 0x0001'u16, 0x0007'u16, 0x000C'u16, 0x0000'u16, 0x0007'u16, 0x0000'u16, 0xFFFF'u16, 0x0096'u16],
      [0x0000'u16, 0x0001'u16, 0x0007'u16, 0x0008'u16, 0x0000'u16, 0x0007'u16, 0x0000'u16, 0xFFFF'u16, 0x0078'u16],
      [0x0000'u16, 0x0001'u16, 0x0005'u16, 0x0008'u16, 0x0000'u16, 0x0007'u16, 0x0000'u16, 0xFFFE'u16, 0x005A'u16],
      [0x0000'u16, 0x0001'u16, 0x0004'u16, 0x0006'u16, 0x0000'u16, 0x0007'u16, 0x0000'u16, 0x0000'u16, 0x003C'u16],
      [0x0000'u16, 0x0001'u16, 0x0007'u16, 0x001B'u16, 0x0003'u16, 0x0007'u16, 0x0001'u16, 0x0000'u16, 0x005A'u16],
      [0x0000'u16, 0x0001'u16, 0x0007'u16, 0x0012'u16, 0x0003'u16, 0x0007'u16, 0x0001'u16, 0x0000'u16, 0x003C'u16],
      [0x0000'u16, 0x0001'u16, 0x0007'u16, 0x000C'u16, 0x0003'u16, 0x0007'u16, 0x0001'u16, 0x0001'u16, 0x001E'u16],
      [0x0000'u16, 0x0001'u16, 0x0007'u16, 0x0009'u16, 0x0003'u16, 0x0007'u16, 0x0001'u16, 0xFFFE'u16, 0x0000'u16],
      [0x0000'u16, 0x0001'u16, 0x0006'u16, 0x0007'u16, 0x0003'u16, 0x0007'u16, 0x0001'u16, 0xFFFF'u16, 0xFFE2'u16],
      [0x0000'u16, 0x0001'u16, 0x0004'u16, 0x0007'u16, 0x0003'u16, 0x0007'u16, 0x0001'u16, 0xFFFF'u16, 0xFFC4'u16],
      [0x0000'u16, 0x0001'u16, 0x0003'u16, 0x0006'u16, 0x0003'u16, 0x0007'u16, 0x0001'u16, 0xFFFF'u16, 0xFFA6'u16],
      [0x0000'u16, 0x0001'u16, 0x0001'u16, 0x0009'u16, 0x0003'u16, 0x0007'u16, 0x0001'u16, 0xFFFF'u16, 0xFF88'u16],
      [0x0000'u16, 0x0001'u16, 0x0001'u16, 0x0007'u16, 0x0003'u16, 0x0007'u16, 0x0001'u16, 0xFFFD'u16, 0xFF6A'u16],
      [0x0000'u16, 0x0001'u16, 0x0000'u16, 0x0009'u16, 0x0003'u16, 0x0007'u16, 0x0001'u16, 0x0000'u16, 0xFF4C'u16],
      [0x0000'u16, 0x0001'u16, 0x0000'u16, 0x0006'u16, 0x0003'u16, 0x0007'u16, 0x0001'u16, 0x0000'u16, 0xFF2E'u16]
    ]

    RfPriBzTxcalPowerSetup: array[RfPriBzTxcalSearchRecords, array[9, uint16]] = [
      [0x0000'u16, 0x0001'u16, 0x0007'u16, 0x001B'u16, 0x0000'u16, 0x0005'u16, 0x0000'u16, 0xFFFE'u16, 0x00E6'u16],
      [0x0000'u16, 0x0001'u16, 0x0007'u16, 0x000F'u16, 0x0000'u16, 0x0005'u16, 0x0000'u16, 0x0002'u16, 0x00C8'u16],
      [0x0000'u16, 0x0001'u16, 0x0007'u16, 0x0009'u16, 0x0000'u16, 0x0005'u16, 0x0000'u16, 0xFFFE'u16, 0x0096'u16],
      [0x0000'u16, 0x0001'u16, 0x0005'u16, 0x0007'u16, 0x0000'u16, 0x0005'u16, 0x0000'u16, 0xFFFC'u16, 0x0064'u16],
      [0x0000'u16, 0x0001'u16, 0x0002'u16, 0x0006'u16, 0x0000'u16, 0x0005'u16, 0x0000'u16, 0x0004'u16, 0x0032'u16],
      [0x0000'u16, 0x0001'u16, 0x0007'u16, 0x0010'u16, 0x0000'u16, 0x0005'u16, 0x0001'u16, 0x0002'u16, 0x005A'u16],
      [0x0000'u16, 0x0001'u16, 0x0007'u16, 0x000A'u16, 0x0000'u16, 0x0005'u16, 0x0001'u16, 0x0000'u16, 0x0032'u16],
      [0x0000'u16, 0x0001'u16, 0x0006'u16, 0x0007'u16, 0x0000'u16, 0x0005'u16, 0x0001'u16, 0x0000'u16, 0x000A'u16],
      [0x0000'u16, 0x0001'u16, 0x0003'u16, 0x0008'u16, 0x0000'u16, 0x0005'u16, 0x0001'u16, 0x0000'u16, 0xFFE2'u16]
    ]

  template rfRegs(): ptr RfRegBlock =
    cast[ptr RfRegBlock](RfBase)

  template rfPllRegs(): ptr RfPllBlock =
    cast[ptr RfPllBlock](RfPllBase)

  template rfAuxCtrlRegs(): ptr RfAuxCtrlBlock =
    cast[ptr RfAuxCtrlBlock](RfAuxCtrlBase)

  template phyRegs(): ptr PhyAgcBlock =
    cast[ptr PhyAgcBlock](PhyBase)

  template agcRegs(): ptr PhyAgcBlock =
    cast[ptr PhyAgcBlock](AgcBase)

  template wifiModemRegs(): ptr WifiModemBlock =
    cast[ptr WifiModemBlock](WifiModemBase)

  template macPhyCtrlRegs(): ptr MacPhyCtrlBlock =
    cast[ptr MacPhyCtrlBlock](MacPhyCtrlBase)

  template crmPhyClockRegs(): ptr CrmPhyClockBlock =
    cast[ptr CrmPhyClockBlock](CrmPhyClockBase)

  template rfDfeInitRegs(): ptr RfDfeInitBlock =
    cast[ptr RfDfeInitBlock](RfDfeInitBase)

  template bbaAgcRegs(): ptr BbaAgcBlock =
    cast[ptr BbaAgcBlock](BbaAgcBase)

  template rfTxPowerCompTableRegs(): ptr RfTxPowerCompTableBlock =
    cast[ptr RfTxPowerCompTableBlock](RfBase)

  template wifiAgcMemoryRegs(): ptr WifiAgcMemoryRam =
    cast[ptr WifiAgcMemoryRam](WifiAgcMemoryBase)

  proc writeRfTxPowerCompTable(words: openArray[uint32]) =
    let table = rfTxPowerCompTableRegs()
    for i, word in words:
      volatileStore(addr table.txPowerCompWords700[i], word)

  proc waitRfUs(us: uint32) {.inline.} =
    arch_delay_us(us)

  proc xtalIndex(xtalfreqHz: uint32): uint32 {.inline.} =
    case xtalfreqHz
    of WlXtal24M: 0'u32
    of WlXtal26M: 1'u32
    of WlXtal32M: 2'u32
    of WlXtal38P4M: 3'u32
    of WlXtal40M: 4'u32
    of WlXtal52M: 5'u32
    else: 5'u32

  proc crm_init() {.exportc, cdecl.}
  proc crm_clk_set(bandwidth: uint32) {.exportc, cdecl.}
  proc crm_mdm_reset() {.exportc, cdecl.}
  proc bba_init() {.exportc, cdecl.}
  proc bba_reset() {.exportc, cdecl.}
  proc bba_loop(rxVector: pointer, frameType: uint32) {.exportc, cdecl.}
  proc bba_rssi_correction(rxVector: pointer) {.exportc, cdecl.}
  proc calc_ppm(rxVector: pointer): int8 {.exportc, cdecl.}
  proc trpc_init() {.exportc, cdecl.}
  proc wrapPhyAssertErr*(fileOrCond, condOrFile: cstring, line: cint)
      {.exportc: "__wrap_phy_assert_err", cdecl, noinline.}
  proc nimFwAgcAfterCopyProbe*() {.exportc, cdecl, noinline.} =
    {.emit: "asm volatile(\"nop\" ::: \"memory\");".}

  var agcmem* {.exportc: "agcmem".}: array[512, uint32] = [
    0x20000000'u32, 0x0400000F'u32, 0x3000106F'u32, 0x60000000'u32, 0x04000059'u32, 0x3000000F'u32, 0x5B000000'u32, 0x0400005C'u32,
    0x300030EF'u32, 0x32000000'u32, 0x04000085'u32, 0x20000000'u32, 0x0400000F'u32, 0x2819008F'u32, 0x08000142'u32, 0x98008000'u32,
    0x01000000'u32, 0x0A69C430'u32, 0x0A69D41E'u32, 0x0A799427'u32, 0x0A799C15'u32, 0x38018000'u32, 0x10000821'u32, 0x00200018'u32,
    0x38008000'u32, 0x0C004003'u32, 0x0020001B'u32, 0x30000005'u32, 0x1404053A'u32, 0x04000039'u32, 0x38018000'u32, 0x10000621'u32,
    0x00200021'u32, 0x38008000'u32, 0x0C003803'u32, 0x00200024'u32, 0x30000005'u32, 0x1404052D'u32, 0x04000039'u32, 0x38018000'u32,
    0x10000421'u32, 0x0020002A'u32, 0x38008000'u32, 0x0C002C03'u32, 0x0020002D'u32, 0x30000005'u32, 0x14040523'u32, 0x04000039'u32,
    0x38018000'u32, 0x10000221'u32, 0x00200033'u32, 0x38008000'u32, 0x0C002003'u32, 0x00200036'u32, 0x30000005'u32, 0x1404051C'u32,
    0x04000039'u32, 0x28018000'u32, 0x0800003B'u32, 0x38020005'u32, 0x40000001'u32, 0x0800003E'u32, 0x30000005'u32, 0x44002001'u32,
    0x04000041'u32, 0x30000005'u32, 0x3D000303'u32, 0x04000044'u32, 0x30000005'u32, 0x3E000200'u32, 0x04000047'u32, 0x30000005'u32,
    0x1F1E2331'u32, 0x0400004A'u32, 0x280D20EF'u32, 0x0800004C'u32, 0x6C193BFF'u32, 0x0414140F'u32, 0x6DC4C48F'u32, 0x08104450'u32,
    0x380132FF'u32, 0x41000F00'u32, 0x0800004C'u32, 0x30000000'u32, 0x01000000'u32, 0x04000056'u32, 0x30000000'u32, 0x2200149C'u32,
    0x0400001E'u32, 0x38020000'u32, 0x10000231'u32, 0x08104466'u32, 0x40002000'u32, 0xE400005F'u32, 0xDC000063'u32, 0x58012000'u32,
    0x0D001401'u32, 0x146DC863'u32, 0x08000066'u32, 0x38008000'u32, 0x60000000'u32, 0x08000059'u32, 0x38012000'u32, 0x3E000100'u32,
    0x08000069'u32, 0x38022007'u32, 0x3D000101'u32, 0x0800006C'u32, 0x380220EF'u32, 0x1F191910'u32, 0x0800006F'u32, 0x280200EF'u32,
    0x08000071'u32, 0x20000CEF'u32, 0x04000073'u32, 0x80000CEF'u32, 0x30B00083'u32, 0x28400081'u32, 0x0400007F'u32, 0x0400007F'u32,
    0x300007EF'u32, 0x1F242010'u32, 0x0400007B'u32, 0x68640FEF'u32, 0x71B6848F'u32, 0x79D6848F'u32, 0x00008C4C'u32, 0x28100CEF'u32,
    0x6C00808F'u32, 0x28080CEF'u32, 0x6C00808F'u32, 0x28060CEF'u32, 0x6C00808F'u32, 0x3000248F'u32, 0x1F191910'u32, 0x04000088'u32,
    0x280424EF'u32, 0x0800008A'u32, 0x20002CEF'u32, 0x0400008C'u32, 0x48078EEF'u32, 0x6DA0448F'u32, 0x0800008F'u32, 0x6000000F'u32,
    0x71BA4493'u32, 0x71B00096'u32, 0x04104499'u32, 0x3000000F'u32, 0x29000300'u32, 0x0400009C'u32, 0x3000000F'u32, 0x29000100'u32,
    0x0400009C'u32, 0x3000000F'u32, 0x29000000'u32, 0x0400009C'u32, 0x3801800F'u32, 0x0EF1EE07'u32, 0x0200809F'u32, 0x30000000'u32,
    0x32000000'u32, 0x040000A2'u32, 0x38020005'u32, 0x3E000201'u32, 0x080000A5'u32, 0x30000007'u32, 0x32000001'u32, 0x040000A8'u32,
    0x30000007'u32, 0x3D000303'u32, 0x040000AB'u32, 0x3000000F'u32, 0x3F000102'u32, 0x040000AE'u32, 0x380402EF'u32, 0x1F102021'u32,
    0x080000B1'u32, 0x380A0A6F'u32, 0x2200209C'u32, 0x080000B4'u32, 0x28060B6F'u32, 0x080000B6'u32, 0x30000B6F'u32, 0x4100000F'u32,
    0x040000B9'u32, 0x30000B6F'u32, 0x21000003'u32, 0x040000BC'u32, 0x80000B6F'u32, 0x71BA44C1'u32, 0x701044C4'u32, 0x6C1044C4'u32,
    0x041044C7'u32, 0x30000F6F'u32, 0x29000301'u32, 0x040000CA'u32, 0x30000F6F'u32, 0x29000101'u32, 0x040000CA'u32, 0x30000F6F'u32,
    0x29000001'u32, 0x040000CA'u32, 0x28320BEF'u32, 0x080000CC'u32, 0x30000BEF'u32, 0x21000303'u32, 0x040000CF'u32, 0xE0000B6F'u32,
    0x79DA44D7'u32, 0x71BA44DA'u32, 0x741044DD'u32, 0x6C1044E0'u32, 0x781044DD'u32, 0x701044E0'u32, 0x041044E3'u32, 0x3000030F'u32,
    0x29030002'u32, 0x04000129'u32, 0x3000030F'u32, 0x29000302'u32, 0x040000E9'u32, 0x3000030F'u32, 0x29010002'u32, 0x04000129'u32,
    0x3000030F'u32, 0x29000102'u32, 0x040000E9'u32, 0x3000030F'u32, 0x29000002'u32, 0x040000E6'u32, 0x3000000F'u32, 0x32000000'u32,
    0x0400000F'u32, 0x3000008F'u32, 0x2200149C'u32, 0x040000EC'u32, 0x7896018F'u32, 0x4100000F'u32, 0x8C0000F1'u32, 0x080000E6'u32,
    0x90104523'u32, 0x88C8000F'u32, 0xC00000FF'u32, 0x90104523'u32, 0x081044F6'u32, 0x941044FC'u32, 0x3000018F'u32, 0x2200289C'u32,
    0x040000F9'u32, 0x3000030F'u32, 0x29000000'u32, 0x9404500F'u32, 0x3000000F'u32, 0x29000000'u32, 0x0410440F'u32, 0x38008005'u32,
    0x3D010101'u32, 0x08000105'u32, 0x30000005'u32, 0x6E000000'u32, 0x04104505'u32, 0x892C000F'u32, 0x0800010A'u32, 0x941044FC'u32,
    0xC610450D'u32, 0xC4185511'u32, 0x4000020F'u32, 0x90104515'u32, 0x04104515'u32, 0x5802800F'u32, 0x0EF1EE07'u32, 0x80000115'u32,
    0x0800011A'u32, 0x5802800F'u32, 0x0FF1EE07'u32, 0x80000115'u32, 0x0420451A'u32, 0x30000007'u32, 0x3D030303'u32, 0x04000118'u32,
    0x2810000F'u32, 0x08000123'u32, 0x30000005'u32, 0x4100000F'u32, 0x0400011D'u32, 0x38030005'u32, 0x3D030303'u32, 0x08000120'u32,
    0x3810000F'u32, 0x4100000F'u32, 0x08000123'u32, 0x3000000F'u32, 0x2200289C'u32, 0x04000126'u32, 0x3000030F'u32, 0x29000000'u32,
    0x9404500F'u32, 0x3000030F'u32, 0x32000000'u32, 0x0400012C'u32, 0x3000130F'u32, 0x32000100'u32, 0x0400012F'u32, 0x5AEE130F'u32,
    0x4100000F'u32, 0x7C000136'u32, 0x08000133'u32, 0x3000030F'u32, 0x32000000'u32, 0x0400000F'u32, 0x492C110F'u32, 0x8C000139'u32,
    0x08000133'u32, 0x3000130F'u32, 0x4100000F'u32, 0x0400013C'u32, 0x3000120F'u32, 0x2200209C'u32, 0x0400013F'u32, 0x3000130F'u32,
    0x29000000'u32, 0x9404500F'u32, 0x3000008F'u32, 0x0EF1F10B'u32, 0x06000145'u32, 0x38038000'u32, 0x34000000'u32, 0x08000148'u32,
    0x28028005'u32, 0x0800014A'u32, 0x3000028F'u32, 0x2200209C'u32, 0x0400014D'u32, 0x2000028F'u32, 0x0400014F'u32, 0x2814028F'u32,
    0x08000151'u32, 0x3000128F'u32, 0x32000100'u32, 0x04000154'u32, 0x5AEE138F'u32, 0x4100000F'u32, 0x7C000158'u32, 0x08000133'u32,
    0x592C138F'u32, 0x29000000'u32, 0x8C00015C'u32, 0x08000133'u32, 0x2000128F'u32, 0x9404500F'u32, 0x00000000'u32, 0x00000000'u32,
    0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32,
    0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32,
    0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32,
    0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32,
    0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32,
    0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32,
    0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32,
    0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32,
    0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32,
    0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32,
    0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32,
    0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32,
    0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32,
    0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32,
    0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32,
    0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32,
    0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32,
    0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32,
    0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32,
    0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0xC0088D03'u32]

  var bbaEnv* {.align: 4, exportc: "bba_env".}: BbaRuntimeState
  const
    BbaPdThresholdAttack: array[4, int8] = [-100'i8, -70'i8, -48'i8, -36'i8]
    BbaPdThresholdRelease: array[4, int8] = [-100'i8, -75'i8, -53'i8, -41'i8]

  var wlCfgGlobal* {.exportc: "wl_cfg".}: pointer
  var phy_env* {.exportc.}: array[48, uint8]

  template bbaState(): ptr BbaRuntimeState =
    addr bbaEnv

  template bbaRxVecPtr(rxVector: pointer): ptr BbaRxVectorView =
    cast[ptr BbaRxVectorView](rxVector)

  template phyEnvViewPtr(): ptr PhyEnvView =
    cast[ptr PhyEnvView](addr phy_env[0])

  template bbaIrqSave(): uint32 =
    block:
      var irqPrev {.gensym.}: uint32
      {.emit: ["asm volatile(\"csrrci %0, mstatus, 8\" : \"=r\"(", irqPrev, ") );"].}
      irqPrev

  template bbaIrqRestore(prev: uint32) =
    if (prev and 8'u32) != 0'u32:
      {.emit: ["asm volatile(\"csrsi mstatus, 8\");"].}

  proc crm_get_mac_freq(): uint32 {.exportc, cdecl.} =
    ## crm_bl616.c.o crm_get_mac_freq returns 60 MHz.
    60'u32

  proc crm_get_cpu_freq*(): uint32 {.exportc, cdecl.} =
    ## Port of crm_bl616.c.o crm_get_cpu_freq+0x0..0x8.
    50_000_000'u32

  proc crm_init() {.exportc, cdecl.} =
    ## Port of crm_bl616.c.o crm_init: set RF clock mux bits at 0x24940010.
    updateReg32(addr crmPhyClockRegs().rfClockMux10,
                0xF8000000'u32, 0x08000000'u32)

  proc crm_mdm_reset() {.exportc, cdecl.} =
    ## Port of crm_bl616.c.o crm_mdm_reset.
    volatileStore(addr crmPhyClockRegs().modemReset18, 0x11'u32)
    arch_delay_us(1'u32)
    volatileStore(addr crmPhyClockRegs().modemReset18, 0'u32)
    arch_delay_us(1'u32)

  proc crm_clk_set(bandwidth: uint32) {.exportc, cdecl.} =
    ## Port of crm_bl616.c.o crm_clk_set. bandwidth 0 selects the default PHY
    ## clock bits; bandwidth 1 selects the alternate 40 MHz bit pattern.
    if bandwidth == 0'u32:
      updateReg32(addr crmPhyClockRegs().phyClockSelect8, 0xFFFFFFCF'u32, 0'u32)
      updateReg32(addr crmPhyClockRegs().phyClockSelect8, 0xFFFFFF3F'u32, 0'u32)
    elif bandwidth == 1'u32:
      updateReg32(addr crmPhyClockRegs().phyClockSelect8,
                  0xFFFFFFCF'u32, 0x10'u32)
      updateReg32(addr crmPhyClockRegs().phyClockSelect8,
                  0xFFFFFF3F'u32, 0x40'u32)

  proc signExtend(value: uint32, bits: uint32): int32 {.inline.} =
    let shift = 32'u32 - bits
    cast[int32](value shl shift) shr shift

  proc bbaExtractBits(value: uint32, high, low: uint32): uint32 {.inline.} =
    (value shr low) and ((1'u32 shl (high - low + 1'u32)) - 1'u32)

  proc bbaSetPdLatch(enable: bool)
  proc bba_set_pd_ofdm*(enable: uint32) {.exportc, cdecl.}
  proc bba_set_pd_dsss*(enable: uint32) {.exportc, cdecl.}
  proc bbaApplyCarrierErrorCapcode()
  proc bbaRunCarrierErrorLoop(rssi: int32, ppm: int32)
  proc bbaRunPowerDetectLoop(rssi: int32)

  proc bbaProgramPdGain(gain: uint32) =
    ## Port of librf_bl808.a:bba.c.o bba_set_pd_gain+0x0..0x25c.
    let mdm = wifiModemRegs()
    let bba = bbaAgcRegs()
    case gain
    of 2'u32:
      updateReg32(addr bba.pdGain390, 0xFFFFFFFF'u32, 0x00000100'u32)
      updateReg32(addr bba.pdGain390, 0xFFFFFDFF'u32, 0'u32)
      updateReg32(addr bba.pdSlope3c0, 0xFFFF00FF'u32, 0x0000C400'u32)
      updateReg32(addr bba.pdSlope3c0, 0xFFFFFF00'u32, 0x000000BA'u32)
      updateReg32(addr mdm.rxGainTimingC044, 0xFFFF00FF'u32, 0x00000400'u32)
      updateReg32(addr bba.pdComp36c, 0xFFFFFF00'u32, 0x00000014'u32)
      updateReg32(addr bba.pdTiming3ac, 0xFFFFFF00'u32, 0x000000C8'u32)
      updateReg32(addr bba.pdTiming3ac, 0xFFF00FFF'u32, 0x000C5000'u32)
      volatileStore(addr bbaState().pdGainCode, 2'u8)
    of 1'u32:
      updateReg32(addr bba.pdGain390, 0xFFFFFEFF'u32, 0'u32)
      updateReg32(addr bba.pdGain390, 0xFFFFFFFF'u32, 0x00000200'u32)
      updateReg32(addr bba.pdSlope3c0, 0xFFFF00FF'u32, 0x0000B900'u32)
      updateReg32(addr bba.pdSlope3c0, 0xFFFFFF00'u32, 0x000000B5'u32)
      updateReg32(addr bba.pdTiming3ac, 0xFFFFFF00'u32, 0x000000C2'u32)
      updateReg32(addr bba.pdTiming3ac, 0xFFF00FFF'u32, 0x000BF000'u32)
      updateReg32(addr mdm.rxGainTimingC044, 0xFFFF00FF'u32, 0x00000600'u32)
      updateReg32(addr bba.pdComp36c, 0xFFFFFF00'u32, 0x00000014'u32)
      volatileStore(addr bbaState().pdGainCode, 1'u8)
    of 3'u32:
      updateReg32(addr bba.pdGain390, 0xFFFFFFFF'u32, 0x00000100'u32)
      updateReg32(addr bba.pdGain390, 0xFFFFFFFF'u32, 0x00000200'u32)
      updateReg32(addr bba.pdSlope3c0, 0xFFFF00FF'u32, 0x0000D000'u32)
      updateReg32(addr bba.pdSlope3c0, 0xFFFFFF00'u32, 0x000000BF'u32)
      updateReg32(addr mdm.rxGainTimingC044, 0xFFFF00FF'u32, 0x00000200'u32)
      updateReg32(addr bba.pdComp36c, 0xFFFFFF00'u32, 0x00000014'u32)
      updateReg32(addr bba.pdTiming3ac, 0xFFFFFF00'u32, 0x000000CC'u32)
      updateReg32(addr bba.pdTiming3ac, 0xFFF00FFF'u32, 0x000C9000'u32)
      volatileStore(addr bbaState().pdGainCode, 3'u8)
    else:
      updateReg32(addr bba.pdGain390, 0xFFFFFEFF'u32, 0'u32)
      updateReg32(addr bba.pdGain390, 0xFFFFFDFF'u32, 0'u32)
      updateReg32(addr bba.pdSlope3c0, 0xFFFF00FF'u32, 0x0000A300'u32)
      updateReg32(addr bba.pdSlope3c0, 0xFFFFFF00'u32, 0x000000B0'u32)
      updateReg32(addr bba.pdTiming3ac, 0xFFFFFF00'u32, 0x000000C2'u32)
      updateReg32(addr bba.pdTiming3ac, 0xFFF00FFF'u32, 0x000BF000'u32)
      updateReg32(addr mdm.rxGainTimingC044, 0xFFFF00FF'u32, 0x00000800'u32)
      updateReg32(addr bba.pdComp36c, 0xFFFFFF00'u32, 0x00000010'u32)
      volatileStore(addr bbaState().pdGainCode, 0'u8)

  proc bba_get_pd_gain*(): uint8 {.exportc, cdecl.} =
    ## Port of librf_bl808.a:bba.c.o bba_get_pd_gain+0x0..0xc.
    volatileLoad(addr bbaState().pdGainCode)

  proc bba_get_pd_state*(): uint8 {.exportc, cdecl.} =
    ## Port of librf_bl808.a:bba.c.o bba_get_pd_state+0x0..0xc.
    volatileLoad(addr bbaState().pdRssiState)

  proc bba_get_pd_mile*(): uint8 {.exportc, cdecl.} =
    ## Port of librf_bl808.a:bba.c.o bba_get_pd_mile+0x0..0xc.
    volatileLoad(addr bbaState().pdCompLatch)

  proc bba_set_pd_state*(state: uint32) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:bba.c.o bba_set_pd_state+0x0..0x132.
    ## Vendor masks MSTATUS.MIE while coordinating OFDM/DSSS detect gates,
    ## MILE comparator latch state, and the active PD gain profile.
    let saved = bbaIrqSave()
    let oldState = volatileLoad(addr bbaState().pdRssiState).uint32

    if state == 0'u32:
      bba_set_pd_ofdm(1'u32)
      bba_set_pd_dsss(1'u32)
      if oldState == 4'u32:
        bbaSetPdLatch(false)
    else:
      if oldState == 0'u32:
        bba_set_pd_ofdm(0'u32)
        bba_set_pd_dsss(0'u32)
        if state == 4'u32:
          bbaSetPdLatch(true)
      elif state == 4'u32:
        bbaSetPdLatch(true)
      elif oldState == 4'u32:
        bbaSetPdLatch(false)

    case state
    of 2'u32:
      bbaProgramPdGain(1'u32)
    of 3'u32, 4'u32:
      bbaProgramPdGain(2'u32)
    of 0'u32, 1'u32:
      bbaProgramPdGain(0'u32)
    else:
      discard

    volatileStore(addr bbaState().pdRssiState, state.uint8)
    bbaIrqRestore(saved)

  proc bba_set_pd_gain*(gain: uint32) {.exportc, cdecl.} =
    ## Public ABI wrapper for bba.c.o bba_set_pd_gain. The typed register
    ## sequence is shared with internal PD loop transitions.
    bbaProgramPdGain(gain)

  proc bba_set_pd_ofdm*(enable: uint32) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:bba.c.o bba_set_pd_ofdm+0x0..0x18.
    updateReg32(
      addr bbaAgcRegs().pdGain390,
      0xFFFFFF0F'u32,
      if enable != 0'u32: 0x00000010'u32 else: 0'u32)

  proc bba_set_pd_dsss*(enable: uint32) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:bba.c.o bba_set_pd_dsss+0x0..0x1c.
    updateReg32(
      addr bbaAgcRegs().pdCompC830,
      0xFC0FFFFF'u32,
      if enable != 0'u32: 0x00100000'u32 else: 0'u32)

  proc bba_set_pd_rssi*(rssiThreshold: uint32) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:bba.c.o bba_set_pd_rssi+0x0..0x1c.
    updateReg32(
      addr bbaAgcRegs().pdSlope3c0,
      0xFFFF00FF'u32,
      (rssiThreshold and 0xFF'u32) shl 8)

  proc bba_set_pd_mile*(enable: uint32) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:bba.c.o bba_set_pd_mile+0x0..0x4e.
    bbaSetPdLatch(enable != 0'u32)

  proc bba_get_pd_cfg*(ofdmOut, dsssOut, rssiOut: pointer) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:bba.c.o bba_get_pd_cfg+0x0..0x2a.
    let bba = bbaAgcRegs()
    if ofdmOut != nil:
      cast[ptr uint8](ofdmOut)[] =
        uint8((volatileLoad(addr bba.pdGain390) shr 4) and 0x0F'u32)
    if dsssOut != nil:
      cast[ptr uint8](dsssOut)[] =
        uint8((volatileLoad(addr bba.pdCompC830) shr 20) and 0x0F'u32)
    if rssiOut != nil:
      cast[ptr uint8](rssiOut)[] =
        uint8((volatileLoad(addr bba.pdSlope3c0) shr 8) and 0xFF'u32)

  proc bba_pd_reset*() {.exportc, cdecl.} =
    ## librf_bl808.a:bba.c.o bba_pd_reset is ret-only.
    discard

  proc bba_ce_reset*() {.exportc, cdecl.} =
    ## Port of librf_bl808.a:bba.c.o bba_ce_reset+0x0..0x12.
    volatileStore(addr bbaState().cePpmAccumulator, 0'u16)
    volatileStore(addr bbaState().ceUpdateInterval, 16'u8)
    volatileStore(addr bbaState().ceUpdateCount, 0'u8)

  proc bba_ce_update_capcode*() {.exportc, cdecl.} =
    ## Public ABI wrapper for librf_bl808.a:bba.c.o
    ## bba_ce_update_capcode+0x0..0x9e.
    bbaApplyCarrierErrorCapcode()

  proc bba_ce_loop*(rssi: int32, ppm: int32) {.exportc, cdecl.} =
    ## Public ABI wrapper for librf_bl808.a:bba.c.o bba_ce_loop+0x0..0xae.
    bbaRunCarrierErrorLoop(rssi, ppm)

  proc bba_pd_loop*(rssi: int32) {.exportc, cdecl.} =
    ## Public ABI wrapper for librf_bl808.a:bba.c.o bba_pd_loop+0x0..0x21a.
    bbaRunPowerDetectLoop(rssi)

  proc bba_init() {.exportc, cdecl.} =
    ## Port of librf_bl808.a:bba.c.o bba_init+0x0..0x106.
    let bba = bbaAgcRegs()
    let rf = rfRegs()
    volatileStore(addr bbaState().pdCompCurrent, 1'u8)
    volatileStore(addr bbaState().ceUpdateInterval, 10'u8)
    volatileStore(addr bbaState().ceUpdateCount, 0'u8)
    volatileStore(addr bbaState().ceLoopScratch0, 0'u32)
    volatileStore(addr bbaState().ceLoopScratch4, 0'u32)
    volatileStore(addr bbaState().pdRssiState, 0'u8)
    volatileStore(addr bbaState().pdLoopReserved12, 0'u8)
    volatileStore(addr bbaState().ceCapcodeHoldoff, 0'u8)
    volatileStore(addr bbaState().cePpmAccumulator, 0'u16)
    bbaProgramPdGain(0'u32)
    updateReg32(addr bba.pdGain390, 0xFFFFFF0F'u32, 0'u32)
    updateReg32(addr bba.pdCompC830, 0xFC0FFFFF'u32, 0x00100000'u32)
    volatileStore(addr bbaState().pdCompLatch, 0'u8)
    updateReg32(addr rf.pdCompLatchCtrl50c, 0xFFFFFEFF'u32, 0'u32)
    updateReg32(addr rf.pdCompLatchCtrl50c, 0xFFFFFDFF'u32, 0'u32)

  proc bba_reset() {.exportc, cdecl.} =
    ## Port of librf_bl808.a:bba.c.o bba_reset+0x0..0x8a.
    let bba = bbaAgcRegs()
    let rf = rfRegs()
    volatileStore(addr bbaState().pdRssiState, 0'u8)
    volatileStore(addr bbaState().pdGainCode, 0'u8)
    volatileStore(addr bbaState().pdCompCurrent, 1'u8)
    volatileStore(addr bbaState().pdCompLatch, 0'u8)
    volatileStore(addr bbaState().ceUpdateInterval, 10'u8)
    volatileStore(addr bbaState().ceUpdateCount, 0'u8)
    volatileStore(addr bbaState().ceLoopScratch0, 0'u32)
    volatileStore(addr bbaState().ceLoopScratch4, 0'u32)
    volatileStore(addr bbaState().pdLoopReserved12, 0'u8)
    volatileStore(addr bbaState().cePpmAccumulator, 0'u16)
    volatileStore(addr bbaState().ceCapcodeHoldoff, 0'u8)
    bbaProgramPdGain(0'u32)
    updateReg32(addr bba.pdGain390, 0xFFFFFF0F'u32, 0'u32)
    updateReg32(addr bba.pdCompC830, 0xFC0FFFFF'u32, 0x00100000'u32)
    volatileStore(addr bbaState().pdCompLatch, 0'u8)
    updateReg32(addr rf.pdCompLatchCtrl50c, 0xFFFFFEFF'u32, 0'u32)
    updateReg32(addr rf.pdCompLatchCtrl50c, 0xFFFFFDFF'u32, 0'u32)

  proc bbaSetPdLatch(enable: bool) =
    let rf = rfRegs()
    if enable:
      updateReg32(addr rf.pdCompLatchCtrl50c, 0xFFFFFFFF'u32, 0x00000100'u32)
      updateReg32(addr rf.pdCompLatchCtrl50c, 0xFFFFFDFF'u32, 0'u32)
      volatileStore(addr bbaState().pdCompLatch, 1'u8)
    else:
      updateReg32(addr rf.pdCompLatchCtrl50c, 0xFFFFFEFF'u32, 0'u32)
      updateReg32(addr rf.pdCompLatchCtrl50c, 0xFFFFFDFF'u32, 0'u32)
      volatileStore(addr bbaState().pdCompLatch, 0'u8)

  proc bbaUpdatePdComp(target: uint8) =
    if volatileLoad(addr bbaState().pdCompCurrent) == target:
      return
    let bba = bbaAgcRegs()
    updateReg32(addr bba.pdGain390, 0xFFFFFF0F'u32, 0'u32)
    updateReg32(addr bba.pdCompC830, 0xFC0FFFFF'u32, target.uint32 shl 20)
    volatileStore(addr bbaState().pdCompCurrent, target)

  proc bbaApplyCarrierErrorCapcode() =
    ## Port of bba_ce_update_capcode+0x0..0x9e, using wl_cfg capcode callbacks.
    if wlCfgGlobal == nil:
      return
    let offset = signExtend(
      volatileLoad(addr bbaState().cePpmAccumulator).uint32, 16'u32)
    if offset == 0'i32:
      return
    let cfg = cast[ptr WlRfConfig](wlCfgGlobal)
    if cfg.capcodeGetCallback == nil or cfg.capcodeSetCallback == nil:
      return
    var capcode: uint8
    var capcodeAux: uint8
    cast[proc(a: ptr uint8, b: ptr uint8) {.cdecl.}](cfg.capcodeGetCallback)(
      addr capcode, addr capcodeAux)
    var next = capcode
    if offset > 0'i32:
      if capcode == 0'u8:
        return
      next = capcode - 1'u8
      if next == capcode:
        return
    else:
      if capcode > 0x3E'u8:
        return
      next = capcode + 1'u8
      if next == capcode:
        return
    cast[proc(a: uint8) {.cdecl.}](cfg.capcodeSetCallback)(next)
    volatileStore(addr bbaState().cePpmAccumulator, 0'u16)
    volatileStore(addr bbaState().ceCapcodeHoldoff, 1'u8)

  proc bbaRunCarrierErrorLoop(rssi: int32, ppm: int32) =
    ## Port of librf_bl808.a:bba.c.o bba_ce_loop+0x0..0xae.
    let ppm6 = signExtend(uint32((ppm shl 6) and 0xFFFF'i32), 16'u32)
    if volatileLoad(addr bbaState().ceCapcodeHoldoff) == 1'u8:
      let count = volatileLoad(addr bbaState().ceUpdateCount)
      if count < volatileLoad(addr bbaState().ceUpdateInterval):
        volatileStore(addr bbaState().ceUpdateCount, count + 1'u8)
        return
      volatileStore(addr bbaState().ceUpdateCount, 0'u8)
      volatileStore(addr bbaState().ceCapcodeHoldoff, 0'u8)

    if abs(ppm6) > 0xC0'i32:
      var accum = signExtend(
        volatileLoad(addr bbaState().cePpmAccumulator).uint32, 16'u32)
      if rssi < -85'i32:
        accum += ppm6
      elif rssi < -65'i32:
        accum += ppm shl 7
      else:
        accum += ppm shl 8
      volatileStore(
        addr bbaState().cePpmAccumulator, uint16(accum and 0xFFFF'i32))

    if abs(signExtend(
        volatileLoad(addr bbaState().cePpmAccumulator).uint32,
        16'u32)) > 0x180'i32:
      bbaApplyCarrierErrorCapcode()

  proc bbaRunPowerDetectLoop(rssi: int32) =
    ## Port of librf_bl808.a:bba.c.o bba_pd_loop+0x0..0x21a.
    let state = volatileLoad(addr bbaState().pdRssiState)
    var nextState = state
    var targetComp = volatileLoad(addr bbaState().pdCompLatch)
    var changeGain = false

    case state
    of 0'u8:
      if rssi > BbaPdThresholdAttack[1].int32:
        nextState = 1'u8
        targetComp = 0'u8
        changeGain = true
      elif rssi < -90'i32:
        targetComp = 1'u8
    of 1'u8:
      if rssi > BbaPdThresholdAttack[2].int32:
        nextState = 2'u8
        targetComp = 0'u8
        changeGain = true
      elif rssi < BbaPdThresholdRelease[1].int32:
        nextState = 0'u8
        targetComp = if rssi < -90'i32: 1'u8 else: 0'u8
        changeGain = true
      else:
        targetComp = 0'u8
    of 2'u8:
      if rssi < -14'i32:
        nextState = 0'u8
        targetComp = 0'u8
      else:
        targetComp = 0'u8
    of 3'u8:
      if rssi < -14'i32:
        if rssi < BbaPdThresholdRelease[1].int32:
          nextState = 0'u8
          targetComp = 1'u8
          changeGain = true
        elif rssi < BbaPdThresholdRelease[2].int32:
          nextState = 1'u8
          targetComp = 0'u8
          changeGain = true
        elif rssi < BbaPdThresholdRelease[3].int32:
          targetComp = 0'u8
        else:
          targetComp = volatileLoad(addr bbaState().pdCompLatch)
      else:
        if volatileLoad(addr bbaState().pdCompLatch) != 1'u8:
          bbaSetPdLatch(true)
        targetComp = 0'u8
    else:
      discard

    if changeGain:
      bbaProgramPdGain(nextState.uint32)
      volatileStore(addr bbaState().pdRssiState, nextState)

    if volatileLoad(addr bbaState().pdCompLatch) != 0'u8 and targetComp == 0'u8:
      bbaSetPdLatch(false)

    bbaUpdatePdComp(targetComp)

  proc bba_loop(rxVector: pointer, frameType: uint32) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:bba.c.o bba_loop+0x0..0x74 with decoded CE/PD
    ## subphases.
    if frameType != 0x80'u32 or rxVector == nil:
      return
    let rxv = bbaRxVecPtr(rxVector)
    let rssi = signExtend(volatileLoad(addr rxv.rssiDbm).uint32, 8'u32)
    let ppm = calc_ppm(rxVector).int32
    bbaRunCarrierErrorLoop(rssi, ppm)
    bbaRunPowerDetectLoop(rssi)

  proc bba_rssi_correction(rxVector: pointer) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:bba.c.o bba_rssi_correction+0x0..0x18.
    if rxVector == nil:
      return
    if volatileLoad(addr bbaState().pdCompLatch) != 0'u8:
      let rxv = bbaRxVecPtr(rxVector)
      volatileStore(addr rxv.rssiDbm, volatileLoad(addr rxv.rssiDbm) + 0x14'u8)

  proc bbaRxFormatWord1(rxv: ptr BbaRxVectorView): uint32 {.inline.} =
    volatileLoad(addr rxv.rxFormatWord1Rate).uint32 or
      (volatileLoad(addr rxv.rssiDbm).uint32 shl 8) or
      (volatileLoad(addr rxv.rxFormatWord1Mcs).uint32 shl 16) or
      (volatileLoad(addr rxv.rxFormatWord1Flags).uint32 shl 24)

  proc calc_ppm(rxVector: pointer): int8 {.exportc, cdecl.} =
    ## Port of librf_bl808.a:bba.c.o calc_ppm+0x0..0x44.
    if rxVector == nil:
      return 0'i8
    let rxv = bbaRxVecPtr(rxVector)
    let carrierOffset = volatileLoad(addr rxv.carrierFreqOffset).uint32
    if (volatileLoad(addr rxv.rxFormatWord0) and 0xF'u32) == 0'u32 and
        bbaExtractBits(bbaRxFormatWord1(rxv), 7'u32, 4'u32) <= 3'u32:
      let ppm = signExtend(carrierOffset, 8'u32)
      return cast[int8](signExtend(uint32((ppm * 3'i32) shr 6), 8'u32))
    else:
      let ppm = signExtend(carrierOffset, 16'u32)
      let rounded = (ppm and not 0xF'i32) + (ppm shr 4)
      return cast[int8](signExtend(uint32((-rounded) shr 7), 8'u32))

  proc modemVersionReg(): uint32 {.inline.} =
    volatileLoad(addr wifiModemRegs().versionWord)

  proc extractBits(value: uint32, high, low: uint32): uint32 {.inline.} =
    (value shr low) and ((1'u32 shl (high - low + 1'u32)) - 1'u32)

  proc validatePhyInitFieldFits(cond: cstring; value, shift, mask: uint32)
      {.inline.} =
    ## Vendor phy_init keeps assertion islands for every modem-version field
    ## copied into a narrowed register field. Keep those checks explicit so a
    ## new modem revision cannot be silently truncated by the typed masks below.
    if (((value shl shift) and not mask) != 0'u32):
      wrapPhyAssertErr("phy.c", cond, 0x35C4.cint)

  proc phyClockCountFromVersion(version: uint32): uint32 {.inline.} =
    ## librf_bl808.a:phy.c.o phy_init+0x22..0x32:
    ##   srli top byte; addi +2; th.addsl self,self,2; th.extu [23:16];
    ##   th.addsl mid,self,1; compare against 32.
    extractBits(version, 23'u32, 16'u32) +
      (((extractBits(version, 31'u32, 24'u32) + 2'u32) * 5'u32) shl 1)

  proc copyPhyInitCfg(cfg: pointer) =
    let env = phyEnvViewPtr()
    if cfg != nil:
      let words = cast[ptr UncheckedArray[uint32]](cfg)
      for i in 0 ..< 9:
        volatileStore(addr env.initCfgWords[i], words[i])
    else:
      for i in 0 ..< 9:
        volatileStore(addr env.initCfgWords[i], 0'u32)
    volatileStore(addr env.channelBandType, 0x0501'u16)
    volatileStore(addr env.primaryFreq, 0x00FF'u16)
    volatileStore(addr env.centerFreq1, 0x0FFF'u16)
    volatileStore(addr env.centerFreq2OrTxPower, 0x00FF'u16)

  proc copyAgcMemory() =
    ## LLVM objdump provenance: librf_bl808.a:phy.c.o phy_init+0x452..0x470
    ## copies only agcmem into the WiFi AGC RAM window at 0x24C0A000. The BL808
    ## WiFi RF archive has no ldpcmem symbol and the decoded WiFi phy/lp_phy
    ## objects do not contain a 0x24C09000 LDPC-memory load path; the 0x24C09000
    ## table load is BLE-only in blecontroller.loadBlePhyMemories().
    static: doAssert agcmem.len == WifiAgcMemoryWords
    nimFwDbgPhyInitPhase = 3'u32
    inc nimFwDbgPhyAgcCopyCount
    nimFwDbgPhyWifiLdpcAbsent = 1'u32
    nimFwDbgPhyAgcSourceFirst = agcmem[0]
    nimFwDbgPhyAgcSourceLast = agcmem[WifiAgcMemoryWords - 1]
    let src = cast[ptr UncheckedArray[uint32]](addr agcmem[0])
    let dst = wifiAgcMemoryRegs()
    for i in 0 ..< WifiAgcMemoryWords:
      volatileStore(addr dst.words[i], src[i])
    nimFwDbgPhyAgcDestFirst = volatileLoad(addr dst.words[0])
    nimFwDbgPhyAgcDestLast =
      volatileLoad(addr dst.words[WifiAgcMemoryWords - 1])
    nimFwAgcAfterCopyProbe()

  proc bl808PhyProgramRecoveredRegs() =
    ## Typed translation of librf_bl808.a:phy.c.o phy_init+0x5a..0x310.
    ## Dynamic fields use the LLVM/GNU-decoded T-Head th.extu operations and
    ## preserve the vendor overflow asserts before writing each bitfield.
    let version = modemVersionReg()
    let mdm = wifiModemRegs()
    let macPhy = macPhyCtrlRegs()
    let spatialStreamCountMinus1 =
      (extractBits(version, 11'u32, 8'u32) - 1'u32) and 0xFF'u32
    let modemProfile15to12Minus1 =
      (extractBits(version, 15'u32, 12'u32) - 1'u32) and 0xFF'u32
    let txChainCountMinus1 =
      (extractBits(version, 7'u32, 4'u32) - 1'u32) and 0xFF'u32
    let heOrBandwidthProfile =
      if extractBits(version, 22'u32, 22'u32) != 0'u32 or
          extractBits(version, 25'u32, 24'u32) != 0'u32:
        0x2'u32
      else:
        0'u32
    let modemCapability21 = extractBits(version, 21'u32, 21'u32)
    let modemCapability30 = extractBits(version, 30'u32, 30'u32)
    validatePhyInitFieldFits(
      "(((uint32_t)rxnssmax << 4) & ~((uint32_t)0x00000070)) == 0",
      spatialStreamCountMinus1, 4'u32, 0x00000070'u32)
    validatePhyInitFieldFits(
      "(((uint32_t)rxndpnstsmax << 12) & ~((uint32_t)0x00007000)) == 0",
      modemProfile15to12Minus1, 12'u32, 0x00007000'u32)
    validatePhyInitFieldFits(
      "(((uint32_t)confnrx << 8) & ~((uint32_t)0x00000F00)) == 0",
      spatialStreamCountMinus1, 8'u32, 0x00000F00'u32)
    validatePhyInitFieldFits(
      "(((uint32_t)txnssmax << 4) & ~((uint32_t)0x00000070)) == 0",
      spatialStreamCountMinus1, 4'u32, 0x00000070'u32)
    validatePhyInitFieldFits(
      "(((uint32_t)ntxmax << 20) & ~((uint32_t)0x00700000)) == 0",
      txChainCountMinus1, 20'u32, 0x00700000'u32)
    validatePhyInitFieldFits(
      "(((uint32_t)maxsupportednss << 20) & ~((uint32_t)0x00700000)) == 0",
      spatialStreamCountMinus1, 20'u32, 0x00700000'u32)
    validatePhyInitFieldFits(
      "(((uint32_t)confntx << 4) & ~((uint32_t)0x000000F0)) == 0",
      txChainCountMinus1, 4'u32, 0x000000F0'u32)
    volatileStore(addr mdm.bandwidth20MProfile820, 0x00000005'u32)
    updateReg32(addr mdm.bandwidth20MProfile820, 0xFFFFFF8F'u32,
                spatialStreamCountMinus1 shl 4)
    updateReg32(addr mdm.bandwidth20MProfile820, 0xFFFF8FFF'u32,
                modemProfile15to12Minus1 shl 12)
    updateReg32(addr mdm.bandwidth20MProfile820, 0xFFFFFEFF'u32,
                extractBits(version, 27'u32, 27'u32) shl 8)
    updateReg32(addr mdm.bandwidth20MProfile820, 0xFFFFFFFC'u32,
                heOrBandwidthProfile)
    updateReg32(addr mdm.bandwidth20MProfile820, not 0x200'u32, 0x200'u32)
    updateReg32(addr mdm.versionFeatureCtrl800, 0xFFFFF0FF'u32,
                spatialStreamCountMinus1 shl 8)
    updateReg32(addr mdm.bandwidth20MProfile820, 0xFFDFFFFF'u32,
                modemCapability21 shl 21)
    updateReg32(addr mdm.bandwidth20MProfile820, 0xFFEFFFFF'u32,
                modemCapability21 shl 20)
    updateReg32(addr mdm.versionFeatureCtrl800, 0xFFFFF0FF'u32,
                spatialStreamCountMinus1 shl 8)
    updateReg32(addr mdm.bandwidth20MProfile820, 0xFFFEFFFF'u32,
                (modemCapability21 and modemCapability30) shl 16)
    updateReg32(addr mdm.bandwidth20MProfile820, 0xEFFFFFFF'u32,
                (modemCapability21 and modemCapability30) shl 28)
    volatileStore(addr mdm.channelTypeCtrl824, 0x00000005'u32)
    updateReg32(addr mdm.channelTypeCtrl824, 0xFFFFFF8F'u32,
                spatialStreamCountMinus1 shl 4)
    updateReg32(addr mdm.channelTypeCtrl824, 0xFF8FFFFF'u32,
                txChainCountMinus1 shl 20)
    updateReg32(addr mdm.channelTypeCtrl824, 0xFCFFFFFF'u32,
                extractBits(version, 25'u32, 24'u32) shl 24)
    updateReg32(addr mdm.channelTypeCtrl824, 0xFFFFFEFF'u32,
                extractBits(version, 26'u32, 26'u32) shl 8)
    updateReg32(addr mdm.channelTypeCtrl824, 0xFFFFFFFC'u32,
                heOrBandwidthProfile)
    updateReg32(addr macPhy.channelBandwidthCtrl310,
                0xFF8FFFFF'u32, spatialStreamCountMinus1 shl 20)
    updateReg32(addr mdm.channelTypeCtrl824, 0xFFFDFFFF'u32,
                ((version shr 4) and 0x20000'u32))
    updateReg32(addr mdm.versionFeatureCtrl800, 0xFFFFFF0F'u32,
                spatialStreamCountMinus1 shl 4)
    updateReg32(addr mdm.channelTypeCtrl824, 0xFFFDFFFF'u32,
                extractBits(version, 31'u32, 31'u32) shl 16)
    updateReg32(addr mdm.channelModeCtrl930, not 0x00000F00'u32, 0x00000100'u32)
    updateReg32(addr mdm.basebandDfeTimeout3bc, not 0'u32, 0x001E8480'u32)
    updateReg32(addr mdm.basebandDfeEnable414, not 0'u32, 0x00000100'u32)
    updateReg32(addr mdm.basebandRxPathCtrlC40, 0xFE0FFFFF'u32, 0x00E00000'u32)
    updateReg32(addr mdm.basebandRxPathCtrlC44, 0xFFF0FFFF'u32, 0x00001000'u32)

  proc bl808PhyProgramPreAgcRegs() =
    ## Deterministic typed port of librf_bl808.a:phy.c.o phy_init+0x318..0x43c.
    let mdm = wifiModemRegs()
    let bba = bbaAgcRegs()
    let crm = crmPhyClockRegs()
    updateReg32(addr mdm.preAgcCtrl324, 0xFFC0FFFF'u32, 0x002D0000'u32)
    updateReg32(addr mdm.preAgcSignal848, 0x00000000'u32, 0x10000000'u32)
    updateReg32(addr mdm.preAgcSignal844, 0x00000000'u32, 0x10000000'u32)
    updateReg32(addr mdm.preAgcTiming8d4, 0xFC00FFFF'u32, 0x008C0000'u32)
    updateReg32(addr mdm.preAgcTiming8d8, 0xFFFFFC00'u32, 0x0000006B'u32)
    updateReg32(addr mdm.preAgcTiming8d8, 0xFC00FFFF'u32, 0x00890000'u32)
    updateReg32(addr mdm.preAgcTiming8e0, 0xFFFFFC00'u32, 0x00000032'u32)
    updateReg32(addr mdm.preAgcTiming8e4, 0x00000000'u32, 0x00740000'u32)
    updateReg32(addr mdm.preAgcTiming8e0, 0xFC00FFFF'u32, 0x00860000'u32)
    updateReg32(addr mdm.bandwidth20MGuard814, 0xFFF00FFF'u32, 0x0000A000'u32)
    updateReg32(addr mdm.preAgcDetect894, 0xFFEFFFFF'u32, 0x00100000'u32)
    updateReg32(addr mdm.bandwidth20MEnable834, 0xFFFFFFEF'u32, 0x00000000'u32)
    updateReg32(addr crm.rfClockMux10, 0xF7FFFFFF'u32, 0x08000000'u32)
    updateReg32(addr bba.macActiveC01c, 0x00000000'u32, 0x000000A0'u32)
    updateReg32(addr bba.agcCoreCtrl100, 0xFFFF80FF'u32, 0x00005000'u32)
    updateReg32(addr bba.agcCoreCtrl100, 0xFFFFFF80'u32, 0x00000050'u32)
    updateReg32(addr bba.agcCoreTableC80c, 0x00FFFFFF'u32, 0xA8000000'u32)
    updateReg32(addr bba.pdGain390, 0xFFFFEFFF'u32, 0x00001000'u32)
    updateReg32(addr crm.rfClockMux10, 0xDFFFFFFF'u32, 0x20000000'u32)

  proc bl808PhyProgramAgcCopyTailRegs() =
    ## phy_init+0x470..0x49c: release AGC copy window and restore clock mux.
    let bba = bbaAgcRegs()
    let crm = crmPhyClockRegs()
    updateReg32(addr bba.pdGain390, 0xFFFFEFFF'u32, 0x00000000'u32)
    updateReg32(addr bba.pdGain390, 0xFFFEFFFF'u32, 0x00010000'u32)
    updateReg32(addr bba.pdGain390, 0xFFFFFBFF'u32, 0x00000000'u32)
    updateReg32(addr crm.rfClockMux10, 0xDFFFFFFF'u32, 0x00000000'u32)

  proc bl808PhyProgramAgcCoreRegs() =
    ## Deterministic typed port of librf_bl808.a:phy.c.o phy_init+0x4ba..0x938.
    let bba = bbaAgcRegs()
    updateReg32(addr bba.agcCoreWindow3a4, 0xFFFFFF00'u32, 0x00000000'u32)
    updateReg32(addr bba.agcCoreWindow3a4, 0xFFFF00FF'u32, 0x00000000'u32)
    updateReg32(addr bba.agcCoreDetect394, 0xFF00FFFF'u32, 0x00F80000'u32)
    updateReg32(addr bba.agcCoreDetect398, 0xFFFF00FF'u32, 0x00009E00'u32)
    updateReg32(addr bba.macActiveB3c4, 0xFFFFFF00'u32, 0x000000CE'u32)
    updateReg32(addr bba.agcCoreProfile364, 0xE0FFFFFF'u32, 0x08000000'u32)
    updateReg32(addr bba.agcCoreProfile364, 0xFFC0FFFF'u32, 0x003C0000'u32)
    updateReg32(addr bba.agcCoreProfile364, 0xFFFFC0FF'u32, 0x00003A00'u32)
    updateReg32(addr bba.agcCoreProfile364, 0xFFFFFFC0'u32, 0x0000003B'u32)
    updateReg32(addr bba.macActiveB368, 0xFFC00FFF'u32, 0x00270000'u32)
    updateReg32(addr bba.macActiveB368, 0xFFFFFC00'u32, 0x00000270'u32)
    updateReg32(addr bba.pdComp36c, 0xFFFFFF00'u32, 0x00000010'u32)
    updateReg32(addr bba.pdComp36c, 0xFFFFF8FF'u32, 0x00000500'u32)
    updateReg32(addr bba.pdComp36c, 0xFF00FFFF'u32, 0x00200000'u32)
    updateReg32(addr bba.pdComp36c, 0xF8FFFFFF'u32, 0x05000000'u32)
    updateReg32(addr bba.agcCoreProfile370, 0xFF80FFFF'u32, 0x00580000'u32)
    updateReg32(addr bba.pdSlope3c0, 0x00FFFFFF'u32, 0x18000000'u32)
    updateReg32(addr bba.macActiveB3c4, 0xFF00FFFF'u32, 0x00E00000'u32)
    updateReg32(addr bba.macActiveB3c4, 0x00FFFFFF'u32, 0xDC000000'u32)
    updateReg32(addr bba.macActiveB3a0, 0xFFFFFF00'u32, 0x0000009D'u32)
    updateReg32(addr bba.pdSlope3c0, 0xFFFFFF00'u32, 0x000000B0'u32)
    updateReg32(addr bba.agcCoreStage0B380, 0xFFF03FFF'u32, 0x000F8000'u32)
    updateReg32(addr bba.agcCoreStage0B380, 0xFC0FFFFF'u32, 0x03700000'u32)
    updateReg32(addr bba.agcCoreStage0B380, 0x03FFFFFF'u32, 0x04000000'u32)
    updateReg32(addr bba.agcCoreStage0B380, 0xFFFFDFFF'u32, 0x00000000'u32)
    updateReg32(addr bba.agcCoreStage0B380, 0xFFFFE3FF'u32, 0x00000400'u32)
    updateReg32(addr bba.macActiveB384, 0x03FFFFFF'u32, 0xE4000000'u32)
    updateReg32(addr bba.macActiveB384, 0xFC0FFFFF'u32, 0x03700000'u32)
    updateReg32(addr bba.macActiveB384, 0xFFF03FFF'u32, 0x00050000'u32)
    updateReg32(addr bba.macActiveB384, 0xFFFFDFFF'u32, 0x00000000'u32)
    updateReg32(addr bba.macActiveB384, 0xFFFFE3FF'u32, 0x00001800'u32)
    updateReg32(addr bba.agcCoreStage2B388, 0x03FFFFFF'u32, 0x3C000000'u32)
    updateReg32(addr bba.agcCoreStage2B388, 0xFC0FFFFF'u32, 0x01700000'u32)
    updateReg32(addr bba.agcCoreStage2B388, 0xFFF03FFF'u32, 0x000A8000'u32)
    updateReg32(addr bba.agcCoreStage2B388, 0xFFFFDFFF'u32, 0x00000000'u32)
    updateReg32(addr bba.agcCoreStage2B388, 0xFFFFE3FF'u32, 0x00001400'u32)
    updateReg32(addr bba.macActiveB38c, 0x03FFFFFF'u32, 0x64000000'u32)
    updateReg32(addr bba.macActiveB38c, 0xFC0FFFFF'u32, 0x03600000'u32)
    updateReg32(addr bba.macActiveB38c, 0xFFF03FFF'u32, 0x000E0000'u32)
    updateReg32(addr bba.macActiveB38c, 0xFFFFE3FF'u32, 0x00001400'u32)
    updateReg32(addr bba.pdCompC830, 0x03FFFFFF'u32, 0xFC000000'u32)
    updateReg32(addr bba.pdCompC830, 0xFC0FFFFF'u32, 0x00100000'u32)
    updateReg32(addr bba.pdCompC830, 0xFFF03FFF'u32, 0x000D8000'u32)
    updateReg32(addr bba.pdCompC830, 0xFFFFE3FF'u32, 0x00001400'u32)
    updateReg32(addr bba.pdCompRampC838, 0x7FFFFFFF'u32, 0x80000000'u32)
    updateReg32(addr bba.pdCompRampC838, 0xFFF80000'u32, 0x00000040'u32)
    updateReg32(addr bba.pdCompRampC83c, 0x7FFFFFFF'u32, 0x80000000'u32)
    updateReg32(addr bba.pdCompRampC83c, 0xFFF00000'u32, 0x00000040'u32)
    updateReg32(addr bba.pdCompRampC840, 0x7FFFFFFF'u32, 0x80000000'u32)
    updateReg32(addr bba.pdCompRampC840, 0xFFC00000'u32, 0x00000036'u32)
    updateReg32(addr bba.agcCoreEnable004, 0x00000000'u32, 0x00000001'u32)
    updateReg32(addr bba.pdGain390, 0xFFFFFFFC'u32, 0x00000001'u32)
    updateReg32(addr bba.macActiveB3bc, 0x00000000'u32, 0x001E8480'u32)
    updateReg32(addr bba.agcCoreTimeout414, 0xFFFFFFFF'u32, 0x00000100'u32)

  var phyRxGainOffsetVsTemperature = -128'i8

  proc phyRxGainByte(index: int, offset: int8): uint32 {.inline.} =
    uint8(int16(PhyRxGainTable[index]) + int16(offset)).uint32

  proc rc2_config_rxgain*(offset: int8) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:phy.c.o rc2_config_rxgain.
    ## Vendor phy_init calls this with offset 0 after AGC core programming.
    if phyRxGainOffsetVsTemperature == offset:
      return
    phyRxGainOffsetVsTemperature = offset
    let mdm = wifiModemRegs()
    updateReg32(addr mdm.rxGainTable0C080,
                0x00000000'u32,
                phyRxGainByte(0, offset) or
                (phyRxGainByte(1, offset) shl 8) or
                (phyRxGainByte(2, offset) shl 16) or
                (phyRxGainByte(3, offset) shl 24))
    updateReg32(addr mdm.rxGainTable1C084,
                0x00000000'u32,
                phyRxGainByte(4, offset) or
                (phyRxGainByte(5, offset) shl 8) or
                (phyRxGainByte(6, offset) shl 16) or
                (phyRxGainByte(7, offset) shl 24))
    updateReg32(addr mdm.rxGainTable2C088, 0xFFFFFF00'u32,
                phyRxGainByte(8, offset))

  proc bl808PhyProgramRxTailRegs() =
    ## phy_init+0x942..0x964: final receive-path RF/AGC writes after
    ## rc2_config_rxgain and before bba_init.
    let rf = rfRegs()
    let mdm = wifiModemRegs()
    updateReg32(addr rf.channelTuneCtrl26c, 0xC00FFFFF'u32, 0x05000000'u32)
    updateReg32(addr mdm.rxGainTailCtrlC018, 0xFFFFFC00'u32, 0x00000050'u32)

  proc bl808MdmSetChannel(primFreq, centerFreq1, chanType: uint32) =
    let mdm = wifiModemRegs()
    let macPhy = macPhyCtrlRegs()
    crm_mdm_reset()
    if primFreq != 0'u32 and centerFreq1 != 0'u32:
      let ratio = ((centerFreq1 shl 15) div primFreq) and 0x7FFF'u32
      updateReg32(addr mdm.channelCenterRatio84c, 0xFFFF8000'u32, ratio)
    updateReg32(addr mdm.channelTypeCtrl824, 0xFCFFFFFF'u32, chanType shl 24)
    updateReg32(addr macPhy.channelBandwidthCtrl310,
                0xFFFCFFFF'u32, chanType shl 16)
    if chanType == 0'u32:
      volatileStore(addr mdm.bandwidth20MProfile820, 0x0000130D'u32)
      volatileStore(addr mdm.channelTypeCtrl824, 0x0000010D'u32)
      volatileStore(addr mdm.bandwidth20MProfile830, 0x00001B0F'u32)
      volatileStore(addr mdm.bandwidth20MSignal83c, 0x04920492'u32)
      volatileStore(addr mdm.bandwidth20MSignal840, 0x03310000'u32)
      volatileStore(addr mdm.bandwidth20MFilter860, 0x00007F03'u32)
      volatileStore(addr mdm.bandwidth20MGate874, 0x08000000'u32)
      updateReg32(addr mdm.bandwidth20MEnable834, 0xFFFFFFFE'u32, 0x00000001'u32)
      updateReg32(addr mdm.bandwidth20MGuard814, not 0x0000A000'u32, 0'u32)

  proc pulsePhyChannelRfWindow() =
    ## Vendor phy_set_channel pulses this modem register immediately before
    ## rf_set_channel/rfc_config_channel.
    let reg = addr wifiModemRegs().phyChannelPulse888
    volatileStore(reg, 0x00000111'u32)
    for _ in 0 ..< 10:
      discard volatileLoad(reg)
    volatileStore(reg, 0'u32)

  proc phy_mdm_isr*() {.exportc, cdecl.} =
    let mdm = wifiModemRegs()
    let status = volatileLoad(addr mdm.intStatusB41c)
    volatileStore(addr mdm.intAckB420, status)
    if (status and 0x00000100'u32) != 0'u32:
      pulsePhyChannelRfWindow()

  proc phy_rc_isr*() {.exportc, cdecl.} =
    let mdm = wifiModemRegs()
    let status = volatileLoad(addr mdm.intStatusB41c)
    volatileStore(addr mdm.intAckB420, status)

  proc phy_get_version*(versionOut: pointer, buf: pointer) {.exportc, cdecl.} =
    if versionOut != nil:
      cast[ptr uint32](versionOut)[] = modemVersionReg()
    if buf != nil:
      cast[ptr uint32](buf)[] = volatileLoad(addr wifiModemRegs().versionScratch3c)

  proc phy_get_channel_raw*(info: pointer, index: uint8)
      {.exportc: "phy_get_channel", cdecl.} =
    discard index
    if info == nil:
      return
    let dst = cast[ptr UncheckedArray[uint32]](info)
    let env = phyEnvViewPtr()
    dst[0] = volatileLoad(addr env.channelBandType).uint32 or
      (volatileLoad(addr env.primaryFreq).uint32 shl 16)
    dst[1] = volatileLoad(addr env.centerFreq1).uint32 or
      (volatileLoad(addr env.centerFreq2OrTxPower).uint32 shl 16)

  proc phy_get_ntx*(): uint8 {.exportc, cdecl.} =
    (((modemVersionReg() shr 4) and 0xF'u32) - 1'u32).uint8

  proc phy_get_nss*(): uint8 {.exportc, cdecl.} =
    (((modemVersionReg() shr 8) and 0xF'u32) - 1'u32).uint8

  proc phy_get_nrx*(): uint8 {.exportc, cdecl.} =
    ((modemVersionReg() and 0xF'u32) - 1'u32).uint8

  proc phy_get_bw*(): uint8 {.exportc, cdecl.} =
    ((modemVersionReg() shr 24) and 0x3'u32).uint8

  proc phy_vht_supported*(): bool {.exportc, cdecl.} =
    ## Port of librf_bl808.a:phy.c.o phy_vht_supported+0x0..0x1a.
    ## Vendor returns true when modem-version bit 21 is set, or when the
    ## modem bandwidth capability field at bits [25:24] is nonzero.
    let version = modemVersionReg()
    ((version shr 21) and 1'u32) != 0'u32 or
      ((version shr 24) and 0x3'u32) != 0'u32

  proc phy_he_supported*(): bool {.exportc, cdecl.} =
    (modemVersionReg() and (1'u32 shl 20)) != 0

  proc phy_uf_supported*(): bool {.exportc, cdecl.} =
    false

  proc phy_uf_enable*() {.exportc, cdecl.} =
    discard

  proc phy_ldpc_tx_supported*(): bool {.exportc, cdecl.} =
    ## librf_bl808.a:phy.c.o exports LDPC support predicates only; no WiFi
    ## LDPC memory image is present in the BL808 RF archive.
    (modemVersionReg() and (1'u32 shl 24)) != 0

  proc phy_ldpc_rx_supported*(): bool {.exportc, cdecl.} =
    (modemVersionReg() and (1'u32 shl 25)) != 0

  proc phy_bfmee_supported*(): bool {.exportc, cdecl.} =
    (modemVersionReg() and (1'u32 shl 26)) != 0

  proc phy_bfmer_supported*(): bool {.exportc, cdecl.} =
    (modemVersionReg() and (1'u32 shl 27)) != 0

  proc phy_mu_mimo_rx_supported*(): bool {.exportc, cdecl.} =
    (modemVersionReg() and (1'u32 shl 28)) != 0

  proc phy_mu_mimo_tx_supported*(): bool {.exportc, cdecl.} =
    (modemVersionReg() and (1'u32 shl 31)) != 0

  proc phy_get_rf_gain_idx*(txPowerElem: pointer, rateParam: pointer)
      {.exportc, cdecl.} =
    if txPowerElem == nil or rateParam == nil:
      return
    var power = cast[ptr int8](txPowerElem)[]
    if power > 22'i8:
      power = 22'i8
    elif power < -10'i8:
      power = -10'i8
    cast[ptr int8](txPowerElem)[] = power
    cast[ptr uint8](rateParam)[] = cast[uint8](power)

  proc phy_get_rf_gain_capab*(maxGain: pointer, minGain: pointer)
      {.exportc, cdecl.} =
    if maxGain != nil:
      cast[ptr int8](maxGain)[] = 22'i8
    if minGain != nil:
      cast[ptr int8](minGain)[] = -10'i8

  proc phy_get_antenna_set*(): uint8 {.exportc, cdecl.} =
    ## Port of librf_bl808.a:phy.c.o phy_get_antenna_set+0x0..0x20.
    ## Vendor returns a bitmask with one bit per configured RX chain.
    let rxChainCount = modemVersionReg() and 0xF'u32
    if rxChainCount == 0'u32:
      0'u8
    else:
      uint8((1'u32 shl rxChainCount) - 1'u32)

  proc phy_switch_antenna_paths*(): uint32 {.exportc, cdecl.} =
    0'u32

  proc phy_get_channel_switch_dur*(): uint32 {.exportc, cdecl.} =
    1000'u32

  proc phy_stop*() {.exportc, cdecl.} =
    discard regRead(MACHW_STATE_CNTRL_REG)

  proc phy_mdm_reset*() {.exportc, cdecl.} =
    crm_mdm_reset()

  proc phy_set_aid*(aid: uint16) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:phy.c.o phy_set_aid+0x0..0x4a.
    ## Vendor asserts when hestaid does not fit the 11-bit modem field, then
    ## continues to write the original value through the assert path.
    if (aid.uint32 and not 0x7FF'u32) != 0'u32:
      wrapPhyAssertErr("phy.c",
        "(((uint32_t)hestaid << 0) & ~((uint32_t)0x000007FF)) == 0",
        0x35C3.cint)
    let mdm = wifiModemRegs()
    volatileStore(addr mdm.aid, aid.uint32)
    volatileStore(addr mdm.aidMaskLo, 0'u32)
    volatileStore(addr mdm.aidMaskHi, 0x7FF'u32)

  proc phy_set_group_id_info*(membership: pointer, userPosition: pointer)
      {.exportc, cdecl.} =
    let mdm = wifiModemRegs()
    if membership != nil:
      let src = cast[ptr UncheckedArray[uint32]](membership)
      volatileStore(addr mdm.groupMembership0, src[0])
      volatileStore(addr mdm.groupMembership1, src[1])
    if userPosition != nil:
      let src = cast[ptr UncheckedArray[uint32]](userPosition)
      for i in 0 ..< 4:
        volatileStore(addr mdm.userPosition[i], src[i])

  proc phy_update_power_table*() {.exportc, cdecl.} =
    let channelType = (volatileLoad(addr phyEnvViewPtr().channelBandType) shr 8).uint8
    trpc_update_power(cast[pointer](channelType.uint))

  proc phyEnvCenter2Word(channel: ptr ChanCtxtDefView): uint16 {.inline.} =
    if channel != nil and channel.centerFreq2 == 0'u16:
      channel.txPower.uint16
    else:
      channel.centerFreq2

  when defined(bl808WifiUseBl808Rf):
    proc rfPriApplyWb03RfcEntryBaseline()
    proc rfPhyTraceCheckpoint(phase: uint32)

  proc phy_set_channel*(channel: ptr ChanCtxtDefView, force: uint32)
      {.exportc, cdecl.} =
    if channel == nil or force != 0'u32:
      return
    let env = phyEnvViewPtr()
    let bandAndType = volatileLoad(addr env.channelBandType)
    let currentType = (bandAndType shr 8).uint8
    let currentPrim = volatileLoad(addr env.primaryFreq)
    let currentCenter = volatileLoad(addr env.centerFreq1)
    let currentCenter2 = volatileLoad(addr env.centerFreq2OrTxPower)
    let nextCenter2 = phyEnvCenter2Word(channel)
    if bandAndType == cast[ptr uint16](channel)[] and
        currentType == channel.chanType and
        currentPrim == channel.primFreq and
        currentCenter == channel.centerFreq1 and
        currentCenter2 == nextCenter2:
      return
    crm_clk_set(channel.chanType.uint32)
    bl808MdmSetChannel(channel.primFreq.uint32, channel.centerFreq1.uint32,
                       channel.chanType.uint32)
    rfc_config_bandwidth(channel.chanType.uint32)
    when defined(bl808WifiUseBl808Rf):
      rfPriApplyWb03RfcEntryBaseline()
      pulsePhyChannelRfWindow()
    rfc_config_channel(channel.centerFreq1.uint32)
    when defined(bl808WifiUseBl808Rf):
      rfPhyTraceCheckpoint(0x41'u32)
    volatileStore(addr env.channelBandType, cast[ptr uint16](channel)[])
    volatileStore(addr env.primaryFreq, channel.primFreq)
    volatileStore(addr env.centerFreq1, channel.centerFreq1)
    volatileStore(addr env.centerFreq2OrTxPower, nextCenter2)
    volatileStore(addr env.txPowerAndReserved,
                  channel.txPower.uint16 or (channel.reserved.uint16 shl 8))
    when defined(bl808WifiUseBl808Rf):
      rfPhyTraceCheckpoint(0x42'u32)
    if currentType != channel.chanType:
      when defined(bl808WifiUseBl808Rf):
        rfPhyTraceCheckpoint(0x43'u32)
      trpc_update_power(cast[pointer](channel.chanType.uint))
      when defined(bl808WifiUseBl808Rf):
        rfPhyTraceCheckpoint(0x44'u32)

  proc phyInitValidateClock() =
    ## phy_init+0x16..0x52: CRM setup and clock-count assert.
    inc nimFwDbgPhyInitCount
    nimFwDbgPhyInitPhase = 1'u32
    crm_init()
    let version = modemVersionReg()
    let clkCount = phyClockCountFromVersion(version)
    nimFwDbgPhyModemVersion = version
    nimFwDbgPhyClockCount = clkCount
    if clkCount != 32'u32:
      wrapPhyAssertErr("clk_cnt", "phy.c", 586)

  proc phyInitProgramBasebandAndAgc() =
    ## phy_init+0x5a..0x938: modem-derived baseband fields, AGC memory copy,
    ## and the recovered AGC core table.
    nimFwDbgPhyInitPhase = 2'u32
    crm_mdm_reset()
    bl808PhyProgramRecoveredRegs()
    bl808PhyProgramPreAgcRegs()
    copyAgcMemory()
    bl808PhyProgramAgcCopyTailRegs()
    bl808PhyProgramAgcCoreRegs()

  proc phyInitProgramReceiveTail() =
    ## phy_init+0x93c..0x964 plus BBA/TRPC setup.
    nimFwDbgPhyInitPhase = 4'u32
    rc2_config_rxgain(0'i8)
    bl808PhyProgramRxTailRegs()
    bba_init()
    trpc_init()

  proc phyInitProgramInitialChannel() =
    ## phy_init+0x976..0x9a2 initializes 20 MHz channel-1 modem/RF state:
    ## crm_clk_set(0), mdm_set_channel.constprop.0(2412, 2412, 0),
    ## rfc_config_bandwidth(0), rfc_config_channel(2412). The following
    ## phy_init+0x9a6..0x9fc block mirrors cfg/env words into phy_env.
    nimFwDbgPhyInitPhase = 5'u32
    crm_clk_set(0'u32)
    var initial = ChanCtxtDefView(
      band: 1'u8,
      chanType: 0'u8,
      primFreq: 2412'u16,
      centerFreq1: 2412'u16,
      centerFreq2: 0'u16,
      txPower: 0xFF'u8,
      reserved: 0x0F'u8)
    bl808MdmSetChannel(initial.primFreq.uint32, initial.centerFreq1.uint32,
                       initial.chanType.uint32)
    rfc_config_bandwidth(0'u32)
    when defined(bl808WifiUseBl808Rf):
      rfPriApplyWb03RfcEntryBaseline()
      pulsePhyChannelRfWindow()
    rfc_config_channel(initial.centerFreq1.uint32)
    trpc_update_power(nil)
    let env = phyEnvViewPtr()
    volatileStore(addr env.channelBandType, cast[ptr uint16](addr initial)[])
    volatileStore(addr env.primaryFreq, initial.primFreq)
    volatileStore(addr env.centerFreq1, initial.centerFreq1)
    volatileStore(addr env.centerFreq2OrTxPower, phyEnvCenter2Word(addr initial))
    volatileStore(addr env.txPowerAndReserved,
                  initial.txPower.uint16 or (initial.reserved.uint16 shl 8))

  proc phy_init*(cfg: pointer) {.exportc, cdecl.} =
    phyInitValidateClock()
    phyInitProgramBasebandAndAgc()
    phyInitProgramReceiveTail()
    phyInitProgramInitialChannel()
    copyPhyInitCfg(cfg)
    nimFwDbgPhyInitPhase = 6'u32

  var wlCalGlobal* {.exportc: "wl_cal".}: pointer
  var wlEnvGlobal* {.exportc: "wl_env".}: pointer
  var rfCalibDataGlobal* {.exportc: "rf_calib_data".}: pointer
  var wifiBl808WlRmem {.align: 4.}: WlRfMemoryOverlay
  var wifiBl808RfInited: uint32

  template wlLowPowerStatusEnv(): ptr WlLowPowerStatusEnv =
    cast[ptr WlLowPowerStatusEnv](wlEnvGlobal)

  var trpcTxpwrVsRateTable* {.exportc: "txpwr_vs_rate_table".}: array[50, uint8] = [
    0x15'u8, 0x15'u8, 0x15'u8, 0x15'u8, 0x00'u8, 0x00'u8, 0x00'u8, 0x00'u8, 0x00'u8, 0x00'u8,
    0x14'u8, 0x14'u8, 0x14'u8, 0x14'u8, 0x14'u8, 0x14'u8, 0x12'u8, 0x12'u8, 0x00'u8, 0x00'u8,
    0x14'u8, 0x14'u8, 0x14'u8, 0x14'u8, 0x13'u8, 0x13'u8, 0x11'u8, 0x11'u8, 0x00'u8, 0x00'u8,
    0x12'u8, 0x12'u8, 0x12'u8, 0x12'u8, 0x12'u8, 0x10'u8, 0x10'u8, 0x10'u8, 0x10'u8, 0x10'u8,
    0x14'u8, 0x14'u8, 0x14'u8, 0x14'u8, 0x13'u8, 0x13'u8, 0x11'u8, 0x11'u8, 0x0F'u8, 0x0F'u8]
  var trpcEnv* {.align: 4, exportc: "trpc_env".}: array[2, uint32]

  proc trpcCopyTable(dstOffset: int, src: pointer, count: int) =
    if src == nil:
      return
    let bytes = cast[ptr UncheckedArray[uint8]](src)
    for i in 0 ..< count:
      trpcTxpwrVsRateTable[dstOffset + i] = bytes[i]

  proc trpcCopyFromWlCfg(dstOffset: int, cfgOffset: uint, count: int) =
    if wlCfgGlobal == nil:
      return
    trpcCopyTable(dstOffset, cast[pointer](cast[uint](wlCfgGlobal) + cfgOffset), count)

  proc trpcCopyTableOut(dst: pointer, srcOffset: int, count: int) =
    if dst == nil:
      return
    let bytes = cast[ptr UncheckedArray[uint8]](dst)
    for i in 0 ..< count:
      bytes[i] = trpcTxpwrVsRateTable[srcOffset + i]

  proc trpc_power_get*(powerTable: pointer) {.exportc, cdecl.} =
    ## Local replacement for the missing archive symbol used by bl_tpc_power_table_get.
    ## phy_trpc.c.o keeps 50 rate bytes; callers request the rate-power prefix.
    trpcCopyTableOut(powerTable, 0, 38)

  proc trpc_update_power_11b*(powerTable: pointer) {.exportc, cdecl.} =
    ## librf_bl808.a:phy_trpc.c.o trpc_update_power_11b+0x0..0x1a.
    trpcCopyTable(0, powerTable, 4)

  proc trpc_update_power_11g*(powerTable: pointer) {.exportc, cdecl.} =
    ## librf_bl808.a:phy_trpc.c.o trpc_update_power_11g+0x0..0x20.
    trpcCopyTable(10, powerTable, 8)

  proc trpc_update_power_11n*(powerTable: pointer) {.exportc, cdecl.} =
    ## librf_bl808.a:phy_trpc.c.o trpc_update_power_11n+0x0..0x20.
    trpcCopyTable(20, powerTable, 8)

  proc trpc_update_power_11ac*(powerTable: pointer) {.exportc, cdecl.} =
    ## librf_bl808.a:phy_trpc.c.o trpc_update_power_11ac+0x0..0x20.
    trpcCopyTable(30, powerTable, 10)

  proc trpc_update_power_11ax*(powerTable: pointer) {.exportc, cdecl.} =
    ## librf_bl808.a:phy_trpc.c.o trpc_update_power_11ax+0x0..0x20.
    trpcCopyTable(40, powerTable, 10)

  proc trpc_update_power*(powerTable: pointer) {.exportc, cdecl.} =
    ## librf_bl808.a:phy_trpc.c.o trpc_update_power+0x0..0xe4.
    ## The argument is a channel-type selector: nil uses the 20 MHz WL config
    ## rows; non-nil uses the alternate rows at 0x46 and 0x78.
    trpcCopyFromWlCfg(0, 0x32'u, 4)
    trpcCopyFromWlCfg(10, 0x36'u, 8)
    if powerTable == nil:
      trpcCopyFromWlCfg(20, 0x3E'u, 8)
      trpcCopyFromWlCfg(30, 0x6C'u, 10)
      trpcCopyFromWlCfg(40, 0x6C'u, 10)
    else:
      trpcCopyFromWlCfg(20, 0x46'u, 8)
      trpcCopyFromWlCfg(30, 0x78'u, 10)
      trpcCopyFromWlCfg(40, 0x78'u, 10)

  proc trpc_init() {.exportc, cdecl.} =
    ## librf_bl808.a:phy_trpc.c.o trpc_init is ret-only.
    discard

  proc trpc_get_default_power_idx(rateType: uint32, rateIdx: uint8): int8
      {.exportc: "trpc_get_default_power_idx", cdecl.} =
    ## librf_bl808.a:phy_trpc.c.o trpc_get_default_power_idx+0x0..0x1a.
    let idx = int(rateType) * 10 + int(rateIdx)
    if idx < 0 or idx >= trpcTxpwrVsRateTable.len:
      return 0'i8
    cast[int8]((trpcTxpwrVsRateTable[idx] shl 2) and 0xFC'u8)

  proc trpc_get_power_idx(powerTable: pointer, rateType: uint32, powerIdx: uint8): int8
      {.exportc: "trpc_get_power_idx", cdecl.} =
    ## librf_bl808.a:phy_trpc.c.o trpc_get_power_idx ignores its table/rate args.
    discard powerTable
    discard rateType
    cast[int8]((powerIdx shl 2) and 0xFC'u8)

  proc wlCfgSetU32(offset: int, value: uint32) =
    if wlCfgGlobal == nil:
      return
    let bytes = cast[ptr UncheckedArray[uint8]](wlCfgGlobal)
    bytes[offset] = uint8(value and 0xFF'u32)
    bytes[offset + 1] = uint8((value shr 8) and 0xFF'u32)
    bytes[offset + 2] = uint8((value shr 16) and 0xFF'u32)
    bytes[offset + 3] = uint8((value shr 24) and 0xFF'u32)

  proc wlCfgSetBytes(offset: int, value: uint8, count: int) =
    if wlCfgGlobal == nil:
      return
    let bytes = cast[ptr UncheckedArray[uint8]](wlCfgGlobal)
    for idx in 0 ..< count:
      bytes[offset + idx] = value

  proc seedWlCfgTxPowerDefaults() =
    ## These rows are the vendor wl_cfg backing store that trpc_update_power()
    ## copies into txpwr_vs_rate_table. A zeroed wl_cfg makes internal auth
    ## frames inherit TX power 0, while the vendor backend seeds 0x1c -> 0x70.
    wlCfgSetBytes(WlRfCfgPower11bOffset, WlRfCfgDefaultRatePower, 4)
    wlCfgSetBytes(WlRfCfgPower11gOffset, WlRfCfgDefaultRatePower, 8)
    wlCfgSetBytes(WlRfCfgPower11n20Offset, WlRfCfgDefaultRatePower, 8)
    wlCfgSetBytes(WlRfCfgPower11nAltOffset, WlRfCfgDefaultRatePower, 8)
    wlCfgSetBytes(WlRfCfgPower11ac20Offset, WlRfCfgDefaultRatePower, 10)
    wlCfgSetBytes(WlRfCfgPower11acAltOffset, WlRfCfgDefaultRatePower, 10)

  proc rf_pri_cfg_init() {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rf_pri.c.o rf_pri_cfg_init+0x0..0x7a.
    ## Initializes the RF-owned wl_cfg fields at offsets 0x10..0x30,
    ## 0x9c, 0xa1..0xbe, and 0xc0..0xc7.
    let cfg = cast[ptr WlRfConfig](wlCfgGlobal)
    if cfg == nil:
      return
    cfg.efuseTrimControl = 0x02000000'u32
    cfg.efuseTxGainComp = 0x01'u8
    cfg.efuseXtalCapCode0 = 0x80'u8
    cfg.efuseXtalCapCode1 = 0x80'u8
    cfg.efuseDfeTrim = 0x80'u8
    cfg.temperaturePowerCompPadding = 0'u16
    for item in cfg.channelPowerComp.mitems:
      item = 0'u8
    for item in cfg.channelLowPowerComp.mitems:
      item = 0'u8
    cfg.channelFreqSeedPair0 = 0x096C0100'u32
    cfg.channelFreqSeedPair1 = 0x098A097B'u32
    cfg.channelFreqSeedPair2 = 0x09A80999'u32
    cfg.temperaturePowerComp = 35'u8
    for item in cfg.channelFreqSeedPadding.mitems:
      item = 0'u32
    cfg.ratePowerTablePreamble = 0'u16
    cfg.ratePowerLimitDbm = 20'u8

  proc wl_rf_cfg_init*() {.exportc, cdecl.} =
    ## librf_bl808.a:wl_api.c.o wl_rf_cfg_init is a tail-call wrapper for
    ## rf_pri_cfg_init.
    let cfg = cast[ptr WlRfConfig](wlCfgGlobal)
    if cfg == nil:
      return
    seedWlCfgTxPowerDefaults()
    rf_pri_cfg_init()
    if Bl808WifiRfDeviceInfo == int(Bl808RfDeviceInfoWb03):
      # Vendor RF RXCAL reads raw wl_cfg+0xA8/+0xAC and uses them to program
      # RF70/RF1600. These bytes overlap the channel-comp table at wl_cfg+0xA1.
      wlCfgSetU32(WlRfCfgRxcalA8Offset, WlRfCfgWb03RxcalA8Default)
      wlCfgSetU32(WlRfCfgRxcalAcOffset, WlRfCfgWb03RxcalAcDefault)

  proc wl_wlan_power_table_update*() {.exportc, cdecl.} =
    ## librf_bl808.a:wl_api.c.o wl_wlan_power_table_update tail-calls
    ## phy_update_power_table.
    phy_update_power_table()

  proc wl_wlan_bb_reset*() {.exportc, cdecl.} =
    ## librf_bl808.a:wl_api.c.o wl_wlan_bb_reset tail-calls bba_reset.
    bba_reset()

  proc wl_wlan_bb_pre_proc*(rxVector: pointer) {.exportc, cdecl.} =
    ## librf_bl808.a:wl_api.c.o wl_wlan_bb_pre_proc tail-calls
    ## bba_rssi_correction.
    bba_rssi_correction(rxVector)

  proc wl_wlan_bb_post_proc*(rxVector: pointer; frameType: uint32)
      {.exportc, cdecl.} =
    ## librf_bl808.a:wl_api.c.o wl_wlan_bb_post_proc tail-calls bba_loop.
    bba_loop(rxVector, frameType)

  proc wl_wlan_rssi_get*(rxVector: pointer): int8 {.exportc, cdecl.} =
    ## Port of librf_bl808.a:wl_api.c.o wl_wlan_rssi_get+0x0..0x4.
    if rxVector == nil:
      return 0'i8
    cast[ptr UncheckedArray[int8]](rxVector)[5]

  proc wl_wlan_ppm_get*(rxVector: pointer): int8 {.exportc, cdecl.} =
    ## librf_bl808.a:wl_api.c.o wl_wlan_ppm_get tail-calls calc_ppm.
    calc_ppm(rxVector)

  proc wl_154_power_cfg_get*(): int8 {.exportc, cdecl.} =
    ## Port of librf_bl808.a:wl_api.c.o wl_154_power_cfg_get+0x0..0xc:
    ## return signed wl_cfg byte at offset 0xA0.
    let cfg = cast[ptr WlRfConfig](wlCfgGlobal)
    if cfg == nil:
      return 0'i8
    cast[int8](cfg.ratePowerTablePostamble[3])

  proc wl_bt_power_cfg_get*(index: uint32): int8 {.exportc, cdecl.} =
    ## Port of librf_bl808.a:wl_api.c.o wl_bt_power_cfg_get+0x0..0x18:
    ## return signed wl_cfg[0x9D + index] for indices 0..2, else -4.
    if index > 2'u32:
      return -4'i8
    let cfg = cast[ptr WlRfConfig](wlCfgGlobal)
    if cfg == nil:
      return 0'i8
    cast[ptr UncheckedArray[int8]](addr cfg.ratePowerTablePostamble[0])[int(index)]

  proc wl_ble_power_cfg_get*(): int8 {.exportc, cdecl.} =
    ## Port of librf_bl808.a:wl_api.c.o wl_ble_power_cfg_get+0x0..0xc:
    ## return signed wl_cfg byte at offset 0x9C.
    let cfg = cast[ptr WlRfConfig](wlCfgGlobal)
    if cfg == nil:
      return 0'i8
    cast[int8](cfg.ratePowerLimitDbm)

  proc wlInvalidPowerCfgIndex(): int8 {.noinline.} =
    ## wl_api.c.o wl_wlan_power_cfg_get branches invalid rate classes/indices
    ## to a local infinite loop at +0x26 instead of returning a fallback.
    while true:
      discard
    0'i8

  proc wl_wlan_power_cfg_get*(rateClass, rateIndex: uint32): int8
      {.exportc, cdecl.} =
    ## Port of librf_bl808.a:wl_api.c.o wl_wlan_power_cfg_get+0x0..0x6a.
    ## The vendor code validates the rate class and per-class index, maps
    ## 11b indices 4..11 to the 0..7 DSSS table range, then tail-calls
    ## trpc_get_default_power_idx(group, adjustedIndex).
    case rateClass
    of 0'u32, 1'u32:
      if rateIndex >= 12'u32:
        return wlInvalidPowerCfgIndex()
      var adjusted = rateIndex
      var group = 0'u32
      if rateIndex > 3'u32:
        adjusted = (rateIndex - 4'u32) and 0xFF'u32
        group = 1'u32
      trpc_get_default_power_idx(group, adjusted.uint8)
    of 2'u32, 3'u32:
      if rateIndex > 7'u32:
        return wlInvalidPowerCfgIndex()
      trpc_get_default_power_idx(2'u32, rateIndex.uint8)
    of 4'u32:
      if rateIndex > 9'u32:
        return wlInvalidPowerCfgIndex()
      trpc_get_default_power_idx(3'u32, rateIndex.uint8)
    of 5'u32, 6'u32, 7'u32:
      if rateIndex >= 10'u32:
        return wlInvalidPowerCfgIndex()
      trpc_get_default_power_idx(4'u32, rateIndex.uint8)
    else:
      wlInvalidPowerCfgIndex()

  proc wl_rf_tcal_handler*(temperatureC: int32): int32 {.exportc, cdecl.} =
    ## Port of librf_bl808.a:wl_api.c.o wl_rf_tcal_handler+0x0..0x22:
    ## apply both WLAN and BZ temperature compensation, then return 1.
    rf_pri_set_temp_comp(temperatureC)
    rf_pri_set_bz_temp_comp(temperatureC)
    1'i32

  proc wl_rf_tcal_period_get*(): int32 {.exportc, cdecl.} =
    ## librf_bl808.a:wl_api.c.o wl_rf_tcal_period_get returns constant 1.
    1'i32

  proc wl_bz_rx_optimize*(channelMhz: uint32) {.exportc, cdecl.} =
    ## librf_bl808.a:wl_api.c.o wl_bz_rx_optimize tail-calls
    ## rf_pri_bz_optimize.
    rf_pri_bz_optimize(channelMhz)

  proc wl_bz_rx_optimize_restore*() {.exportc, cdecl.} =
    ## librf_bl808.a:wl_api.c.o wl_bz_rx_optimize_restore tail-calls
    ## rf_pri_bz_optimize_restore.
    rf_pri_bz_optimize_restore()

  proc wl_rf_set_bz_target_power_table*(targetPowerDbm: int32)
      {.exportc, cdecl.} =
    ## librf_bl808.a:wl_api.c.o wl_rf_set_bz_target_power_table tail-calls
    ## rf_pri_input_bz_target_power.
    rf_pri_input_bz_target_power(targetPowerDbm)

  proc wl_rf_set_channel_pwr_comp*(channelIndex: uint32) {.exportc, cdecl.} =
    ## librf_bl808.a:wl_api.c.o wl_rf_set_channel_pwr_comp tail-calls
    ## rf_pri_set_channel_pwr_comp.
    rf_pri_set_channel_pwr_comp(channelIndex)

  proc wl_cfg_get(rmem: ptr WlRfMemoryOverlay): ptr WlRfConfig {.exportc, cdecl.} =
    if rmem == nil:
      wlCfgGlobal = nil
      wlCalGlobal = nil
      wlEnvGlobal = nil
      rfCalibDataGlobal = nil
      return nil
    wlCfgGlobal = cast[pointer](addr rmem.config)
    wlCalGlobal = cast[pointer](addr rmem.calib[0])
    wlEnvGlobal = cast[pointer](addr rmem.env[0])
    rfCalibDataGlobal = wlCalGlobal
    if rmem.config.status != WlRfConfigMagic:
      rmem.config.xtalfreqHz = 40_000_000'u32
      rmem.config.xtalCapCodes = 0x2020'u16
      rmem.config.capcodeGetCallback = nil
      rmem.config.capcodeSetCallback = nil
    wl_rf_cfg_init()
    addr rmem.config

  proc wl_rmem_size_get*(): uint32 {.exportc, cdecl.} =
    sizeof(WlRfMemoryOverlay).uint32

  proc wl_env_get*(rmem: ptr WlRfMemoryOverlay): pointer {.exportc, cdecl.} =
    if rmem == nil:
      wlCfgGlobal = nil
      wlCalGlobal = nil
      wlEnvGlobal = nil
      rfCalibDataGlobal = nil
      return nil
    wlCfgGlobal = cast[pointer](addr rmem.config)
    wlCalGlobal = cast[pointer](addr rmem.calib[0])
    wlEnvGlobal = cast[pointer](addr rmem.env[0])
    rfCalibDataGlobal = wlCalGlobal
    wlEnvGlobal

  template pdsSleepRetainMaskReg(): ptr uint32 =
    cast[ptr uint32](0x249000E0'u)

  proc wlLpXtalIndex(xtalfreqHz: uint32): uint32 {.inline.} =
    ## Port of librf_bl808.a:wl_api.c.o wl_lp_init+0x44..0x90.
    case xtalfreqHz
    of WlXtal26M:
      1'u32
    of WlXtal32M:
      2'u32
    of WlXtal38P4M:
      3'u32
    of WlXtal40M:
      4'u32
    of WlXtal52M:
      5'u32
    else:
      4'u32

  proc wlLpDefaultInit() =
    ## Port of librf_bl808.a:lp_phy.c.o lp_default_init+0x0..0xb4.
    let rf = rfRegs()
    let crm = crmPhyClockRegs()
    let aux = rfAuxCtrlRegs()
    volatileStore(addr rf.modemPathEnable504, 0x002C0000'u32)
    volatileStore(addr rf.reserved508, 0x003C0002'u32)
    volatileStore(addr rf.pdCompLatchCtrl50c, 0x003FFC02'u32)
    volatileStore(pdsSleepRetainMaskReg(), 0xFFFFFF00'u32)
    volatileStore(addr crm.rfClockMux10, 0'u32)
    volatileStore(addr crm.reserved014, 0'u32)
    let cfg = cast[ptr WlRfConfig](wlCfgGlobal)
    if cfg == nil or cfg.apiMode != 1'u8:
      return
    updateReg32(addr rf.rfcSequencerBias400, 0xFF7FFFFF'u32, 0'u32)
    updateReg32(addr rf.rfcSequencerBias400, 0xFFFF7FFF'u32, 0'u32)
    updateReg32(addr rf.rfcSequencerBias400, 0xFFFFBFFF'u32, 0'u32)
    updateReg32(addr rf.rfcSequencerBias400, not 0x200'u32, 0'u32)
    updateReg32(addr rf.rfcSequencerBias400, not 0x100'u32, 0'u32)
    updateReg32(addr aux.rfcAuxPathSelect540, not 0'u32, 0x00000F00'u32)
    updateReg32(addr aux.rfcAuxPathGate544, not 0'u32, 0x00000004'u32)

  proc wlLpProgramEarlyPhyRegs(xtalIndex: uint32) =
    ## Port of librf_bl808.a:lp_phy.c.o lp_phy_init+0x0..0x16a.
    ## This is the common low-power PHY register phase before the
    ## apiMode-specific branch at lp_phy_init+0x184.
    let rf = rfRegs()
    let idx =
      if xtalIndex < rfcXtalCfg.len.uint32: xtalIndex
      else: wlLpXtalIndex(WlXtal40M)
    let xtalCfg = rfcXtalCfg[idx]
    updateReg32(addr rf.xtalControlCode1c0, 0xFFFFF000'u32,
                xtalCfg.xtalControlCode and 0x00000FFF'u32)
    updateReg32(addr rf.xtalDividerConfig1c4, 0xE0000000'u32,
                xtalCfg.xtalDividerConfig and 0x1FFFFFFF'u32)
    updateReg32(addr rf.xtalCountWindowMin1c8, 0xFFF00000'u32,
                xtalCfg.xtalCountWindowMin and 0x000FFFFF'u32)
    updateReg32(addr rf.xtalCountWindowMax1cc, 0xFFF00000'u32,
                xtalCfg.xtalCountWindowMax and 0x000FFFFF'u32)

    if wlCalGlobal != nil:
      let calWords = cast[ptr UncheckedArray[uint32]](wlCalGlobal)
      for i in 0 ..< rf.vcoPairTable13c.len:
        volatileStore(addr rf.vcoPairTable13c[i], calWords[i + 7])
      volatileStore(addr rf.vcoPair2484Mhz164, calWords[17])

    updateReg32(addr rf.baseCtrl1, 0xFFFFF7FF'u32, 0'u32)
    updateReg32(addr rf.channelTuneCtrl26c, not 0x00000008'u32, 0'u32)
    updateReg32(addr rf.channelTuneStrobe268, 0xFFFF0000'u32, 0x00001040'u32)
    updateReg32(addr rf.baseCtrl1, not 0'u32, 0x00000002'u32)
    updateReg32(addr rf.synthCtrl2c, not 0'u32, 0x00000002'u32)
    updateReg32(addr rf.synthCtrl2c, 0xFFFFBFFF'u32, 0'u32)
    updateReg32(addr rf.synthCtrl2c, not 0x00000020'u32, 0'u32)
    updateReg32(addr rf.baseCtrl1, not 0'u32, 0x00000002'u32)
    updateReg32(addr rf.synthCtrl2c, not 0x00000020'u32, 0'u32)
    updateReg32(addr rf.scanSynthControl608, 0xDFFFFFFF'u32, 0x20000000'u32)

  proc wlLpApiModeActive(): bool {.inline.} =
    let cfg = cast[ptr WlRfConfig](wlCfgGlobal)
    cfg != nil and (cfg.apiMode and 0xFD'u8) == 1'u8

  proc wlLpProgramApiModePhyBranchStart() =
    ## Port of librf_bl808.a:lp_phy.c.o lp_phy_init+0x184..0x236.
    ## Vendor enters this path when (wl_cfg.apiMode & 0xfd) == 1, then sets
    ## the low-power modem/RF clock-domain controls before programming the
    ## larger modem/AGC body that starts at lp_phy_init+0x236.
    if not wlLpApiModeActive():
      return
    let mdm = wifiModemRegs()
    let rf = rfRegs()
    let crm = crmPhyClockRegs()
    updateReg32(addr mdm.lowPowerRxPathCtrlC814, not 0x00000003'u32,
                0x00000002'u32)
    updateReg32(addr mdm.lowPowerRxPathCtrlC814, not 0x0000003C'u32,
                0x00000008'u32)
    updateReg32(addr mdm.lowPowerRxPathCtrlC814, not 0x000003C0'u32,
                0x00000080'u32)
    updateReg32(addr mdm.rxGainInitC040, 0xFE0FFFFF'u32, 0x00C00000'u32)
    updateReg32(addr mdm.rxGainInitC040, 0xFFF07FFF'u32, 0x00018000'u32)
    updateReg32(addr mdm.rxGainTimingC044, 0xFFFF00FF'u32, 0x00000800'u32)
    updateReg32(addr mdm.rxGainTimingC044, 0xFFFFFF00'u32, 0'u32)
    rc2_config_rxgain(-5'i8)
    updateReg32(addr rf.channelTuneCtrl26c, 0xC00FFFFF'u32, 0x05000000'u32)
    updateReg32(addr crm.modemReset18, 0xFFFFFC00'u32, 0x00000050'u32)
    crm_init()
    crm_mdm_reset()

  proc wlLpProgramApiModeTuneAndAgcPrep(phyCfg: pointer) =
    ## Port of librf_bl808.a:lp_phy.c.o lp_phy_init+0x236..0x35c.
    ## This low-power-only phase sets pre-AGC, RF tune strobes, and AGC-copy
    ## gates before the vendor copies agcmem at lp_phy_init+0x364..0x380.
    if not wlLpApiModeActive():
      return
    let mdm = wifiModemRegs()
    let bba = bbaAgcRegs()
    let rf = rfRegs()
    let crm = crmPhyClockRegs()
    updateReg32(addr mdm.preAgcCtrl324, 0xFFC0FFFF'u32, 0x002D0000'u32)
    updateReg32(addr crm.rfClockMux10, 0xF7FFFFFF'u32, 0x08000000'u32)
    volatileStore(addr bba.macActiveC01c, 0x000000A0'u32)
    updateReg32(addr bba.agcCoreTableC80c, 0x00FFFFFF'u32, 0xA8000000'u32)
    updateReg32(addr rf.channelTuneGate228, not 0'u32, 0x00000008'u32)
    updateReg32(addr rf.synthCtrl2c, not 0'u32, 0x00000040'u32)
    updateReg32(addr rf.synthCtrl2c, not 0'u32, 0x00000200'u32)
    updateReg32(addr rf.synthCtrl2c, not 0'u32, 0x00000001'u32)
    updateReg32(addr rf.channelFreqMhz264, 0xFFFFF000'u32,
                pointerAddrU32(phyCfg) and 0x00000FFF'u32)
    updateReg32(addr rf.channelTuneStrobe268, 0xFFFDFFFF'u32, 0x00020000'u32)
    updateReg32(addr rf.channelTuneStrobe268, 0xFFFDFFFF'u32, 0'u32)
    updateReg32(addr rf.baseCtrl1, not 0'u32, 0x00000002'u32)
    waitRfUs(1'u32)
    updateReg32(addr rf.channelTuneCtrl26c, not 0x00000007'u32, 0x00000001'u32)
    waitRfUs(1'u32)
    updateReg32(addr rf.channelTuneCtrl26c, not 0'u32, 0x00000008'u32)
    waitRfUs(1'u32)
    updateReg32(addr rf.channelTuneCtrl26c, not 0x00000007'u32, 0x00000002'u32)
    updateReg32(addr bba.pdGain390, 0xFFFFEFFF'u32, 0x00001000'u32)
    updateReg32(addr crm.rfClockMux10, 0xDFFFFFFF'u32, 0x20000000'u32)

  proc wlLpCopyAgcMemoryAndReleaseGate() =
    ## Port of librf_bl808.a:lp_phy.c.o lp_phy_init+0x364..0x3a6.
    ## The copy loop is the same agcmem -> 0x24C0A000 transfer used by
    ## phy_init; the low-power tail only clears the AGC-copy clock/gate bits
    ## that this path set before continuing into the AGC core body.
    if not wlLpApiModeActive():
      return
    copyAgcMemory()
    let bba = bbaAgcRegs()
    let crm = crmPhyClockRegs()
    updateReg32(addr crm.rfClockMux10, 0xDFFFFFFF'u32, 0'u32)
    updateReg32(addr bba.pdGain390, 0xFFFFEFFF'u32, 0'u32)

  proc wlLpProgramAgcCoreRegs() =
    ## Port of librf_bl808.a:lp_phy.c.o lp_phy_init+0x3a6..0x774.
    ## This block is register-identical to the typed main-PHY AGC core phase.
    if not wlLpApiModeActive():
      return
    bl808PhyProgramAgcCoreRegs()

  proc wlLpProgramPostAgcPowerDetectTail() =
    ## Port of librf_bl808.a:lp_phy.c.o lp_phy_init+0x774..0x86c.
    ## Final low-power post-AGC phase: retunes BBA power-detect thresholds,
    ## restores the default PHY clock selection, clears the WL active latch,
    ## and releases the RF low-power tune gates before returning.
    if not wlLpApiModeActive():
      return
    let bba = bbaAgcRegs()
    let rf = rfRegs()
    let env = wlLowPowerStatusEnv()
    volatileStore(addr bba.lowPowerPdCompC864, 0x0000C078'u32)
    updateReg32(addr bba.pdGain390, 0xFFFFFF0F'u32, 0x00000010'u32)
    updateReg32(addr bba.lowPowerPdCompC834, 0xFFFFFFFC'u32, 0x00000001'u32)
    updateReg32(addr bba.agcCoreLowPowerThreshold304,
                0xFFFF80FF'u32, 0x00004B00'u32)
    crm_clk_set(0'u32)
    updateReg32(addr bba.pdGain390, 0xFFFFFEFF'u32, 0'u32)
    updateReg32(addr bba.pdGain390, not 0'u32, 0x00000200'u32)
    updateReg32(addr bba.macActiveB3a0, 0xFFFFFF00'u32, 0x000000A8'u32)
    updateReg32(addr bba.pdSlope3c0, 0xFFFF00FF'u32, 0x0000AB00'u32)
    updateReg32(addr bba.pdSlope3c0, 0xFFFFFF00'u32, 0x000000AB'u32)
    updateReg32(addr bba.lowPowerPdThresholdC044,
                0xFFFF00FF'u32, 0x00000600'u32)
    updateReg32(addr bba.pdComp36c, 0xFFFFF8FF'u32, 0x00000500'u32)
    updateReg32(addr bba.pdComp36c, 0xFFFFFF00'u32, 0x00000014'u32)
    updateReg32(addr bba.pdCompC830, 0xFC0FFFFF'u32, 0'u32)
    if env != nil:
      volatileStore(addr env.lowPowerActiveLatch, 0'u8)
    updateReg32(addr rf.channelTuneCtrl26c, 0xFFFFFFF7'u32, 0'u32)
    waitRfUs(1'u32)
    updateReg32(addr rf.channelTuneGate228, 0xFFFFFFF7'u32, 0'u32)

  proc wl_lp_init*(rmem: ptr WlRfMemoryOverlay; phyCfg: pointer): int32
      {.exportc, cdecl.} =
    ## Porting boundary for librf_bl808.a:wl_api.c.o wl_lp_init+0x0..0xa6.
    ## Recovered top-level behavior: bind wl_cfg/wl_cal/wl_env to rmem
    ## offsets 0/0xd4/0x214, run lp_default_init, restore RF using the WL
    ## efuse tx-gain byte, map xtal Hz to the low-power table index, and run
    ## the recovered lp_phy_init register phases. This implementation still
    ## routes through the existing typed phy_init afterward until low-power
    ## hardware validation proves whether the fallback can be removed.
    if rmem == nil:
      wlCfgGlobal = nil
      wlCalGlobal = nil
      wlEnvGlobal = nil
      rfCalibDataGlobal = nil
      return -1'i32
    wlCfgGlobal = cast[pointer](addr rmem.config)
    wlCalGlobal = cast[pointer](addr rmem.calib[0])
    wlEnvGlobal = cast[pointer](addr rmem.env[0])
    rfCalibDataGlobal = wlCalGlobal
    wlLpDefaultInit()
    let cfg = cast[ptr WlRfConfig](wlCfgGlobal)
    if cfg != nil:
      rf_pri_input_xtalfreq(cfg.xtalfreqHz)
      rf_pri_init(0'u32, uint32(cfg.apiMode))
      let lpXtalIndex = wlLpXtalIndex(cfg.xtalfreqHz)
      wlLpProgramEarlyPhyRegs(lpXtalIndex)
      wlLpProgramApiModePhyBranchStart()
      wlLpProgramApiModeTuneAndAgcPrep(phyCfg)
      wlLpCopyAgcMemoryAndReleaseGate()
      wlLpProgramAgcCoreRegs()
      wlLpProgramPostAgcPowerDetectTail()
    phy_init(phyCfg)
    0'i32

  proc wl_lp_status_clear*(context: uint32) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:wl_api.c.o wl_lp_status_clear+0x0..0x1a.
    ## Resets the 12-byte WL low-power status env at wl_env.
    let env = wlLowPowerStatusEnv()
    if env == nil:
      return
    env.inactiveUpdateCount = 0'u16
    env.lastStatusCode = cast[int8](0xA6'u8)
    env.lastUpdateContext = context
    env.statusValid = 0'u8

  proc wl_lp_status_update*(active: uint32; statusCode: int8;
                            context: uint32) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:wl_api.c.o wl_lp_status_update+0x0..0x60.
    ## The low-power status env keeps the most recent active status and clears
    ## validity after two inactive updates.
    let env = wlLowPowerStatusEnv()
    if env == nil:
      return
    if active == 0'u32:
      let nextInactive =
        if env.inactiveUpdateCount >= 1'u16: 2'u16
        else: env.inactiveUpdateCount + 1'u16
      if nextInactive == 2'u16:
        env.inactiveUpdateCount = 0'u16
        env.statusValid = 0'u8
      else:
        env.inactiveUpdateCount = nextInactive
      env.lastUpdateContext = context
      return

    env.lastStatusCode = statusCode
    env.inactiveUpdateCount = 0'u16
    env.statusValid = 1'u8
    env.lastUpdateContext = context

  proc rf_pri_init_calib_mem() {.exportc, cdecl.} =
    ## Exact port of librf_bl808.a:rf_calib_data.c.o rf_pri_init_calib_mem.
    ## Recovered body is one assignment: rf_calib_data = wl_cal.
    rfCalibDataGlobal = wlCalGlobal

  type
    RfPriCalState = object
      baseCtrl1: uint32
      synthCtrl2c: uint32
      calCtrl1c: uint32
      priModeCtrl30: uint32
      txcalCtrlB8: uint32
      sdmCtrlC0: uint32
      sdmDivC4: uint32
      hbnCtrl30: uint32
      txcalDfe88: uint32
      calPathConfig8c: uint32
      txcalTosdac600: uint32
      calMeasurePrep60c: uint32
      measureCtrl618: uint32
      measureMode61c: uint32
      rccalTone48: uint32
      calSingenCtrl20c: uint32
      calSingenAmpLo214: uint32
      calSingenAmpHi218: uint32
      calDfeGate23c: uint32
      calDfeState240: uint32
      calDfeState244: uint32
      calMixerStateF0: uint32
      txcalGain64: uint32
      txcalBias58: uint32
      rxMode220: uint32
      txcalParam74: uint32
      acalCtrlA4: uint32

    RfPriVendorCalState = object
      baseCtrl1: uint32
      synthCtrl2c: uint32
      calCtrl1c: uint32
      priModeCtrl30: uint32
      txcalCtrlB8: uint32
      sdmCtrlC0: uint32
      sdmDivC4: uint32
      hbnCtrl30: uint32
      txcalDfe88: uint32
      calPathCtrl90: uint32
      txcalTosdac600: uint32
      calMeasurePrep60c: uint32
      measureCtrl618: uint32
      measureMode61c: uint32
      rccalTone48: uint32
      calSingenCtrl20c: uint32
      calSingenAmpLo214: uint32
      calSingenAmpHi218: uint32
      calDfeGate23c: uint32
      calDfeState240: uint32
      calDfeState244: uint32
      calMixerStateF0: uint32
      txcalGain64: uint32
      txcalBias58: uint32
      rxMode220: uint32
      txcalParam74: uint32
      acalCtrlA4: uint32

  var
    bl808RfXtalIndex: uint32
    bl808RfPriXtal24mFlag: uint8
    bl808RfPriXtal26mFlag: uint8
    bl808RfPriXtal32mFlag: uint8
    bl808RfPriXtal38p4mFlag: uint8
    bl808RfPriXtal40mFlag: uint8 = 1
    bl808RfPriXtal52mFlag: uint8
    bl808RfMode: RadioPhyMode
    bl808RfColdInit: uint32
    bl808RfChannelMhz: uint32
    bl808RfBandwidthMhz: uint32
    bl808RfChannelPowerIndex: uint32
    bl808RfLowPowerTableDelta: int16
    bl808RfChannelPowerComp: array[14, int16]
    bl808RfChannelLpPowerComp: array[14, int16]
    bl808RfBzChannelPowerComp: array[5, int16]
    bl808RfBzTempCorrAvg: int16
    bl808RfBzChCorrAvg: int16
    bl808RfBzTxCorrOffset: int16
    bl808RfBzTargetPowerRecords: array[4, int] =
      RfPriBzTargetPowerDefaultRecords
    bl808RfBzTempPowerComp: array[5, int16]
    bl808RfBzAppliedTempComp: array[5, int16]
    bl808RfBzTemperatureMeasurementPass: uint8
    bl808RfTempChannelCount: uint32 = 5'u32
    bl808RfTempChannels: array[5, uint16] = [
      2412'u16, 2427'u16, 2442'u16, 2457'u16, 2472'u16]
    bl808RfTempHighOffsets: array[5, int16] = [
      180'i16, 170'i16, 160'i16, 140'i16, 120'i16]
    bl808RfTempLowOffsets: array[5, int16] = [
      200'i16, 190'i16, 180'i16, 160'i16, 130'i16]
    bl808RfTempRoomOffset: int16
    bl808RfTempCalEnabled: uint8
    bl808RfCurrentTemperatureC: int16 = 35'i16
    bl808RfTempMeasurementPass: uint8
    bl808RfAppliedPowerComp: int16
    bl808RfTempPowerComp: int16
    bl808RfTxGainComp: int16
    bl808RfEfuseCapComp: int16
    bl808RfEfusePowerComp: int16
    bl808RfDeviceBl616: uint8
    bl808RfDeviceWb03: uint8
    bl808RfDeviceBl618m: uint8
    bl808RfDeviceInfoSet: uint8
    bl808RfChipVersion: uint8 = 1'u8
    bl808RfTxPowerTable: array[18, RfPriTxPowerTableRow] =
      RfPriTxPowerTableDefault
    bl808RfTxPowerTableIndex: array[13, int16] =
      RfPriTxPowerTableIndexDefault
    bl808RfPriVendorCalState: RfPriVendorCalState

  proc rf_pri_input_device_info(deviceInfo: uint32) {.exportc, cdecl.} =
    ## Vendor rf_pri_input_device_info clears the three device flags, then
    ## maps 0 -> bl616, 1 -> wb03, 2 -> bl618m.
    bl808RfDeviceBl616 = 0
    bl808RfDeviceWb03 = 0
    bl808RfDeviceBl618m = 0
    case deviceInfo
    of Bl808RfDeviceInfoBl616:
      bl808RfDeviceBl616 = 1
    of Bl808RfDeviceInfoWb03:
      bl808RfDeviceWb03 = 1
    of Bl808RfDeviceInfoBl618m:
      bl808RfDeviceBl618m = 1
    else:
      discard
    bl808RfDeviceInfoSet = 1

  proc rf_pri_input_chip_ver(chipVersion: uint32) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rf_pri.c.o rf_pri_input_chip_ver+0x0..0x12.
    ## Vendor leaves Chip_Version unchanged when called with zero.
    if chipVersion != 0'u32:
      bl808RfChipVersion = uint8(chipVersion and 0xFF'u32)

  proc rfPriManualCalAdjustCoarse(delta: int32) =
    let rf = rfRegs()
    var word = volatileLoad(addr rf.fcalCtrlA0)
    let coarse = ((word shr 16) and 0x3F'u32).int32 + delta
    word = (word and 0xFFC0FFFF'u32) or
      ((uint32(coarse) shl 16) and 0x003F0000'u32)
    volatileStore(addr rf.fcalCtrlA0, word)

  proc rfPriManualCalAdjustFine(delta: int32) =
    let rf = rfRegs()
    var word = volatileLoad(addr rf.fcalCtrlA0)
    let fine = (word and 0xFF'u32).int32 + delta
    word = (word and 0xFFFFFF00'u32) or (uint32(fine) and 0xFF'u32)
    volatileStore(addr rf.fcalCtrlA0, word)

  proc rf_pri_manual_incremental_cal_start() {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rf_pri.c.o
    ## rf_pri_manual_incremental_cal_start+0x0..0x252.
    ## Recovered behavior: mirror the manual calibration seed fields across
    ## RF calibration-control registers, pulse the manual trigger, then adjust
    ## RF[0x10a0] coarse/fine fields while RF[0x10ac] status remains in the
    ## vendor retry states 0 or 3.
    let rf = rfRegs()

    var txcalCtrl = volatileLoad(addr rf.txcalCtrlB8)
    txcalCtrl = (txcalCtrl and not 0x00000010'u32) or
      ((txcalCtrl shl 4) and 0x00000010'u32)
    txcalCtrl = (txcalCtrl and 0xFFFEFFFF'u32) or
      ((txcalCtrl shr 4) and 0x00010000'u32)
    volatileStore(addr rf.txcalCtrlB8, txcalCtrl)

    var strobe = volatileLoad(addr rf.channelCalStrobeB0)
    strobe = (strobe and not 0x00000001'u32) or
      ((strobe shr 1) and 0x00000001'u32)
    strobe = (strobe and 0xEFFFFFFF'u32) or
      ((strobe shr 1) and 0x10000000'u32)
    volatileStore(addr rf.channelCalStrobeB0, strobe)

    var statusCtrl = volatileLoad(addr rf.channelCalStatusB4)
    statusCtrl = (statusCtrl and 0xFFFF3FFF'u32) or
      (((statusCtrl shr 8) shl 14) and 0x0000FFFF'u32)
    statusCtrl = (statusCtrl and 0xFFFCFFFF'u32) or
      ((statusCtrl shl 12) and 0x00030000'u32)
    volatileStore(addr rf.channelCalStatusB4, statusCtrl)

    var fcal = volatileLoad(addr rf.fcalCtrlA0)
    let savedFine = (fcal shr 8) and 0xFF'u32
    fcal = (fcal and 0xFFC0FFFF'u32) or ((fcal shr 8) and 0x003F0000'u32)
    fcal = (fcal and 0xFFFFFF00'u32) or savedFine
    volatileStore(addr rf.fcalCtrlA0, fcal)

    let sdmHigh = volatileLoad(addr rf.sdmFractionalHighC8) and 0x3FFFFFFF'u32
    let sdmLow = volatileLoad(addr rf.sdmDivC4) and 0xC0000000'u32
    volatileStore(addr rf.sdmDivC4, sdmLow or sdmHigh)

    var sdmCtrl = volatileLoad(addr rf.sdmCtrlC0)
    sdmCtrl = (sdmCtrl and 0xFFFEFFFF'u32) or
      ((sdmCtrl shr 1) and 0x00010000'u32)
    volatileStore(addr rf.sdmCtrlC0, sdmCtrl)

    updateReg32(addr rf.synthCtrl2c, not 0x00000040'u32, 0'u32)
    updateReg32(addr rf.baseCtrl1, not 0x0000000C'u32, 0'u32)
    updateReg32(addr rf.calCtrl1c, not 0'u32, 0x00000060'u32)
    updateReg32(addr rf.txcalCtrlB8, not 0'u32, 0x00010000'u32)
    waitRfUs(10'u32)
    updateReg32(addr rf.txcalCtrlB8, 0xFFFEFFFF'u32, 0'u32)
    waitRfUs(10'u32)

    var retries = 10
    while retries > 0:
      let calState = (volatileLoad(addr rf.fcalAc) shr 24) and 0x3'u32
      if calState != 0'u32 and calState != 3'u32:
        break
      if (volatileLoad(addr rf.acalCtrlA4) and 0x00001000'u32) != 0'u32:
        rfPriManualCalAdjustCoarse(-1)
      else:
        rfPriManualCalAdjustCoarse(1)
      if calState == 0'u32:
        rfPriManualCalAdjustFine(1)
      else:
        rfPriManualCalAdjustFine(-1)
      waitRfUs(10'u32)
      dec retries

    updateReg32(addr rf.calCtrl1c, not 0x00000060'u32, 0'u32)
    updateReg32(addr rf.channelCalStrobeB0, not 0'u32, 0x10000000'u32)
    waitRfUs(10'u32)
    updateReg32(addr rf.channelCalStrobeB0, 0xEFFFFFFF'u32, 0'u32)

  proc rf_pri_manual_incremental_cal_stop() {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rf_pri.c.o
    ## rf_pri_manual_incremental_cal_stop+0x0..0x1e.
    let rf = rfRegs()
    updateReg32(addr rf.synthCtrl2c, not 0'u32, 0x00000040'u32)
    updateReg32(addr rf.baseCtrl1, not 0x0000000C'u32, 0x00000004'u32)
    updateReg32(addr rf.calCtrl1c, not 0'u32, 0x00000060'u32)

  proc rf_pri_get_wl_cfg(): uint32 {.exportc, cdecl.} =
    ## Exact local replacement for librf_bl808.a:rf_pri.c.o rf_pri_get_wl_cfg:
    ## the BL808 body returns constant 1.
    1'u32

  proc rfPriDivTowardZeroBy10(x: int32): int32 {.inline.} =
    ## RISC-V DIV truncates toward zero. Keep that explicit for negative
    ## table entries even though the vendor max/min defaults are non-negative.
    if x >= 0:
      x div 10
    else:
      -((-x) div 10)

  proc rfPriTxGainDbForTableIndex(tableIndex: int16): int32 {.inline.} =
    ## librf_bl808.a:rf_pri.c.o rf_pri_get_txgain_max/min index
    ## .data.tx_pwr_table_idx, step 18-byte .data.tx_pwr_table rows, read
    ## row offset 0x0c, then signed-divide by 10.
    let idx = int(tableIndex)
    if idx < 0 or idx >= bl808RfTxPowerTable.len:
      return 0
    let tenths = int32(bl808RfTxPowerTable[idx][RfPriTxPowerRowTxGainTenthsIndex])
    rfPriDivTowardZeroBy10(tenths)

  proc rfPriGetTxGainIndex(requestedPowerTenths: int32;
                           rateGroup: uint32): uint32 {.inline.} =
    ## BL808 librf_bl808.a:rfc_helper.c.o rfc_get_power_level+0x0..0x4a
    ## calls an external rf_pri_get_txgain_index(power, group). That helper is
    ## not defined by the BL808 RF archive; the recovered BL602 implementation
    ## scans descending tx_pwr_table thresholds, subtracting 3 dB for group 0.
    ## On BL808 the 18-byte tx_pwr_table row keeps that threshold at element 8;
    ## element 6 is a separate tx-gain tenths field used by max/min above.
    var adjustedPower = requestedPowerTenths
    if rateGroup == 0'u32:
      adjustedPower -= 30'i32
    let rowCount =
      if bl808RfTxPowerTable.len < 16: bl808RfTxPowerTable.len else: 16
    for idx in 0 ..< rowCount:
      let threshold =
        int32(bl808RfTxPowerTable[idx][RfPriTxPowerRowPowerThresholdTenthsIndex]) +
        bl808RfTxGainComp.int32
      if adjustedPower >= threshold:
        return idx.uint32
    15'u32

  proc rf_pri_get_txgain_max(): int32 {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rf_pri.c.o rf_pri_get_txgain_max+0x0..0x24.
    rfPriTxGainDbForTableIndex(bl808RfTxPowerTableIndex[0])

  proc rf_pri_get_txgain_min(): int32 {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rf_pri.c.o rf_pri_get_txgain_min+0x0..0x24.
    rfPriTxGainDbForTableIndex(bl808RfTxPowerTableIndex[12])

  proc rfPriLoadConfiguredDeviceInfo() =
    rf_pri_input_device_info(uint32(Bl808WifiRfDeviceInfo))

  proc rfPriDeviceInfoValid(): bool {.inline.} =
    (bl808RfDeviceBl616 or bl808RfDeviceWb03 or bl808RfDeviceBl618m) != 0

  proc rfPriEnsureDeviceInfo() =
    if bl808RfDeviceInfoSet == 0 or not rfPriDeviceInfoValid():
      rf_pri_input_device_info(uint32(Bl808WifiRfDeviceInfo))

  proc rfPriIsWb03(): bool {.inline.} =
    if bl808RfDeviceInfoSet != 0:
      bl808RfDeviceWb03 != 0
    else:
      Bl808WifiRfDeviceInfo == int(Bl808RfDeviceInfoWb03)

  proc rfPriAnyKnownDeviceFlag(): bool {.inline.} =
    if bl808RfDeviceInfoSet != 0:
      (bl808RfDeviceBl616 or bl808RfDeviceWb03 or bl808RfDeviceBl618m) != 0
    else:
      true

  proc rfPriDeviceTraceWord(): uint32 {.inline.} =
    uint32(rfPriIsWb03()) or
      (bl808RfDeviceBl616.uint32 shl 4) or
      (bl808RfDeviceBl618m.uint32 shl 8) or
      ((bl808RfXtalIndex and 0xFF'u32) shl 16)

  proc rfPhyTraceCheckpoint(phase: uint32) =
    let rf = rfRegs()
    let idx = int(nimFwDbgRfPhyTraceCount and uint32(NimFwDbgRfPhyTraceLen - 1))
    inc nimFwDbgRfPhyTraceCount
    nimFwDbgRfPhyTracePhase[idx] = phase
    nimFwDbgRfPhyTraceDevice[idx] = rfPriDeviceTraceWord()
    let env = phyEnvViewPtr()
    nimFwDbgRfPhyTraceChanMeta[idx] =
      volatileLoad(addr env.channelBandType).uint32 or
      (volatileLoad(addr env.primaryFreq).uint32 shl 16)
    nimFwDbgRfPhyTraceChanFreq[idx] =
      volatileLoad(addr env.primaryFreq).uint32 or
      (volatileLoad(addr env.centerFreq1).uint32 shl 16)
    nimFwDbgRfPhyTraceRf2c[idx] = volatileLoad(addr rf.synthCtrl2c)
    nimFwDbgRfPhyTraceRf04[idx] = volatileLoad(addr rf.baseCtrl1)
    nimFwDbgRfPhyTraceRf34[idx] = volatileLoad(addr rf.scanSynthLatch34)
    nimFwDbgRfPhyTraceRf40[idx] = volatileLoad(addr rf.scanSynthLatch40)
    nimFwDbgRfPhyTraceRf4c[idx] = volatileLoad(addr rf.scanRxLatch4c)
    nimFwDbgRfPhyTraceRf70[idx] = volatileLoad(addr rf.txcalParam70)
    nimFwDbgRfPhyTraceRf74[idx] = volatileLoad(addr rf.txcalParam74)
    nimFwDbgRfPhyTraceRf88[idx] = volatileLoad(addr rf.txcalDfe88)
    nimFwDbgRfPhyTraceRf90[idx] = volatileLoad(addr rf.calPathCtrl90)
    nimFwDbgRfPhyTraceRfa0[idx] = volatileLoad(addr rf.fcalCtrlA0)
    nimFwDbgRfPhyTraceRfa4[idx] = volatileLoad(addr rf.acalCtrlA4)
    nimFwDbgRfPhyTraceRfbc[idx] = volatileLoad(addr rf.channelFcalConfigBc)
    nimFwDbgRfPhyTraceRfd0[idx] = volatileLoad(addr rf.optimizeCtrlD0)
    nimFwDbgRfPhyTraceRf80[idx] = volatileLoad(addr rf.rbbRccalCtrl80)
    nimFwDbgRfPhyTraceRf84[idx] = volatileLoad(addr rf.rccalReplay84)
    nimFwDbgRfPhyTraceRf8c[idx] = volatileLoad(addr rf.calPathConfig8c)
    nimFwDbgRfPhyTraceRfb4[idx] = volatileLoad(addr rf.channelCalStatusB4)
    nimFwDbgRfPhyTraceRf1600[idx] = volatileLoad(addr rf.txcalTosdac600)
    nimFwDbgRfPhyTraceRf1614[idx] = volatileLoad(addr rf.rxcalSearch614)
    nimFwDbgRfPhyTraceRf1618[idx] = volatileLoad(addr rf.measureCtrl618)
    nimFwDbgRfPhyTraceRf162c[idx] = volatileLoad(addr rf.scanTxMeasureControl62c)
    nimFwDbgRfPhyTraceRf1680[idx] = volatileLoad(addr rf.notchCtrl680)
    nimFwDbgRfPhyTraceRf113c[idx] = volatileLoad(addr rf.vcoPairTable13c[0])
    let mdm = wifiModemRegs()
    nimFwDbgRfPhyTracePhy820[idx] = volatileLoad(addr mdm.bandwidth20MProfile820)
    nimFwDbgRfPhyTracePhy824[idx] = volatileLoad(addr mdm.channelTypeCtrl824)
    nimFwDbgRfPhyTracePhy830[idx] = volatileLoad(addr mdm.bandwidth20MProfile830)
    nimFwDbgRfPhyTracePhy874[idx] = volatileLoad(addr mdm.bandwidth20MGate874)
    nimFwDbgRfPhyTraceRxCtrl[idx] = regRead(MACHW_RX_CNTRL_REG)
    nimFwDbgRfPhyTraceIrqRaw[idx] = regRead(0x24B0806C'u)
    nimFwDbgRfPhyTraceGenRaw[idx] = regRead(0x24B08084'u)
    nimFwDbgRfPhyTraceHd[idx] = machwRxHdSubmittedHead()
    nimFwDbgRfPhyTracePd[idx] = machwRxPdSubmittedHead()
    nimFwDbgRfPhyTraceHwHd[idx] = machwRxHwHdHead()
    nimFwDbgRfPhyTraceHwPd[idx] = machwRxHwPdHead()

  proc rfPriTracePhase(base: uint32): uint32 {.inline.} =
    base or (uint32(rfPriIsWb03()) shl 8) or
      (bl808RfDeviceBl616.uint32 shl 12) or
      (bl808RfDeviceBl618m.uint32 shl 16) or
      (bl808RfXtalIndex and 0xFF'u32)

  const
    RfPriStageSnapshotEntries {.intdefine.} = 8

  var nim_wifi_rf_stage_snapshot_count* {.exportc.}: uint32
  var nim_wifi_rf_stage_tag_log* {.exportc.}: array[RfPriStageSnapshotEntries, uint32]
  var nim_wifi_rf_stage_rf4c_log* {.exportc.}: array[RfPriStageSnapshotEntries, uint32]
  var nim_wifi_rf_stage_rf70_log* {.exportc.}: array[RfPriStageSnapshotEntries, uint32]
  var nim_wifi_rf_stage_rf7c_log* {.exportc.}: array[RfPriStageSnapshotEntries, uint32]
  var nim_wifi_rf_stage_rf80_log* {.exportc.}: array[RfPriStageSnapshotEntries, uint32]
  var nim_wifi_rf_stage_rf88_log* {.exportc.}: array[RfPriStageSnapshotEntries, uint32]
  var nim_wifi_rf_stage_rfa0_log* {.exportc.}: array[RfPriStageSnapshotEntries, uint32]
  var nim_wifi_rf_stage_rfd0_log* {.exportc.}: array[RfPriStageSnapshotEntries, uint32]
  var nim_wifi_rf_stage_rf1600_log* {.exportc.}: array[RfPriStageSnapshotEntries, uint32]
  var nim_wifi_rf_stage_rf162c_log* {.exportc.}: array[RfPriStageSnapshotEntries, uint32]
  var nim_wifi_rf_stage_rfb0_log* {.exportc.}: array[RfPriStageSnapshotEntries, uint32]
  var nim_wifi_rf_stage_rfb4_log* {.exportc.}: array[RfPriStageSnapshotEntries, uint32]
  var nim_wifi_rf_stage_rfbc_log* {.exportc.}: array[RfPriStageSnapshotEntries, uint32]
  var nim_wifi_rf_optimize_count* {.exportc.}: uint32
  var nim_wifi_rf_optimize_channel_log* {.exportc.}: array[RfPriStageSnapshotEntries, uint32]
  var nim_wifi_rf_optimize_device_log* {.exportc.}: array[RfPriStageSnapshotEntries, uint32]
  var nim_wifi_rf_optimize_rfd0_log* {.exportc.}: array[RfPriStageSnapshotEntries, uint32]
  var nim_wifi_rf_optimize_rf70_log* {.exportc.}: array[RfPriStageSnapshotEntries, uint32]
  var nim_wifi_rf_optimize_nibble_log* {.exportc.}: array[RfPriStageSnapshotEntries, uint32]
  var nim_wifi_rf_fixed_val_count* {.exportc.}: uint32
  var nim_wifi_rf_fixed_val_device* {.exportc.}: uint32
  var nim_wifi_rf_fixed_val_branch* {.exportc.}: uint32
  var nim_wifi_rf_fixed_val_rf70* {.exportc.}: uint32
  var nim_wifi_rf_fixed_val_rf88* {.exportc.}: uint32
  var nim_wifi_rf_fixed_val_rfd0* {.exportc.}: uint32
  var nim_wifi_rf_fixed_val_rf814* {.exportc.}: uint32
  var nim_wifi_rf_fixed_val_rfa0* {.exportc.}: uint32
  var nim_wifi_rf_rf70_replay_apply_count* {.exportc.}: uint32
  var nim_wifi_rf_rf70_replay_reason* {.exportc.}: uint32
  var nim_wifi_rf_rf70_replay_reg_before* {.exportc.}: uint32
  var nim_wifi_rf_rf70_replay_reg_after* {.exportc.}: uint32
  var nim_wifi_rf_rf70_replay_cal_word3_before* {.exportc.}: uint32
  var nim_wifi_rf_rf70_replay_cal_word4_before* {.exportc.}: uint32
  var nim_wifi_rf_rf70_replay_cal_word3_after* {.exportc.}: uint32
  var nim_wifi_rf_rf70_replay_cal_word4_after* {.exportc.}: uint32
  var rf70ReplayWindow0SourceNibble* {.exportc: "nim_wifi_rf_rf70_txcal_window0_nibble".}: uint32
  var rf70ReplayWindow1SourceNibble* {.exportc: "nim_wifi_rf_rf70_txcal_window1_nibble".}: uint32
  var rf70ReplayWindow2SourceNibble* {.exportc: "nim_wifi_rf_rf70_txcal_window2_nibble".}: uint32
  var rf70ReplayWindowValidMask* {.exportc: "nim_wifi_rf_rf70_txcal_window_mask".}: uint32
  var nim_wifi_rf_rf70_txcal_search_count* {.exportc.}: uint32
  var nim_wifi_rf_rf70_txcal_search_ok_mask* {.exportc.}: uint32
  var rf70ReplaySearchBestNibble* {.exportc: "nim_wifi_rf_rf70_txcal_search_best_nibble".}: array[3, uint32]
  var rf70ReplaySearchRunnerUpNibble* {.exportc: "nim_wifi_rf_rf70_txcal_search_runner_nibble".}: array[3, uint32]
  var rf70ReplaySearchBestSample* {.exportc: "nim_wifi_rf_rf70_txcal_search_best_sample".}: array[3, uint32]
  var rf70ReplaySearchRunnerUpSample* {.exportc: "nim_wifi_rf_rf70_txcal_search_runner_sample".}: array[3, uint32]
  var rf70ReplaySearchMeasureCtrl* {.exportc: "nim_wifi_rf_rf70_txcal_search_ctrl".}: array[3, uint32]
  var rf70ReplaySearchMeasureMode* {.exportc: "nim_wifi_rf_rf70_txcal_search_mode".}: array[3, uint32]
  var rf70ReplaySearchMeasureIRaw* {.exportc: "nim_wifi_rf_rf70_txcal_search_i_raw".}: array[3, uint32]
  var rf70ReplayCandidateValidMask* {.exportc: "nim_wifi_rf_rf70_txcal_candidate_ok_mask".}: array[3, uint32]
  var rf70ReplayCandidateAverageSample* {.exportc: "nim_wifi_rf_rf70_txcal_candidate_sample".}: array[48, uint32]

  var nim_wifi_rf_breakpoint_tag* {.exportc.}: uint32
  var nim_wifi_rf_breakpoint_count* {.exportc.}: uint32

  proc nim_wifi_rf_stage_breakpoint*(tag: uint32)
      {.exportc, cdecl, noinline.} =
    ## JTAG anchor for RF/PHY bring-up. Hardware validation can break here and
    ## inspect RF70/RF88/RFD0 without relying on local static proc symbols.
    nim_wifi_rf_breakpoint_tag = tag
    inc nim_wifi_rf_breakpoint_count

  proc nim_wifi_rf_fixed_val_breakpoint*()
      {.exportc, cdecl, noinline.} =
    nim_wifi_rf_stage_breakpoint(0xF100'u32)

  proc nim_wifi_rf_pri_init_entry_breakpoint*()
      {.exportc, cdecl, noinline.} =
    nim_wifi_rf_stage_breakpoint(0xF400'u32)

  proc rfPriSnapshotStage(tag: uint32) =
    nim_wifi_rf_stage_breakpoint(tag)
    let rf = rfRegs()
    let idx = int(nim_wifi_rf_stage_snapshot_count mod
      uint32(RfPriStageSnapshotEntries))
    inc nim_wifi_rf_stage_snapshot_count
    nim_wifi_rf_stage_tag_log[idx] = tag
    nim_wifi_rf_stage_rf4c_log[idx] = volatileLoad(addr rf.scanRxLatch4c)
    nim_wifi_rf_stage_rf70_log[idx] = volatileLoad(addr rf.txcalParam70)
    nim_wifi_rf_stage_rf7c_log[idx] = volatileLoad(addr rf.roscalCtrl7c)
    nim_wifi_rf_stage_rf80_log[idx] = volatileLoad(addr rf.rbbRccalCtrl80)
    nim_wifi_rf_stage_rf88_log[idx] = volatileLoad(addr rf.txcalDfe88)
    nim_wifi_rf_stage_rfa0_log[idx] = volatileLoad(addr rf.fcalCtrlA0)
    nim_wifi_rf_stage_rfd0_log[idx] = volatileLoad(addr rf.optimizeCtrlD0)
    nim_wifi_rf_stage_rf1600_log[idx] = volatileLoad(addr rf.txcalTosdac600)
    nim_wifi_rf_stage_rf162c_log[idx] = volatileLoad(addr rf.scanTxMeasureControl62c)
    nim_wifi_rf_stage_rfb0_log[idx] = volatileLoad(addr rf.channelCalStrobeB0)
    nim_wifi_rf_stage_rfb4_log[idx] = volatileLoad(addr rf.channelCalStatusB4)
    nim_wifi_rf_stage_rfbc_log[idx] = volatileLoad(addr rf.channelFcalConfigBc)

  proc writeRfPriFixedCommonPreBranch() =
    ## Common pre-branch writes from librf_bl808.a:rf_pri.c.o
    ## rf_pri_fixed_val_regs.
    let rf = rfRegs()
    let pll = rfPllRegs()
    let dfe = rfDfeInitRegs()
    updateReg32(addr rf.calSingenMeasurePrep21c, 0xEFFFEFFF'u32, 0'u32)
    updateReg32(addr rf.bandwidthCtrl94, 0xFFFFFFFF'u32, 0x30010000'u32)
    updateReg32(addr rf.rxMode220, 0xFFFFFFFF'u32, 0x00000600'u32)
    updateReg32(addr rf.scanSynthControl608, 0xDFFFFFFF'u32, 0'u32)
    updateReg32(addr rf.synthDfePathControl63c, 0x00000000'u32, 0'u32)
    updateReg32(addr rf.calPathCtrl90, 0xFFFFFFF8'u32, 0x00000004'u32)
    updateReg32(addr rf.measureCtrl618, 0x3FFFFFFF'u32, 0'u32)
    updateReg32(addr rf.modemPathEnable504, 0xFFFFFFFF'u32, 0x00100000'u32)
    updateReg32(addr dfe.dfeRfFixedDefault884, 0xCFFF1FFF'u32, 0x20008000'u32)
    updateReg32(addr dfe.dfeRfFixedCtrl814, 0xFFFFF0FF'u32, 0x00000300'u32)
    updateReg32(addr pll.pllFixedDefault84, 0xFFFF7FFF'u32, 0'u32)
    updateReg32(addr rf.rxMode220, 0xFFFFFFEF'u32, 0'u32)
    updateReg32(addr rf.rxModeCalibrationGate78, 0xCFFFFFFF'u32, 0'u32)
    updateReg32(addr pll.refdivCtrl14, 0xFCCFFFFF'u32, 0x00100000'u32)

  proc writeRfPriFixedCommonPostBranch() =
    ## Common post-branch writes from librf_bl808.a:rf_pri.c.o
    ## rf_pri_fixed_val_regs.
    let rf = rfRegs()
    let dfe = rfDfeInitRegs()
    updateReg32(addr dfe.hbnCtrl30, 0xF0FFFFFF'u32, 0x08000000'u32)
    updateReg32(addr rf.priModeCtrl30, 0xFFFFFFFF'u32, 0x00001003'u32)
    updateReg32(addr dfe.dfeRfFixedDefault884, 0xFFFFFFFF'u32, 0x00000004'u32)
    updateReg32(addr rf.channelCalStrobeB0, 0xFFFFFF3F'u32, 0x00000040'u32)
    updateReg32(addr rf.rfPriBiasTrimCc, 0xFFFFFFFF'u32, 0x00200000'u32)
    updateReg32(addr rf.acalCtrlA4, 0xFFFFFFF8'u32, 0x00000005'u32)
    updateReg32(addr rf.acalCtrlA4, 0xFFFFF0FF'u32, 0x00000A00'u32)
    updateReg32(addr rf.txcalCtrlB8, 0xFFFFFFFF'u32, 0x00000010'u32)
    updateReg32(addr rf.calModeDefault138, 0xFFFFFFFF'u32, 0x00000003'u32)
    updateReg32(addr rf.channelCalStrobeB0, 0xFFFFFFFE'u32, 0'u32)
    updateReg32(addr rf.channelCalStatusB4, 0xFFFCC7FF'u32, 0x0000C000'u32)
    updateReg32(addr rf.calCtrl1c, 0xFFFFFF7F'u32, 0'u32)
    updateReg32(addr rf.baseCtrl1, 0xFFFFFFF3'u32, 0x00000004'u32)
    updateReg32(addr rf.rfCodeConfig110c, 0xFFFFFF00'u32, 0x00000066'u32)
    updateReg32(addr rf.roscalCtrl7c, 0xFFFFFF8F'u32, 0x00000030'u32)
    updateReg32(addr rf.txcalDfe88, 0xFFFF8FFF'u32, 0x00004000'u32)
    updateReg32(addr rf.channelCalStrobeB0, 0xFFFFFFFB'u32, 0'u32)
    updateReg32(addr rf.txcalParam70, 0xFFFFF8FF'u32, 0x00000270'u32)
    updateReg32(addr rf.txcalGain68, 0xC00C0088'u32, 0xE17E0244'u32)
    updateReg32(addr rf.rfBiasTrimD4, 0xFFF0F00F'u32, 0x00F013C1'u32)

  proc writeRfPriFixedPowerCompTailDefaults() =
    ## TX power-compensation tail writes from librf_bl808.a:rf_pri.c.o
    ## rf_pri_fixed_val_regs.
    ## These eight writes program the trailing TX power-compensation defaults.
    let rf = rfRegs()
    updateReg32(addr rf.txPowerCompTail7bc, 0xFFC00000'u32, 0x00177124'u32)
    updateReg32(addr rf.txPowerCompTail7c0, 0xFFC00000'u32, 0x0019E0A4'u32)
    updateReg32(addr rf.txPowerCompTail7c4, 0xFFC00000'u32, 0x0019E0A4'u32)
    updateReg32(addr rf.txPowerCompTail7c8, 0xFFC00000'u32, 0x0017C0A4'u32)
    updateReg32(addr rf.txPowerCompTail7cc, 0xFFC00000'u32, 0x0017C0A4'u32)
    updateReg32(addr rf.txPowerCompTail7d0, 0xFFC00000'u32, 0x0017C0A4'u32)
    updateReg32(addr rf.txPowerCompTail7d4, 0xFFC00000'u32, 0x00191064'u32)
    updateReg32(addr rf.txPowerCompTail7d8, 0xFFC00000'u32, 0x00177064'u32)

  proc writeRfPriStaticInit() =
    ## Typed port of librf_bl808.a:rf_pri.c.o rf_pri_init static register phase.
    let rf = rfRegs()
    let pll = rfPllRegs()
    let dfe = rfDfeInitRegs()
    updateReg32(addr pll.enableCtrl30, 0xFFFFF9FF'u32, 0x000001FC'u32)
    updateReg32(addr pll.enableCtrl30, 0xFFFFFFFF'u32, 0x00000002'u32)
    updateReg32(addr pll.enableCtrl30, 0xFFFFFFFF'u32, 0x00000001'u32)
    updateReg32(addr rf.rxMode220, 0xFFFFE67D'u32, 0'u32)
    updateReg32(addr rf.rxMode220, 0xFFFFFF9E'u32, 0'u32)
    updateReg32(addr dfe.dfeStaticCtrl820, 0xFF0FFFFF'u32, 0x00300000'u32)
    updateReg32(addr dfe.hbnCtrl30, 0xF0FFFFFF'u32, 0x08000000'u32)
    updateReg32(addr rf.priModeCtrl30, 0xFFFFFFFF'u32, 0x00001003'u32)
    updateReg32(addr dfe.dfeRfFixedDefault884, 0xF000FFFF'u32, 0x082000F4'u32)
    updateReg32(addr rf.rfPriBiasTrimCc, 0xFFFFFFFF'u32, 0x10000000'u32)
    updateReg32(addr rf.synthDfePathControl63c, 0x00000000'u32, 0'u32)
    updateReg32(addr rf.txcalGain64, 0xFFFE0008'u32, 0x00004C2C'u32)
    updateReg32(addr rf.txcalDefaultProfile128, 0xFF800800'u32, 0x004C2491'u32)
    updateReg32(addr rf.txcalDefaultProfile12c, 0xFF800800'u32, 0x004C24C2'u32)
    updateReg32(addr rf.txcalDefaultProfile130, 0xFF800FFF'u32, 0x00491000'u32)
    updateReg32(addr rf.rfBiasTrimD4, 0xFFF0F00F'u32, 0x00F013C1'u32)
    updateReg32(addr rf.calPathCtrl90, 0xFFFFFFFF'u32, 0x00010000'u32)
    updateReg32(addr rf.txcalCtrlB8, 0xFFFFFFFF'u32, 0x00000010'u32)
    updateReg32(addr rf.calModeDefault138, 0xFFFFFFFF'u32, 0x00000003'u32)
    updateReg32(addr rf.txcalDefaultProfile130, 0xFFFFFE92'u32, 0x00000092'u32)
    updateReg32(addr rf.calPathConfig8c, 0xFFFFFFF8'u32, 0x00000002'u32)
    updateReg32(addr rf.measureCtrl618, 0x3FFFFFFF'u32, 0'u32)
    updateReg32(addr rf.rxMode220, 0xFFFFFFEF'u32, 0'u32)

  proc writeRfPriFixedValueRegs() =
    ## Port of librf_bl808.a:rf_pri.c.o rf_pri_fixed_val_regs.
    nim_wifi_rf_fixed_val_breakpoint()
    rfPriSnapshotStage(0xF100'u32)
    rfPhyTraceCheckpoint(rfPriTracePhase(0x1C00'u32))
    rfPhyTraceCheckpoint(rfPriTracePhase(0x1D00'u32))
    writeRfPriFixedCommonPreBranch()
    rfPriSnapshotStage(0xF101'u32)
    let rf = rfRegs()
    let dfe = rfDfeInitRegs()
    if rfPriIsWb03():
      updateReg32(addr dfe.dfeRfFixedCtrl814, 0xFFFFFFE0'u32, 0x00000015'u32)
      updateReg32(addr rf.acalCtrlA4, 0xDFFFFFFF'u32, 0x00000000'u32)
    else:
      updateReg32(addr dfe.dfeRfFixedCtrl814, 0xFFFFFFE0'u32, 0x0000001B'u32)
      updateReg32(addr rf.acalCtrlA4, 0xFFFFFFFF'u32, 0x20000000'u32)
    rfPhyTraceCheckpoint(0x1E'u32)
    writeRfPriFixedCommonPostBranch()
    writeRfPriFixedPowerCompTailDefaults()
    rfPriSnapshotStage(0xF102'u32)
    inc nim_wifi_rf_fixed_val_count
    nim_wifi_rf_fixed_val_device = rfPriDeviceTraceWord()
    nim_wifi_rf_fixed_val_branch = uint32(rfPriIsWb03())
    nim_wifi_rf_fixed_val_rf70 = volatileLoad(addr rf.txcalParam70)
    nim_wifi_rf_fixed_val_rf88 = volatileLoad(addr rf.txcalDfe88)
    nim_wifi_rf_fixed_val_rfd0 = volatileLoad(addr rf.optimizeCtrlD0)
    nim_wifi_rf_fixed_val_rf814 = volatileLoad(addr dfe.dfeRfFixedCtrl814)
    nim_wifi_rf_fixed_val_rfa0 = volatileLoad(addr rf.acalCtrlA4)
    rfPhyTraceCheckpoint(0x1F'u32)
    rfPhyTraceCheckpoint(0x20'u32)

  proc rfPriApplyWb03RuntimeLatches() =
    if rfPriIsWb03():
      let rf = rfRegs()
      updateReg32(addr rf.calPathCtrl90, 0xFFFFFFFF'u32, 0x00010000'u32)
      updateReg32(addr rf.txcalDfe88, 0xFFFFFFFF'u32, 0x00010000'u32)
      updateReg32(addr rf.acalCtrlA4, 0xFFFFFFFF'u32, 0x00000100'u32)

  var nim_wifi_rf_pri_txcal_count* {.exportc.}: uint32
  var nim_wifi_rf_pri_lo_fcal_count* {.exportc.}: uint32
  var nim_wifi_rf_pri_lo_acal_count* {.exportc.}: uint32
  var nim_wifi_rf_pri_roscal_count* {.exportc.}: uint32
  var nim_wifi_rf_pri_rccal_count* {.exportc.}: uint32
  var nim_wifi_rf_pri_rxcal_count* {.exportc.}: uint32
  var nim_wifi_rf_fcal_wait_timeout_count* {.exportc.}: uint32
  var nim_wifi_rf_roscal_wait_timeout_count* {.exportc.}: uint32
  var nim_wifi_rf_rccal_wait_timeout_count* {.exportc.}: uint32
  var nim_wifi_rf_txcal_wait_timeout_count* {.exportc.}: uint32
  var nim_wifi_rf_rxcal_wait_timeout_count* {.exportc.}: uint32
  var nim_wifi_rf_measure_wait_timeout_count* {.exportc.}: uint32
  var nim_wifi_rf_config_channel_wait_timeout_count* {.exportc.}: uint32
  var nim_wifi_rf_txcal_search_count* {.exportc.}: uint32
  var nim_wifi_rf_txcal_amp_search_count* {.exportc.}: uint32
  var nim_wifi_rf_rxcal_search_count* {.exportc.}: uint32
  var nim_wifi_rf_last_roscal_i* {.exportc.}: uint32
  var nim_wifi_rf_last_roscal_q* {.exportc.}: uint32
  var nim_wifi_rf_last_rccal_code* {.exportc.}: uint32
  var nim_wifi_rf_last_rccal_baseline* {.exportc.}: uint32
  var nim_wifi_rf_last_rccal_target* {.exportc.}: uint32
  var nim_wifi_rf_last_rccal_power* {.exportc.}: uint32
  var nim_wifi_rf_last_lo_fcal* {.exportc.}: uint32
  var nim_wifi_rf_last_lo_acal* {.exportc.}: uint32
  var nim_wifi_rf_last_txcal_word0* {.exportc.}: uint32
  var nim_wifi_rf_last_txcal_word1* {.exportc.}: uint32
  var nim_wifi_rf_last_txcal_amp* {.exportc.}: uint32
  var nim_wifi_rf_last_txcal_amp_mean* {.exportc.}: uint32
  var nim_wifi_rf_last_txcal_tmxcs* {.exportc.}: uint32
  var nim_wifi_rf_last_txcal_tmxcs_power* {.exportc.}: uint32
  var preRf70TxcalSingenAmplitude* {.exportc: "nim_wifi_rf_pre_rf70_txcal_amp".}: uint32
  var preRf70TxcalAdcMean* {.exportc: "nim_wifi_rf_pre_rf70_txcal_amp_mean".}: uint32
  var preRf70TxcalParamReg* {.exportc: "nim_wifi_rf_pre_rf70_rf70".}: uint32
  var preRf70TxcalMixerDcReg* {.exportc: "nim_wifi_rf_pre_rf70_rf6c".}: uint32
  var preRf70SingenControlReg* {.exportc: "nim_wifi_rf_pre_rf70_rf120c".}: uint32
  var preRf70SingenAmplitudeLoReg* {.exportc: "nim_wifi_rf_pre_rf70_rf1214".}: uint32
  var preRf70SingenAmplitudeHiReg* {.exportc: "nim_wifi_rf_pre_rf70_rf1218".}: uint32
  var preRf70AverageMeasureCtrlReg* {.exportc: "nim_wifi_rf_pre_rf70_rf1618".}: uint32
  var preRf70AverageMeasureModeReg* {.exportc: "nim_wifi_rf_pre_rf70_rf161c".}: uint32
  var nim_wifi_rf_last_rxcal_word0* {.exportc.}: uint32
  var nim_wifi_rf_last_rxcal_word1* {.exportc.}: uint32
  var nim_wifi_rf_last_rxcal_power* {.exportc.}: uint32
  var nim_wifi_rf_last_config_channel_index* {.exportc.}: uint32
  var nim_wifi_rf_last_config_channel_status* {.exportc.}: uint32
  var nim_wifi_rf_last_config_channel_fcal* {.exportc.}: uint32
  var nim_wifi_rf_last_config_channel_acal* {.exportc.}: uint32
  var nim_wifi_rf_last_config_channel_sdm2* {.exportc.}: uint32
  var nim_wifi_rf_last_config_channel_b8* {.exportc.}: uint32
  var nim_wifi_rf_last_config_channel_b0* {.exportc.}: uint32
  var nim_wifi_rf_cw_start_count* {.exportc.}: uint32
  var nim_wifi_rf_cw_start_channel* {.exportc.}: uint32
  var nim_wifi_rf_cw_start_power_index* {.exportc.}: uint32
  var nim_wifi_rf_cw_start_channel_index* {.exportc.}: uint32
  var nim_wifi_rf_cw_start_sdm_div* {.exportc.}: uint32
  var nim_wifi_rf_cw_start_rf220* {.exportc.}: uint32
  var nim_wifi_rf_cw_start_rf20c* {.exportc.}: uint32
  var nim_wifi_rf_cw_start_rf214* {.exportc.}: uint32
  var nim_wifi_rf_cw_start_rf218* {.exportc.}: uint32
  var nim_wifi_rf_txcal_word0_log* {.exportc.}: array[RfPriTxcalSearchRecords, uint32]
  var nim_wifi_rf_txcal_word1_log* {.exportc.}: array[RfPriTxcalSearchRecords, uint32]
  var nim_wifi_rf_txcal_power_log* {.exportc.}: array[RfPriTxcalSearchRecords, uint32]
  var nim_wifi_rf_txcal_amp_log* {.exportc.}: array[RfPriTxcalSearchRecords, uint32]
  var nim_wifi_rf_txcal_tmxcs_power_log* {.exportc.}: array[RfTxcalMixerCsCount, uint32]
  var nim_wifi_rf_txcal_sample_count* {.exportc.}: uint32
  var nim_wifi_rf_txcal_sample_param_log* {.exportc.}: array[RfTxcalSampleTraceEntries, uint32]
  var nim_wifi_rf_txcal_sample_candidate_log* {.exportc.}: array[RfTxcalSampleTraceEntries, uint32]
  var nim_wifi_rf_txcal_sample_freq_log* {.exportc.}: array[RfTxcalSampleTraceEntries, uint32]
  var nim_wifi_rf_txcal_sample_ctrl_log* {.exportc.}: array[RfTxcalSampleTraceEntries, uint32]
  var nim_wifi_rf_txcal_sample_i_log* {.exportc.}: array[RfTxcalSampleTraceEntries, uint32]
  var nim_wifi_rf_txcal_sample_q_log* {.exportc.}: array[RfTxcalSampleTraceEntries, uint32]
  var nim_wifi_rf_txcal_sample_power_log* {.exportc.}: array[RfTxcalSampleTraceEntries, uint32]
  var nim_wifi_rf_rxcal_word0_log* {.exportc.}: array[4, uint32]
  var nim_wifi_rf_rxcal_word1_log* {.exportc.}: array[4, uint32]
  var nim_wifi_rf_rxcal_power_log* {.exportc.}: array[4, uint32]
  var nim_wifi_rf_bz_txcal_snapshot_count* {.exportc.}: uint32
  var nim_wifi_rf_bz_txcal_snapshot_tag* {.exportc.}: uint32
  var nim_wifi_rf_bz_txcal_word0_log* {.exportc.}: array[9, uint32]
  var nim_wifi_rf_bz_txcal_word1_log* {.exportc.}: array[9, uint32]
  var nim_wifi_rf_bz_txcal_ok_mask_log* {.exportc.}: array[9, uint32]
  var nim_wifi_rf_bz_txcal_power_log* {.exportc.}: array[9, uint32]
  var nim_wifi_rf_bz_txcal_rf48_log* {.exportc.}: array[8, uint32]
  var nim_wifi_rf_bz_txcal_rf4c_log* {.exportc.}: array[8, uint32]
  var nim_wifi_rf_bz_txcal_rf88_log* {.exportc.}: array[8, uint32]
  var nim_wifi_rf_bz_txcal_rf1600_log* {.exportc.}: array[8, uint32]
  var nim_wifi_rf_bz_txcal_rf162c_log* {.exportc.}: array[8, uint32]
  var nim_wifi_rf_bz_txcal_tag_log* {.exportc.}: array[8, uint32]
  var nim_wifi_rf_tx_power_replay_mode* {.exportc.}: uint32
  var nim_wifi_rf_tx_power_replay_skip_reason* {.exportc.}: uint32
  var nim_wifi_rf_tx_power_txcal_complete* {.exportc.}: uint32
  var nim_wifi_rf_tx_power_bz_txcal_complete* {.exportc.}: uint32

  proc sampleRfTxcalAverage(): tuple[ok: bool, value: int32]
  proc rfPriConfigChannelForCal(index: int)
  var nim_wifi_rf_roscal_search_log* {.exportc.}: array[16, uint32]
  var nim_wifi_rf_fcal_search_log* {.exportc.}: array[16, uint32]
  var nim_wifi_rf_rccal_search_log* {.exportc.}: array[32, uint32]
  var nim_wifi_rf_rccal_power_log* {.exportc.}: array[32, uint32]

  proc rfPriApplyWb03RxcalTosdacLatch() =
    if not rfPriIsWb03() or
        bl808RfXtalIndex != xtalIndex(WlXtal40M):
      return
    let rf = rfRegs()
    updateReg32(addr rf.txcalTosdac600, not RfPriWb03RxcalTosdacReplayMask,
                RfPriWb03RxcalTosdacSeed and
                RfPriWb03RxcalTosdacReplayMask)

  proc rfSignedByte(value: uint8): int16 {.inline.} =
    cast[int8](value).int16

  proc rfSignExtend16(value: int32): int16 {.inline.} =
    cast[int16](uint16(value and 0xFFFF'i32))

  proc rfCalibWord(index: int): uint32 {.inline.} =
    cast[ptr UncheckedArray[uint32]](rfCalibDataGlobal)[index]

  proc rfCalibSetWord(index: int, value: uint32) {.inline.} =
    cast[ptr UncheckedArray[uint32]](rfCalibDataGlobal)[index] = value

  proc rfCalibHalf(index: int): uint16 {.inline.} =
    cast[ptr UncheckedArray[uint16]](rfCalibDataGlobal)[index]

  proc rfCalibSetHalf(index: int, value: uint16) {.inline.} =
    cast[ptr UncheckedArray[uint16]](rfCalibDataGlobal)[index] = value

  proc rfCalibByte(offset: int): uint8 {.inline.} =
    cast[ptr UncheckedArray[uint8]](rfCalibDataGlobal)[offset]

  proc rfCalibSetByte(offset: int, value: uint8) {.inline.} =
    cast[ptr UncheckedArray[uint8]](rfCalibDataGlobal)[offset] = value

  proc rfCalibBzTxcalRecordByteOffset(record: int): int {.inline.} =
    RfCalibBzTxcalRecordBaseByte +
      record * RfCalibBzTxcalRecordStrideBytes

  proc rfCalibBzTxcalRecordWord0(record: int): uint32 {.inline.} =
    let offset = rfCalibBzTxcalRecordByteOffset(record)
    rfCalibByte(offset).uint32 or
      (rfCalibByte(offset + 1).uint32 shl 8) or
      (rfCalibHalf((offset + 2) div 2).uint32 shl 16)

  proc rfCalibBzTxcalRecordWord1(record: int): uint32 {.inline.} =
    let offset = rfCalibBzTxcalRecordByteOffset(record)
    rfCalibHalf((offset + 4) div 2).uint32

  proc rfCalibStoreBzTxcalRecordWords(record: int; word0, word1: uint32) =
    let offset = rfCalibBzTxcalRecordByteOffset(record)
    rfCalibSetByte(offset, (word0 and 0xFF'u32).uint8)
    rfCalibSetByte(offset + 1, ((word0 shr 8) and 0xFF'u32).uint8)
    rfCalibSetHalf((offset + 2) div 2, ((word0 shr 16) and 0xFFFF'u32).uint16)
    rfCalibSetHalf((offset + 4) div 2, (word1 and 0xFFFF'u32).uint16)

  proc rfPriSnapshotBzTxcalState(tag: uint32) =
    nim_wifi_rf_bz_txcal_snapshot_tag = tag
    let rf = rfRegs()
    let idx = int(nim_wifi_rf_bz_txcal_snapshot_count and 0x7'u32)
    inc nim_wifi_rf_bz_txcal_snapshot_count
    nim_wifi_rf_bz_txcal_tag_log[idx] = tag
    nim_wifi_rf_bz_txcal_rf48_log[idx] = volatileLoad(addr rf.rccalTone48)
    nim_wifi_rf_bz_txcal_rf4c_log[idx] = volatileLoad(addr rf.scanRxLatch4c)
    nim_wifi_rf_bz_txcal_rf88_log[idx] = volatileLoad(addr rf.txcalDfe88)
    nim_wifi_rf_bz_txcal_rf1600_log[idx] = volatileLoad(addr rf.txcalTosdac600)
    nim_wifi_rf_bz_txcal_rf162c_log[idx] = volatileLoad(addr rf.scanTxMeasureControl62c)
    if rfCalibDataGlobal == nil:
      return
    for record in 0 ..< 9:
      nim_wifi_rf_bz_txcal_word0_log[record] =
        rfCalibBzTxcalRecordWord0(record)
      nim_wifi_rf_bz_txcal_word1_log[record] =
        rfCalibBzTxcalRecordWord1(record)

  proc rfCalibRf70ReplayLowBandWord(): uint32 {.inline.} =
    rfCalibWord(RfCalibRf70ReplayLowBandWordIndex)

  proc rfCalibRf70ReplayHighBandWord(): uint32 {.inline.} =
    rfCalibWord(RfCalibRf70ReplayHighBandWordIndex)

  proc rfCalibSetRf70ReplayLowBandWord(value: uint32) {.inline.} =
    rfCalibSetWord(RfCalibRf70ReplayLowBandWordIndex, value)

  proc rfCalibSetRf70ReplayHighBandWord(value: uint32) {.inline.} =
    rfCalibSetWord(RfCalibRf70ReplayHighBandWordIndex, value)

  proc rfPriRf70ReplayWindow0Nibble(): uint32 {.inline.} =
    (rfCalibRf70ReplayLowBandWord() shr 24) and 0xF'u32

  proc rfPriRf70ReplayWindow1Nibble(): uint32 {.inline.} =
    (rfCalibRf70ReplayHighBandWord() shr 8) and 0xF'u32

  proc rfPriRf70ReplayWindow2Nibble(): uint32 {.inline.} =
    (rfCalibRf70ReplayHighBandWord() shr 4) and 0xF'u32

  proc rfPriRefreshRf70ReplayWindowDiagnostics() =
    if rfCalibDataGlobal == nil:
      rf70ReplayWindowValidMask = 0'u32
      rf70ReplayWindow0SourceNibble = 0'u32
      rf70ReplayWindow1SourceNibble = 0'u32
      rf70ReplayWindow2SourceNibble = 0'u32
      return
    let lowBandReplayWord = rfCalibRf70ReplayLowBandWord()
    let highBandReplayWord = rfCalibRf70ReplayHighBandWord()
    rf70ReplayWindow0SourceNibble = (lowBandReplayWord shr 24) and 0xF'u32
    rf70ReplayWindow1SourceNibble = (highBandReplayWord shr 8) and 0xF'u32
    rf70ReplayWindow2SourceNibble = (highBandReplayWord shr 4) and 0xF'u32
    rf70ReplayWindowValidMask =
      (if lowBandReplayWord != 0'u32: 0x1'u32 else: 0'u32) or
      (if (highBandReplayWord and 0x00000F00'u32) != 0'u32: 0x2'u32 else: 0'u32) or
      (if (highBandReplayWord and 0x000000F0'u32) != 0'u32: 0x4'u32 else: 0'u32)

  proc rfPriStoreRf70ReplayWindowNibbles(window0, window1, window2: uint32) =
    rfCalibSetRf70ReplayLowBandWord(
      (rfCalibRf70ReplayLowBandWord() and 0x00FF_FFFF'u32) or
      ((window0 and 0xF'u32) shl 24))
    rfCalibSetRf70ReplayHighBandWord(
      (rfCalibRf70ReplayHighBandWord() and 0xFFFF_F00F'u32) or
      ((window1 and 0xF'u32) shl 8) or
      ((window2 and 0xF'u32) shl 4))
    rfPriRefreshRf70ReplayWindowDiagnostics()

  proc rfPriApplyTxcalLowBandRf70ReplayNibble() =
    ## Port of librf_bl808.a:rf_pri.c.o rf_pri_txcal+0x534..0x54a.
    ## After the three replay-window searches, vendor reloads RF70[3:0] from
    ## rf_calib_data+0x0c bits 27:24 before entering the general TXCAL record
    ## search loop.
    if rfCalibDataGlobal == nil:
      return
    updateReg32(addr rfRegs().txcalParam70, 0xFFFF_FFF0'u32,
                rfPriRf70ReplayWindow0Nibble())

  proc rfPriRecordRf70SearchWindow(window: int; ok: bool;
                                   bestNibble, runnerUpNibble: uint32;
                                   bestSample, runnerUpSample: int32;
                                   measureCtrl, measureMode, measureIRaw: uint32) =
    if window < 0 or window >= 3:
      return
    rf70ReplaySearchBestNibble[window] = bestNibble and 0xF'u32
    rf70ReplaySearchRunnerUpNibble[window] = runnerUpNibble and 0xF'u32
    rf70ReplaySearchBestSample[window] = cast[uint32](bestSample)
    rf70ReplaySearchRunnerUpSample[window] = cast[uint32](runnerUpSample)
    rf70ReplaySearchMeasureCtrl[window] = measureCtrl
    rf70ReplaySearchMeasureMode[window] = measureMode
    rf70ReplaySearchMeasureIRaw[window] = measureIRaw
    if ok:
      nim_wifi_rf_rf70_txcal_search_ok_mask =
        nim_wifi_rf_rf70_txcal_search_ok_mask or (1'u32 shl uint32(window))

  proc rfPriSearchRf70ReplayWindow(window: int): tuple[ok: bool, nibble: uint32] =
    ## Port boundary for librf_bl808.a:rf_pri.c.o rf_pri_txcal RF70
    ## replay-source scans:
    ##   +0x316..0x3a2 -> rf_calib_data+0x0c bits 27:24
    ##   +0x3da..0x466 -> rf_calib_data+0x10 bits 11:8
    ##   +0x49e..0x52a -> rf_calib_data+0x10 bits 7:4
    ##
    ## Each window writes candidate RF70 low nibbles 0..15 and tracks the two
    ## strongest signed measurements. LLVM objdump shows the vendor path stores
    ## the strongest nibble, except when the top two candidates are adjacent; in
    ## that case it stores the lower adjacent nibble.
    inc nim_wifi_rf_rf70_txcal_search_count
    var bestNibble = 5'u32
    var runnerUpNibble = 5'u32
    var bestSample = low(int32)
    var runnerUpSample = low(int32)
    var lastMeasureCtrl = 0'u32
    var lastMeasureMode = 0'u32
    var lastMeasureIRaw = 0'u32
    let rf = rfRegs()
    let originalRf70 = volatileLoad(addr rf.txcalParam70)
    for candidate in 0'u32 .. 15'u32:
      updateReg32(addr rf.txcalParam70, 0xFFFF_FFF0'u32, candidate)
      let sample = sampleRfTxcalAverage()
      let candidateTraceIndex = window * 16 + int(candidate)
      if candidateTraceIndex >= 0 and candidateTraceIndex < 48:
        rf70ReplayCandidateAverageSample[candidateTraceIndex] =
          if sample.ok: cast[uint32](sample.value) else: 0x8000_0000'u32
      if sample.ok:
        rf70ReplayCandidateValidMask[window] =
          rf70ReplayCandidateValidMask[window] or
          (1'u32 shl candidate)
      lastMeasureCtrl = volatileLoad(addr rf.measureCtrl618)
      lastMeasureMode = volatileLoad(addr rf.measureMode61c)
      lastMeasureIRaw = volatileLoad(addr rf.measureI620)
      if sample.ok:
        if sample.value > bestSample:
          runnerUpSample = bestSample
          runnerUpNibble = bestNibble
          bestSample = sample.value
          bestNibble = candidate
        elif sample.value > runnerUpSample:
          runnerUpSample = sample.value
          runnerUpNibble = candidate
    volatileStore(addr rf.txcalParam70, originalRf70)

    let adjacent =
      (int32(bestNibble) - int32(runnerUpNibble) == 1'i32) or
      (int32(runnerUpNibble) - int32(bestNibble) == 1'i32)
    let ok = bestSample != low(int32)
    let selected =
      if ok and adjacent and runnerUpSample != low(int32):
        min(bestNibble, runnerUpNibble)
      elif ok:
        bestNibble
      else:
        RfPriWb03Rf70ColdSeed and 0xF'u32
    rfPriRecordRf70SearchWindow(
      window, ok, bestNibble, runnerUpNibble, bestSample, runnerUpSample,
      lastMeasureCtrl, lastMeasureMode, lastMeasureIRaw)
    (ok, selected)

  proc rfPriPopulateWb03TxcalRf70ReplayFieldsFromSearch(): bool =
    if not rfPriIsWb03() or
        bl808RfXtalIndex != xtalIndex(WlXtal40M) or
        rfCalibDataGlobal == nil:
      return false
    nim_wifi_rf_rf70_txcal_search_ok_mask = 0'u32
    for i in 0 ..< 3:
      rf70ReplaySearchBestNibble[i] = 0'u32
      rf70ReplaySearchRunnerUpNibble[i] = 0'u32
      rf70ReplaySearchBestSample[i] = 0'u32
      rf70ReplaySearchRunnerUpSample[i] = 0'u32
      rf70ReplaySearchMeasureCtrl[i] = 0'u32
      rf70ReplaySearchMeasureMode[i] = 0'u32
      rf70ReplaySearchMeasureIRaw[i] = 0'u32
      rf70ReplayCandidateValidMask[i] = 0'u32
      for candidate in 0 ..< 16:
        rf70ReplayCandidateAverageSample[i * 16 + candidate] = 0'u32
    let window0 = rfPriSearchRf70ReplayWindow(0)
    rfPriConfigChannelForCal(2)
    let window1 = rfPriSearchRf70ReplayWindow(1)
    rfPriConfigChannelForCal(0x11)
    let window2 = rfPriSearchRf70ReplayWindow(2)
    rfPriConfigChannelForCal(9)
    if window0.ok and window1.ok and window2.ok:
      if bl808WifiRfWb03ApplyMeasuredRf70Replay:
        rfPriStoreRf70ReplayWindowNibbles(
          window0.nibble, window1.nibble, window2.nibble)
        return true
      return false
    false

  proc rfPriReplayWb03Rf70FromTxcalCalWords() =
    ## WB03/40M vendor cold init enters the MAC-active scan transition with
    ## RF70=0x25181222. Vendor rf_pri_restore_cal_reg rebuilds RF70 from
    ## rf_calib_data word 3 bits 27:24; the matching word-4 nibble is consumed
    ## later by rf_pri_optimize. Keep this replay explicit so logs distinguish
    ## a true TXCAL-produced source field from a late fallback.
    if not rfPriIsWb03() or
        bl808RfXtalIndex != xtalIndex(WlXtal40M) or
        rfCalibDataGlobal == nil:
      nim_wifi_rf_rf70_replay_reason = RfPriRf70ReplayNotApplicable
      rfPriRefreshRf70ReplayWindowDiagnostics()
      return
    let lowBandReplayWordBefore = rfCalibRf70ReplayLowBandWord()
    let highBandReplayWordBefore = rfCalibRf70ReplayHighBandWord()
    let rf = rfRegs()
    if lowBandReplayWordBefore != 0'u32 or highBandReplayWordBefore != 0'u32:
      rfPriRefreshRf70ReplayWindowDiagnostics()
      let hasVendorSource = rf70ReplayWindowValidMask == 0x7'u32
      if nim_wifi_rf_rf70_replay_reason != RfPriRf70ReplayFieldsMeasuredByTxcal and
          nim_wifi_rf_rf70_replay_reason != RfPriRf70ReplayFieldsMeasuredFallback:
        nim_wifi_rf_rf70_replay_reason =
          if hasVendorSource:
            RfPriRf70ReplayFieldsPopulatedByTxcal
          else:
            RfPriRf70ReplayFieldsUnexpected
      nim_wifi_rf_rf70_replay_cal_word3_before = lowBandReplayWordBefore
      nim_wifi_rf_rf70_replay_cal_word4_before = highBandReplayWordBefore
      nim_wifi_rf_rf70_replay_reg_before = volatileLoad(addr rf.txcalParam70)
      if hasVendorSource:
        inc nim_wifi_rf_rf70_replay_apply_count
        volatileStore(addr rf.txcalParam70,
                      (RfPriWb03Rf70ColdSeed and 0xFFFF_FFF0'u32) or
                      rfPriRf70ReplayWindow0Nibble())
        nim_wifi_rf_rf70_replay_cal_word3_after =
          rfCalibRf70ReplayLowBandWord()
        nim_wifi_rf_rf70_replay_cal_word4_after =
          rfCalibRf70ReplayHighBandWord()
        nim_wifi_rf_rf70_replay_reg_after = volatileLoad(addr rf.txcalParam70)
      rfPriRefreshRf70ReplayWindowDiagnostics()
      return
    inc nim_wifi_rf_rf70_replay_apply_count
    nim_wifi_rf_rf70_replay_reason = RfPriRf70ReplayFieldsSeededAtReplay
    nim_wifi_rf_rf70_replay_reg_before = volatileLoad(addr rf.txcalParam70)
    nim_wifi_rf_rf70_replay_cal_word3_before = lowBandReplayWordBefore
    nim_wifi_rf_rf70_replay_cal_word4_before = highBandReplayWordBefore
    let nibble = RfPriWb03Rf70ColdSeed and 0xF'u32
    rfPriStoreRf70ReplayWindowNibbles(nibble, nibble, nibble)
    volatileStore(addr rf.txcalParam70, RfPriWb03Rf70ColdSeed)
    nim_wifi_rf_rf70_replay_cal_word3_after =
      rfCalibRf70ReplayLowBandWord()
    nim_wifi_rf_rf70_replay_cal_word4_after =
      rfCalibRf70ReplayHighBandWord()
    nim_wifi_rf_rf70_replay_reg_after = volatileLoad(addr rf.txcalParam70)

  proc rfPriPopulateWb03TxcalRf70ReplayFields() =
    ## LLVM objdump provenance: librf_bl808.a:rf_pri.c.o rf_pri_txcal writes
    ## RF70's replay source words before the per-record rf_pri_txcal_w2reg
    ## table path:
    ##   rf_pri_txcal+0x388..0x3a2 -> rf_calib_data+0x0c bits 27:24
    ##   rf_pri_txcal+0x450..0x466 -> rf_calib_data+0x10 bits 11:8
    ##   rf_pri_txcal+0x512..0x52a -> rf_calib_data+0x10 bits 7:4
    ## Run the recovered strongest-candidate search for UART/JTAG visibility.
    ## Applying those measured replay windows is default-off because the
    ## remaining vendor TXCAL setup is not fully recovered yet; the known
    ## WB03/40M fallback keeps scan/auth behavior stable.
    if not rfPriIsWb03() or
        bl808RfXtalIndex != xtalIndex(WlXtal40M) or
        rfCalibDataGlobal == nil:
      return
    if rfCalibRf70ReplayLowBandWord() != 0'u32 or
        rfCalibRf70ReplayHighBandWord() != 0'u32:
      return
    if rfPriPopulateWb03TxcalRf70ReplayFieldsFromSearch():
      nim_wifi_rf_rf70_replay_reason = RfPriRf70ReplayFieldsMeasuredByTxcal
      return
    nim_wifi_rf_rf70_replay_reason = RfPriRf70ReplayFieldsMeasuredFallback
    let nibble = RfPriWb03Rf70ColdSeed and 0xF'u32
    rfPriStoreRf70ReplayWindowNibbles(nibble, nibble, nibble)

  proc rfPriApplyWb03RccalSeed() =
    if not rfPriIsWb03() or
        bl808RfXtalIndex != xtalIndex(WlXtal40M):
      return
    let rf = rfRegs()
    volatileStore(addr rf.rbbRccalCtrl80, RfPriWb03RccalRf80Seed)
    volatileStore(addr rf.rccalReplay84, RfPriWb03RccalRf84Seed)
    if rfCalibDataGlobal != nil:
      let value = RfPriWb03RccalRf80Seed and RfRccalCodeMask
      rfCalibSetWord(RfCalibRccalReplayWordIndex,
        (rfCalibWord(RfCalibRccalReplayWordIndex) and not 0x00FF_FFFF'u32) or
        value or (value shl 6) or (value shl 12) or (value shl 18))

  proc rfPriApplyWb03ScanRxLatches() =
    if not rfPriIsWb03() or
        bl808RfXtalIndex != xtalIndex(WlXtal40M):
      return
    ## Hardware evidence: the scan RX latch phase is where the pure path brings
    ## RF4C/RF88 to the vendor-observed 0x01A76237/0x00011005 state. Keep this
    ## explicit until the preceding calibration/latch source is fully recovered.
    rfPriSnapshotBzTxcalState(0x4A'u32)
    rfPhyTraceCheckpoint(0x4A'u32)
    let rf = rfRegs()
    updateReg32(addr rf.calMode14, not 0'u32, 0x00040000'u32)
    updateReg32(addr rf.calCtrl1c, not 0'u32, 0x00000080'u32)
    volatileStore(addr rf.txcalParam70, RfPriWb03Rf70ScanSeed)
    volatileStore(addr rf.txcalTosdac600, RfPriWb03ScanRf1600ActiveSeed)
    volatileStore(addr rf.scanSynthControl608, RfPriWb03ScanRf1608Seed)
    volatileStore(addr rf.measureCtrl618, RfPriWb03ScanRf1618Seed)
    volatileStore(addr rf.scanTxMeasureControl62c, RfPriWb03ScanRf162cSeed)
    volatileStore(addr rf.rbbRccalCtrl80, RfPriWb03ScanRf80ActiveSeed)
    volatileStore(addr rf.fcalCtrlA0, 0x0C0C9F96'u32)
    volatileStore(addr rf.channelCalStatusB4, RfPriWb03ScanRfb4Seed)
    volatileStore(addr rf.channelFcalConfigBc, RfPriWb03ScanRfbcSeed)
    volatileStore(addr rf.scanRxLatch4c, RfPriWb03ScanRf4cSeed)
    volatileStore(addr rf.txcalDfe88, RfPriWb03ScanRf88Seed)
    volatileStore(addr rf.calPathConfig8c, RfPriWb03ScanRf8cSeed)
    rfPhyTraceCheckpoint(0x4B'u32)
    nim_wifi_rf_latch_service_enable(1'u32)
    waitRfUs(1'u32)
    rfPhyTraceCheckpoint(0x4C'u32)
    nim_wifi_rf_latch_service_enable(0'u32)
    rfPhyTraceCheckpoint(0x4D'u32)

  proc rfPriPrepareWb03MacActiveScanState() =
    ## Vendor reaches chan_pre_switch_channel's mm_active edge with these
    ## RF and modem latch inputs already set; applying them at the late scan
    ## RX filter point is too late for the MAC-active RF latch transition.
    if not rfPriIsWb03() or
        bl808RfXtalIndex != xtalIndex(WlXtal40M):
      return
    rfPriSnapshotBzTxcalState(0x45'u32)
    let rf = rfRegs()
    let bba = bbaAgcRegs()
    volatileStore(addr bba.macActiveB340, 0x00000000'u32)
    volatileStore(addr bba.macActiveB344, 0x00000000'u32)
    volatileStore(addr bba.macActiveB368, 0x00070070'u32)
    volatileStore(addr bba.pdComp36c, 0x07280510'u32)
    volatileStore(addr bba.macActiveB384, 0xE7750805'u32)
    volatileStore(addr bba.macActiveB38c, 0x6403880B'u32)
    volatileStore(addr bba.pdGain390, 0x00000001'u32)
    volatileStore(addr bba.macActiveB3a0, 0x0BF3009E'u32)
    volatileStore(addr bba.macActiveB3bc, 0x003D0900'u32)
    volatileStore(addr bba.macActiveB3c4, 0xDDDBBFCE'u32)
    volatileStore(addr bba.macActiveC01c, 0x00050050'u32)
    volatileStore(addr bba.macActiveC020, 0x00050050'u32)
    volatileStore(addr bba.macActiveC02c, 0x00000008'u32)
    volatileStore(addr rf.txcalDc6c, 0x00000644'u32)
    volatileStore(addr rf.txcalParam70, RfPriWb03MacActiveRf70Seed)
    volatileStore(addr rf.roscalCtrl7c, RfPriWb03MacActiveRf7cSeed)
    volatileStore(addr rf.fcalCtrlA0, RfPriWb03MacActiveRfa0Seed)
    volatileStore(addr rf.txcalTosdac600, RfPriWb03MacActiveRf1600Seed)
    volatileStore(addr rf.scanTxMeasureControl62c, 0x00070007'u32)
    volatileStore(addr rf.rbbRccalCtrl80, RfPriWb03MacActiveRf80Seed)
    updateReg32(addr rf.calMode14, not 0'u32, 0x00040000'u32)
    updateReg32(addr rf.calCtrl1c, not 0'u32, 0x00000080'u32)
    rfPriSnapshotBzTxcalState(0x46'u32)

  proc rfPriApplyWb03AuthTxLatches() =
    if not bl808WifiRfWb03ForceAuthTxLatches:
      return
    if not rfPriIsWb03() or
        bl808RfXtalIndex != xtalIndex(WlXtal40M):
      return
    let rf = rfRegs()
    volatileStore(addr rf.txcalParam70, RfPriWb03MacActiveRf70Seed)
    volatileStore(addr rf.roscalCtrl7c, RfPriWb03MacActiveRf7cSeed)
    volatileStore(addr rf.fcalCtrlA0, RfPriWb03MacActiveRfa0Seed)
    when bl808WifiRfWb03AuthTxPulseLatch:
      volatileStore(addr rf.txcalDfe88, RfPriWb03ScanRf88Seed)
    volatileStore(addr rf.txcalTosdac600, RfPriWb03MacActiveRf1600Seed)
    volatileStore(addr rf.scanTxMeasureControl62c, 0x00070007'u32)
    volatileStore(addr rf.rbbRccalCtrl80, RfPriWb03MacActiveRf80Seed)
    when bl808WifiRfWb03AuthTxPulseLatch:
      nim_wifi_rf_latch_service_enable(1'u32)
      waitRfUs(1'u32)
      nim_wifi_rf_latch_service_enable(0'u32)
    rfPriSnapshotBzTxcalState(0x4B'u32)
    when bl808WifiRfWb03AuthTxSettleUs > 0:
      waitRfUs(uint32(bl808WifiRfWb03AuthTxSettleUs))

  proc rfPriCaptureWb03AuthTxPrePush() =
    let rf = rfRegs()
    nimFwDbgAuthRfPrePush[0] = volatileLoad(addr rf.txcalParam70)
    nimFwDbgAuthRfPrePush[1] = volatileLoad(addr rf.txcalDfe88)
    nimFwDbgAuthRfPrePush[2] = volatileLoad(addr rf.calPathConfig8c)
    nimFwDbgAuthRfPrePush[3] = volatileLoad(addr rf.fcalCtrlA0)
    nimFwDbgAuthRfPrePush[4] = volatileLoad(addr rf.channelCalStatusB4)
    nimFwDbgAuthRfPrePush[5] = volatileLoad(addr rf.channelFcalConfigBc)
    nimFwDbgAuthRfPrePush[6] = volatileLoad(addr rf.optimizeCtrlD0)
    nimFwDbgAuthRfPrePush[7] = volatileLoad(addr rf.txcalTosdac600)

  proc captureAuthTxHwPrePush(desc: ptr HostTxDescView, thd: ptr HostTxHwDescView) =
    nimFwDbgAuthHwPrePush[0] = desc.descWord4
    nimFwDbgAuthHwPrePush[1] = cast[uint32](desc.cfmDst)
    nimFwDbgAuthHwPrePush[2] =
      desc.frameLen.uint32 or (desc.seqAssigned.uint32 shl 16)
    nimFwDbgAuthHwPrePush[3] =
      desc.staIdx.uint32 or (desc.vifIdx.uint32 shl 8) or
      (desc.hostVifType.uint32 shl 16) or (desc.staInfoIdx.uint32 shl 24)
    nimFwDbgAuthHwPrePush[4] = desc.bufferPtrs[0]
    nimFwDbgAuthHwPrePush[5] = desc.bufferLens[0]
    nimFwDbgAuthHwPrePush[6] = desc.pendingMacTime
    nimFwDbgAuthHwPrePush[7] = cast[uint32](desc.policy)
    nimFwDbgAuthHwPrePush[8] =
      desc.hdrLen.uint32 or (desc.qosExtLen.uint32 shl 8) or
      (desc.secTailLen.uint32 shl 16)
    nimFwDbgAuthHwPrePush[9] = desc.txFlags
    nimFwDbgAuthHwPrePush[10] = thd.status
    nimFwDbgAuthHwPrePush[11] = thd.payloadStart
    nimFwDbgAuthHwPrePush[12] = thd.payloadEnd
    nimFwDbgAuthHwPrePush[13] = thd.frameLen
    nimFwDbgAuthHwPrePush[14] = thd.txHwReserved32
    nimFwDbgAuthHwPrePush[15] = thd.retryLimitControl
    nimFwDbgAuthHwPrePush[16] = cast[uint32](thd.chainedThd)
    nimFwDbgAuthHwPrePush[17] = thd.txHwReserved44
    nimFwDbgAuthHwPrePush[18] = thd.txHwReserved48
    nimFwDbgAuthHwPrePush[19] = thd.controlFlags
    nimFwDbgAuthHwPrePush[20] = thd.txHwReserved52
    nimFwDbgAuthHwPrePush[21] = thd.ackPolicyControl
    nimFwDbgAuthHwPrePush[22] = thd.confirmStatus
    if thd.chainedThd != nil:
      let rate = hostTxRateTemplateAt(thd.chainedThd)
      nimFwDbgAuthHwPrePush[23] = rate.magic
      nimFwDbgAuthHwPrePush[24] = rate.ntxConfig
      nimFwDbgAuthHwPrePush[25] = rate.bwMask
      nimFwDbgAuthHwPrePush[26] = rate.policyWord
      nimFwDbgAuthHwPrePush[27] = rate.rateWord
      nimFwDbgAuthHwPrePush[28] = rate.txPower.uint32
      nimFwDbgAuthHwPrePush[29] = rate.retryTxPowerControl0
      nimFwDbgAuthHwPrePush[30] = rate.retryTxPowerControl1
      nimFwDbgAuthHwPrePush[31] = rate.retryTxPowerControl2

  proc applyForcedInternalMgmtTxPower(thd: ptr HostTxHwDescView) {.inline.} =
    when declared(NimFwForcedMgmtTxPower):
      if thd != nil and thd.chainedThd != nil:
        let rate = hostTxRateTemplateAt(thd.chainedThd)
        rate.txPower = NimFwForcedMgmtTxPower.int32
        rate.retryTxPowerControl0 = NimFwForcedMgmtTxPower
        rate.retryTxPowerControl1 = NimFwForcedMgmtTxPower
        rate.retryTxPowerControl2 = NimFwForcedMgmtTxPower

  proc rfPriWaitConfigIdleForWb03RfcEntry() =
    ## Vendor rf_pri_config_channel tolerates RF[0x10B4] bit 24 at channel
    ## entry, but bit 20 must clear after paired TXCAL/PRI strobes. The pure
    ## restore path can otherwise
    ## enter rfc_config_channel with stale busy/status bits set.
    if not rfPriIsWb03() or
        bl808RfXtalIndex != xtalIndex(WlXtal40M):
      return
    let rf = rfRegs()
    var status = volatileLoad(addr rf.channelCalStatusB4)
    if (status and 0x00100000'u32) == 0'u32:
      return
    for _ in 0 ..< RfConfigChannelWaitLimit:
      updateReg32(addr rf.txcalCtrlB8, not 0'u32, 0x00010000'u32)
      waitRfUs(10'u32)
      updateReg32(addr rf.txcalCtrlB8, not 0x00010000'u32, 0'u32)
      waitRfUs(50'u32)
      updateReg32(addr rf.channelCalStrobeB0, 0xFFFFFFFF'u32, 0x10000000'u32)
      waitRfUs(10'u32)
      updateReg32(addr rf.channelCalStrobeB0, not 0x10000000'u32, 0'u32)
      waitRfUs(50'u32)
      status = volatileLoad(addr rf.channelCalStatusB4)
      if (status and 0x00100000'u32) == 0'u32:
        return
    inc nim_wifi_rf_config_channel_wait_timeout_count
    nim_wifi_rf_last_config_channel_status = status

  proc rfPriApplyWb03RfcEntryBaseline() =
    ## Keep the scan/RFC latch inputs that are not yet naturally reproduced by
    ## pure calibration. Do not force RF70/RFA0/RFB4 here: JTAG at
    ## rfc_config_channel shows those are calibration-derived in the vendor path.
    if not rfPriIsWb03() or
        bl808RfXtalIndex != xtalIndex(WlXtal40M):
      return
    let rf = rfRegs()
    volatileStore(addr rf.txcalTosdac600, RfPriWb03RfcEntryRf1600Seed)
    volatileStore(addr rf.rbbRccalCtrl80, RfPriWb03ScanRf80ListenSeed)
    volatileStore(addr rf.channelFcalConfigBc, RfPriWb03ScanRfbcSeed)
    volatileStore(addr rf.scanSynthControl608, RfPriWb03ScanRf1608Seed)
    volatileStore(addr rf.measureCtrl618, RfPriWb03ScanRf1618Seed)
    volatileStore(addr rf.calPathConfig8c, RfPriWb03ScanRf8cSeed)
    rfPriWaitConfigIdleForWb03RfcEntry()

  proc rfPriApplyWb03ScanBaseline() =
    if not rfPriIsWb03() or
        bl808RfXtalIndex != xtalIndex(WlXtal40M):
      return
    let rf = rfRegs()
    volatileStore(addr rf.txcalTosdac600, RfPriWb03ScanRf1600BaselineSeed)
    volatileStore(addr rf.scanSynthControl608, RfPriWb03ScanRf1608Seed)
    volatileStore(addr rf.measureCtrl618, RfPriWb03ScanRf1618Seed)
    volatileStore(addr rf.rbbRccalCtrl80, RfPriWb03RccalRf80Seed)
    volatileStore(addr rf.channelCalStatusB4, RfPriWb03ScanRfb4Seed)
    volatileStore(addr rf.channelFcalConfigBc, RfPriWb03ScanRfbcSeed)
    volatileStore(addr rf.txcalDfe88, RfPriWb03ScanRf88Seed)
    volatileStore(addr rf.calPathConfig8c, RfPriWb03ScanRf8cSeed)

  proc wlCfgU32(offset: int): uint32 =
    if wlCfgGlobal == nil:
      return 0'u32
    let bytes = cast[ptr UncheckedArray[uint8]](wlCfgGlobal)
    bytes[offset].uint32 or
      (bytes[offset + 1].uint32 shl 8) or
      (bytes[offset + 2].uint32 shl 16) or
      (bytes[offset + 3].uint32 shl 24)

  proc wlCfgWb03RxcalReplayA8Word(): uint32 {.inline.} =
    wlCfgU32(WlRfCfgRxcalA8Offset)

  proc wlCfgWb03RxcalReplayAcWord(): uint32 {.inline.} =
    wlCfgU32(WlRfCfgRxcalAcOffset)

  proc rfLoFcal(index: int): uint16 {.inline.} =
    (rfCalibHalf(RfCalibLoVcoHalfwordBase + index) shr 8) and 0x00FF'u16

  proc rfLoAcal(index: int): uint16 {.inline.} =
    rfCalibHalf(RfCalibLoVcoHalfwordBase + index) and 0x003F'u16

  proc setRfLoFcal(index: int, fcal: uint16) =
    let halfIndex = RfCalibLoVcoHalfwordBase + index
    let value = (rfCalibHalf(halfIndex) and 0x00FF'u16) or
      ((fcal and 0x00FF'u16) shl 8)
    rfCalibSetHalf(halfIndex, value)

  proc setRfLoAcal(index: int, acal: uint16) =
    let halfIndex = RfCalibLoVcoHalfwordBase + index
    let value = (rfCalibHalf(halfIndex) and 0xFF00'u16) or
      (acal and 0x003F'u16)
    rfCalibSetHalf(halfIndex, value)

  proc rfCalibHasRestoreData(): bool =
    if rfCalibDataGlobal == nil:
      return false
    for index in [2, 3, 18, 19, 20, 21, 22, 23, 24, 25]:
      if rfCalibWord(index) != 0'u32:
        return true
    false

  proc rfCalibHasTxcalData(): bool =
    if rfCalibDataGlobal == nil:
      return false
    for i in 0 ..< RfPriTxcalSearchRecords * 2:
      if rfCalibWord(RfCalibTxcalRecordBaseWord + i) != 0'u32:
        return true
    false

  proc saveRfPriCalState(): RfPriCalState
  proc restoreRfPriCalState(state: RfPriCalState)

  proc waitRfFcalReady(): bool =
    let rf = rfRegs()
    for _ in 0 ..< RfFcalWaitLimit:
      if (volatileLoad(addr rf.fcalAc) and RfFcalReadyMask) != 0'u32:
        return true
      waitRfUs(1'u32)
    inc nim_wifi_rf_fcal_wait_timeout_count
    false

  proc sampleRfFcalCount(): uint16 =
    let rf = rfRegs()
    updateReg32(addr rf.fcalAc, not RfFcalReadyMask, 0'u32)
    updateReg32(addr rf.fcalAc, not 0'u32, RfFcalStartMask)
    discard waitRfFcalReady()
    result = uint16((volatileLoad(addr rf.calResultA8) shr 16) and 0xFFFF'u32)
    updateReg32(addr rf.fcalAc, not RfFcalStartMask, 0'u32)

  proc writeRfFcalCode(code: uint16) =
    let rf = rfRegs()
    updateReg32(addr rf.fcalCtrlA0, not RfFcalCodeMask,
                uint32(code and 0x00FF'u16))

  proc writeRfAcalCode(code: uint16) =
    let rf = rfRegs()
    updateReg32(addr rf.fcalCtrlA0, not RfAcalCodeMask,
                uint32(code and 0x003F'u16) shl 16)

  proc vendorLikeRfAcalForFcal(fcal: uint16): uint16 {.inline.} =
    if fcal >= 0x00A1'u16:
      0x000C'u16
    elif fcal >= 0x0090'u16:
      0x000B'u16
    else:
      0x000A'u16

  proc prepareRfPriLoFcal() =
    let rf = rfRegs()
    updateReg32(addr rf.calMode14, not 0x00000030'u32, 0x00000010'u32)
    updateReg32(addr rf.baseCtrl1, not RfCtrlTuneEnableMask, 0'u32)
    volatileStore(addr rf.synthCtrl2c, 0'u32)
    updateReg32(addr rf.priModeCtrl30, not 0'u32, 0x00000002'u32)
    updateReg32(addr rf.priModeCtrl30, 0x0CF090FF'u32, 0x0CF00000'u32)
    updateReg32(addr rf.calCtrl1c, not 0'u32, 0x00000008'u32)
    writeRfFcalCode(0x80'u16)
    updateReg32(addr rf.txcalCtrlB8, not 0x00003000'u32, 0'u32)
    updateReg32(addr rf.calResultA8, 0xFFFF0000'u32, uint32(RfLoFcalDiv))
    volatileStore(addr rf.sdmDivC4, 0x01000000'u32)
    updateReg32(addr rf.sdmCtrlC0, not 0'u32, 0x00001000'u32)
    updateReg32(addr rf.sdmCtrlC0, not 0x00010000'u32, 0'u32)
    updateReg32(addr rf.txcalCtrlB8, not 0'u32, 0x00010000'u32)
    waitRfUs(10'u32)
    updateReg32(addr rf.sdmCtrlC0, not 0'u32, 0x00010000'u32)
    updateReg32(addr rf.txcalCtrlB8, not 0x00010000'u32, 0'u32)
    waitRfUs(50'u32)
    updateReg32(addr rf.acalCtrlA4, 0xFFFFFFFC'u32, 0x00000002'u32)
    waitRfUs(50'u32)

  proc chooseRfBaseFcalCode(): uint16 =
    var code = 0x80'u16
    var logIndex = 0
    for _ in 0 ..< 4:
      var bit = 0x40'u16
      while bit != 0'u16:
        writeRfFcalCode(code)
        waitRfUs(100'u32)
        let count = sampleRfFcalCount()
        if logIndex < nim_wifi_rf_fcal_search_log.len:
          nim_wifi_rf_fcal_search_log[logIndex] =
            (uint32(code) shl 24) or (uint32(bit) shl 16) or uint32(count)
          inc logIndex
        if count < RfLoFcalLowCount:
          code = uint16((uint32(code) - uint32(bit)) and 0x00FF'u32)
        elif count > RfLoFcalHighCount:
          code = uint16((uint32(code) + uint32(bit)) and 0x00FF'u32)
        else:
          bit = 0'u16
          break
        bit = bit shr 1
      if code >= 15'u16 and code <= 240'u16:
        return code
      let rf = rfRegs()
      updateReg32(addr rf.sdmCtrlC0, not 0x00010000'u32, 0'u32)
      updateReg32(addr rf.txcalCtrlB8, not 0'u32, 0x00010000'u32)
      waitRfUs(50'u32)
      updateReg32(addr rf.sdmCtrlC0, not 0'u32, 0x00010000'u32)
      updateReg32(addr rf.txcalCtrlB8, not 0x00010000'u32, 0'u32)
      waitRfUs(50'u32)
      code = 0x80'u16
    if logIndex < nim_wifi_rf_fcal_search_log.len:
      nim_wifi_rf_fcal_search_log[logIndex] = (0xFF'u32 shl 24) or uint32(code)
    code

  proc runRfPriLoFcal() =
    if rfCalibDataGlobal == nil:
      return
    let rf = rfRegs()
    inc nim_wifi_rf_pri_lo_fcal_count
    updateReg32(addr rf.calMode14, not 0x00000030'u32, 0x00000010'u32)
    let saved = saveRfPriCalState()
    prepareRfPriLoFcal()

    let baseCode = chooseRfBaseFcalCode()
    var measured: array[42, uint16]
    var measuredLen = 0
    var code = uint16(uint32(baseCode + 1'u16) and 0x00FF'u32)
    while measuredLen < measured.len and code != 0'u16:
      writeRfFcalCode(code)
      waitRfUs(100'u32)
      measured[measuredLen] = sampleRfFcalCount()
      if measuredLen < 7:
        nim_wifi_rf_fcal_search_log[8 + measuredLen] =
          (uint32(code) shl 16) or uint32(measured[measuredLen])
      inc measuredLen
      if measured[measuredLen - 1] > RfLoFcalStopCount:
        break
      dec code

    nim_wifi_rf_fcal_search_log[15] =
      if measuredLen == 0:
        (uint32(baseCode) shl 24)
      else:
        (uint32(baseCode) shl 24) or (uint32(measuredLen) shl 16) or
          uint32(measured[measuredLen - 1])

    for i in 0 ..< RfLoChannelCount:
      var offset = 0
      while offset < measuredLen and measured[offset] < RfChannelCntTable40M[i]:
        inc offset
      var fcal: int
      if measuredLen == 0:
        fcal = int(baseCode) + 1
      elif offset == 0:
        fcal = int(baseCode) + 1
      elif offset >= measuredLen:
        fcal = int(baseCode) + 1 - (measuredLen - 1)
      else:
        fcal = int(baseCode) + 1 - offset
      if fcal < 0:
        fcal = 0
      elif fcal > 255:
        fcal = 255
      setRfLoFcal(i, uint16(fcal))

    restoreRfPriCalState(saved)
    updateReg32(addr rf.calMode14, not 0'u32, 0x00000030'u32)
    nim_wifi_rf_last_lo_fcal = uint32(rfLoFcal(RfLoChannelCount - 1))

  proc prepareRfPriLoAcal() =
    let rf = rfRegs()
    updateReg32(addr rf.calMode14, not 0x000000C0'u32, 0x00000040'u32)
    updateReg32(addr rf.baseCtrl1, not RfCtrlTuneEnableMask, 0'u32)
    volatileStore(addr rf.synthCtrl2c, 0'u32)
    updateReg32(addr rf.priModeCtrl30, not 0'u32, 0x00000002'u32)
    updateReg32(addr rf.priModeCtrl30, 0x0CF090FF'u32, 0x0CF00000'u32)
    updateReg32(addr rf.calCtrl1c, not 0'u32, 0x00000010'u32)

  proc runRfPriLoAcal() =
    if rfCalibDataGlobal == nil:
      return
    let rf = rfRegs()
    inc nim_wifi_rf_pri_lo_acal_count
    updateReg32(addr rf.calMode14, not 0x000000C0'u32, 0x00000040'u32)
    let saved = saveRfPriCalState()
    prepareRfPriLoAcal()

    for i in 0 ..< RfLoChannelCount:
      updateReg32(addr rf.acalCtrlA4, 0xFFFFF8FF'u32, 0x00000400'u32)
      updateReg32(addr rf.fcalCtrlA0, not RfAcalCodeMask, 0x00100000'u32)
      updateReg32(addr rf.fcalCtrlA0, not RfFcalCodeMask, uint32(rfLoFcal(i)))
      volatileStore(addr rf.sdmDivC4, RfChannelDivTable40M[i])
      waitRfUs(1'u32)

      var acal = 0x10'u16
      var bit = 0x08'u16
      while bit != 0'u16:
        writeRfAcalCode(acal)
        waitRfUs(1'u32)
        if (volatileLoad(addr rf.acalCtrlA4) and RfAcalComparatorMask) == 0'u32:
          acal = uint16((uint32(acal) + uint32(bit)) and 0xFFFF'u32)
        else:
          acal = uint16((uint32(acal) - uint32(bit)) and 0xFFFF'u32)
        bit = bit shr 1

      writeRfAcalCode(acal)
      waitRfUs(1'u32)
      if (volatileLoad(addr rf.acalCtrlA4) and RfAcalComparatorMask) == 0'u32 and
          acal <= 30'u16:
        inc acal
      acal = vendorLikeRfAcalForFcal(rfLoFcal(i))
      setRfLoAcal(i, acal and 0x001F'u16)

    restoreRfPriCalState(saved)
    updateReg32(addr rf.calMode14, not 0'u32, 0x000000C0'u32)
    nim_wifi_rf_last_lo_acal = uint32(rfLoAcal(RfLoChannelCount - 1))

  proc saveRfPriCalState(): RfPriCalState =
    inc nimFwDbgRfCalSaveCount
    let rf = rfRegs()
    let dfe = rfDfeInitRegs()
    result.baseCtrl1 = volatileLoad(addr rf.baseCtrl1)
    result.synthCtrl2c = volatileLoad(addr rf.synthCtrl2c)
    result.calCtrl1c = volatileLoad(addr rf.calCtrl1c)
    result.priModeCtrl30 = volatileLoad(addr rf.priModeCtrl30)
    result.txcalCtrlB8 = volatileLoad(addr rf.txcalCtrlB8)
    result.sdmCtrlC0 = volatileLoad(addr rf.sdmCtrlC0)
    result.sdmDivC4 = volatileLoad(addr rf.sdmDivC4)
    result.hbnCtrl30 = volatileLoad(addr dfe.hbnCtrl30)
    result.txcalDfe88 = volatileLoad(addr rf.txcalDfe88)
    result.calPathConfig8c = volatileLoad(addr rf.calPathConfig8c)
    result.txcalTosdac600 = volatileLoad(addr rf.txcalTosdac600)
    result.calMeasurePrep60c = volatileLoad(addr rf.calMeasurePrep60c)
    result.measureCtrl618 = volatileLoad(addr rf.measureCtrl618)
    result.measureMode61c = volatileLoad(addr rf.measureMode61c)
    result.rccalTone48 = volatileLoad(addr rf.rccalTone48)
    result.calSingenCtrl20c = volatileLoad(addr rf.calSingenCtrl20c)
    result.calSingenAmpLo214 = volatileLoad(addr rf.calSingenAmpLo214)
    result.calSingenAmpHi218 = volatileLoad(addr rf.calSingenAmpHi218)
    result.calDfeGate23c = volatileLoad(addr rf.calDfeGate23c)
    result.calDfeState240 = volatileLoad(addr rf.calDfeState240)
    result.calDfeState244 = volatileLoad(addr rf.calDfeState244)
    result.calMixerStateF0 = volatileLoad(addr rf.calMixerStateF0)
    result.txcalGain64 = volatileLoad(addr rf.txcalGain64)
    result.txcalBias58 = volatileLoad(addr rf.txcalBias58)
    result.rxMode220 = volatileLoad(addr rf.rxMode220)
    result.txcalParam74 = volatileLoad(addr rf.txcalParam74)
    result.acalCtrlA4 = volatileLoad(addr rf.acalCtrlA4)
    nimFwDbgRfCalSaveRf2c = result.synthCtrl2c
    nimFwDbgRfCalSaveRf88 = result.txcalDfe88

  proc restoreRfPriCalState(state: RfPriCalState) =
    inc nimFwDbgRfCalRestoreCount
    let rf = rfRegs()
    let dfe = rfDfeInitRegs()
    nimFwDbgRfCalRestoreRf2c = state.synthCtrl2c
    nimFwDbgRfCalRestoreRf88 = state.txcalDfe88
    volatileStore(addr rf.baseCtrl1, state.baseCtrl1)
    volatileStore(addr rf.synthCtrl2c, state.synthCtrl2c)
    volatileStore(addr rf.calCtrl1c, state.calCtrl1c)
    volatileStore(addr rf.priModeCtrl30, state.priModeCtrl30)
    volatileStore(addr rf.txcalCtrlB8, state.txcalCtrlB8)
    volatileStore(addr rf.sdmCtrlC0, state.sdmCtrlC0)
    volatileStore(addr rf.sdmDivC4, state.sdmDivC4)
    volatileStore(addr dfe.hbnCtrl30, state.hbnCtrl30)
    volatileStore(addr rf.txcalDfe88, state.txcalDfe88)
    volatileStore(addr rf.calPathConfig8c, state.calPathConfig8c)
    volatileStore(addr rf.txcalTosdac600, state.txcalTosdac600)
    volatileStore(addr rf.calMeasurePrep60c, state.calMeasurePrep60c)
    volatileStore(addr rf.measureCtrl618, state.measureCtrl618)
    volatileStore(addr rf.measureMode61c, state.measureMode61c)
    volatileStore(addr rf.rccalTone48, state.rccalTone48)
    volatileStore(addr rf.calSingenCtrl20c, state.calSingenCtrl20c)
    volatileStore(addr rf.calSingenAmpLo214, state.calSingenAmpLo214)
    volatileStore(addr rf.calSingenAmpHi218, state.calSingenAmpHi218)
    volatileStore(addr rf.calDfeGate23c, state.calDfeGate23c)
    volatileStore(addr rf.calDfeState240, state.calDfeState240)
    volatileStore(addr rf.calDfeState244, state.calDfeState244)
    volatileStore(addr rf.calMixerStateF0, state.calMixerStateF0)
    volatileStore(addr rf.txcalGain64, state.txcalGain64)
    volatileStore(addr rf.txcalBias58, state.txcalBias58)
    volatileStore(addr rf.rxMode220, state.rxMode220)
    volatileStore(addr rf.txcalParam74, state.txcalParam74)
    volatileStore(addr rf.acalCtrlA4, state.acalCtrlA4)
    nimFwDbgRfCalRestoreReadbackRf2c = volatileLoad(addr rf.synthCtrl2c)
    nimFwDbgRfCalRestoreReadbackRf88 = volatileLoad(addr rf.txcalDfe88)
    nimFwDbgRfCalRestoreRf8c = volatileLoad(addr rf.calPathConfig8c)

  proc rf_pri_save_state_before_cal() {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rf_pri.c.o
    ## rf_pri_save_state_before_cal+0x0..0x13a.
    ## Vendor saves RF[0x90], not RF[0x8C]; keep this public ABI snapshot
    ## separate from the local calibration snapshot above.
    inc nimFwDbgRfCalSaveCount
    let rf = rfRegs()
    let dfe = rfDfeInitRegs()
    bl808RfPriVendorCalState.baseCtrl1 = volatileLoad(addr rf.baseCtrl1)
    bl808RfPriVendorCalState.synthCtrl2c = volatileLoad(addr rf.synthCtrl2c)
    bl808RfPriVendorCalState.calCtrl1c = volatileLoad(addr rf.calCtrl1c)
    bl808RfPriVendorCalState.priModeCtrl30 = volatileLoad(addr rf.priModeCtrl30)
    bl808RfPriVendorCalState.txcalCtrlB8 = volatileLoad(addr rf.txcalCtrlB8)
    bl808RfPriVendorCalState.sdmCtrlC0 = volatileLoad(addr rf.sdmCtrlC0)
    bl808RfPriVendorCalState.sdmDivC4 = volatileLoad(addr rf.sdmDivC4)
    bl808RfPriVendorCalState.hbnCtrl30 = volatileLoad(addr dfe.hbnCtrl30)
    bl808RfPriVendorCalState.txcalDfe88 = volatileLoad(addr rf.txcalDfe88)
    bl808RfPriVendorCalState.calPathCtrl90 = volatileLoad(addr rf.calPathCtrl90)
    bl808RfPriVendorCalState.txcalTosdac600 = volatileLoad(addr rf.txcalTosdac600)
    bl808RfPriVendorCalState.calMeasurePrep60c = volatileLoad(addr rf.calMeasurePrep60c)
    bl808RfPriVendorCalState.measureCtrl618 = volatileLoad(addr rf.measureCtrl618)
    bl808RfPriVendorCalState.measureMode61c = volatileLoad(addr rf.measureMode61c)
    bl808RfPriVendorCalState.rccalTone48 = volatileLoad(addr rf.rccalTone48)
    bl808RfPriVendorCalState.calSingenCtrl20c = volatileLoad(addr rf.calSingenCtrl20c)
    bl808RfPriVendorCalState.calSingenAmpLo214 = volatileLoad(addr rf.calSingenAmpLo214)
    bl808RfPriVendorCalState.calSingenAmpHi218 = volatileLoad(addr rf.calSingenAmpHi218)
    bl808RfPriVendorCalState.calDfeGate23c = volatileLoad(addr rf.calDfeGate23c)
    bl808RfPriVendorCalState.calDfeState240 = volatileLoad(addr rf.calDfeState240)
    bl808RfPriVendorCalState.calDfeState244 = volatileLoad(addr rf.calDfeState244)
    bl808RfPriVendorCalState.calMixerStateF0 = volatileLoad(addr rf.calMixerStateF0)
    bl808RfPriVendorCalState.txcalGain64 = volatileLoad(addr rf.txcalGain64)
    bl808RfPriVendorCalState.txcalBias58 = volatileLoad(addr rf.txcalBias58)
    bl808RfPriVendorCalState.rxMode220 = volatileLoad(addr rf.rxMode220)
    bl808RfPriVendorCalState.txcalParam74 = volatileLoad(addr rf.txcalParam74)
    bl808RfPriVendorCalState.acalCtrlA4 = volatileLoad(addr rf.acalCtrlA4)
    nimFwDbgRfCalSaveRf2c = bl808RfPriVendorCalState.synthCtrl2c
    nimFwDbgRfCalSaveRf88 = bl808RfPriVendorCalState.txcalDfe88

  proc rf_pri_restore_state_after_cal() {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rf_pri.c.o
    ## rf_pri_restore_state_after_cal+0x0..0x13a.
    inc nimFwDbgRfCalRestoreCount
    let rf = rfRegs()
    let dfe = rfDfeInitRegs()
    nimFwDbgRfCalRestoreRf2c = bl808RfPriVendorCalState.synthCtrl2c
    nimFwDbgRfCalRestoreRf88 = bl808RfPriVendorCalState.txcalDfe88
    volatileStore(addr rf.baseCtrl1, bl808RfPriVendorCalState.baseCtrl1)
    volatileStore(addr rf.synthCtrl2c, bl808RfPriVendorCalState.synthCtrl2c)
    volatileStore(addr rf.calCtrl1c, bl808RfPriVendorCalState.calCtrl1c)
    volatileStore(addr rf.priModeCtrl30, bl808RfPriVendorCalState.priModeCtrl30)
    volatileStore(addr rf.txcalCtrlB8, bl808RfPriVendorCalState.txcalCtrlB8)
    volatileStore(addr rf.sdmCtrlC0, bl808RfPriVendorCalState.sdmCtrlC0)
    volatileStore(addr rf.sdmDivC4, bl808RfPriVendorCalState.sdmDivC4)
    volatileStore(addr dfe.hbnCtrl30, bl808RfPriVendorCalState.hbnCtrl30)
    volatileStore(addr rf.txcalDfe88, bl808RfPriVendorCalState.txcalDfe88)
    volatileStore(addr rf.calPathCtrl90, bl808RfPriVendorCalState.calPathCtrl90)
    volatileStore(addr rf.txcalTosdac600, bl808RfPriVendorCalState.txcalTosdac600)
    volatileStore(addr rf.calMeasurePrep60c, bl808RfPriVendorCalState.calMeasurePrep60c)
    volatileStore(addr rf.measureCtrl618, bl808RfPriVendorCalState.measureCtrl618)
    volatileStore(addr rf.measureMode61c, bl808RfPriVendorCalState.measureMode61c)
    volatileStore(addr rf.rccalTone48, bl808RfPriVendorCalState.rccalTone48)
    volatileStore(addr rf.calSingenCtrl20c, bl808RfPriVendorCalState.calSingenCtrl20c)
    volatileStore(addr rf.calSingenAmpLo214, bl808RfPriVendorCalState.calSingenAmpLo214)
    volatileStore(addr rf.calSingenAmpHi218, bl808RfPriVendorCalState.calSingenAmpHi218)
    volatileStore(addr rf.calDfeGate23c, bl808RfPriVendorCalState.calDfeGate23c)
    volatileStore(addr rf.calDfeState240, bl808RfPriVendorCalState.calDfeState240)
    volatileStore(addr rf.calDfeState244, bl808RfPriVendorCalState.calDfeState244)
    volatileStore(addr rf.calMixerStateF0, bl808RfPriVendorCalState.calMixerStateF0)
    volatileStore(addr rf.txcalGain64, bl808RfPriVendorCalState.txcalGain64)
    volatileStore(addr rf.txcalBias58, bl808RfPriVendorCalState.txcalBias58)
    volatileStore(addr rf.rxMode220, bl808RfPriVendorCalState.rxMode220)
    volatileStore(addr rf.txcalParam74, bl808RfPriVendorCalState.txcalParam74)
    volatileStore(addr rf.acalCtrlA4, bl808RfPriVendorCalState.acalCtrlA4)
    nimFwDbgRfCalRestoreReadbackRf2c = volatileLoad(addr rf.synthCtrl2c)
    nimFwDbgRfCalRestoreReadbackRf88 = volatileLoad(addr rf.txcalDfe88)
    nimFwDbgRfCalRestoreRf8c = volatileLoad(addr rf.calPathConfig8c)

  proc rf_pri_cw_stop() {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rf_pri.c.o rf_pri_cw_stop+0x0..0x1a:
    ## mask RF[0x220] with 0xFFFFE67D, then restore the vendor cal snapshot.
    let rf = rfRegs()
    volatileStore(addr rf.rxMode220,
                  volatileLoad(addr rf.rxMode220) and 0xFFFFE67D'u32)
    rf_pri_restore_state_after_cal()

  proc rfPriConfigChannelForCal(index: int) =
    if rfCalibDataGlobal == nil or index < 0 or index >= RfLoChannelCount:
      return
    let rf = rfRegs()
    nim_wifi_rf_last_config_channel_index = uint32(index)
    updateReg32(addr rf.priModeCtrl30, not 0'u32, 0x00F00000'u32)

    let fcalByte = uint32(rfLoFcal(index))
    let acalByte = uint32(rfLoAcal(index))
    nim_wifi_rf_last_config_channel_fcal = fcalByte
    nim_wifi_rf_last_config_channel_acal = acalByte
    nim_wifi_rf_last_config_channel_sdm2 = RfChannelDivTable40M[index]
    volatileStore(addr rf.fcalCtrlA0,
                  (volatileLoad(addr rf.fcalCtrlA0) and 0xFFC0FF00'u32) or
                  fcalByte or ((acalByte shl 16) and 0x003F0000'u32))
    volatileStore(addr rf.channelFcalConfigBc,
                  (volatileLoad(addr rf.channelFcalConfigBc) and 0xFF100FFF'u32) or
                  (((fcalByte shr 4) shl 20) and 0x00F00000'u32))
    volatileStore(addr rf.sdmDivC4,
                  (volatileLoad(addr rf.sdmDivC4) and 0xC0000000'u32) or
                  (RfChannelDivTable40M[index] and 0x3FFFFFFF'u32))
    updateReg32(addr rf.sdmCtrlC0, not 0x00001000'u32, 0'u32)

    var status = 0'u32
    for _ in 0 ..< RfConfigChannelWaitLimit:
      updateReg32(addr rf.txcalCtrlB8, not 0'u32, 0x00010000'u32)
      waitRfUs(10'u32)
      updateReg32(addr rf.txcalCtrlB8, not 0x00010000'u32, 0'u32)
      waitRfUs(50'u32)
      updateReg32(addr rf.channelCalStrobeB0, not 0'u32, 0x10000000'u32)
      waitRfUs(10'u32)
      updateReg32(addr rf.channelCalStrobeB0, not 0x10000000'u32, 0'u32)
      waitRfUs(50'u32)
      status = volatileLoad(addr rf.channelCalStatusB4)
      if (status and 0x01100000'u32) == 0'u32:
        nim_wifi_rf_last_config_channel_b8 = volatileLoad(addr rf.txcalCtrlB8)
        nim_wifi_rf_last_config_channel_b0 = volatileLoad(addr rf.channelCalStrobeB0)
        nim_wifi_rf_last_config_channel_status = status
        return

    inc nim_wifi_rf_config_channel_wait_timeout_count
    nim_wifi_rf_last_config_channel_b8 = volatileLoad(addr rf.txcalCtrlB8)
    nim_wifi_rf_last_config_channel_b0 = volatileLoad(addr rf.channelCalStrobeB0)
    nim_wifi_rf_last_config_channel_status = status

  proc startRfPriTxDfeForCal() =
    let rf = rfRegs()
    updateReg32(addr rf.rxMode220, not 0x00000180'u32, 0'u32)
    updateReg32(addr rf.rxMode220, 0xFFFFE7FF'u32, 0x00001082'u32)
    updateReg32(addr rf.rxMode220, not 0x00000010'u32, 0x00000100'u32)

  proc startRfPriRxDfeForCal() =
    let rf = rfRegs()
    updateReg32(addr rf.rxMode220, not 0x00000060'u32, 0x00000061'u32)

  proc rfPriCwChannelIndex(channelMhz: uint32): int {.inline.} =
    ## rf_pri_cw_start+0x36..0x5e maps ordinary 2.4 GHz WiFi channels to
    ## 0..12 and uses 13 for the out-of-grid CW validation channels.
    if channelMhz >= 2412'u32 and channelMhz <= 2472'u32:
      int((channelMhz - 2412'u32) div 5'u32)
    else:
      13

  proc rfPriCwLoCalIndex(channelMhz: uint32): int {.inline.} =
    var index =
      if channelMhz > 2402'u32: (channelMhz - 2402'u32) shr 2
      else: 0'u32
    if index >= RfLoChannelCount.uint32:
      index = RfLoChannelCount.uint32 - 1'u32
    int(index)

  proc rfPriCwPowerTableIndex(targetPowerDbm: int32;
                              channelIndex: int): uint32 =
    var compensated = targetPowerDbm
    if channelIndex >= 0 and channelIndex < bl808RfChannelPowerComp.len:
      compensated += int32(
        (bl808RfChannelPowerComp[channelIndex] + bl808RfTxGainComp) div 4)
    if compensated < 0'i32:
      0'u32
    elif compensated >= RfPriCwPowerAmplitudeTable.len.int32:
      uint32(RfPriCwPowerAmplitudeTable.len - 1)
    else:
      uint32(compensated)

  proc rfPriCwXtalDivisorTenths(): uint32 {.inline.} =
    ## rf_pri_cw_start+0xe6..0x172 selects the divisor used by
    ## floor((4 * channel_mhz / divisor) * 2^22) from the active xtal flag.
    if bl808RfPriXtal24mFlag != 0: 720'u32
    elif bl808RfPriXtal26mFlag != 0: 780'u32
    elif bl808RfPriXtal32mFlag != 0: 960'u32
    elif bl808RfPriXtal38p4mFlag != 0: 1152'u32
    elif bl808RfPriXtal52mFlag != 0: 1560'u32
    else: 1200'u32

  proc rfPriCwSdmDivWord(channelMhz: uint32): uint32 {.inline.} =
    let divisorTenths = rfPriCwXtalDivisorTenths()
    uint32((uint64(channelMhz) * 40'u64 * (1'u64 shl 22)) div
      uint64(divisorTenths)) and 0x3FFF_FFFF'u32

  proc rfPriProgramCwChannel(channelMhz: uint32) =
    ## Port of rf_pri_cw_start+0x1d2..0x25c. Unlike the normal calibration
    ## channel path, CW programming computes RF[0xC4] from the active xtal
    ## divisor and channel MHz instead of replaying the 40 MHz divider table.
    if rfCalibDataGlobal == nil:
      return
    let index = rfPriCwLoCalIndex(channelMhz)
    let fcalByte = uint32(rfLoFcal(index))
    let acalByte = uint32(rfLoAcal(index))
    let rf = rfRegs()
    nim_wifi_rf_last_config_channel_index = uint32(index)
    nim_wifi_rf_last_config_channel_fcal = fcalByte
    nim_wifi_rf_last_config_channel_acal = acalByte
    volatileStore(addr rf.fcalCtrlA0,
                  (volatileLoad(addr rf.fcalCtrlA0) and 0xFFC0FF00'u32) or
                  fcalByte or ((acalByte shl 16) and 0x003F0000'u32))
    volatileStore(addr rf.channelFcalConfigBc,
                  (volatileLoad(addr rf.channelFcalConfigBc) and
                   0xFF100FFF'u32) or
                  (((fcalByte shr 4) shl 20) and 0x00F00000'u32))
    let sdmDivWord = rfPriCwSdmDivWord(channelMhz)
    nim_wifi_rf_cw_start_sdm_div = sdmDivWord
    nim_wifi_rf_last_config_channel_sdm2 = sdmDivWord
    volatileStore(addr rf.sdmDivC4,
                  (volatileLoad(addr rf.sdmDivC4) and 0xC0000000'u32) or
                  sdmDivWord)
    updateReg32(addr rf.sdmCtrlC0, not 0x00001000'u32, 0'u32)

  proc rfPriStartCwDfeStrobes() =
    ## Port of rf_pri_cw_start+0x272..0x2d6: pulse TXCAL and channel
    ## calibration strobes until RF[0xB4] clears the busy/error bits.
    let rf = rfRegs()
    for _ in 0 ..< RfConfigChannelWaitLimit:
      updateReg32(addr rf.txcalCtrlB8, not 0'u32, 0x00010000'u32)
      waitRfUs(10'u32)
      updateReg32(addr rf.txcalCtrlB8, not 0x00010000'u32, 0'u32)
      waitRfUs(50'u32)
      updateReg32(addr rf.channelCalStrobeB0, not 0'u32, 0x10000000'u32)
      waitRfUs(10'u32)
      updateReg32(addr rf.channelCalStrobeB0, not 0x10000000'u32, 0'u32)
      waitRfUs(50'u32)
      if (volatileLoad(addr rf.channelCalStatusB4) and 0x01100000'u32) == 0'u32:
        return
    inc nim_wifi_rf_config_channel_wait_timeout_count

  proc rf_pri_cw_start(targetPowerDbm: int32; channelMhz: uint32)
      {.exportc, cdecl.} =
    ## Semantic port of librf_bl808.a:rf_pri.c.o rf_pri_cw_start.
    ## Recovered exact effects: channel range gate, RF[0x2C/0x48/0x68/0x63C]
    ## CW staging, LO calibration table replay, RF[0xB8]/RF[0xB0] strobe loop,
    ## signal-generator path setup, RF[0x214]/RF[0x218] amplitude programming,
    ## and RF[0x220]/RF[0x20C]/RF[0x23C] CW output enable.
    ## The vendor double `pow` region at rf_pri_cw_start+0x136..0x24c is
    ## represented as fixed-point RF[0xC4] synthesis in rfPriProgramCwChannel.
    if channelMhz < 2402'u32 or channelMhz > 2484'u32:
      return

    inc nim_wifi_rf_cw_start_count
    nim_wifi_rf_cw_start_channel = channelMhz
    let cwChannelIndex = rfPriCwChannelIndex(channelMhz)
    nim_wifi_rf_cw_start_channel_index = uint32(cwChannelIndex)
    let powerIndex = rfPriCwPowerTableIndex(targetPowerDbm, cwChannelIndex)
    nim_wifi_rf_cw_start_power_index = powerIndex
    let amplitude =
      uint32(RfPriCwPowerAmplitudeTable[int(powerIndex)]) and
      RfTxcalSingenAmplitudeMask

    let rf = rfRegs()
    updateReg32(addr rf.synthCtrl2c, not 0x00000004'u32, 0'u32)
    updateReg32(addr rf.txcalGain68, 0x0C00C088'u32, 0xE1770244'u32)
    updateReg32(addr rf.rccalTone48, 0xCE08FFFF'u32, 0x10700000'u32)
    updateReg32(addr rf.txcalGain68, 0x1DFFFFFF'u32, 0xE0000000'u32)
    updateReg32(addr rf.synthDfePathControl63c, 0xFF800000'u32, 0'u32)

    updateReg32(addr rf.rxMode220, 0xFFFFE67D'u32, 0'u32)
    updateReg32(addr rf.baseCtrl1, not RfCtrlTuneEnableMask, 0'u32)
    volatileStore(addr rf.synthCtrl2c, 0'u32)
    updateReg32(addr rf.priModeCtrl30, not 0'u32, 0x00000002'u32)
    updateReg32(addr rf.priModeCtrl30, 0xCEFFF8FF'u32, 0xCEFF7800'u32)
    updateReg32(addr rf.priModeCtrl30, not 0'u32, 0x0F000000'u32)

    rfPriProgramCwChannel(channelMhz)
    rfPriStartCwDfeStrobes()

    updateReg32(addr rf.calSingenCtrl20c, 0xFC00FFFF'u32, 0'u32)
    updateReg32(addr rf.calSingenAmpLo214, 0x003FFFFF'u32, 0'u32)
    updateReg32(addr rf.calSingenAmpHi218, 0x003FFFFF'u32, 0xC0000000'u32)
    updateReg32(addr rf.calSingenMeasurePrep21c, 0xEFFFFFFF'u32, 0'u32)
    updateReg32(addr rf.calSingenAmpLo214, not RfTxcalSingenAmplitudeMask,
                amplitude)
    updateReg32(addr rf.calSingenAmpHi218, not RfTxcalSingenAmplitudeMask,
                amplitude)
    waitRfUs(1'u32)

    updateReg32(addr rf.calDfeGate23c, not 0x00040000'u32, 0x00040000'u32)
    startRfPriTxDfeForCal()
    updateReg32(addr rf.rxMode220, not 0x00000180'u32, 0'u32)
    updateReg32(addr rf.rxMode220, 0xFFFFE7FF'u32, 0x00001082'u32)
    updateReg32(addr rf.rxMode220, not 0x00000010'u32, 0x00000100'u32)
    updateReg32(addr rf.calSingenCtrl20c, not 0x80000000'u32, 0'u32)
    updateReg32(addr rf.calSingenCtrl20c, not 0x80000000'u32, 0x80000000'u32)

    nim_wifi_rf_cw_start_rf220 = volatileLoad(addr rf.rxMode220)
    nim_wifi_rf_cw_start_rf20c = volatileLoad(addr rf.calSingenCtrl20c)
    nim_wifi_rf_cw_start_rf214 = volatileLoad(addr rf.calSingenAmpLo214)
    nim_wifi_rf_cw_start_rf218 = volatileLoad(addr rf.calSingenAmpHi218)

  proc signedRfPowerMeasurement(word: uint32): int32 {.inline.} =
    let sample = (word shr 9) and 0x0000FFFF'u32
    result = int32(sample)
    if (sample and 0x00008000'u32) != 0'u32:
      result = result - 0x00010000'i32

  proc signedRfAverageMeasurement(word: uint32): int32 {.inline.} =
    let sample = word and 0x01FF_FFFF'u32
    result = int32(sample)
    if (sample and 0x0100_0000'u32) != 0'u32:
      result = result - 0x0200_0000'i32

  proc signedRfAverageAdcMean(word: uint32): int32 {.inline.} =
    ## Vendor TXCAL amplitude tuning uses `sample << 7 >> 17`, i.e. signed
    ## RF1620 bits 24:10. RF70 replay-window search still uses the full
    ## signed 25-bit average sample.
    let sample = (word shr 10) and 0x0000_7FFF'u32
    result = int32(sample)
    if (sample and 0x0000_4000'u32) != 0'u32:
      result = result - 0x0000_8000'i32

  proc squareRfSample(sample: int32): uint64 {.inline.} =
    let value = int64(sample)
    uint64(value * value)

  proc saturatingRfUint32(value: uint64): uint32 {.inline.} =
    if value > uint64(high(uint32)):
      high(uint32)
    else:
      uint32(value)

  proc waitRfRoscalMeasurementReady(): bool =
    let rf = rfRegs()
    for _ in 0 ..< RfRoscalWaitLimit:
      if (volatileLoad(addr rf.measureCtrl618) and RfMeasureReadyMask) != 0'u32:
        return true
      waitRfUs(1'u32)
    inc nim_wifi_rf_roscal_wait_timeout_count
    false

  proc writeRfRoscalCandidate(iBranch: bool, code: uint32) =
    let value = code and RfRoscalCodeMask
    let rf = rfRegs()
    if iBranch:
      updateReg32(addr rf.roscalCtrl7c, not RfRoscalIRegMask, value shl 8)
    else:
      updateReg32(addr rf.roscalCtrl7c, not RfRoscalQRegMask, value)

  type
    RfRoscalSample = object
      raw: uint32
      signed: int32

  proc sampleRfRoscalMeasurement(iBranch: bool): RfRoscalSample =
    let rf = rfRegs()
    updateReg32(addr rf.measureCtrl618, not RfMeasureTriggerClearMask, 0'u32)
    updateReg32(addr rf.measureMode61c, RfMeasureModeKeepMask,
                RfMeasureRoscalMode)
    updateReg32(addr rf.measureCtrl618, 0xFFFFFFFF'u32, RfMeasureStartMask)
    discard waitRfRoscalMeasurementReady()
    result.raw =
      if iBranch:
        volatileLoad(addr rf.measureI620)
      else:
        volatileLoad(addr rf.measureQ624)
    result.signed = signedRfAverageMeasurement(result.raw)
    updateReg32(addr rf.measureCtrl618, not RfMeasureTriggerClearMask, 0'u32)

  proc logRfRoscalSearch(index: var int, iBranch: bool, code: uint32,
                         sample: RfRoscalSample) =
    if index < nim_wifi_rf_roscal_search_log.len:
      let branchBit =
        if iBranch: 0x80000000'u32 else: 0'u32
      let sampleBits = uint32(sample.signed) and 0x0000FFFF'u32
      nim_wifi_rf_roscal_search_log[index] =
        branchBit or ((code and RfRoscalCodeMask) shl 16) or sampleBits
      inc index

  proc chooseRfRoscalCode(iBranch: bool): uint8 =
    var code = 0'u32
    var bit = 32'u32
    var logIndex =
      if iBranch: 0 else: 8

    for _ in 0 ..< 6:
      let candidate = (code + bit) and RfRoscalCodeMask
      writeRfRoscalCandidate(iBranch, candidate)
      let sample = sampleRfRoscalMeasurement(iBranch)
      logRfRoscalSearch(logIndex, iBranch, candidate, sample)
      if sample.signed > 0:
        code = candidate
      bit = bit shr 1

    var history = 0'u32
    for attempt in 0 ..< 63:
      writeRfRoscalCandidate(iBranch, code)
      let sample = sampleRfRoscalMeasurement(iBranch)
      if attempt < 2:
        logRfRoscalSearch(logIndex, iBranch, code, sample)
      history = (history shl 1) and 0x0F'u32
      if sample.signed > 0:
        history = (history + 1'u32) and 0x0F'u32
        code = (code - 1'u32) and RfRoscalCodeMask
        if history == 5'u32:
          break
      else:
        code = (code + 1'u32) and RfRoscalCodeMask
        if history == 10'u32:
          break

    uint8(code and RfRoscalCodeMask)

  proc applyRfRoscalCodes(iCode, qCode: uint32) =
    let iBits = iCode and RfRoscalCodeMask
    let qBits = qCode and RfRoscalCodeMask
    if rfCalibDataGlobal != nil:
      var rccalReplayWord = rfCalibWord(RfCalibRccalReplayWordIndex)
      rccalReplayWord = (rccalReplayWord and not 0x00FF_FFFF'u32) or
        iBits or (qBits shl 6) or (iBits shl 12) or (qBits shl 18)
      rfCalibSetWord(RfCalibRccalReplayWordIndex, rccalReplayWord)

    let packed = iBits or (qBits shl 8) or (iBits shl 16) or (qBits shl 24)
    let rf = rfRegs()
    volatileStore(addr rf.roscalCal0,
                  (volatileLoad(addr rf.roscalCal0) and
                   RfRoscalRegisterKeepMask) or packed)
    volatileStore(addr rf.roscalCal1,
                  (volatileLoad(addr rf.roscalCal1) and
                   RfRoscalRegisterKeepMask) or packed)
    nim_wifi_rf_last_roscal_i = iBits
    nim_wifi_rf_last_roscal_q = qBits

  proc prepareRfPriRoscal() =
    let rf = rfRegs()
    updateReg32(addr rf.baseCtrl1, not RfCtrlTuneEnableMask, 0'u32)
    volatileStore(addr rf.synthCtrl2c, 0'u32)
    updateReg32(addr rf.priModeCtrl30, not 0'u32, 0x00000002'u32)
    updateReg32(addr rf.priModeCtrl30, 0x21F0FEFF'u32, 0x21F06E00'u32)
    waitRfUs(1'u32)

    updateReg32(addr rf.rxMode220, not 0x00000180'u32, 0'u32)
    updateReg32(addr rf.rxMode220, 0xFFFFE7FF'u32, 0x00001082'u32)
    updateReg32(addr rf.rxMode220, not 0x00000010'u32, 0x00000100'u32)
    updateReg32(addr rf.rxMode220, not 0x00000060'u32, 0x00000061'u32)
    updateReg32(addr rf.calCtrl1c, not 0'u32, 0x00000200'u32)
    updateReg32(addr rf.rccalTone48, 0xFFFF8CFF'u32, 0x00003137'u32)
    updateReg32(addr rf.roscalCtrl7c, not 0x80000000'u32, 0'u32)

  proc runRfPriRoscal() =
    let rf = rfRegs()
    if (volatileLoad(addr rf.capability20) and RfRoscalCapabilityMask) == 0'u32:
      updateReg32(addr rf.calMode14, not RfRoscalModeMask, 0'u32)
      return

    inc nim_wifi_rf_pri_roscal_count
    updateReg32(addr rf.calMode14, not RfRoscalModeMask, RfRoscalStartMode)
    let saved = saveRfPriCalState()
    prepareRfPriRoscal()
    let iCode = uint32(chooseRfRoscalCode(true))
    let qCode = uint32(chooseRfRoscalCode(false))
    applyRfRoscalCodes(iCode, qCode)
    restoreRfPriCalState(saved)
    updateReg32(addr rf.calMode14, not 0'u32, RfRoscalDoneMode)

  proc rf_pri_roscal() {.exportc, cdecl.} =
    ## Vendor rf_pri_roscal checks RF[0x20] bit 8, clears the ROSCAL mode
    ## field in RF[0x14] when unsupported, otherwise enters rf_pri_roscal.part.0.
    runRfPriRoscal()

  proc waitRfRccalMeasurementReady(): bool =
    let rf = rfRegs()
    for _ in 0 ..< RfRccalWaitLimit:
      if (volatileLoad(addr rf.measureCtrl618) and RfMeasureReadyMask) != 0'u32:
        return true
      waitRfUs(1'u32)
    inc nim_wifi_rf_rccal_wait_timeout_count
    false

  proc sampleRfRccalPower(): uint32 =
    let rf = rfRegs()
    updateReg32(addr rf.measureCtrl618, not RfMeasureRccalTriggerMask, 0'u32)
    updateReg32(addr rf.measureCtrl618, not RfMeasureRccalTriggerMask,
                RfMeasureRccalTriggerMask)
    waitRfUs(1'u32)
    if not waitRfRccalMeasurementReady():
      updateReg32(addr rf.measureCtrl618, not RfMeasureRccalTriggerMask, 0'u32)
      return 0'u32

    let iSample = signedRfPowerMeasurement(volatileLoad(addr rf.measureI620))
    let qSample = signedRfPowerMeasurement(volatileLoad(addr rf.measureQ624))
    updateReg32(addr rf.measureCtrl618, not RfMeasureRccalTriggerMask, 0'u32)
    saturatingRfUint32(squareRfSample(iSample) + squareRfSample(qSample))

  proc primeRfRccalPowerMeasurement() =
    let rf = rfRegs()
    updateReg32(addr rf.measureCtrl618, 0xFFF00000'u32,
                RfRccalReferenceMeasureCtrl)
    updateReg32(addr rf.measureMode61c, RfMeasureModeKeepMask,
                RfMeasureRoscalMode)
    updateReg32(addr rf.measureCtrl618, not RfMeasureRccalTriggerMask, 0'u32)
    updateReg32(addr rf.measureCtrl618, not RfMeasureStartMask,
                RfMeasureStartMask)
    waitRfUs(1'u32)
    discard waitRfRccalMeasurementReady()
    discard volatileLoad(addr rf.measureI620)
    updateReg32(addr rf.measureCtrl618, not RfMeasureRccalTriggerMask, 0'u32)

  proc writeRfRccalCode(code: uint32) =
    let value = code and RfRccalCodeMask
    let packed = value or (value shl 8) or (value shl 16) or (value shl 24)
    let rf = rfRegs()
    volatileStore(addr rf.rbbRccalCtrl80,
                  (volatileLoad(addr rf.rbbRccalCtrl80) and
                   RfRccalRegisterKeepMask) or packed)
    if rfCalibDataGlobal != nil:
      rfCalibSetWord(RfCalibRccalReplayWordIndex,
        (rfCalibWord(RfCalibRccalReplayWordIndex) and
          not 0x00FF_FFFF'u32) or
          value or (value shl 6) or (value shl 12) or (value shl 18))

  proc writeRfRccalSearchCode(code: uint32) =
    let value = code and RfRccalCodeMask
    let rf = rfRegs()
    var word = volatileLoad(addr rf.rbbRccalCtrl80)
    word = (word and 0xC0FF_FFFF'u32) or (value shl 24)
    word = (word and 0xFFFF_C0FF'u32) or (value shl 8)
    volatileStore(addr rf.rbbRccalCtrl80, word)

  proc prepareRfPriRccal() =
    let rf = rfRegs()
    updateReg32(addr rf.baseCtrl1, not RfCtrlTuneEnableMask, 0'u32)
    volatileStore(addr rf.synthCtrl2c, 0'u32)
    updateReg32(addr rf.priModeCtrl30, not 0'u32, 0x00000002'u32)
    updateReg32(addr rf.priModeCtrl30, 0x2DF8F8FF'u32, 0x2DF87800'u32)
    waitRfUs(1'u32)

    startRfPriTxDfeForCal()
    startRfPriRxDfeForCal()
    updateReg32(addr rf.rccalReplay84, not 0x00030000'u32, 0'u32)
    volatileStore(addr rf.rccalReplay84,
                  (volatileLoad(addr rf.rccalReplay84) and 0xFCFF_FFFF'u32) or
                  0x0200_0000'u32)
    updateReg32(addr rf.calPathConfig8c, not 0x00001000'u32, 0x00001000'u32)
    updateReg32(addr rf.calCtrl1c, not 0'u32, 0x00000800'u32)
    updateReg32(addr rf.calMeasurePrep60c, not 0x00000400'u32, 0'u32)
    updateReg32(addr rf.calMeasurePrep60c, not 0x04000000'u32, 0x04000000'u32)
    updateReg32(addr rf.rccalTone48, 0xFFFF8CFF'u32, 0x00003100'u32)
    updateReg32(addr rf.calSingenCtrl20c, 0xFC00FFFF'u32, 0x00300000'u32)
    updateReg32(addr rf.calSingenAmpLo214, 0x003FFFFF'u32, 0'u32)
    updateReg32(addr rf.calSingenAmpHi218, 0x003FFFFF'u32, 0xC0000000'u32)
    updateReg32(addr rf.calSingenAmpLo214, 0xFFFFF800'u32, 0x000000FF'u32)
    updateReg32(addr rf.calSingenAmpHi218, 0xFFFFF800'u32, 0x000000FF'u32)
    updateReg32(addr rf.calSingenCtrl20c, not 0x80000000'u32, 0'u32)
    updateReg32(addr rf.calSingenCtrl20c, not 0x80000000'u32, 0x80000000'u32)
    startRfPriTxDfeForCal()
    updateReg32(addr rf.measureCtrl618, 0xFFF00000'u32,
                RfRccalReferenceMeasureCtrl)
    updateReg32(addr rf.measureCtrl618, not RfMeasureRccalTriggerMask, 0'u32)
    updateReg32(addr rf.measureMode61c, RfMeasureModeKeepMask,
                RfMeasureRoscalMode)

  proc prepareRfPriRccalTone() =
    let rf = rfRegs()
    updateReg32(addr rf.rccalTone48, 0xFFFF8CFF'u32, 0x00006200'u32)
    updateReg32(addr rf.calSingenCtrl20c, 0xFC00FFFF'u32, 0x00B50000'u32)
    updateReg32(addr rf.calSingenAmpLo214, 0x003FFFFF'u32, 0'u32)
    updateReg32(addr rf.calSingenAmpHi218, 0x003FFFFF'u32, 0xC0000000'u32)
    updateReg32(addr rf.calSingenCtrl20c, not 0x80000000'u32, 0'u32)
    updateReg32(addr rf.calSingenCtrl20c, not 0x80000000'u32, 0x80000000'u32)
    startRfPriTxDfeForCal()
    updateReg32(addr rf.measureCtrl618, 0xFFF00000'u32, RfRccalToneMeasureCtrl)

  proc logRfRccalSearch(index: var int, code, power: uint32) =
    if index < nim_wifi_rf_rccal_search_log.len:
      nim_wifi_rf_rccal_search_log[index] =
        ((code and RfRccalCodeMask) shl 24) or (power and 0x00FF_FFFF'u32)
      nim_wifi_rf_rccal_power_log[index] = power
      inc index

  proc chooseRfRccalCode(): tuple[ok: bool, code: uint32] =
    for i in 0 ..< nim_wifi_rf_rccal_search_log.len:
      nim_wifi_rf_rccal_search_log[i] = 0
      nim_wifi_rf_rccal_power_log[i] = 0

    primeRfRccalPowerMeasurement()
    let baseline = sampleRfRccalPower()
    nim_wifi_rf_last_rccal_baseline = baseline
    if baseline == 0'u32:
      nim_wifi_rf_last_rccal_target = 0
      nim_wifi_rf_last_rccal_power = 0
      nim_wifi_rf_last_rccal_code = RfRccalBaselineCode
      writeRfRccalCode(RfRccalBaselineCode)
      return (false, RfRccalBaselineCode)

    var target = (uint64(baseline) * RfRccalTargetNumerator) div
      RfRccalTargetDenominator
    nim_wifi_rf_last_rccal_target = saturatingRfUint32(target)

    var logIndex = 0
    var code = 0'u32
    var bit = 0x20'u32
    var lastMeasuredCode = RfRccalBaselineCode
    var lastMeasuredPower = baseline
    prepareRfPriRccalTone()

    for _ in 0 ..< 6:
      let candidate = (code + bit) and RfRccalCodeMask
      writeRfRccalSearchCode(candidate)
      waitRfUs(1'u32)
      let power = sampleRfRccalPower()
      lastMeasuredCode = candidate
      lastMeasuredPower = power
      logRfRccalSearch(logIndex, candidate, power)
      if bit == RfRccalBaselineCode and
          baseline < RfRccalMinReferencePower and
          power > RfRccalMinReferencePower:
        target = (uint64(power) * RfRccalFallbackTargetNumerator) div
          RfRccalFallbackTargetDenominator
        nim_wifi_rf_last_rccal_target = saturatingRfUint32(target)
      if power != 0'u32 and uint64(power) > target:
        code = candidate
      bit = bit shr 1

    var history = 0'u32
    var ok = false
    for _ in 0 ..< 63:
      let candidate = code and RfRccalCodeMask
      writeRfRccalSearchCode(candidate)
      waitRfUs(1'u32)
      let power = sampleRfRccalPower()
      lastMeasuredCode = candidate
      lastMeasuredPower = power
      logRfRccalSearch(logIndex, candidate, power)

      history = (history shl 1) and 0x0F'u32
      if power != 0'u32 and uint64(power) > target:
        history = (history + 1'u32) and 0x0F'u32
        if history == 0x05'u32:
          ok = true
          break
        if code < RfRccalCodeMask:
          inc code
      else:
        if history == 0x0A'u32:
          ok = true
          break
        if code > 0'u32:
          dec code

    writeRfRccalCode(lastMeasuredCode)
    nim_wifi_rf_last_rccal_code = lastMeasuredCode
    nim_wifi_rf_last_rccal_power = lastMeasuredPower
    (ok, lastMeasuredCode)

  proc runRfPriRccal() =
    let rf = rfRegs()
    if (volatileLoad(addr rf.capability20) and RfRccalCapabilityMask) == 0'u32:
      updateReg32(addr rf.calMode14, not RfRccalModeMask, 0'u32)
      return

    inc nim_wifi_rf_pri_rccal_count
    updateReg32(addr rf.calMode14, not RfRccalModeMask, RfRccalStartMode)
    let saved = saveRfPriCalState()
    prepareRfPriRccal()
    let result = chooseRfRccalCode()
    restoreRfPriCalState(saved)
    writeRfRccalCode(result.code)
    rfPriApplyWb03RccalSeed()
    if result.ok:
      updateReg32(addr rf.calMode14, not 0'u32, RfRccalDoneMode)
    else:
      updateReg32(addr rf.calMode14, not RfRccalModeMask, RfRccalFailMode)

  proc rf_pri_rccal() {.exportc, cdecl.} =
    ## Vendor rf_pri_rccal checks RF[0x20] bit 10, clears the RCCAL mode
    ## field in RF[0x14] when unsupported, otherwise enters rf_pri_rccal.part.0.
    runRfPriRccal()

  proc clampRfTxcalParam(paramInd: uint32, value: int32): int32 {.inline.} =
    case paramInd
    of 0'u32, 1'u32:
      if value < 0'i32: 0'i32
      elif value > 63'i32: 63'i32
      else: value
    of 2'u32:
      if value < 0'i32: 0'i32
      elif value > 2047'i32: 2047'i32
      else: value
    of 3'u32:
      if value < -512'i32: -512'i32
      elif value > 511'i32: 511'i32
      else: value
    else:
      0'i32

  proc encodeRfTxcalParam3(value: int32): uint32 {.inline.} =
    let clamped = clampRfTxcalParam(3'u32, value)
    if clamped < 0'i32:
      uint32(clamped + 1024'i32) and RfTxcalParam3Mask
    else:
      uint32(clamped) and RfTxcalParam3Mask

  proc writeRfTxcalParam(paramInd: uint32, value: int32) =
    let rf = rfRegs()
    let clamped = clampRfTxcalParam(paramInd, value)
    case paramInd
    of 0'u32:
      updateReg32(addr rf.txcalParam74, not RfTxcalParam0Mask,
                  (uint32(clamped) and 0x3F'u32) shl 24)
    of 1'u32:
      updateReg32(addr rf.txcalParam74, not RfTxcalParam1Mask,
                  (uint32(clamped) and 0x3F'u32) shl 16)
    of 2'u32:
      updateReg32(addr rf.txcalTosdac600, not RfTxcalParam2Mask,
                  ((uint32(clamped) and 0x7FF'u32) shl 12) or
                  RfTxcalParam2EnableBit)
    of 3'u32:
      updateReg32(addr rf.txcalTosdac600, not RfTxcalParam3Mask,
                  encodeRfTxcalParam3(clamped) or RfTxcalParam3SignBit)
    else:
      discard

  proc waitRfTxcalMeasurementReady(): bool =
    let rf = rfRegs()
    for _ in 0 ..< RfTxcalWaitLimit:
      if (volatileLoad(addr rf.measureCtrl618) and RfMeasureReadyMask) != 0'u32:
        return true
      waitRfUs(1'u32)
    inc nim_wifi_rf_txcal_wait_timeout_count
    false

  proc clampRfTxcalAmp(value: int32): uint32 {.inline.} =
    if value < 0'i32:
      0'u32
    elif value > int32(RfTxcalSingenAmplitudeMask):
      RfTxcalSingenAmplitudeMask
    else:
      uint32(value)

  proc writeRfTxcalSingenAmplitude(amp: uint32) =
    let rf = rfRegs()
    let value = amp and RfTxcalSingenAmplitudeMask
    updateReg32(addr rf.calSingenAmpLo214, not RfTxcalSingenAmplitudeMask,
                value)
    updateReg32(addr rf.calSingenAmpHi218, not RfTxcalSingenAmplitudeMask,
                value)
    updateReg32(addr rf.calSingenCtrl20c, not 0x80000000'u32, 0'u32)
    updateReg32(addr rf.calSingenCtrl20c, not 0x80000000'u32, 0x80000000'u32)
    startRfPriTxDfeForCal()

  proc sampleRfTxcalAverage(): tuple[ok: bool, value: int32] =
    let rf = rfRegs()
    updateReg32(addr rf.measureCtrl618, not RfMeasureTriggerClearMask, 0'u32)
    updateReg32(addr rf.measureMode61c, RfMeasureModeKeepMask,
                RfTxcalAverageMeasureMode)
    updateReg32(addr rf.measureCtrl618, not RfMeasureStartMask,
                RfMeasureStartMask)
    if not waitRfTxcalMeasurementReady():
      updateReg32(addr rf.measureCtrl618, not RfMeasureTriggerClearMask, 0'u32)
      return (false, 0'i32)

    let sample = signedRfAverageMeasurement(volatileLoad(addr rf.measureI620))
    updateReg32(addr rf.measureCtrl618, not RfMeasureTriggerClearMask, 0'u32)
    (true, sample)

  proc sampleRfTxcalAdcMean(): tuple[ok: bool, value: int32] =
    let rf = rfRegs()
    updateReg32(addr rf.measureCtrl618, not RfMeasureTriggerClearMask, 0'u32)
    updateReg32(addr rf.measureMode61c, RfMeasureModeKeepMask,
                RfTxcalAverageMeasureMode)
    updateReg32(addr rf.measureCtrl618, not RfMeasureStartMask,
                RfMeasureStartMask)
    if not waitRfTxcalMeasurementReady():
      updateReg32(addr rf.measureCtrl618, not RfMeasureTriggerClearMask, 0'u32)
      return (false, 0'i32)

    let sample = signedRfAverageAdcMean(volatileLoad(addr rf.measureI620))
    updateReg32(addr rf.measureCtrl618, not RfMeasureTriggerClearMask, 0'u32)
    (true, sample)

  proc tuneRfTxcalSingenPower(initialAmp: uint32,
                              adcMeanMax, adcMeanMin: int32): uint32 =
    inc nim_wifi_rf_txcal_amp_search_count
    var amp = int32(initialAmp and RfTxcalSingenAmplitudeMask)
    var step = amp div 2'i32
    var lastMean = 0'i32

    while true:
      let clamped = clampRfTxcalAmp(amp)
      writeRfTxcalSingenAmplitude(clamped)
      waitRfUs(10'u32)
      let sample = sampleRfTxcalAdcMean()
      if sample.ok:
        lastMean = sample.value
      nim_wifi_rf_last_txcal_amp = clamped
      nim_wifi_rf_last_txcal_amp_mean = cast[uint32](lastMean)

      if sample.ok and lastMean >= adcMeanMin and lastMean <= adcMeanMax:
        return clamped
      if step == 0'i32:
        return clamped

      if not sample.ok or lastMean < adcMeanMin:
        amp = int32(clamped) + step
      else:
        amp = int32(clamped) - step
      step = step div 2'i32

  proc writeRfTxcalMixerCs(value: uint32) =
    updateReg32(addr rfRegs().txcalDc6c, not RfTxcalMixerCsMask,
                value and RfTxcalMixerCsMask)

  proc chooseRfTxcalMixerCs(): uint32 =
    var best = 0'u32
    var bestPower = low(int32)
    for cs in 0'u32 ..< uint32(RfTxcalMixerCsCount):
      writeRfTxcalMixerCs(cs)
      let sample = sampleRfTxcalAverage()
      let power = if sample.ok: sample.value else: low(int32)
      nim_wifi_rf_txcal_tmxcs_power_log[int(cs)] = cast[uint32](power)
      if power > bestPower:
        bestPower = power
        best = cs

    writeRfTxcalMixerCs(best)
    if rfCalibDataGlobal != nil:
      rfCalibSetWord(RfCalibRccalReplayWordIndex,
        (rfCalibWord(RfCalibRccalReplayWordIndex) and 0xF8FF_FFFF'u32) or
          ((best and RfTxcalMixerCsMask) shl 24))
    nim_wifi_rf_last_txcal_tmxcs = best
    nim_wifi_rf_last_txcal_tmxcs_power = cast[uint32](bestPower)
    best

  proc prepareRfTxcalSearchStage() =
    ## Vendor rf_pri_txcal+0x54c..0x6a0 prepares the post-RF70 TXCAL search
    ## with the same signal-generator profile used by the BZ branch, then
    ## applies a one-shot RF64/RF58/RF21c/RF220 staging sequence before the
    ## per-record TXCAL gain table loop.
    let rf = rfRegs()
    updateReg32(addr rf.calSingenCtrl20c, 0xFC00_FFFF'u32, 0x0049_0000'u32)
    updateReg32(addr rf.calSingenAmpLo214, 0x003F_FFFF'u32, 0'u32)
    updateReg32(addr rf.calSingenAmpHi218, 0x003F_FFFF'u32, 0xC000_0000'u32)
    updateReg32(addr rf.rxcalPrep60, not 0x0000_0003'u32, 0x0000_0003'u32)
    updateReg32(addr rf.txcalGain64, 0x0FC3_FFFF'u32, 0x9030_0000'u32)
    updateReg32(addr rf.txcalBias58, 0xFFF8_FFFF'u32, 0x0004_0000'u32)
    updateReg32(addr rf.rccalTone48, 0xCE0F_FFFF'u32, 0x0077_0000'u32)
    updateReg32(addr rf.calPathConfig8c, not 0x0000_0030'u32, 0x0000_0010'u32)
    updateReg32(addr rf.txcalGain64, 0xF8FF_FFFF'u32, 0x0400_0000'u32)
    updateReg32(addr rf.txcalGain64, 0xFF83_FFFF'u32, 0xF040_0000'u32)
    updateReg32(addr rf.rxcalPrep60, not 0x0000_0003'u32, 0x0000_0003'u32)
    updateReg32(addr rf.priModeCtrl30, 0xFFFE_FFFF'u32, 0'u32)
    updateReg32(addr rf.txcalBias58, 0xFFF8_FFFF'u32, 0x0001_0000'u32)
    updateReg32(addr rf.calSingenMeasurePrep21c, 0xEFFF_EFFF'u32, 0'u32)
    updateReg32(addr rf.calSingenAmpLo214, not 0x0000_07FF'u32, 0x0000_0010'u32)
    updateReg32(addr rf.calSingenAmpHi218, not 0x0000_07FF'u32, 0x0000_0010'u32)
    updateReg32(addr rf.calDfeGate23c, not 0x0004_0000'u32, 0x0004_0000'u32)
    updateReg32(addr rf.rxMode220, not 0x0000_0180'u32, 0'u32)
    updateReg32(addr rf.rxMode220, 0xFFFF_E7FF'u32, 0x0000_1082'u32)
    updateReg32(addr rf.rxMode220, not 0x0000_0010'u32, 0x0000_0100'u32)
    updateReg32(addr rf.calSingenCtrl20c, not 0x8000_0000'u32, 0'u32)
    updateReg32(addr rf.calSingenCtrl20c, not 0x8000_0000'u32, 0x8000_0000'u32)
    waitRfUs(10'u32)

  proc sampleRfTxcalPower(measFreq: uint32): tuple[ok: bool, power, iRaw, qRaw, ctrl: uint32] =
    let rf = rfRegs()
    updateReg32(addr rf.measureCtrl618, 0xFFF00000'u32,
                (measFreq and 0x07FF'u32) shl RfMeasureFrequencyShift)
    updateReg32(addr rf.measureCtrl618, not RfMeasureRccalTriggerMask, 0'u32)
    updateReg32(addr rf.measureCtrl618, not RfMeasureRccalTriggerMask,
                RfMeasureRccalTriggerMask)
    if not waitRfTxcalMeasurementReady():
      updateReg32(addr rf.measureCtrl618, not RfMeasureRccalTriggerMask, 0'u32)
      return (false, 0'u32, 0'u32, 0'u32, volatileLoad(addr rf.measureCtrl618))

    let iRaw = volatileLoad(addr rf.measureI620)
    let qRaw = volatileLoad(addr rf.measureQ624)
    let ctrl = volatileLoad(addr rf.measureCtrl618)
    let iSample = signedRfPowerMeasurement(iRaw)
    let qSample = signedRfPowerMeasurement(qRaw)
    updateReg32(addr rf.measureCtrl618, not RfMeasureRccalTriggerMask, 0'u32)
    (true, saturatingRfUint32(squareRfSample(iSample) + squareRfSample(qSample)),
     iRaw, qRaw, ctrl)

  proc measureRfTxcalCandidate(paramInd: uint32, candidate: int32,
                               measFreq: uint32): tuple[ok: bool, power: uint32] =
    writeRfTxcalParam(paramInd, candidate)
    waitRfUs(10'u32)
    let sample = sampleRfTxcalPower(measFreq)
    let idx = int(nim_wifi_rf_txcal_sample_count mod RfTxcalSampleTraceEntries.uint32)
    inc nim_wifi_rf_txcal_sample_count
    nim_wifi_rf_txcal_sample_param_log[idx] = paramInd
    nim_wifi_rf_txcal_sample_candidate_log[idx] = cast[uint32](candidate)
    nim_wifi_rf_txcal_sample_freq_log[idx] = measFreq
    nim_wifi_rf_txcal_sample_ctrl_log[idx] = sample.ctrl
    nim_wifi_rf_txcal_sample_i_log[idx] = sample.iRaw
    nim_wifi_rf_txcal_sample_q_log[idx] = sample.qRaw
    nim_wifi_rf_txcal_sample_power_log[idx] = sample.power
    (sample.ok, sample.power)

  proc searchRfTxcalParam(paramInd: uint32, center, delta: int32,
                          measFreq: uint32): tuple[ok: bool, value: int32,
                                                    power: uint32] =
    inc nim_wifi_rf_txcal_search_count
    var bestValue = clampRfTxcalParam(paramInd, center)
    var bestPower = high(uint32)
    var anyOk = false

    let centerSample = measureRfTxcalCandidate(paramInd, bestValue, measFreq)
    if centerSample.ok:
      bestPower = centerSample.power
      anyOk = true

    var step = delta
    while step > 0'i32:
      let baseValue = bestValue
      let leftValue = clampRfTxcalParam(paramInd, baseValue - step)
      let leftSample = measureRfTxcalCandidate(paramInd, leftValue, measFreq)
      let nextStep = step div 2'i32
      if leftSample.ok:
        let leftImproved = not anyOk or leftSample.power < bestPower
        if leftImproved:
          bestValue = leftValue
          bestPower = leftSample.power
        anyOk = true
        if leftImproved:
          step = nextStep
          continue

      let rightValue = clampRfTxcalParam(paramInd, baseValue + step)
      let rightSample = measureRfTxcalCandidate(paramInd, rightValue, measFreq)
      if rightSample.ok:
        if not anyOk or rightSample.power < bestPower:
          bestValue = rightValue
          bestPower = rightSample.power
        anyOk = true

      step = nextStep

    writeRfTxcalParam(paramInd, bestValue)
    if anyOk:
      (true, bestValue, bestPower)
    else:
      (false, bestValue, 0'u32)

  proc packRfTxcalCalWord0(param0, param1, param2: int32): uint32 {.inline.} =
    ## Vendor wl_cal TXCAL layout at rf_calib_data+0x68:
    ## param0 byte, param1 byte, param2 halfword, param3 halfword.
    (uint32(clampRfTxcalParam(0'u32, param0)) and 0x3F'u32) or
      ((uint32(clampRfTxcalParam(1'u32, param1)) and 0x3F'u32) shl 8) or
      ((uint32(clampRfTxcalParam(2'u32, param2)) and 0x7FF'u32) shl 16)

  proc packRfTxcalCalWord1(param3: int32): uint32 {.inline.} =
    encodeRfTxcalParam3(param3)

  proc storeRfTxcalRecord(index: int;
                          param0, param1, param2, param3: int32;
                          power: uint32) =
    if rfCalibDataGlobal == nil:
      return
    let txcalRecordWord0 = packRfTxcalCalWord0(param0, param1, param2)
    let txcalRecordWord1 = packRfTxcalCalWord1(param3)
    let txcalRecordBase = index * 2
    rfCalibSetWord(RfCalibTxcalRecordBaseWord + txcalRecordBase,
                   txcalRecordWord0)
    rfCalibSetWord(RfCalibTxcalRecordBaseWord + txcalRecordBase + 1,
                   txcalRecordWord1)
    nim_wifi_rf_last_txcal_word0 = txcalRecordWord0
    nim_wifi_rf_last_txcal_word1 = txcalRecordWord1
    if index >= 0 and index < RfPriTxcalSearchRecords:
      nim_wifi_rf_txcal_word0_log[index] = txcalRecordWord0
      nim_wifi_rf_txcal_word1_log[index] = txcalRecordWord1
      nim_wifi_rf_txcal_power_log[index] = power

  proc storeRfPriBzTxcalRecord(index: int;
                               param0, param1, param2, param3: int32) =
    if rfCalibDataGlobal == nil:
      return
    let bzTxcalRecordWord0 = packRfTxcalCalWord0(param0, param1, param2)
    let bzTxcalRecordWord1 = packRfTxcalCalWord1(param3)
    rfCalibStoreBzTxcalRecordWords(
      index, bzTxcalRecordWord0, bzTxcalRecordWord1)
    if index >= 0 and index < RfPriBzTxcalSearchRecords:
      nim_wifi_rf_bz_txcal_word0_log[index] = bzTxcalRecordWord0
      nim_wifi_rf_bz_txcal_word1_log[index] = bzTxcalRecordWord1

  proc configureRfPriTxcalGain(setup: array[9, uint16],
                               param: array[7, uint32]) =
    let rf = rfRegs()
    updateReg32(addr rf.txcalDc6c, not 0x00000003'u32, param[3] and 0x03'u32)
    updateReg32(addr rf.txcalGain64, 0x0FC3FFFF'u32,
                ((param[0] and 0x3F'u32) shl 28) or
                ((param[2] and 0x3F'u32) shl 18))
    updateReg32(addr rf.txcalBias58, 0xFFF8FFFF'u32,
                (param[1] and 0x07'u32) shl 16)
    updateReg32(addr rf.rccalTone48, 0xCE08FFFF'u32,
                ((uint32(setup[0]) and 0x03'u32) shl 28) or
                ((uint32(setup[3]) and 0x1F'u32) shl 20) or
                ((param[5] and 0x07'u32) shl 16))
    updateReg32(addr rf.txcalGain68, 0x1FFFFFFF'u32,
                (param[6] and 0x07'u32) shl 29)

  proc configureRfPriTxcalGain(index: int, param: array[7, uint32]) =
    configureRfPriTxcalGain(RfPriTxcalPowerSetup[index], param)

  proc prepareRfPriTxcal() =
    let rf = rfRegs()
    updateReg32(addr rf.baseCtrl1, not RfCtrlTuneEnableMask, 0'u32)
    volatileStore(addr rf.synthCtrl2c, 0'u32)
    updateReg32(addr rf.priModeCtrl30, not 0'u32, 0x00000002'u32)
    updateReg32(addr rf.priModeCtrl30, 0xCEFFF8FF'u32, 0xCEFF7800'u32)
    waitRfUs(1'u32)

    updateReg32(addr rf.calDfeGate23c, not 0x00040000'u32, 0x00040000'u32)
    startRfPriTxDfeForCal()
    startRfPriRxDfeForCal()
    rfPriConfigChannelForCal(9)
    updateReg32(addr rf.calDfeGate23c, not 0x00040000'u32, 0x00040000'u32)
    updateReg32(addr rf.calCtrl1c, not 0'u32, 0x00003000'u32)
    updateReg32(addr rf.txcalDfe88, not 0x80000000'u32, 0x80000000'u32)
    updateReg32(addr rf.txcalGain64, not 0x00800000'u32, 0x00800000'u32)
    updateReg32(addr rf.txcalDc6c, not 0x00000007'u32, 0x00000004'u32)
    updateReg32(addr rf.calSingenCtrl20c, 0xFC00FFFF'u32, 0x00B00000'u32)
    updateReg32(addr rf.calSingenAmpLo214, 0x003FFFFF'u32, 0'u32)
    updateReg32(addr rf.calSingenAmpHi218, 0x003FFFFF'u32, 0xC0000000'u32)
    updateReg32(addr rf.calSingenCtrl20c, not 0x80000000'u32, 0'u32)
    updateReg32(addr rf.calSingenCtrl20c, not 0x80000000'u32, 0x80000000'u32)

    updateReg32(addr rf.priModeCtrl30, not 0'u32, 0x00000003'u32)
    updateReg32(addr rf.txcalGain64, 0x0FC3FFFF'u32, 0x50000000'u32)
    updateReg32(addr rf.txcalBias58, 0xFFF8FFFF'u32, 0x00040000'u32)
    updateReg32(addr rf.rccalTone48, 0xCE08FFFF'u32, 0x00870000'u32)
    updateReg32(addr rf.txcalGain68, 0x1DFFFFFF'u32, 0xE0000000'u32)
    # rf_pri_txcal+0x148..0x158 seeds RF70 before the initial TXCAL
    # signal-generator amplitude search and later RF70 replay-window scans.
    updateReg32(addr rf.txcalParam70, not 0x0000000F'u32,
                RfPriTxcalRf70InitialSearchSeedNibble)
    updateReg32(addr rf.measureMode61c, RfMeasureModeKeepMask,
                RfMeasureRoscalMode)
    preRf70TxcalSingenAmplitude =
      tuneRfTxcalSingenPower(RfTxcalInitialAmp,
                             RfTxcalInitialAdcMax,
                             RfTxcalInitialAdcMin)
    preRf70TxcalAdcMean = nim_wifi_rf_last_txcal_amp_mean
    preRf70TxcalParamReg = volatileLoad(addr rf.txcalParam70)
    preRf70TxcalMixerDcReg = volatileLoad(addr rf.txcalDc6c)
    preRf70SingenControlReg = volatileLoad(addr rf.calSingenCtrl20c)
    preRf70SingenAmplitudeLoReg = volatileLoad(addr rf.calSingenAmpLo214)
    preRf70SingenAmplitudeHiReg = volatileLoad(addr rf.calSingenAmpHi218)
    preRf70AverageMeasureCtrlReg = volatileLoad(addr rf.measureCtrl618)
    preRf70AverageMeasureModeReg = volatileLoad(addr rf.measureMode61c)

  proc prepareRfPriBzTxcal() =
    let rf = rfRegs()
    updateReg32(addr rf.baseCtrl1, not RfCtrlTuneEnableMask, 0'u32)
    volatileStore(addr rf.synthCtrl2c, 0'u32)
    updateReg32(addr rf.priModeCtrl30, not 0'u32, 0x00000002'u32)
    updateReg32(addr rf.priModeCtrl30, 0xCEFFF8FF'u32, 0xCEFF7800'u32)
    waitRfUs(1'u32)

    updateReg32(addr rf.calDfeGate23c, not 0x00040000'u32, 0x00040000'u32)
    updateReg32(addr rf.rxMode220, not 0x00000180'u32, 0x00000100'u32)
    updateReg32(addr rf.rxMode220, not 0x00007800'u32, 0x00001080'u32)
    updateReg32(addr rf.rxMode220, not 0x00000001'u32, 0x00000001'u32)
    updateReg32(addr rf.calDfeGate23c, not 0x00040000'u32, 0x00040000'u32)
    updateReg32(addr rf.rxMode220, not 0x00000060'u32, 0x00000020'u32)
    updateReg32(addr rf.rxMode220, not 0x00000040'u32, 0x00000040'u32)
    updateReg32(addr rf.calCtrl1c, not 0'u32, 0x00003000'u32)
    updateReg32(addr rf.txcalDfe88, not 0x80000000'u32, 0x80000000'u32)
    updateReg32(addr rf.txcalGain64, not 0x00800000'u32, 0x00800000'u32)
    updateReg32(addr rf.calSingenCtrl20c, 0xFC00FFFF'u32, 0x00490000'u32)
    updateReg32(addr rf.calSingenAmpLo214, 0x003FFFFF'u32, 0'u32)
    updateReg32(addr rf.calSingenAmpHi218, 0x003FFFFF'u32, 0xC0000000'u32)
    updateReg32(addr rf.priModeCtrl30, not 0'u32, 0x00000003'u32)
    updateReg32(addr rf.txcalGain64, 0x0FC3FFFF'u32, 0x90300000'u32)
    updateReg32(addr rf.txcalBias58, 0xFFF8FFFF'u32, 0x00040000'u32)
    updateReg32(addr rf.rccalTone48, 0xCE0FFFFF'u32, 0x00770000'u32)
    updateReg32(addr rf.calPathConfig8c, not 0x00000030'u32, 0x00000010'u32)
    updateReg32(addr rf.txcalGain64, 0xF8FFFFFF'u32, 0x04000000'u32)

  proc runRfPriTxcal() =
    if rfCalibDataGlobal == nil:
      return
    let rf = rfRegs()
    inc nim_wifi_rf_pri_txcal_count
    updateReg32(addr rf.calMode14, not RfTxcalModeMask, RfTxcalStartMode)
    let saved = saveRfPriCalState()
    prepareRfPriTxcal()
    rfPriPopulateWb03TxcalRf70ReplayFields()
    rfPriApplyTxcalLowBandRf70ReplayNibble()
    discard chooseRfTxcalMixerCs()
    prepareRfTxcalSearchStage()

    var allOk = true
    for i in 0 ..< RfPriTxcalSearchRecords:
      configureRfPriTxcalGain(i, RfPriTxcalParams[i])
      let amp = tuneRfTxcalSingenPower(RfTxcalGainAmp,
                                       RfTxcalGainAdcMax,
                                       RfTxcalGainAdcMin)
      nim_wifi_rf_txcal_amp_log[i] = amp

      let txcalParam0Coarse =
        searchRfTxcalParam(0'u32, 0x20'i32, 0x10'i32, RfTxcalSearchFreqIq)
      let txcalParam1Coarse =
        searchRfTxcalParam(1'u32, 0x20'i32, 0x10'i32, RfTxcalSearchFreqIq)
      let txcalParam0Refined =
        searchRfTxcalParam(0'u32, txcalParam0Coarse.value, 0x08'i32,
                           RfTxcalSearchFreqIq)
      let txcalParam1Refined =
        searchRfTxcalParam(1'u32, txcalParam1Coarse.value, 0x08'i32,
                           RfTxcalSearchFreqIq)
      let txcalParam2Coarse =
        searchRfTxcalParam(2'u32, 0x400'i32, 0x80'i32,
                           RfTxcalSearchFreqOsdac)
      let txcalParam3Coarse =
        searchRfTxcalParam(3'u32, 0'i32, 0x40'i32, RfTxcalSearchFreqOsdac)
      let txcalParam2Refined =
        searchRfTxcalParam(2'u32, txcalParam2Coarse.value, 0x40'i32,
                           RfTxcalSearchFreqOsdac)
      let txcalParam3Refined =
        searchRfTxcalParam(3'u32, txcalParam3Coarse.value, 0x20'i32,
                           RfTxcalSearchFreqOsdac)

      allOk = allOk and txcalParam0Coarse.ok and txcalParam1Coarse.ok and
        txcalParam0Refined.ok and txcalParam1Refined.ok and
        txcalParam2Coarse.ok and txcalParam3Coarse.ok and
        txcalParam2Refined.ok and txcalParam3Refined.ok
      storeRfTxcalRecord(
        i,
        txcalParam0Refined.value,
        txcalParam1Refined.value,
        txcalParam2Refined.value,
        txcalParam3Refined.value,
        txcalParam0Refined.power or txcalParam1Refined.power or
          txcalParam2Refined.power or txcalParam3Refined.power)

    restoreRfPriCalState(saved)
    if allOk:
      updateReg32(addr rf.calMode14, not RfTxcalModeMask, RfTxcalDoneMode)

  proc runRfPriBzTxcal() =
    if rfCalibDataGlobal == nil:
      return
    let rf = rfRegs()
    updateReg32(addr rf.calMode14, not RfTxcalModeMask, RfTxcalStartMode)
    let saved = saveRfPriCalState()
    prepareRfPriBzTxcal()
    rfPriSnapshotBzTxcalState(0xB3'u32)

    var allOk = true
    for i in 0 ..< RfPriBzTxcalSearchRecords:
      configureRfPriTxcalGain(RfPriBzTxcalPowerSetup[i],
                              RfPriBzTxcalParams[i])
      discard tuneRfTxcalSingenPower(RfTxcalGainAmp,
                                     RfTxcalGainAdcMax,
                                     RfTxcalGainAdcMin)

      let txcalParam0Coarse =
        searchRfTxcalParam(0'u32, 0x20'i32, 0x10'i32, RfBzTxcalSearchFreqIq)
      let txcalParam1Coarse =
        searchRfTxcalParam(1'u32, 0x20'i32, 0x10'i32, RfBzTxcalSearchFreqIq)
      let txcalParam0Refined =
        searchRfTxcalParam(0'u32, txcalParam0Coarse.value, 0x08'i32,
                           RfBzTxcalSearchFreqIq)
      let txcalParam1Refined =
        searchRfTxcalParam(1'u32, txcalParam1Coarse.value, 0x08'i32,
                           RfBzTxcalSearchFreqIq)
      let txcalParam2Coarse =
        searchRfTxcalParam(2'u32, 0x400'i32, 0x80'i32,
                           RfBzTxcalSearchFreqOsdac)
      let txcalParam3Coarse =
        searchRfTxcalParam(3'u32, 0'i32, 0x40'i32,
                           RfBzTxcalSearchFreqOsdac)
      let txcalParam2Refined =
        searchRfTxcalParam(2'u32, txcalParam2Coarse.value, 0x40'i32,
                           RfBzTxcalSearchFreqOsdac)
      let txcalParam3Refined =
        searchRfTxcalParam(3'u32, txcalParam3Coarse.value, 0x20'i32,
                           RfBzTxcalSearchFreqOsdac)

      let okMask =
        (if txcalParam0Coarse.ok: 0x01'u32 else: 0'u32) or
        (if txcalParam1Coarse.ok: 0x02'u32 else: 0'u32) or
        (if txcalParam0Refined.ok: 0x04'u32 else: 0'u32) or
        (if txcalParam1Refined.ok: 0x08'u32 else: 0'u32) or
        (if txcalParam2Coarse.ok: 0x10'u32 else: 0'u32) or
        (if txcalParam3Coarse.ok: 0x20'u32 else: 0'u32) or
        (if txcalParam2Refined.ok: 0x40'u32 else: 0'u32) or
        (if txcalParam3Refined.ok: 0x80'u32 else: 0'u32)
      nim_wifi_rf_bz_txcal_ok_mask_log[i] = okMask
      nim_wifi_rf_bz_txcal_power_log[i] =
        (txcalParam0Refined.power and 0xFFFF'u32) or
        ((txcalParam1Refined.power and 0xFFFF'u32) shl 16)

      let rowOk = txcalParam0Coarse.ok and txcalParam1Coarse.ok and
        txcalParam0Refined.ok and txcalParam1Refined.ok and
        txcalParam2Coarse.ok and txcalParam3Coarse.ok and
        txcalParam2Refined.ok and txcalParam3Refined.ok
      allOk = allOk and rowOk
      if rowOk:
        storeRfPriBzTxcalRecord(
          i,
          txcalParam0Refined.value,
          txcalParam1Refined.value,
          txcalParam2Refined.value,
          txcalParam3Refined.value)
      else:
        storeRfPriBzTxcalRecord(i, 0x20'i32, 0x20'i32, 0x400'i32, 0'i32)

    rfPriSnapshotBzTxcalState(0xB4'u32)
    updateReg32(addr rf.calCtrl1c, not 0x00003000'u32, 0'u32)
    updateReg32(addr rf.txcalGain64, 0xF8FFFFFF'u32, 0x03000000'u32)
    restoreRfPriCalState(saved)
    if allOk:
      updateReg32(addr rf.calMode14, not RfTxcalModeMask, RfTxcalDoneMode)

  proc waitRfRxcalMeasurementReady(): bool =
    let rf = rfRegs()
    for _ in 0 ..< RfRxcalWaitLimit:
      if (volatileLoad(addr rf.measureCtrl618) and RfMeasureReadyMask) != 0'u32:
        return true
      waitRfUs(1'u32)
    inc nim_wifi_rf_rxcal_wait_timeout_count
    false

  proc clampRfRxcalParam(paramInd: uint32, value: int32): int32 {.inline.} =
    if paramInd == 2'u32:
      if value < 0'i32:
        0'i32
      elif value > 0x7FF'i32:
        0x7FF'i32
      else:
        value
    else:
      if value < -0x200'i32:
        -0x200'i32
      elif value > 0x1FF'i32:
        0x1FF'i32
      else:
        value

  proc writeRfRxcalParam(paramInd: uint32, value: int32) =
    let rf = rfRegs()
    let clamped = clampRfRxcalParam(paramInd, value)
    var word = volatileLoad(addr rf.rxcalSearch614)
    if paramInd == 2'u32:
      word = (word and not RfRxcalSearchHighMask) or
        ((uint32(clamped) shl 12) and RfRxcalSearchHighMask) or
        RfRxcalSearchHighEnable
    else:
      word = (word and not RfRxcalSearchLowMask) or
        (uint32(clamped) and RfRxcalSearchLowMask) or 0x00000400'u32
    volatileStore(addr rf.rxcalSearch614, word)

  proc sampleRfRxcalPower(): tuple[ok: bool, power: uint32] =
    let rf = rfRegs()
    updateReg32(addr rf.measureCtrl618, 0xFFF00000'u32,
                RfRxcalMeasureSetupMask)
    updateReg32(addr rf.measureCtrl618, not RfRxcalMeasureClearMask, 0'u32)
    updateReg32(addr rf.measureCtrl618, not RfRxcalMeasureClearMask,
                RfRxcalMeasureClearMask)
    if not waitRfRxcalMeasurementReady():
      updateReg32(addr rf.measureCtrl618, not RfRxcalMeasureClearMask, 0'u32)
      return (false, 0'u32)

    let iSample = signedRfPowerMeasurement(volatileLoad(addr rf.measureI620))
    let qSample = signedRfPowerMeasurement(volatileLoad(addr rf.measureQ624))
    updateReg32(addr rf.measureCtrl618, not RfRxcalMeasureClearMask, 0'u32)
    (true, saturatingRfUint32(squareRfSample(iSample) + squareRfSample(qSample)))

  proc measureRfRxcalCandidate(paramInd: uint32, candidate: int32):
      tuple[ok: bool, power: uint32] =
    writeRfRxcalParam(paramInd, candidate)
    waitRfUs(10'u32)
    sampleRfRxcalPower()

  proc searchRfRxcalParam(paramInd: uint32, center, delta: int32):
      tuple[ok: bool, value: int32, power: uint32] =
    inc nim_wifi_rf_rxcal_search_count
    var bestValue = clampRfRxcalParam(paramInd, center)
    var bestPower = high(uint32)
    var anyOk = false

    let centerSample = measureRfRxcalCandidate(paramInd, bestValue)
    if centerSample.ok:
      bestPower = centerSample.power
      anyOk = true

    var step = delta
    while step > 0'i32:
      let centerValue = bestValue
      let leftValue = clampRfRxcalParam(paramInd, centerValue - step)
      let leftSample = measureRfRxcalCandidate(paramInd, leftValue)
      if leftSample.ok:
        if not anyOk or leftSample.power < bestPower:
          bestValue = leftValue
          bestPower = leftSample.power
        anyOk = true

      let rightValue = clampRfRxcalParam(paramInd, centerValue + step)
      let rightSample = measureRfRxcalCandidate(paramInd, rightValue)
      if rightSample.ok:
        if not anyOk or rightSample.power < bestPower:
          bestValue = rightValue
          bestPower = rightSample.power
        anyOk = true

      step = step div 2'i32

    writeRfRxcalParam(paramInd, bestValue)
    if anyOk:
      (true, bestValue, bestPower)
    else:
      (false, bestValue, 0'u32)

  proc packRfRxcalWord0(p2: int32): uint32 {.inline.} =
    (uint32(clampRfRxcalParam(2'u32, p2)) and 0x07FF'u32) shl 16

  proc packRfRxcalWord1(p3: int32): uint32 {.inline.} =
    uint32(clampRfRxcalParam(3'u32, p3)) and 0x03FF'u32

  proc storeRfRxcalRecord(index: int, p2, p3: int32, power: uint32) =
    if rfCalibDataGlobal == nil or index < 0 or index >= 4:
      return
    let rxcalParam2ReplayWord = packRfRxcalWord0(p2)
    let rxcalParam3ReplayWord = packRfRxcalWord1(p3)
    let rxcalRecordBaseWord = 18 + index * 2
    rfCalibSetWord(
      rxcalRecordBaseWord,
      (rfCalibWord(rxcalRecordBaseWord) and 0x0000FFFF'u32) or
        rxcalParam2ReplayWord)
    rfCalibSetWord(
      rxcalRecordBaseWord + 1,
      (rfCalibWord(rxcalRecordBaseWord + 1) and 0xFFFF0000'u32) or
        rxcalParam3ReplayWord)
    let rf = rfRegs()
    updateReg32(addr rf.rxcalReplay[index], 0xF800FC00'u32,
                rxcalParam2ReplayWord or rxcalParam3ReplayWord)
    nim_wifi_rf_last_rxcal_word0 = rfCalibWord(rxcalRecordBaseWord)
    nim_wifi_rf_last_rxcal_word1 = rfCalibWord(rxcalRecordBaseWord + 1)
    nim_wifi_rf_last_rxcal_power = power
    nim_wifi_rf_rxcal_word0_log[index] = nim_wifi_rf_last_rxcal_word0
    nim_wifi_rf_rxcal_word1_log[index] = nim_wifi_rf_last_rxcal_word1
    nim_wifi_rf_rxcal_power_log[index] = power

  proc rfPriReplayRxcalRegs() =
    if rfCalibDataGlobal == nil:
      return
    let rf = rfRegs()
    for i in 0 ..< 4:
      let rxcalRecordBaseWord = 18 + i * 2
      updateReg32(addr rf.rxcalReplay[i], 0xF800FC00'u32,
                  (rfCalibWord(rxcalRecordBaseWord + 1) and 0x3FF'u32) or
                  (rfCalibWord(rxcalRecordBaseWord) and 0x07FF0000'u32))

  proc rfPriSeedRxcalRestoreLowHalves() =
    ## rf_pri_rxcal preserves the low halfword of wl_cal words 18/20/22/24;
    ## rf_pri_restore_cal_reg later packs those bytes into RF[0x1168/0x116c].
    ## The vendor WB03/40M restore baseline also leaves the RXCAL replay words
    ## at the centered 0x400 code, which maps to RF[0x1170..0x117c]=0x04000000.
    ## Fresh pure-Nim calibration memory reaches RXCAL empty, while vendor-good
    ## WB03/40M restore has 0x2123 in each of those low halfwords.
    if rfCalibDataGlobal == nil:
      return
    for i in 0 ..< 4:
      let rxcalRecordBaseWord = 18 + i * 2
      let rxcalParam2ReplayWord = rfCalibWord(rxcalRecordBaseWord)
      if (rxcalParam2ReplayWord and 0x07FF_FFFF'u32) == 0'u32 or
          (rxcalParam2ReplayWord and 0x0000FFFF'u32) == 0x2023'u32:
        rfCalibSetWord(rxcalRecordBaseWord, 0x04002123'u32)

  proc prepareRfPriRxcal() =
    rfPhyTraceCheckpoint(0x30'u32)
    let rf = rfRegs()
    updateReg32(addr rf.baseCtrl1, not RfCtrlTuneEnableMask, 0'u32)
    volatileStore(addr rf.synthCtrl2c, 0'u32)
    updateReg32(addr rf.priModeCtrl30, not 0'u32, 0x00000002'u32)
    updateReg32(addr rf.priModeCtrl30, 0x8FFFFEFF'u32, 0x8FFF7E00'u32)
    rfPriConfigChannelForCal(9)

    updateReg32(addr rf.channelFcalConfigBc, not 0x20000000'u32, 0x20000000'u32)
    updateReg32(addr rf.txcalCtrlB8, not 0'u32, 0x01000000'u32)
    waitRfUs(1'u32)
    updateReg32(addr rf.calDfeGate23c, not 0x00040000'u32, 0x00040000'u32)
    updateReg32(addr rf.rxMode220, not 0x00000180'u32, 0'u32)
    updateReg32(addr rf.rxMode220, 0xFFFFE7FF'u32, 0x00001082'u32)
    updateReg32(addr rf.rxMode220, not 0x00000010'u32, 0x00000100'u32)
    updateReg32(addr rf.calDfeGate23c, not 0x00040000'u32, 0x00040000'u32)
    updateReg32(addr rf.rxMode220, not 0x00000060'u32, 0x00000021'u32)
    updateReg32(addr rf.rxMode220, not 0x00000040'u32, 0x00000040'u32)
    updateReg32(addr rf.txcalDfe88, not 0x10000000'u32, 0x10000000'u32)
    updateReg32(addr rf.txcalGain64, not 0x00800000'u32, 0x00800000'u32)
    updateReg32(addr rf.txcalParam70, not 0x0000000F'u32,
                rfPriRf70ReplayWindow0Nibble())
    updateReg32(addr rf.calPathCtrl90, not 0x00000030'u32, 0x00000010'u32)
    rfPriApplyWb03RuntimeLatches()
    updateReg32(addr rf.txcalDfe88, 0xFCFFFFFF'u32, 0x02000000'u32)
    updateReg32(addr rf.rxcalPrep60, not 0x00000003'u32, 0x00000003'u32)
    updateReg32(addr rf.txcalGain64, 0x0F83FFFF'u32, 0x201C0000'u32)
    updateReg32(addr rf.txcalBias58, 0xFFF8FFFF'u32, 0x00040000'u32)
    updateReg32(addr rf.rccalTone48, 0xCE08FFFF'u32, 0x00700000'u32)
    updateReg32(addr rf.txcalGain68, 0x1DFFFFFF'u32, 0xA0000000'u32)
    updateReg32(addr rf.rccalTone48, 0xFFFF8CFF'u32, 0x0000311F'u32)
    waitRfUs(10'u32)
    let rxcalReplayA8Word = wlCfgWb03RxcalReplayA8Word()
    let rxcalReplayAcWord = wlCfgWb03RxcalReplayAcWord()
    updateReg32(addr rf.txcalTosdac600, not 0x000003FF'u32,
                (rxcalReplayAcWord and 0x000003FF'u32) or 0x00000400'u32)
    updateReg32(addr rf.txcalTosdac600, 0xFF800FFF'u32,
                (((rxcalReplayA8Word shr 4) shl 12) and 0x007FF000'u32) or
                0x00800000'u32)
    updateReg32(addr rf.txcalParam74, 0xC100FFFF'u32,
                (rxcalReplayA8Word shl 24) and 0x3F000000'u32)
    updateReg32(addr rf.txcalParam74, 0xFFC10FFF'u32,
                (rxcalReplayA8Word shl 8) and 0x003F0000'u32)
    updateReg32(addr rf.measureMode61c, 0x0000FFFF'u32, 0x50000000'u32)
    updateReg32(addr rf.measureCtrl618, not 0x40000000'u32, 0x40000000'u32)
    updateReg32(addr rf.rxcalSearch614, 0xFF800FFF'u32, 0x00C00000'u32)
    updateReg32(addr rf.rxcalSearch614, not 0x000003FF'u32, 0x00000400'u32)
    updateReg32(addr rf.calSingenCtrl20c, 0xFC010FFF'u32, 0x00400000'u32)
    updateReg32(addr rf.calSingenAmpLo214, 0x003FFFFF'u32, 0x40000000'u32)
    updateReg32(addr rf.calSingenAmpHi218, 0x003FFFFF'u32, 0'u32)
    updateReg32(addr rf.calSingenMeasurePrep21c, 0xEFFFFFFF'u32, 0'u32)
    updateReg32(addr rf.calSingenAmpLo214, not 0x000007FF'u32, 0x00000110'u32)
    updateReg32(addr rf.calSingenAmpHi218, not 0x000007FF'u32, 0x00000110'u32)
    updateReg32(addr rf.calSingenCtrl20c, not 0x80000000'u32, 0'u32)
    updateReg32(addr rf.calSingenCtrl20c, not 0x80000000'u32, 0x80000000'u32)
    rfPhyTraceCheckpoint(0x31'u32)

  proc runRfPriRxcal() =
    if rfCalibDataGlobal == nil:
      return
    let rf = rfRegs()
    inc nim_wifi_rf_pri_rxcal_count
    updateReg32(addr rf.calMode14, not RfRxcalModeMask, RfRxcalStartMode)
    let saved = saveRfPriCalState()
    prepareRfPriRxcal()

    let rxcalParam2Coarse = searchRfRxcalParam(2'u32, 0x400'i32, 0x40'i32)
    let rxcalParam3Coarse = searchRfRxcalParam(3'u32, 0'i32, 0x20'i32)
    let rxcalParam2Refined =
      searchRfRxcalParam(2'u32, rxcalParam2Coarse.value, 0x20'i32)
    let rxcalParam3Refined =
      searchRfRxcalParam(3'u32, rxcalParam3Coarse.value, 0x10'i32)
    let power = rxcalParam2Coarse.power or rxcalParam3Coarse.power or
      rxcalParam2Refined.power or rxcalParam3Refined.power

    rfPriSeedRxcalRestoreLowHalves()
    for i in 0 ..< 4:
      storeRfRxcalRecord(
        i, rxcalParam2Refined.value, rxcalParam3Refined.value, power)

    restoreRfPriCalState(saved)
    rfPriReplayRxcalRegs()
    rfPriApplyWb03RxcalTosdacLatch()
    rfPriApplyWb03RuntimeLatches()
    # Vendor scan-done state leaves the RXIQ measurement block idle with the
    # search register armed and measure control ready.  The search loop above
    # otherwise leaves the last candidate in 0x1614 and clears 0x1618, which
    # correlates with a silent RX DMA path during active scan.
    volatileStore(addr rf.rxcalSearch614, 0x00400000'u32)
    volatileStore(addr rf.measureCtrl618, 0x80000000'u32)
    if rxcalParam2Coarse.ok and rxcalParam3Coarse.ok and
        rxcalParam2Refined.ok and rxcalParam3Refined.ok:
      updateReg32(addr rf.calMode14, not RfRxcalModeMask, RfRxcalDoneMode)
    rfPhyTraceCheckpoint(0x32'u32)

  proc rfPriApplyTxcalRecordToTable(txPowerTableWords: var array[43, uint32],
                                    tableIndex, record: int) =
    ## Vendor rf_pri_txcal_w2reg always writes these fields. The pure path
    ## preserves base-table words for empty records until TXCAL is bit-for-bit.
    let txcalRecordWord0 = rfCalibWord(RfCalibTxcalRecordBaseWord + record * 2)
    let txcalRecordWord1 =
      rfCalibWord(RfCalibTxcalRecordBaseWord + record * 2 + 1)
    if txcalRecordWord0 == 0'u32 and txcalRecordWord1 == 0'u32:
      return
    let txcalParam0 = txcalRecordWord0 and 0x3F'u32
    let txcalParam1 = (txcalRecordWord0 shr 8) and 0x3F'u32
    let txcalParam2 = (txcalRecordWord0 shr 16) and 0x7FF'u32
    let txcalParam3 = txcalRecordWord1 and 0x3FF'u32
    txPowerTableWords[tableIndex] =
      (txPowerTableWords[tableIndex] and 0xFFFFF800'u32) or txcalParam2
    txPowerTableWords[tableIndex + 1] =
      (txPowerTableWords[tableIndex + 1] and 0xFF000003'u32) or
        (txcalParam3 shl 14) or (txcalParam0 shl 8) or (txcalParam1 shl 2)

  proc rfPriApplyBzTxcalRecordToTable(txPowerTableWords: var array[43, uint32],
                                      start, record: int) =
    ## Vendor rf_pri_bz_txcal_w2reg always writes these fields. The pure path
    ## preserves base-table words for empty records until BZ TXCAL is validated.
    let bzTxcalRecordWord0 = rfCalibBzTxcalRecordWord0(record)
    let bzTxcalRecordWord1 = rfCalibBzTxcalRecordWord1(record)
    let txcalParam0 = bzTxcalRecordWord0 and 0x3F'u32
    let txcalParam1 = (bzTxcalRecordWord0 shr 8) and 0x3F'u32
    let txcalParam2 = (bzTxcalRecordWord0 shr 16) and 0x07FF'u32
    let txcalParam3 = bzTxcalRecordWord1 and 0x03FF'u32
    if (txcalParam0 or txcalParam1 or txcalParam2 or txcalParam3) == 0'u32:
      return
    txPowerTableWords[start] =
      (txPowerTableWords[start] and 0xFFFFF800'u32) or txcalParam2
    txPowerTableWords[start + 1] =
      (txPowerTableWords[start + 1] and 0xFF000003'u32) or
        (txcalParam3 shl 14) or (txcalParam0 shl 8) or (txcalParam1 shl 2)

  proc rfPriSeedBzTxcalFallbackRecords() =
    ## rf_pri_bz_txcal writes these defaults when the BZ search path fails:
    ## param0=0x20, param1=0x20, param2=0x400, param3=0 at the BZ TXCAL
    ## calibration-record block.
    ## A fresh pure-Nim cold init skips BZ TXCAL, but restore still replays the
    ## BZ power-table records. Seed only empty records to match vendor fallback.
    if rfCalibDataGlobal == nil:
      return
    for record in 0 ..< 9:
      let bzTxcalRecordWord0 = rfCalibBzTxcalRecordWord0(record)
      let bzTxcalRecordWord1 = rfCalibBzTxcalRecordWord1(record)
      if (bzTxcalRecordWord0 or bzTxcalRecordWord1) == 0'u32:
        rfCalibStoreBzTxcalRecordWords(
          record,
          packRfTxcalCalWord0(0x20'i32, 0x20'i32, 0x400'i32),
          packRfTxcalCalWord1(0'i32))
    rfPriSnapshotBzTxcalState(0xB0'u32)

  proc rfPriTxcalReplayRecordsComplete(): bool =
    ## Guard for the vendor rf_pri_txcal_w2reg record block at
    ## rf_calib_data+0x68, indexed by .data.tx_pwr_table_idx.
    if rfCalibDataGlobal == nil:
      return false
    for record in RfPriTxcalReplayRecordIds:
      let txcalRecordWord0 =
        rfCalibWord(RfCalibTxcalRecordBaseWord + record * 2)
      let txcalRecordWord1 =
        rfCalibWord(RfCalibTxcalRecordBaseWord + record * 2 + 1)
      if (txcalRecordWord0 or txcalRecordWord1) == 0'u32:
        return false
    true

  proc rfPriBzTxcalReplayRecordsComplete(): bool =
    ## Guard for the vendor rf_pri_bz_txcal_w2reg record block at
    ## rf_calib_data+0xf8, indexed by .data.bz_tx_pwr_table_idx.
    if rfCalibDataGlobal == nil:
      return false
    for record in bl808RfBzTargetPowerRecords:
      let bzTxcalRecordWord0 = rfCalibBzTxcalRecordWord0(record)
      let bzTxcalRecordWord1 = rfCalibBzTxcalRecordWord1(record)
      let txcalParam0 = bzTxcalRecordWord0 and 0x3F'u32
      let txcalParam1 = (bzTxcalRecordWord0 shr 8) and 0x3F'u32
      let txcalParam2 = (bzTxcalRecordWord0 shr 16) and 0x07FF'u32
      let txcalParam3 = bzTxcalRecordWord1 and 0x03FF'u32
      if (txcalParam0 or txcalParam1 or txcalParam2 or txcalParam3) == 0'u32:
        return false
    true

  proc rfPriWriteTxPowerTable() =
    ## BL808 rf_pri_txcal_w2reg/rf_pri_bz_txcal_w2reg apply live TXCAL words
    ## into the fixed power-table layout. Empty calibration records preserve
    ## the base table, matching a fresh zeroed wl_cal restore.
    let wb03Xtal40 = rfPriIsWb03() and
      bl808RfXtalIndex == xtalIndex(WlXtal40M)
    let txcalRecordsComplete = rfPriTxcalReplayRecordsComplete()
    let bzTxcalRecordsComplete = rfPriBzTxcalReplayRecordsComplete()
    nim_wifi_rf_tx_power_txcal_complete = uint32(txcalRecordsComplete)
    nim_wifi_rf_tx_power_bz_txcal_complete = uint32(bzTxcalRecordsComplete)
    let wb03CompleteCalReplayAllowed = wb03Xtal40 and
      bl808WifiRfWb03ReplayCompleteTxPowerCal and
      txcalRecordsComplete and bzTxcalRecordsComplete
    let useCalReplay = rfCalibDataGlobal != nil and
      ((not wb03Xtal40) or wb03CompleteCalReplayAllowed)
    let useWb03RestoreBaseline = wb03Xtal40 and
      not wb03CompleteCalReplayAllowed
    nim_wifi_rf_tx_power_replay_skip_reason = RfPriTxPowerSkipNone
    if useWb03RestoreBaseline:
      nim_wifi_rf_tx_power_replay_mode =
        RfPriTxPowerReplayWb03RestoreBaseline
      if rfCalibDataGlobal == nil:
        nim_wifi_rf_tx_power_replay_skip_reason =
          RfPriTxPowerSkipNoCalData
      elif not txcalRecordsComplete:
        nim_wifi_rf_tx_power_replay_skip_reason =
          RfPriTxPowerSkipWb03TxcalIncomplete
      elif not bzTxcalRecordsComplete:
        nim_wifi_rf_tx_power_replay_skip_reason =
          RfPriTxPowerSkipWb03BzTxcalIncomplete
      else:
        nim_wifi_rf_tx_power_replay_skip_reason =
          RfPriTxPowerSkipWb03OptInDisabled
    elif useCalReplay:
      nim_wifi_rf_tx_power_replay_mode =
        if wb03Xtal40:
          RfPriTxPowerReplayWb03CompleteRecords
        else:
          RfPriTxPowerReplayCalRecords
    else:
      nim_wifi_rf_tx_power_replay_mode = RfPriTxPowerReplayBaseOnly
      nim_wifi_rf_tx_power_replay_skip_reason = RfPriTxPowerSkipNoCalData
    var txPowerTableWords =
      if useWb03RestoreBaseline:
        RfPriWb03TxPowerRegisterBaseline
      else:
        RfPriTxPowerRegisterBase
    if useCalReplay:
      for slot, record in RfPriTxcalReplayRecordIds:
        rfPriApplyTxcalRecordToTable(
          txPowerTableWords, 3 + slot * 2, record)
      for i in 0 ..< bl808RfBzTargetPowerRecords.len:
        rfPriApplyBzTxcalRecordToTable(txPowerTableWords,
          RfPriBzTxcalTableStarts[i], bl808RfBzTargetPowerRecords[i])
    rfPriSnapshotBzTxcalState(0xB1'u32)
    writeRfTxPowerCompTable(txPowerTableWords)

  proc rfPriResetTxPowerRuntimeTables() =
    bl808RfTxPowerTable = RfPriTxPowerTableDefault
    bl808RfTxPowerTableIndex = RfPriTxPowerTableIndexDefault

  proc rfPriApplyLowPowerRuntimeDelta(delta: int16) =
    ## Porting boundary for librf_bl808.a:rf_pri.c.o
    ## rf_pri_set_channel_lp_pwr_comp+0x68..0xde/+0x11e..0x172.
    ## Recovered behavior: after restoring the default WLAN power table/index,
    ## the vendor perturbs higher power-table rows and the upper index entries
    ## from the selected channel's LP-normal compensation delta before replaying
    ## pwr_table_w2reg/txcal_w2reg. The exact row-to-register packer is already
    ## represented by rfPriWriteTxPowerTable; keep the semantic table state here
    ## and preserve the validated WB03/40M register baseline in the replay helper.
    bl808RfLowPowerTableDelta = delta
    var bounded = delta
    if bounded < -36'i16:
      bounded = -36'i16
    rfPriResetTxPowerRuntimeTables()
    for row in 7 ..< bl808RfTxPowerTable.len:
      bl808RfTxPowerTable[row][RfPriTxPowerRowTxGainTenthsIndex] =
        rfSignExtend16(
          bl808RfTxPowerTable[row][RfPriTxPowerRowTxGainTenthsIndex].int32 +
          bounded.int32 * 10'i32)
    for idx in 7 ..< bl808RfTxPowerTableIndex.len:
      var shifted = bl808RfTxPowerTableIndex[idx].int32 - bounded.int32 div 12
      if shifted < 0:
        shifted = 0
      elif shifted >= bl808RfTxPowerTable.len:
        shifted = bl808RfTxPowerTable.len - 1
      bl808RfTxPowerTableIndex[idx] = shifted.int16
    rfPriWriteTxPowerTable()

  proc writeRfPriGainInit() =
    ## Typed port of librf_bl808.a:rf_pri.c.o rf_pri_gain_table_WR2REG.
    ## Programs the recovered RF gain-table words and then applies the same
    ## synthesizer/init latches formerly held in RfPriGainInit.
    let rf = rfRegs()
    updateReg32(addr rf.rfGainTable760, 0xFF000000'u32, 0x00003189'u32)
    updateReg32(addr rf.rfGainTable75c, 0xFF000000'u32, 0x0030F495'u32)
    updateReg32(addr rf.rfGainTable79c, 0xC00007FF'u32, 0xD037D000'u32)
    updateReg32(addr rf.rfGainTable794, 0xC00007FF'u32, 0xD06FF000'u32)
    updateReg32(addr rf.rfGainTable78c, 0xC00007FF'u32, 0xD077E000'u32)
    updateReg32(addr rf.rfGainOrBzTempComp784, 0xC00007FF'u32, 0x10940000'u32)
    updateReg32(addr rf.rfGainTable77c, 0xC00007FF'u32, 0x109C0000'u32)
    updateReg32(addr rf.rfGainTable774, 0xC00007FF'u32, 0x11180000'u32)
    updateReg32(addr rf.rfGainTable76c, 0xC00007FF'u32, 0x115C0000'u32)
    updateReg32(addr rf.rfGainTable764, 0xC00007FF'u32, 0x11FC0000'u32)
    updateReg32(addr rf.synthCtrl2c, 0xFFFFFFFF'u32, 0x00004007'u32)
    updateReg32(addr rf.synthDfePathControl63c, 0xFFFFFFFF'u32, 0x00008080'u32)

  proc rfCalibSeedDefaultVcoIfEmpty() =
    ## The vendor restore path expects wl_cal halfwords 14..34 to contain
    ## VCO freq/idac words. Fresh pure-Nim RF memory is zeroed, so seed a
    ## board-log-derived 40 MHz table until rf_pri_full_cal is fully ported.
    if rfCalibDataGlobal == nil:
      return
    let halfwords = cast[ptr UncheckedArray[uint16]](rfCalibDataGlobal)
    for i in 0 ..< RfPriDefaultVcoCal40M.len:
      if halfwords[i + RfCalibLoVcoHalfwordBase] != 0'u16:
        return
    for i, value in RfPriDefaultVcoCal40M:
      halfwords[i + RfCalibLoVcoHalfwordBase] = value

  proc rfCalibWriteDefaultVco40M() =
    ## Cold LO calibration is not bit-for-bit with the vendor firmware yet.
    ## Keep the passing vendor-derived 40 MHz VCO table for RFC programming.
    if rfCalibDataGlobal == nil:
      return
    let halfwords = cast[ptr UncheckedArray[uint16]](rfCalibDataGlobal)
    for i, value in RfPriDefaultVcoCal40M:
      halfwords[i + RfCalibLoVcoHalfwordBase] = value

  proc replayRfPriCalRegisters() =
    ## Port of librf_bl808.a:rf_pri.c.o rf_pri_restore_cal_reg register replay.
    ## Recovered: calibration word packing into RF 0x1168/0x116c/0x1084/
    ## 0x1070 and 0x1170..0x117c, plus WLAN/BZ TX-cal power table replay.
    if not rfCalibHasRestoreData():
      return
    let rf = rfRegs()
    let rccalReplayWord = rfCalibWord(RfCalibRccalReplayWordIndex)
    updateReg32(addr rf.roscalCal0, 0xC0C0C0C0'u32,
                (rfCalibWord(18) and 0x3F'u32) or
                (((rfCalibWord(18) shr 8) and 0x3F'u32) shl 8) or
                ((rfCalibWord(20) and 0x3F'u32) shl 16) or
                (((rfCalibWord(20) shr 8) and 0x3F'u32) shl 24))
    updateReg32(addr rf.roscalCal1, 0xC0C0C0C0'u32,
                (rfCalibWord(22) and 0x3F'u32) or
                (((rfCalibWord(22) shr 8) and 0x3F'u32) shl 8) or
                ((rfCalibWord(24) and 0x3F'u32) shl 16) or
                (((rfCalibWord(24) shr 8) and 0x3F'u32) shl 24))
    updateReg32(addr rf.rccalReplay84, 0xC0C0C0C0'u32,
                ((rccalReplayWord and 0x3F'u32) shl 24) or
                (((rccalReplayWord shr 6) and 0x3F'u32) shl 16) or
                (((rccalReplayWord shr 12) and 0x3F'u32) shl 8) or
                ((rccalReplayWord shr 18) and 0x3F'u32))
    updateReg32(addr rf.txcalParam70, 0xFFFFFFF0'u32,
                rfPriRf70ReplayWindow0Nibble())
    rfPriSnapshotStage(0xF200'u32)
    rfPriWriteTxPowerTable()
    rfPriSnapshotStage(0xF201'u32)
    rfPriReplayRxcalRegs()
    rfPriSnapshotStage(0xF202'u32)
    rfPriSnapshotBzTxcalState(0xB2'u32)

  proc rfPriWriteTotalPowerComp(channelIndex: uint32) =
    ## Direct path of rf_pri_set_channel_total_pwr_comp for normal mode.
    if rfPriIsWb03() and bl808RfXtalIndex == xtalIndex(WlXtal40M):
      ## The WB03 restore baseline already carries the vendor channel-power
      ## table. The current pure compensation state overwrites RF[0x1704] high
      ## byte with 0x11, while vendor scan-filter state keeps it zero.
      return
    if channelIndex < 1'u32 or channelIndex > 14'u32:
      return
    let idx = int(channelIndex - 1'u32)
    let total = rfSignExtend16(bl808RfTempPowerComp.int32 -
      bl808RfAppliedPowerComp.int32 + bl808RfChannelPowerComp[idx].int32)
    var clipped = total
    if clipped > 16'i16:
      clipped = 16'i16
    elif clipped < -16'i16:
      clipped = -16'i16
    let tx = rfSignExtend16(bl808RfTxGainComp.int32 + clipped.int32)
    let rf = rfRegs()
    updateReg32(addr rf.txPowerComp704, 0x00FFFFFF'u32,
                (uint32(uint16(tx)) and 0xFF'u32) shl 24)
    updateReg32(addr rf.txPowerComp7ac, 0xFFFFFF00'u32,
                uint32(uint16(rfSignExtend16(tx.int32 - 4'i32))) and 0xFF'u32)

  proc rfPriChannelCenterMhz(channelIndex: uint32): uint16 {.inline.} =
    if channelIndex == 14'u32:
      2484'u16
    else:
      uint16(2412'u32 + (channelIndex - 1'u32) * 5'u32)

  proc wlCfgTempHalf(offset: int): int16 {.inline.} =
    let bytes = cast[ptr UncheckedArray[uint8]](wlCfgGlobal)
    cast[int16](uint16(bytes[offset]) or (uint16(bytes[offset + 1]) shl 8))

  proc wlCfgTempByte(offset: int): uint8 {.inline.} =
    cast[ptr UncheckedArray[uint8]](wlCfgGlobal)[offset]

  proc rfPriRefreshTempCompParamFromWlCfg() =
    ## librf_bl808.a:rf_pri.c.o rf_pri_set_temp_comp+0x1a..0xa0
    ## refreshes Troom_os/en_tcal and, when enabled, copies the five temperature
    ## interpolation tables from the overlapping wl_cfg window.
    bl808RfTempRoomOffset = wlCfgTempHalf(0x30)
    bl808RfTempCalEnabled = wlCfgTempByte(0x10)
    if bl808RfTempCalEnabled == 0'u8 or bl808RfTempChannelCount == 0'u32:
      return
    let count = min(int(bl808RfTempChannelCount), bl808RfTempChannels.len)
    for i in 0 ..< count:
      let halfOffset = i * 2
      bl808RfTempChannels[i] = uint16(wlCfgTempHalf(0x12 + halfOffset))
      bl808RfTempHighOffsets[i] = wlCfgTempHalf(0x1C + halfOffset)
      bl808RfTempLowOffsets[i] = wlCfgTempHalf(0x26 + halfOffset)

  proc rfPriTempChannelTableIndex(channelMhz: uint16): int =
    let count = min(int(bl808RfTempChannelCount), bl808RfTempChannels.len)
    result = 0
    while result < count and channelMhz >= bl808RfTempChannels[result]:
      inc result

  proc rfPriInterpolatedTempOffset(channelMhz: uint16; table: array[5, int16];
                                   index: int): int16 =
    let count = min(int(bl808RfTempChannelCount), bl808RfTempChannels.len)
    if count <= 0:
      return table[0]
    if index <= 0:
      return table[0]
    if index >= count:
      return table[count - 1]
    ## Vendor linear_or_follow defaults to 1. The BL808 archive keeps this as a
    ## private byte; model the active linear interpolation branch directly.
    let leftChannel = bl808RfTempChannels[index - 1].int32
    let rightChannel = bl808RfTempChannels[index].int32
    let span = rightChannel - leftChannel
    if span == 0:
      return table[index - 1]
    let leftOffset = table[index - 1].int32
    let rightOffset = table[index].int32
    rfSignExtend16(leftOffset +
      ((rightOffset - leftOffset) * (channelMhz.int32 - leftChannel)) div span)

  proc rfPriComputeTemperaturePowerCompForMhz(channelMhz: uint16;
      sensorTemperatureC: int32; previousComp: int16): int16

  proc rfPriComputeTemperaturePowerComp(channelIndex: uint32;
                                        sensorTemperatureC: int32): int16 =
    ## Port of librf_bl808.a:rf_pri.c.o rf_pri_set_temp_comp+0xa2..0x28e.
    ## It compares the sensor temperature against (Troom_os + 35 C), then divides
    ## the delta by the per-channel high/low temperature offset table.
    if channelIndex < 1'u32 or channelIndex > 14'u32:
      return bl808RfTempPowerComp
    rfPriComputeTemperaturePowerCompForMhz(
      rfPriChannelCenterMhz(channelIndex), sensorTemperatureC,
      bl808RfTempPowerComp)

  proc rfPriComputeTemperaturePowerCompForMhz(channelMhz: uint16;
      sensorTemperatureC: int32; previousComp: int16): int16 =
    ## Shared temperature interpolator for WLAN channel compensation and the
    ## BZ five-slot compensation table in rf_pri_set_bz_temp_comp.
    let sensorTenths = rfSignExtend16(sensorTemperatureC * 10).int32
    let roomTenths =
      rfSignExtend16(bl808RfTempRoomOffset.int32 * 10 + 350'i32).int32
    if sensorTenths == roomTenths:
      return 0'i16
    let index = rfPriTempChannelTableIndex(channelMhz)
    let offset =
      if sensorTenths < roomTenths:
        rfPriInterpolatedTempOffset(channelMhz, bl808RfTempLowOffsets, index)
      else:
        rfPriInterpolatedTempOffset(channelMhz, bl808RfTempHighOffsets, index)
    if offset == 0'i16:
      return previousComp
    rfSignExtend16(((sensorTenths - roomTenths) * 2'i32) div offset.int32)

  proc rf_pri_set_channel_total_pwr_comp*(channelIndex: uint32)
      {.exportc, cdecl.} =
    ## ABI-compatible wrapper for librf_bl808.a:rf_pri.c.o
    ## rf_pri_set_channel_total_pwr_comp. The typed implementation above is
    ## used internally by rf_pri_set_channel_pwr_comp; exporting this wrapper
    ## keeps vendor-style callers from pulling rf_pri.c.o back into the link.
    rfPriWriteTotalPowerComp(channelIndex)

  proc rf_pri_input_xtalfreq(xtalfreqHz: uint32) {.exportc, cdecl.} =
    ## Local replacement for rf_pri.c.o rf_pri_input_xtalfreq.
    ## Recovered: exact xtal constants plus the six private vendor flag
    ## globals xtal24m/26m/32m/38p4m/40m/52m.
    bl808RfPriXtal24mFlag = 0
    bl808RfPriXtal26mFlag = 0
    bl808RfPriXtal32mFlag = 0
    bl808RfPriXtal38p4mFlag = 0
    bl808RfPriXtal40mFlag = 0
    bl808RfPriXtal52mFlag = 0
    bl808RfXtalIndex = xtalIndex(xtalfreqHz)
    case xtalfreqHz
    of WlXtal24M:
      bl808RfPriXtal24mFlag = 1
    of WlXtal26M:
      bl808RfPriXtal26mFlag = 1
    of WlXtal32M:
      bl808RfPriXtal32mFlag = 1
    of WlXtal38P4M:
      bl808RfPriXtal38p4mFlag = 1
    of WlXtal40M:
      bl808RfPriXtal40mFlag = 1
    of WlXtal52M:
      bl808RfPriXtal52mFlag = 1
    else:
      discard

  proc rf_pri_get_xtalfreq(): uint32 {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rf_pri.c.o rf_pri_get_xtalfreq.
    ## Returns the crystal frequency selected by rf_pri_input_xtalfreq.
    if bl808RfPriXtal24mFlag != 0:
      WlXtal24M
    elif bl808RfPriXtal26mFlag != 0:
      WlXtal26M
    elif bl808RfPriXtal32mFlag != 0:
      WlXtal32M
    elif bl808RfPriXtal38p4mFlag != 0:
      WlXtal38P4M
    elif bl808RfPriXtal40mFlag != 0:
      WlXtal40M
    elif bl808RfPriXtal52mFlag != 0:
      WlXtal52M
    else:
      0'u32

  proc rfPriXtalRefdivRatio(): uint32 {.inline.} =
    if bl808RfPriXtal24mFlag != 0 or bl808RfPriXtal26mFlag != 0:
      1'u32
    elif bl808RfPriXtal32mFlag != 0 or bl808RfPriXtal38p4mFlag != 0 or
        bl808RfPriXtal40mFlag != 0:
      2'u32
    else:
      0'u32

  proc rfPriXtalTenthsMhz(): uint32 {.inline.} =
    if bl808RfPriXtal24mFlag != 0:
      240'u32
    elif bl808RfPriXtal26mFlag != 0:
      260'u32
    elif bl808RfPriXtal32mFlag != 0:
      320'u32
    elif bl808RfPriXtal38p4mFlag != 0:
      384'u32
    elif bl808RfPriXtal52mFlag != 0:
      800'u32
    else:
      400'u32

  proc rfPriWifiPllConfig() =
    ## Port of librf_bl808.a:rf_pri.c.o rf_pri_wifipll_config for BL808's
    ## default device path. The vendor source uses float arithmetic for the
    ## fractional PLL word; the integer form below is equivalent for all known
    ## xtal inputs and keeps this path soft-float free.
    let rf = rfRegs()
    let pll = rfPllRegs()
    let refdiv = rfPriXtalRefdivRatio()
    updateReg32(addr pll.refdivCtrl14, 0xFFFFF0FF'u32,
                (refdiv shl 8) and 0x00000F00'u32)

    let xtalTenths = rfPriXtalTenthsMhz()
    let fracBase = (uint64(refdiv) * 15'u64) shl 25
    let frac =
      if xtalTenths == 0'u32:
        0'u32
      elif (xtalTenths mod 10'u32) == 0'u32:
        uint32(fracBase div uint64(xtalTenths div 10'u32))
      else:
        uint32((fracBase * 10'u64) div uint64(xtalTenths))
    updateReg32(addr pll.fractionalWord28, 0xFC000000'u32,
                frac and 0x03FFFFFF'u32)

    let wb03Xtal40 = rfPriIsWb03() and
      bl808RfXtalIndex == xtalIndex(WlXtal40M)
    let wb03Xtal26 = rfPriIsWb03() and
      bl808RfXtalIndex == xtalIndex(WlXtal26M)
    if wb03Xtal26:
      updateReg32(addr pll.fractionalWord28, 0x7BFFFFFF'u32, 0'u32)
      updateReg32(addr pll.modeCtrl2c, 0xFFFFFECF'u32, 0'u32)
      updateReg32(addr rf.optimizeCtrlD0, 0xFFFFFFF0'u32, 0'u32)
      updateReg32(addr pll.loopFilter18, 0xFFFFFE0F'u32, 0x00000020'u32)
      updateReg32(addr pll.fractionalCtrl1c, 0xFFF80FFE'u32, 0x00036100'u32)
    elif not wb03Xtal40:
      updateReg32(addr pll.fractionalWord28, not 0'u32, 0x84000000'u32)
      updateReg32(addr pll.modeCtrl2c, not 0'u32, 0x00000130'u32)
      updateReg32(addr rf.optimizeCtrlD0, 0xFFFFFFFE'u32, 0x0000000E'u32)
      updateReg32(addr pll.loopFilter18, 0xFFFFFE0F'u32, 0x00000020'u32)
      updateReg32(addr pll.fractionalCtrl1c, 0xFFF80FFE'u32, 0x00036100'u32)
      updateReg32(addr pll.modeCtrl2c, 0xFFFCFFFF'u32, 0x00010000'u32)

    updateReg32(addr pll.pllReset10, 0xFFFFFFFA'u32, 0'u32)
    updateReg32(addr pll.pllReset10, not 0'u32, 0x00000001'u32)
    updateReg32(addr pll.pllReset10, not 0'u32, 0x00000004'u32)
    updateReg32(addr pll.enableCtrl30, 0xFFFFFFF3'u32, 0x00001FF3'u32)
    for _ in 0 ..< 11:
      discard volatileLoad(addr pll.enableCtrl30)

  proc rf_pri_xtalfreq() {.exportc, cdecl.} =
    ## ABI wrapper for librf_bl808.a:rf_pri.c.o rf_pri_xtalfreq.
    ## LLVM objdump shows the vendor body selecting xtal-specific private PLL
    ## parameter anchors from the six xtal flags. The pure-Nim RF path keeps
    ## that state as named xtal flags and writes the resulting typed PLL/RF
    ## registers directly in rfPriWifiPllConfig.
    rfPriWifiPllConfig()

  proc rfPriEfuseXtalCapPairValid(cfg: ptr WlRfConfig): bool {.inline.} =
    cfg.efuseXtalCapCode0 != 0x80'u8 and cfg.efuseXtalCapCode1 != 0x80'u8

  proc rfPriApplyEfuseXtalCapTrim(cfg: ptr WlRfConfig;
                                  txCorrRegHigh, txCorrRegLow: var uint32) =
    let efuseXtalCapCode0 = cfg.efuseXtalCapCode0
    let efuseXtalCapCode1 = cfg.efuseXtalCapCode1
    let rf = rfRegs()
    if rfPriEfuseXtalCapPairValid(cfg):
      updateReg32(addr rf.xtalCapTrim5c, 0xFFE0FC0F'u32,
                  ((efuseXtalCapCode0.uint32 shl 16) and 0x001F0000'u32) or
                  ((efuseXtalCapCode1.uint32 shl 4) and 0x000003F0'u32))
      bl808RfEfuseCapComp = -7'i16
      bl808RfEfusePowerComp = -4'i16
      bl808RfBzTxCorrOffset = bl808RfEfuseCapComp
      txCorrRegHigh = 0xFC000000'u32
      txCorrRegLow = 0x000000F8'u32
    else:
      updateReg32(addr rf.xtalCapTrim5c, 0xFFE0FC0F'u32,
                  0x00100200'u32)
      bl808RfEfuseCapComp = -3'i16
      bl808RfEfusePowerComp = 0'i16
      bl808RfBzTxCorrOffset = bl808RfEfuseCapComp
      txCorrRegHigh = 0'u32
      txCorrRegLow = 0x000000FC'u32

  proc rf_pri_set_rcal_code(code0, code1: uint32) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rf_pri.c.o rf_pri_set_rcal_code.
    ## Recovered: code0/code1 program RF[0x105c] xtal-cap trim fields;
    ## 0x80 is the vendor invalid-efuse sentinel and selects the default trim.
    ## Vendor also mirrors compensation state into three private halfword
    ## anchors; the semantic consumers here use bl808RfEfuse*Comp directly.
    let rf = rfRegs()
    if (code0 and 0xFF'u32) != 0x80'u32 and
        (code1 and 0xFF'u32) != 0x80'u32:
      updateReg32(addr rf.xtalCapTrim5c, 0xFFE0FC0F'u32,
                  ((code0 shl 16) and 0x001F0000'u32) or
                  ((code1 shl 4) and 0x000003F0'u32))
      bl808RfEfuseCapComp = -7'i16
      bl808RfEfusePowerComp = -4'i16
      bl808RfBzTxCorrOffset = bl808RfEfuseCapComp
    else:
      updateReg32(addr rf.xtalCapTrim5c, 0xFFE0FC0F'u32,
                  0x00100200'u32)
      bl808RfEfuseCapComp = -3'i16
      bl808RfEfusePowerComp = 0'i16
      bl808RfBzTxCorrOffset = bl808RfEfuseCapComp

  proc rfPriApplyEfuseTxGainTrim(cfg: ptr WlRfConfig) =
    let efuseTxGainByte = cfg.efuseTxGainComp
    bl808RfTxGainComp =
      if efuseTxGainByte == 0'u8: 1'i16
      else: cast[int8](efuseTxGainByte).int16
    bl808RfTempPowerComp = rfSignedByte(cfg.temperaturePowerComp)

  proc rfPriApplyEfuseDfeTrim(cfg: ptr WlRfConfig) =
    let efuseDfeTrimNibble = cfg.efuseDfeTrim
    let dfe = rfDfeInitRegs()
    if efuseDfeTrimNibble != 0x80'u8:
      updateReg32(addr dfe.dfeTrim824, 0xFFFFFFF0'u32,
                  efuseDfeTrimNibble.uint32 and 0xF'u32)
    else:
      updateReg32(addr dfe.dfeTrim824, 0xFFFFFFF0'u32, 0x4'u32)

  proc rfPriEfuseInit() =
    ## Port of librf_bl808.a:rf_pri.c.o rf_pri_efuse_init.part.0 for the
    ## BL808 WLAN RF trim fields at wl_cfg+0xc4..0xc7.
    let cfg = cast[ptr WlRfConfig](wlCfgGlobal)
    if cfg == nil:
      return
    var txCorrRegHigh: uint32
    var txCorrRegLow: uint32
    let rf = rfRegs()
    rfPriApplyEfuseXtalCapTrim(cfg, txCorrRegHigh, txCorrRegLow)
    rfPriApplyEfuseTxGainTrim(cfg)
    rfPriApplyEfuseDfeTrim(cfg)
    updateReg32(addr rf.txPowerComp704, 0x00FFFFFF'u32, txCorrRegHigh)
    updateReg32(addr rf.txPowerComp7ac, 0xFFFFFF00'u32, txCorrRegLow)

  proc runRfPriFullCalRestoreBaseline() =
    ## Porting boundary for librf_bl808.a:rf_pri.c.o rf_pri_full_cal.
    ## Recovered from the linked BL808 scan image:
    ##   rf_pri_lo_fcal -> rf_pri_lo_acal -> optional rf_pri_roscal.part.0
    ##   -> optional rf_pri_rccal.part.0 -> rf_pri_txcal -> rf_pri_bz_txcal
    ##   -> rf_pri_rxcal.
    ## WB03/40 MHz runs the recovered rf_pri_bz_txcal path. Other board paths
    ## retain the fallback records until their BZ branch is validated.
    runRfPriLoFcal()
    runRfPriLoAcal()
    rfCalibWriteDefaultVco40M()
    runRfPriRoscal()
    runRfPriRccal()
    runRfPriTxcal()
    if rfPriIsWb03() and bl808RfXtalIndex == xtalIndex(WlXtal40M):
      runRfPriBzTxcal()
    else:
      rfPriSeedBzTxcalFallbackRecords()
    runRfPriRxcal()
    rfPriSnapshotStage(0xF300'u32)
    rfPriSeedRxcalRestoreLowHalves()
    replayRfPriCalRegisters()
    rfPriSnapshotStage(0xF301'u32)
    rfPriReplayWb03Rf70FromTxcalCalWords()
    rfPriApplyWb03RccalSeed()
    rfPriApplyWb03RxcalTosdacLatch()
    rfPriSnapshotStage(0xF302'u32)

  proc rf_pri_lo_fcal() {.exportc, cdecl.} =
    ## Public ABI wrapper for librf_bl808.a:rf_pri.c.o rf_pri_lo_fcal.
    runRfPriLoFcal()

  proc rf_pri_lo_acal() {.exportc, cdecl.} =
    ## Public ABI wrapper for librf_bl808.a:rf_pri.c.o rf_pri_lo_acal.
    runRfPriLoAcal()

  proc rf_pri_txcal() {.exportc, cdecl.} =
    ## Public ABI wrapper for librf_bl808.a:rf_pri.c.o rf_pri_txcal.
    runRfPriTxcal()

  proc rf_pri_bz_txcal() {.exportc, cdecl.} =
    ## Public ABI wrapper for librf_bl808.a:rf_pri.c.o rf_pri_bz_txcal.
    runRfPriBzTxcal()

  proc rf_pri_rxcal() {.exportc, cdecl.} =
    ## Public ABI wrapper for librf_bl808.a:rf_pri.c.o rf_pri_rxcal.
    runRfPriRxcal()

  proc rf_pri_full_cal() {.exportc, cdecl.} =
    ## Public ABI wrapper for librf_bl808.a:rf_pri.c.o rf_pri_full_cal.
    runRfPriFullCalRestoreBaseline()

  proc rf_pri_restore_cal_reg() {.exportc, cdecl.} =
    ## Public ABI wrapper for librf_bl808.a:rf_pri.c.o rf_pri_restore_cal_reg.
    replayRfPriCalRegisters()

  proc rf_pri_init(coldInit, mode: uint32) {.exportc, cdecl.} =
    ## Local replacement boundary for rf_pri.c.o rf_pri_init.
    ## Recovered: fixed RF defaults, wifipll/static register phase, full-cal
    ## order, and the rf_pri_gain_table_WR2REG follow-up.
    ##
    ## Remaining calibration deltas, tied to LLVM objdump offsets:
    ## - librf_bl808.a:rf_pri.c.o rf_pri_full_cal+0x36..0x5e gates the
    ##   optional ROSCAL/RCCAL branches from RF capability bits; runRfPriRoscal
    ##   and runRfPriRccal preserve those RF[0x20] gates. Callback-driven
    ##   temperature compensation and low-power variants remain unrecovered.
    ## - librf_bl808.a:rf_pri.c.o rf_pri_txcal+0x316..0x52a measures RF70
    ##   replay-source windows. We run that strongest-candidate search for
    ##   diagnostics, but applying measured windows is default-off until the
    ##   earlier TXCAL measurement setup is bit-for-bit recovered.
    ## - librf_bl808.a:rf_pri.c.o rf_pri_restore_cal_reg+0x10c..0x1a8 replays
    ##   RF70 and RXCAL words from calibration memory. RF70/RFA0/RFB4 remain
    ##   calibration/channel-state derived; rf_pri_fixed_val_regs' WB03 branch
    ##   is not their late-value source, and JTAG/UART traces show RF88/RFD0
    ##   now match the scan and auth paths. Keep these registers observable
    ##   through rfPriSnapshotStage and avoid masking calibration gaps with
    ##   unconditional RFC-entry seeds.
    nim_wifi_rf_pri_init_entry_breakpoint()
    bl808RfColdInit = coldInit
    bl808RfMode = radioPhyModeFromApi(uint8(mode and 0xFF'u32))
    rfPriEnsureDeviceInfo()
    rfCalibDataGlobal = wlCalGlobal
    let needsFullCal = coldInit != 0'u32 or not rfCalibHasTxcalData()
    if not needsFullCal:
      rfCalibSeedDefaultVcoIfEmpty()
    updateReg32(addr rfDfeInitRegs().dfeTrim824, 0x9FFFFFFF'u32,
                0x40000000'u32)
    rfPriEfuseInit()
    rfPriSnapshotStage(0xF400'u32)
    writeRfPriFixedValueRegs()
    writeRfPriStaticInit()
    rfPriSnapshotStage(0xF401'u32)
    rfPriWifiPllConfig()
    rfPriSnapshotStage(0xF402'u32)
    rfPhyTraceCheckpoint(0x21'u32)
    rfPriApplyWb03RuntimeLatches()
    rfPriSnapshotStage(0xF403'u32)
    let rf = rfRegs()
    updateReg32(addr rf.calPathCtrl90, not 0'u32, 0x1'u32)
    updateReg32(addr rf.rxMode220, 0xFFFFE67D'u32, 0'u32)
    updateReg32(addr rf.rxMode220, 0xFFFFFF9E'u32, 0'u32)
    if needsFullCal:
      runRfPriFullCalRestoreBaseline()
      rfPriSnapshotStage(0xF404'u32)
    elif coldInit == 0'u32:
      replayRfPriCalRegisters()
      rfPriSnapshotStage(0xF405'u32)
      rfPriReplayWb03Rf70FromTxcalCalWords()
      rfPriApplyWb03RccalSeed()
      rfPriApplyWb03RxcalTosdacLatch()
      rfPriSnapshotStage(0xF406'u32)
    writeRfPriGainInit()
    rfPriSnapshotStage(0xF407'u32)
    rfPriWriteTxPowerTable()
    rfPriSnapshotStage(0xF408'u32)
    rfPriApplyWb03RccalSeed()
    rfPriApplyWb03RxcalTosdacLatch()
    rfPriSnapshotStage(0xF409'u32)
    updateReg32(addr rf.synthCtrl2c, not 0'u32, 0x6'u32)
    updateReg32(addr rf.synthCtrl2c, not 0'u32, 0x4001'u32)
    updateReg32(addr rf.synthDfePathControl63c, not 0'u32, 0x8080'u32)
    updateReg32(addr rf.rxMode220, not 0x600'u32, 0'u32)
    rfPriSnapshotStage(0xF40A'u32)
    rfPriApplyWb03RfcEntryBaseline()
    rfPriSnapshotStage(0xF40B'u32)
    rfPhyTraceCheckpoint(0x22'u32)

  proc rf_pri_config_mode(mode: uint32) {.exportc, cdecl.} =
    bl808RfMode = radioPhyModeFromApi(uint8(mode and 0xFF'u32))

  proc rf_pri_update_param(channelMhz: uint32) {.exportc, cdecl.} =
    bl808RfChannelMhz = channelMhz

  proc rf_pri_read(reg: ptr uint32): uint32 {.exportc, cdecl.} =
    ## Exact local replacement for librf_bl808.a:rf_pri.c.o rf_pri_read:
    ## LLVM objdump shows a single `lw a0, 0(a0)` followed by return.
    volatileLoad(reg)

  proc rf_pri_get_notch_param*(channelMhz: uint32, enable: ptr uint8,
                               param: ptr uint32) {.exportc, cdecl.} =
    ## Vendor BL808 helper currently returns disabled notch parameters, but
    ## rfc_config_channel still consumes the zero outputs to program RF[0x680].
    discard channelMhz
    if enable != nil:
      enable[] = 0
    if param != nil:
      param[] = 0

  proc rfPriApplyNotchParam(channelMhz: uint32) =
    var notchEnable: uint8
    var notchParam: uint32
    rf_pri_get_notch_param(channelMhz, addr notchEnable, addr notchParam)
    let notchWord =
      uint32(((uint64(notchParam) * 2048'u64 + 20_000_000'u64) div
        40_000_000'u64) and 0x07FF'u64)
    let rf = rfRegs()
    var notchCtrlWord = volatileLoad(addr rf.notchCtrl680)
    notchCtrlWord = (notchCtrlWord and 0x87FFFFFF'u32) or 0x08000000'u32
    notchCtrlWord =
      (notchCtrlWord and 0xF800FFFF'u32) or
      ((notchWord shl 16) and 0x07FF0000'u32)
    notchCtrlWord =
      (notchCtrlWord and 0x7FFFFFFF'u32) or
      (uint32(notchEnable and 1'u8) shl 31)
    volatileStore(addr rf.notchCtrl680, notchCtrlWord)

  proc rfPriApplyWb03Non40OptimizePll(channelMhz: uint32) =
    ## LLVM objdump provenance: librf_bl808.a:rf_pri.c.o
    ## rf_pri_optimize+0x82..0x14e. This is the WB03 branch used when the
    ## xtal-40 flag is clear; WB03/40M stays on the default RFD0/RF70 path.
    if not rfPriIsWb03() or bl808RfXtalIndex == xtalIndex(WlXtal40M):
      return
    let pll = rfPllRegs()
    if channelMhz == RfOptimizeWb03PllEdge0Mhz or
        channelMhz == RfOptimizeWb03PllEdge1Mhz:
      updateReg32(addr pll.loopFilter18, not 0x000001F0'u32, 0x00000020'u32)
      updateReg32(addr pll.fractionalCtrl1c, not 0x0007F001'u32, 0x00036100'u32)
    else:
      updateReg32(addr pll.loopFilter18, not 0x000000F0'u32, 0x00000040'u32)
      updateReg32(addr pll.fractionalCtrl1c, not 0x0007F100'u32, 0x0005A000'u32)

  proc rf_pri_optimize(channelMhz: uint32) {.exportc, cdecl.} =
    ## Port of the default rf_pri_optimize path in librf_bl808.a:rf_pri.c.o.
    ## Recovered with LLVM/XuanTie disassembly: RF[0xd0] bit 0 tracks the
    ## 2452..2472 MHz mid-band window, then RF[0x70]'s calibration nibble is
    ## replayed from wl_cal word 4 for 2462..2484 MHz and word 3 otherwise.
    ## Vendor WB03/40M reaches this same branch; the RF[0x818]/RF[0x81c] writes
    ## are on the WB03/non-40M branch at rf_pri_optimize+0x82..0x14e.
    bl808RfChannelMhz = channelMhz
    let traceIdx = int(nim_wifi_rf_optimize_count mod
      uint32(RfPriStageSnapshotEntries))
    inc nim_wifi_rf_optimize_count
    nim_wifi_rf_optimize_channel_log[traceIdx] = channelMhz
    nim_wifi_rf_optimize_device_log[traceIdx] = rfPriDeviceTraceWord()
    let rf = rfRegs()
    var word = volatileLoad(addr rf.optimizeCtrlD0)
    if channelMhz >= RfOptimizeMidBandFirstMhz and
        channelMhz <= RfOptimizeMidBandLastMhz:
      word = word and not RfOptimizeMidBandMask
    else:
      word = word or RfOptimizeMidBandMask
    volatileStore(addr rf.optimizeCtrlD0, word)
    nim_wifi_rf_optimize_rfd0_log[traceIdx] = word
    if rfCalibDataGlobal != nil:
      let useWord4 = channelMhz >= RfOptimizeTxcalFirstMhz and
        channelMhz <= RfOptimizeTxcalLastMhz
      let txcalNibble =
        if useWord4:
          rfPriRf70ReplayWindow2Nibble()
        else:
          rfPriRf70ReplayWindow0Nibble()
      nim_wifi_rf_optimize_nibble_log[traceIdx] =
        txcalNibble or (uint32(useWord4) shl 8)
      updateReg32(addr rf.txcalParam70, 0xFFFFFFF0'u32, txcalNibble)
    else:
      nim_wifi_rf_optimize_nibble_log[traceIdx] = 0xFFFF_FFFF'u32
    nim_wifi_rf_optimize_rf70_log[traceIdx] = volatileLoad(addr rf.txcalParam70)
    rfPriApplyWb03Non40OptimizePll(channelMhz)

  proc rfPriBzOptimizeEnabled(): bool {.inline.} =
    ## librf_bl808.a:rf_pri.c.o rf_pri_bz_optimize gates RF[0x10d0] bit 2 on
    ## BL616/WB03/BL618M device flags and the 38.4 MHz xtal flag.
    rfPriAnyKnownDeviceFlag() and bl808RfPriXtal38p4mFlag != 0

  proc rf_pri_bz_optimize(channelMhz: uint32) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rf_pri.c.o rf_pri_bz_optimize+0x0..0x7c.
    ## Recovered with LLVM/XuanTie disassembly: on the gated device/xtal path,
    ## RF[0x10d0] bit 2 is cleared for 2460/2480 MHz and set otherwise.
    if not rfPriBzOptimizeEnabled():
      return
    let rf = rfRegs()
    if channelMhz == 2460'u32 or channelMhz == 2480'u32:
      updateReg32(addr rf.optimizeCtrlD0, not 0x4'u32, 0'u32)
    else:
      updateReg32(addr rf.optimizeCtrlD0, not 0'u32, 0x4'u32)

  proc rf_pri_bz_optimize_restore() {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rf_pri.c.o rf_pri_bz_optimize_restore+0x0..0x5c.
    ## Same gate as rf_pri_bz_optimize, then restore RF[0x10d0] bit 2.
    if rfPriBzOptimizeEnabled():
      updateReg32(addr rfRegs().optimizeCtrlD0, not 0'u32, 0x4'u32)

  proc rf_pri_input_channel_pwr_comp(comp: pointer) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rf_pri.c.o rf_pri_input_channel_pwr_comp+0x0..0x1c.
    ## Vendor copies 14 signed bytes from caller storage into its halfword
    ## normal-channel compensation table.
    let bytes = cast[ptr UncheckedArray[uint8]](comp)
    for i in 0 ..< bl808RfChannelPowerComp.len:
      bl808RfChannelPowerComp[i] = rfSignedByte(bytes[i])

  proc rf_pri_input_channel_lp_pwr_comp(comp: pointer) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rf_pri.c.o rf_pri_input_channel_lp_pwr_comp+0x0..0x1c.
    ## Vendor copies 14 signed bytes from caller storage into its halfword
    ## low-power channel compensation table.
    let bytes = cast[ptr UncheckedArray[uint8]](comp)
    for i in 0 ..< bl808RfChannelLpPowerComp.len:
      bl808RfChannelLpPowerComp[i] = rfSignedByte(bytes[i])

  proc rf_pri_set_channel_lp_pwr_comp(channelIndex: uint32) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rf_pri.c.o rf_pri_set_channel_lp_pwr_comp.
    ## Recovered semantics: compute channel_lp_pwr_comp[channel] -
    ## channel_pwr_comp[channel], restore the default WLAN power tables, apply
    ## the LP delta to the high-power table region, then replay RF power-table
    ## registers through the same typed table writer used by restore/cal paths.
    if channelIndex < 1'u32 or channelIndex > 14'u32:
      return
    let idx = int(channelIndex - 1'u32)
    let delta = rfSignExtend16(bl808RfChannelLpPowerComp[idx].int32 -
      bl808RfChannelPowerComp[idx].int32)
    rfPriApplyLowPowerRuntimeDelta(delta)

  proc rf_pri_input_temp_comp_param(channels: pointer; highOffsets: pointer;
                                    lowOffsets: pointer; roomOffset: int16;
                                    enable: uint8) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rf_pri.c.o rf_pri_input_temp_comp_param+0x0..0x62.
    ## Vendor stores Troom_os/en_tcal, then when enabled copies T_channel_len
    ## halfword entries from Tchannels/Tchannel_os/Tchannel_os_low sources.
    bl808RfTempRoomOffset = roomOffset
    bl808RfTempCalEnabled = enable
    if enable == 0'u8 or bl808RfTempChannelCount == 0'u32:
      return
    let count = min(int(bl808RfTempChannelCount), bl808RfTempChannels.len)
    let channelWords = cast[ptr UncheckedArray[uint16]](channels)
    let highWords = cast[ptr UncheckedArray[int16]](highOffsets)
    let lowWords = cast[ptr UncheckedArray[int16]](lowOffsets)
    for i in 0 ..< count:
      bl808RfTempChannels[i] = channelWords[i]
      bl808RfTempHighOffsets[i] = highWords[i]
      bl808RfTempLowOffsets[i] = lowWords[i]

  proc rf_pri_set_temp_comp(sensorTemperatureC: int32) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rf_pri.c.o rf_pri_set_temp_comp.
    ## Recovered semantics: refresh temperature-comp tables from wl_cfg, compute
    ## temperature_comp for the current channel, and outside the vendor
    ## measurement pass update present_Tsensor before applying total power comp.
    let channelIndex = bl808RfChannelPowerIndex
    if channelIndex < 1'u32 or channelIndex > 14'u32:
      return
    let cfg = cast[ptr WlRfConfig](wlCfgGlobal)
    if cfg == nil:
      return
    rfPriRefreshTempCompParamFromWlCfg()
    if bl808RfTempCalEnabled == 0'u8:
      bl808RfTempPowerComp = 0'i16
    else:
      bl808RfTempPowerComp =
        rfPriComputeTemperaturePowerComp(channelIndex, sensorTemperatureC)
    if bl808RfTempMeasurementPass != 0'u8:
      return
    bl808RfCurrentTemperatureC = rfSignExtend16(sensorTemperatureC)
    rf_pri_set_channel_total_pwr_comp(channelIndex)

  proc rf_pri_input_bz_channel_pwr_comp(comp: pointer) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rf_pri.c.o rf_pri_input_bz_channel_pwr_comp+0x0..0x1a.
    ## Vendor copies five signed bytes from caller storage into the BZ channel
    ## compensation halfword table consumed by rf_pri_set_bz_channel_pwr_comp.
    let bytes = cast[ptr UncheckedArray[uint8]](comp)
    for i in 0 ..< bl808RfBzChannelPowerComp.len:
      bl808RfBzChannelPowerComp[i] = rfSignedByte(bytes[i])

  proc rfPriRefreshBzChannelPowerComp(cfg: ptr WlRfConfig) =
    ## librf_bl808.a:rf_pri.c.o rf_pri_set_bz_channel_pwr_comp+0x0..0x28
    ## refreshes five signed bytes from wl_cfg+0xbe into bz_channel_pwr_comp.
    ## That BZ window overlaps the named wl_cfg efuse/control area, so keep
    ## the raw-byte access isolated here instead of exposing overlapping fields.
    let bytes = cast[ptr UncheckedArray[uint8]](cfg)
    const BzChannelPowerCompOffset = 0xBE
    for i in 0 ..< bl808RfBzChannelPowerComp.len:
      bl808RfBzChannelPowerComp[i] =
        rfSignedByte(bytes[BzChannelPowerCompOffset + i])

  proc rfPriClampBzChannelComp(value: int16): int16 {.inline.} =
    if value > 16'i16:
      16'i16
    elif value < -16'i16:
      -16'i16
    else:
      value

  proc rfPriPackFive6BitFields(values: array[5, int16]): uint32 =
    var word: uint32
    for i, value in values:
      word = word or ((uint32(uint16(value)) and 0x3F'u32) shl (i * 6))
    word

  proc rf_pri_set_bz_channel_pwr_comp() {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rf_pri.c.o
    ## rf_pri_set_bz_channel_pwr_comp+0x0..0x1f0. Recovered behavior:
    ## refresh five BZ channel compensation bytes from wl_cfg+0xbe, clamp them
    ## to signed 6-bit correction range, write packed RF[0x1780]/RF[0x17b4],
    ## then update the BZ channel average correction anchor.
    let cfg = cast[ptr WlRfConfig](wlCfgGlobal)
    if cfg == nil:
      return
    rfPriRefreshBzChannelPowerComp(cfg)
    var tempAdjusted: array[5, int16]
    var txAdjusted: array[5, int16]
    var sum: int32
    var minNegative: int16
    var foundNegative = false
    for i, rawComp in bl808RfBzChannelPowerComp:
      let clipped = rfPriClampBzChannelComp(rawComp)
      tempAdjusted[i] = rfSignExtend16(
        bl808RfBzTempCorrAvg.int32 + clipped.int32)
      txAdjusted[i] = rfSignExtend16(
        clipped.int32 + bl808RfBzTxCorrOffset.int32)
      sum += rawComp.int32
      if rawComp < 0'i16 and (not foundNegative or rawComp < minNegative):
        minNegative = rawComp
        foundNegative = true
    let rf = rfRegs()
    updateReg32(addr rf.bzChannelPowerComp780, 0xC0000000'u32,
                rfPriPackFive6BitFields(tempAdjusted))
    updateReg32(addr rf.bzChannelPowerComp7b4, 0xC0000000'u32,
                rfPriPackFive6BitFields(txAdjusted))
    if foundNegative and minNegative != 0'i16:
      bl808RfBzChCorrAvg = minNegative
    else:
      bl808RfBzChCorrAvg = rfSignExtend16(sum div 5)

  proc rfPriUpdateBzTempCorrAverage(values: array[5, int16]) =
    var sum: int32
    var minNegative: int16
    var foundNegative = false
    for value in values:
      sum += value.int32
      if value < 0'i16 and (not foundNegative or value < minNegative):
        minNegative = value
        foundNegative = true
    if foundNegative and minNegative != 0'i16:
      bl808RfBzTempCorrAvg = minNegative
    else:
      bl808RfBzTempCorrAvg = rfSignExtend16(sum div 5)

  proc rfPriWriteBzTemperatureCompDeltas() =
    var deltas: array[5, int16]
    for i in 0 ..< deltas.len:
      deltas[i] = rfSignExtend16(
        bl808RfBzTempPowerComp[i].int32 -
        bl808RfBzAppliedTempComp[i].int32)
    let rf = rfRegs()
    updateReg32(addr rf.rfGainOrBzTempComp784, 0xC0000000'u32,
                rfPriPackFive6BitFields(deltas))
    updateReg32(addr rf.bzTemperatureComp7b8, 0xC0000000'u32,
                rfPriPackFive6BitFields(deltas))

  proc rf_pri_set_bz_temp_comp(sensorTemperatureC: int32) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rf_pri.c.o rf_pri_set_bz_temp_comp.
    ## Recovered behavior: refresh the shared temperature interpolation
    ## parameters, compute five BZ-band temperature corrections, capture them
    ## during the measurement pass, and otherwise write current-minus-baseline
    ## deltas to RF[0x1784]/RF[0x17b8].
    const BzTempCompChannelsMhz = [
      2412'u16, 2434'u16, 2450'u16, 2466'u16, 2478'u16]
    let cfg = cast[ptr WlRfConfig](wlCfgGlobal)
    if cfg == nil:
      return
    rfPriRefreshTempCompParamFromWlCfg()
    if bl808RfTempCalEnabled == 0'u8:
      for item in bl808RfBzTempPowerComp.mitems:
        item = 0'i16
    else:
      for i, channelMhz in BzTempCompChannelsMhz:
        bl808RfBzTempPowerComp[i] =
          rfPriComputeTemperaturePowerCompForMhz(
            channelMhz, sensorTemperatureC,
            bl808RfBzTempPowerComp[i])
    if bl808RfBzTemperatureMeasurementPass != 0'u8:
      bl808RfBzAppliedTempComp = bl808RfBzTempPowerComp
      return
    rfPriWriteBzTemperatureCompDeltas()
    rfPriUpdateBzTempCorrAverage(bl808RfBzTempPowerComp)

  proc rf_pri_get_bz_temp_mp_comp() {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rf_pri.c.o rf_pri_get_bz_temp_mp_comp.
    ## Vendor captures BZ temperature compensation at wl_cfg+0xbd, then
    ## restores the room-temperature default pass at 35 C.
    let cfg = cast[ptr WlRfConfig](wlCfgGlobal)
    if cfg == nil:
      return
    bl808RfBzTemperatureMeasurementPass = 1'u8
    rf_pri_set_bz_temp_comp(rfSignedByte(cfg.temperaturePowerComp).int32)
    bl808RfBzTemperatureMeasurementPass = 0'u8
    rf_pri_set_bz_temp_comp(35'i32)

  proc rfPriSelectBzTargetPowerRecords(targetPowerDbm: int32): array[4, int] =
    ## librf_bl808.a:rf_pri.c.o rf_pri_input_bz_target_power+0x2c..0xdc
    ## selects one of four BZ TX power/TXCAL record windows. These record
    ## indices feed rf_pri_bz_pwr_table_w2reg and rf_pri_bz_txcal_w2reg.
    if targetPowerDbm <= 5'i32:
      RfPriBzTargetPowerLowRecords
    elif targetPowerDbm <= 20'i32:
      RfPriBzTargetPowerMidRecords
    elif targetPowerDbm <= 23'i32:
      RfPriBzTargetPowerHighRecords
    else:
      RfPriBzTargetPowerDefaultRecords

  proc rf_pri_input_bz_target_power(targetPowerDbm: int32) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rf_pri.c.o rf_pri_input_bz_target_power.
    ## Recovered behavior: refresh BZ channel-power compensation, mirror the
    ## low-band RF70 replay nibble from calibration memory, choose the BZ target
    ## power record window, then replay BZ power/TXCAL registers.
    rf_pri_set_bz_channel_pwr_comp()
    if rfCalibDataGlobal != nil:
      updateReg32(addr rfRegs().txcalParam70, 0xFFFFFFF0'u32,
                  rfPriRf70ReplayWindow0Nibble())
    let nextRecords = rfPriSelectBzTargetPowerRecords(targetPowerDbm)
    if bl808RfBzTargetPowerRecords == nextRecords:
      return
    bl808RfBzTargetPowerRecords = nextRecords
    rfPriWriteTxPowerTable()
    rfPriSnapshotBzTxcalState(0xB5'u32)

  proc rf_pri_set_channel_pwr_comp(channelIndex: uint32) {.exportc, cdecl.} =
    bl808RfChannelPowerIndex = channelIndex
    if channelIndex < 1'u32 or channelIndex > 14'u32:
      return
    let cfg = cast[ptr WlRfConfig](wlCfgGlobal)
    if cfg == nil:
      return
    for i in 0 ..< 14:
      bl808RfChannelPowerComp[i] = rfSignedByte(cfg.channelPowerComp[i])
      bl808RfChannelLpPowerComp[i] =
        rfSignedByte(cfg.channelLowPowerComp[i])
    rf_pri_set_channel_lp_pwr_comp(channelIndex)
    bl808RfTempMeasurementPass = 1'u8
    rf_pri_set_temp_comp(rfSignedByte(cfg.temperaturePowerComp).int32)
    bl808RfAppliedPowerComp = bl808RfTempPowerComp
    bl808RfTempMeasurementPass = 0'u8
    rf_pri_set_temp_comp(bl808RfCurrentTemperatureC.int32)

  proc rf_pri_set_bandwidth(bandwidthMhz: uint32) {.exportc, cdecl.} =
    ## The vendor rf_pri_set_bandwidth body is a ret-only function in
    ## librf_bl808.a:rf_pri.c.o; keep the symbol local to avoid archive pulls.
    bl808RfBandwidthMhz = bandwidthMhz

  proc rfPriVcoCalWord(channelMhz: uint32): uint32 =
    ## Port of rf_pri.c.o rf_pri_get_vco_{freq,idac}_cw.
    ## The vendor body reads the VCO table at rf_calib_data halfword[14 + index], where
    ## index = min(((channelMhz - 2402) >> 2), 20).
    if rfCalibDataGlobal == nil:
      return 0'u32
    var index =
      if channelMhz > 2402'u32: (channelMhz - 2402'u32) shr 2
      else: 0'u32
    if index > 20'u32:
      index = 20'u32
    let halfwords = cast[ptr UncheckedArray[uint16]](rfCalibDataGlobal)
    halfwords[index + RfCalibLoVcoHalfwordBase.uint32].uint32

  proc rf_pri_get_vco_freq_cw(channelMhz: uint32): uint32 {.exportc, cdecl.} =
    (rfPriVcoCalWord(channelMhz) shr 8) and 0xFF'u32

  proc rf_pri_get_vco_idac_cw(channelMhz: uint32): uint32 {.exportc, cdecl.} =
    rfPriVcoCalWord(channelMhz) and 0xFF'u32

  proc rfcVcoPair(channelMhz: uint32): uint32 =
    ((rf_pri_get_vco_freq_cw(channelMhz) and 0xFF'u32) shl 8) or
      (rf_pri_get_vco_idac_cw(channelMhz) and 0xFF'u32)

  proc programRfcVcoTable() =
    ## Port of librf_bl808.a:rfc.c.o modem_init_core+0x128..0x19e.
    ## Packs two channel control words per RF register at
    ## 0x2000113C..0x20001160, then writes the 2484 MHz slot at 0x20001164.
    let rf = rfRegs()
    var channelMhz = 2404'u32
    for i in 0'u ..< 10'u:
      let low = rfcVcoPair(channelMhz)
      let high = rfcVcoPair(channelMhz + 4'u32)
      volatileStore(addr rf.vcoPairTable13c[i], (high shl 16) or low)
      channelMhz += 8'u32
    volatileStore(addr rf.vcoPair2484Mhz164, rfcVcoPair(2484'u32))

  proc rf_dump_status*() {.exportc, cdecl.} =
    ## The vendor rf.c.o rf_dump_status body is ret-only.
    discard

  proc rf_lo_isr*() {.exportc, cdecl.} =
    ## librf_bl808.a:rf.c.o rf_lo_isr is ret-only.
    discard

  proc rf_clkpll_isr*() {.exportc, cdecl.} =
    ## librf_bl808.a:rf.c.o rf_clkpll_isr is ret-only.
    discard

  type
    WlParamLoadCb = proc(xtalfreq: ptr uint32): int8 {.cdecl.}
    WlCapcodeSetCb = proc(cap0, cap1: uint8) {.cdecl.}
    WlCapcodeGetCb = proc(cap: ptr uint8) {.cdecl.}

  proc modem_init_core*(xtalfreqHz, restore: uint32) {.exportc, cdecl.}
  proc modemInitCoreMode(xtalfreqHz, restoreExistingCalibration: uint32;
                         mode: RadioPhyMode)

  proc configureWlRfConfig(cfg: ptr WlRfConfig; xtalfreqHz: uint32;
                           mode: RadioPhyMode; requestFullCalibration: uint8) =
    if cfg == nil:
      return
    cfg.status = 0
    cfg.apiMode = apiFromRadioPhyMode(mode)
    cfg.enableParamLoadCallback = 0'u8
    cfg.requestFullCalibration = requestFullCalibration
    cfg.enableCapcodeSetCallback = 0'u8
    cfg.xtalfreqHz = xtalfreqHz
    cfg.paramLoadCallback = nil
    cfg.capcodeSetCallback = nil
    cfg.capcodeGetCallback = nil

  proc wl_init*(): int8 {.exportc, cdecl.} =
    ## Port of librf_bl808.a:wl_api.c.o wl_init.
    ## Recovered behavior: optional parameter callback, optional capcode
    ## callbacks, full-cal vs restore modem path, 0xACDE status, and env status
    ## byte clear. The API mode field is preserved for higher-level RF routing.
    let cfg = cast[ptr WlRfConfig](wlCfgGlobal)
    if cfg == nil:
      return -1'i8
    var cbStatus = 0'i8
    if cfg.enableParamLoadCallback != 0'u8 and cfg.paramLoadCallback != nil:
      cbStatus = cast[WlParamLoadCb](cfg.paramLoadCallback)(addr cfg.xtalfreqHz)
    if cfg.capcodeSetCallback != nil:
      let cap0 = uint8(cfg.xtalCapCodes and 0x00FF'u16)
      let cap1 = uint8((cfg.xtalCapCodes shr 8) and 0x00FF'u16)
      if cap0 <= 63'u8 and cap1 <= 63'u8:
        cast[WlCapcodeSetCb](cfg.capcodeSetCallback)(cap0, cap1)
    if cfg.capcodeGetCallback != nil:
      var cap: uint8
      cast[WlCapcodeGetCb](cfg.capcodeGetCallback)(addr cap)
    let restoreExistingCalibration =
      if cfg.requestFullCalibration != 0'u8: 0'u32 else: 1'u32
    modemInitCoreMode(
      cfg.xtalfreqHz,
      restoreExistingCalibration,
      radioPhyModeFromApi(cfg.apiMode))
    cfg.status = WlRfConfigMagic
    if wlEnvGlobal != nil:
      cast[ptr UncheckedArray[uint8]](wlEnvGlobal)[9] = 0'u8
    cbStatus

  proc channelPowerIndex(channelMhz: uint32): uint32 {.inline.} =
    if channelMhz >= 2412'u32 and channelMhz <= 2484'u32:
      if channelMhz == 2484'u32:
        return 14'u32
      return ((channelMhz - 2412'u32) div 5'u32 + 1'u32) and 0xFF'u32
    0'u32

  proc rfc_config_bandwidth*(bandwidth: uint32) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rfc_helper.c.o rfc_config_bandwidth.
    ## The low-level rf_pri_set_bandwidth body is a no-op in this archive, but
    ## preserving these register phases keeps vendor phy_init from pulling
    ## rfc.c.o and gives the modem path typed RF-plane ownership.
    let rf = rfRegs()
    updateReg32(addr rf.rbbRccalCtrl80, 0xFEFFFFFF'u32,
                if bandwidth != 0'u32: 0x01000000'u32 else: 0'u32)
    if bandwidth == 1'u32:
      updateReg32(addr rf.bandwidthCtrl94, 0xEFFFFFFF'u32, 0x10000000'u32)
      updateReg32(addr rf.bandwidthCtrl94, 0xDFFFFFFF'u32, 0x20000000'u32)
      updateReg32(addr rf.scanSynthControl608, 0xDFFFFFFF'u32, 0'u32)
      updateReg32(addr rf.txcalDfe88, 0xFCFFFFFF'u32, 0x03000000'u32)
      rf_pri_set_bandwidth(20'u32)
    else:
      updateReg32(addr rf.bandwidthCtrl94, 0xEFFFFFFF'u32, 0x10000000'u32)
      updateReg32(addr rf.bandwidthCtrl94, 0xDFFFFFFF'u32, 0'u32)
      updateReg32(addr rf.scanSynthControl608, 0xDFFFFFFF'u32, 0x20000000'u32)
      updateReg32(addr rf.txcalDfe88, 0xFCFFFFFF'u32, 0x02000000'u32)
      rf_pri_set_bandwidth(10'u32)
    updateReg32(addr rf.channelTuneGate228, not 0x4'u32, 0'u32)
    updateReg32(addr rf.roscalCtrl7c, not 0x100'u32, 0'u32)

  proc rfc_config_power*() {.exportc, cdecl.} =
    ## librf_bl808.a:rfc_helper.c.o rfc_config_power is ret-only.
    discard

  proc rfc_get_power_level*(rateClass: uint32; requestedPowerTenths: int32): uint32
      {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rfc_helper.c.o rfc_get_power_level+0x0..0x4a.
    let group =
      if rateClass == 0'u32:
        0'u32
      elif rateClass == 1'u32:
        1'u32
      else:
        2'u32
    rfPriGetTxGainIndex(requestedPowerTenths, group) shl 2

  proc rfc_apply_tx_dvga_offset*() {.exportc, cdecl.} =
    ## librf_bl808.a:rfc_helper.c.o rfc_apply_tx_dvga_offset is ret-only.
    discard

  proc rfc_apply_tx_dvga*() {.exportc, cdecl.} =
    ## librf_bl808.a:rfc_helper.c.o rfc_apply_tx_dvga is ret-only.
    discard

  proc rfc_apply_tx_power_offset*() {.exportc, cdecl.} =
    ## librf_bl808.a:rfc_helper.c.o rfc_apply_tx_power_offset is ret-only.
    discard

  proc rfcPowerMeasureClockHz(clockSelect: uint32): uint32 {.inline.} =
    case clockSelect
    of 0'u32: 160_000_000'u32
    of 1'u32: 40_000_000'u32
    else: 16_000_000'u32

  proc rfcPowerMeasureFrequencyWord(clockSelect: uint32;
                                    offsetHz: int32): uint32 {.inline.} =
    ## rfc_power_meas+0x6e..0xbe computes int(((2 * offset) / clk) *
    ## 524288 + 0.5), then keeps the low 20 bits for RF[0x618].
    let doubled = int64(offsetHz) * 2'i64
    let scaled =
      (doubled * 524_288'i64 + int64(rfcPowerMeasureClockHz(clockSelect)) div 2) div
      int64(rfcPowerMeasureClockHz(clockSelect))
    uint32(scaled) and 0x000F_FFFF'u32

  proc rfc_power_meas*(clockSelect: uint32; offsetHz: int32;
                       sampleCount: uint32; measureFlags: uint32;
                       iOut, qOut: ptr int32) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rfc_helper.c.o rfc_power_meas+0x0..0x1b2.
    ## Programs RF[0x618]/RF[0x61c], starts an averaged I/Q measurement, and
    ## returns signed RF[0x620]/RF[0x624] samples when output pointers are set.
    discard sampleCount
    discard measureFlags
    let rf = rfRegs()
    let frequencyWord = rfcPowerMeasureFrequencyWord(clockSelect, offsetHz)
    let clockSelectBits = (clockSelect shl 30) and 0xC000_0000'u32
    let frequencyPresentBit =
      if frequencyWord != 0'u32: 0x0010_0000'u32 else: 0'u32

    updateReg32(addr rf.measureCtrl618, not 0x2000_0000'u32, 0'u32)
    updateReg32(addr rf.measureCtrl618, not 0x0010_0000'u32, 0'u32)
    updateReg32(addr rf.measureMode61c, 0xFFFF_0000'u32, 0x0000_0400'u32)
    updateReg32(addr rf.measureMode61c, not 0x0010_0000'u32,
                frequencyPresentBit)
    updateReg32(addr rf.measureCtrl618, not 0x0010_0000'u32,
                frequencyPresentBit)
    updateReg32(addr rf.measureCtrl618, 0xFFF0_0000'u32, frequencyWord)
    updateReg32(addr rf.measureCtrl618, 0x3FFF_FFFF'u32, clockSelectBits)
    updateReg32(addr rf.measureCtrl618, not 0x2000_0000'u32, 0x2000_0000'u32)

    if not radioWaitRegMaskSet(addr rf.measureCtrl618, RfMeasureReadyMask,
                               RfRccalWaitLimit.uint32):
      inc nim_wifi_rf_measure_wait_timeout_count
      if iOut != nil:
        iOut[] = 0'i32
      if qOut != nil:
        qOut[] = 0'i32
      updateReg32(addr rf.measureCtrl618, not 0x2000_0000'u32, 0'u32)
      updateReg32(addr rf.measureCtrl618, not 0x0010_0000'u32, 0'u32)
      return

    let iSample = signedRfAverageMeasurement(volatileLoad(addr rf.measureI620))
    let qSample = signedRfAverageMeasurement(volatileLoad(addr rf.measureQ624))
    if iOut != nil:
      iOut[] = iSample
    if qOut != nil:
      qOut[] = qSample

    updateReg32(addr rf.measureCtrl618, not 0x2000_0000'u32, 0'u32)
    updateReg32(addr rf.measureCtrl618, not 0x0010_0000'u32, 0'u32)

  proc rfc_sg_start*(frequencyHz: int32; amplitude: uint32;
                     signedQuadraturePath: uint32) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rfc_helper.c.o rfc_sg_start+0x0..0x146.
    ## Programs the RF signal generator frequency field, 11-bit amplitude
    ## fields, optional signed high-path phase, then asserts the enable latch.
    let rf = rfRegs()
    let magnitudeHz =
      if frequencyHz < 0'i32: uint32(-frequencyHz) else: uint32(frequencyHz)
    let frequencyControl =
      uint32((uint64(magnitudeHz) * 1024'u64) div 80_000_000'u64) and
      0x03FF'u32
    let amplitudeCode =
      if amplitude > 1023'u32: 1023'u32 else: amplitude
    let highPathPhase =
      if frequencyHz < 0'i32: 0x40000000'u32 else: 0xC0000000'u32

    updateReg32(addr rf.calSingenCtrl20c, not 0x80000000'u32, 0'u32)
    updateReg32(addr rf.calSingenCtrl20c, 0xFC00FFFF'u32,
                frequencyControl shl 16)
    updateReg32(addr rf.calSingenCtrl20c, 0x9FFFFFFF'u32, 0'u32)
    updateReg32(addr rf.calSingenMeasurePrep21c, 0x0FFFFFFF'u32, 0'u32)
    updateReg32(addr rf.calSingenMeasurePrep21c, 0xFFFF0FFF'u32, 0'u32)
    updateReg32(addr rf.calSingenAmpLo214, not 0x000007FF'u32, amplitudeCode)
    updateReg32(addr rf.calSingenAmpHi218, not 0x000007FF'u32, amplitudeCode)

    if signedQuadraturePath != 0'u32:
      updateReg32(addr rf.calSingenAmpLo214, 0x003FFFFF'u32, 0'u32)
      updateReg32(addr rf.calSingenAmpHi218, 0x003FFFFF'u32, highPathPhase)
    else:
      updateReg32(addr rf.calSingenAmpLo214, 0x003FFFFF'u32, 0'u32)
      updateReg32(addr rf.calSingenAmpHi218, 0x003FFFFF'u32, 0'u32)

    updateReg32(addr rf.calSingenCtrl20c, not 0x80000000'u32, 0x80000000'u32)

  proc rfc_sg_stop*() {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rfc_helper.c.o rfc_sg_stop+0x0..0x16.
    ## Clears the signal-generator enable latch at RF[0x20c] bit31.
    updateReg32(addr rfRegs().calSingenCtrl20c, not 0x80000000'u32, 0'u32)

  proc rfc_rf_fsm_force*(mode: uint32) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rfc_helper.c.o rfc_rf_fsm_force+0x0..0x6a.
    ## mode 15 releases the forced RF FSM state; other modes select the low
    ## three state bits, wait 20 us, then assert the force latch.
    let rf = rfRegs()
    if mode == 15'u32:
      updateReg32(addr rf.channelTuneCtrl26c, not 0x8'u32, 0'u32)
      return
    updateReg32(addr rf.channelTuneCtrl26c, not 0x7'u32, mode and 0x7'u32)
    waitRfUs(20)
    updateReg32(addr rf.channelTuneCtrl26c, not 0'u32, 0x8'u32)

  proc rfc_rc_fsm_force*(mode: uint32) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rfc_helper.c.o rfc_rc_fsm_force+0x0..0xb0.
    ## Bits 10:8 hold the requested RC FSM state and bit11 is the force latch.
    let rf = rfRegs()
    if mode == 15'u32:
      updateReg32(addr rf.baseCtrl1, not 0x700'u32, 0'u32)
      waitRfUs(20)
      updateReg32(addr rf.baseCtrl1, not 0x800'u32, 0'u32)
      return
    updateReg32(addr rf.baseCtrl1, not 0x700'u32, (mode shl 8) and 0x700'u32)
    waitRfUs(20)
    updateReg32(addr rf.baseCtrl1, not 0x800'u32, 0x800'u32)

  proc rfc_config_channel*(channelMhz: uint32) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rfc.c.o rfc_config_channel.
    ## Recovered: RF tune strobes, channel register, channel-power index
    ## calculation from LLVM-decoded th.extu at rfc.c.o+0xee..0x118, and
    ## final RF optimize call.
    let rf = rfRegs()
    updateReg32(addr rf.channelTuneGate228, not 0'u32, 0x8'u32)
    updateReg32(addr rf.synthCtrl2c, not 0'u32, 0x40'u32)
    updateReg32(addr rf.synthCtrl2c, not 0'u32, 0x200'u32)
    updateReg32(addr rf.synthCtrl2c, not 0'u32, 0x1'u32)
    updateReg32(addr rf.channelFreqMhz264, 0xFFFFF000'u32,
                channelMhz and 0xFFF'u32)
    updateReg32(addr rf.channelTuneStrobe268, 0xFFFDFFFF'u32, 0x00020000'u32)
    waitRfUs(1)
    updateReg32(addr rf.channelTuneStrobe268, 0xFFFDFFFF'u32, 0'u32)
    waitRfUs(1)
    updateReg32(addr rf.baseCtrl1, not 0'u32, 0x2'u32)
    waitRfUs(1)
    updateReg32(addr rf.channelTuneCtrl26c, not 0x7'u32, 0x1'u32)
    waitRfUs(1)
    updateReg32(addr rf.channelTuneCtrl26c, not 0'u32, 0x8'u32)
    waitRfUs(1)
    updateReg32(addr rf.channelTuneCtrl26c, not 0x7'u32, 0x2'u32)
    waitRfUs(100)
    updateReg32(addr rf.channelTuneCtrl26c, not 0x8'u32, 0'u32)
    waitRfUs(1)
    updateReg32(addr rf.channelTuneGate228, not 0x8'u32, 0'u32)
    rf_pri_update_param(channelMhz)
    rfPriApplyNotchParam(channelMhz)
    rf_pri_set_channel_pwr_comp(channelPowerIndex(channelMhz))
    rf_pri_optimize(channelMhz)
    rfPhyTraceCheckpoint(0x40'u32)

  proc rf_set_channel*(unusedBand: uint32, channelMhz: uint32)
      {.exportc, cdecl.} =
    ## librf_bl808.a:rf.c.o rf_set_channel+0x0..0x6 ignores its first
    ## argument and tail-calls rfc_config_channel with the second.
    discard unusedBand
    rfc_config_channel(channelMhz)

  proc rfc_wlan_mode_force*(mode: uint32) {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rfc_helper.c.o rfc_wlan_mode_force+0x0..0x56.
    let rf = rfRegs()
    if mode <= 4'u32:
      updateReg32(addr rf.channelTuneGate228, 0xFFFF800F'u32,
                  (mode shl 4) and 0x00007FF0'u32)
      updateReg32(addr rf.rxMode220, 0xFDFFFFFF'u32, 0x02000000'u32)
    else:
      updateReg32(addr rf.channelTuneGate228, 0xFFFF800F'u32, 0'u32)
      updateReg32(addr rf.rxMode220, 0xFDFFFFFF'u32, 0'u32)

  proc rfc_dump*() {.exportc, cdecl.} =
    ## Port of librf_bl808.a:rfc_helper.c.o rfc_dump+0x0..0x30: select two RF
    ## dump windows in rxMode220 and read rxModeDumpReadback224 after each
    ## selection.
    let rf = rfRegs()
    updateReg32(addr rf.rxMode220, 0x0FFFFFFF'u32, 0x10000000'u32)
    discard volatileLoad(addr rf.rxModeDumpReadback224)
    updateReg32(addr rf.rxMode220, 0x0FFFFFFF'u32, 0x20000000'u32)
    discard volatileLoad(addr rf.rxModeDumpReadback224)

  proc programRfcModemLateInit() =
    ## Typed portion of librf_bl808.a:rfc.c.o modem_init_core+0x1a2..0x3b6.
    ## The 0x400/0x540/0x544/0x28a8 fields are still recovered from sequence
    ## context rather than a public register manual; names describe the modem
    ## bring-up roles implied by the vendor write order.
    let rf = rfRegs()
    let bba = bbaAgcRegs()
    let phy = phyRegs()
    let aux = rfAuxCtrlRegs()
    updateReg32(addr rf.baseCtrl1, 0xFFFFF7FF'u32, 0x00000000'u32)
    updateReg32(addr rf.channelTuneCtrl26c, 0xFFFFFFF7'u32, 0x00000000'u32)
    updateReg32(addr rf.channelTuneStrobe268, 0xFFFF0000'u32, 0x00001040'u32)
    updateReg32(addr rf.baseCtrl1, 0xFFFFFFFF'u32, 0x00000002'u32)
    updateReg32(addr rf.synthCtrl2c, 0xFFFFFFFF'u32, 0x00000004'u32)
    updateReg32(addr rf.synthDfePathControl63c, 0xFFFFFFFF'u32, 0x00000080'u32)
    updateReg32(addr rf.synthDfePathControl63c, 0xFFFF7FFF'u32, 0x00008000'u32)
    updateReg32(addr rf.synthDfePathControl63c, 0xFFFFFF80'u32, 0x00000000'u32)
    updateReg32(addr rf.synthDfePathControl63c, 0xFFFF80FF'u32, 0x00000000'u32)
    updateReg32(addr rf.synthCtrl2c, 0xFFFFFFFF'u32, 0x00000002'u32)
    updateReg32(addr rf.synthCtrl2c, 0xFFFFBFFF'u32, 0x00004000'u32)
    updateReg32(addr rf.synthCtrl2c, 0xFFFFFFFF'u32, 0x00000020'u32)
    updateReg32(addr rf.rfcSequencerBias400, 0xFF7FFFFF'u32, 0x00800000'u32)
    updateReg32(addr rf.rfcSequencerBias400, 0xFFFF7FFF'u32, 0x00008000'u32)
    updateReg32(addr rf.rfcSequencerBias400, 0xFFFFBFFF'u32, 0x00004000'u32)
    updateReg32(addr rf.rfcSequencerBias400, 0xFFFFFFFF'u32, 0x00000200'u32)
    updateReg32(addr rf.rfcSequencerBias400, 0xFFFFFFFF'u32, 0x00000100'u32)
    updateReg32(addr aux.rfcAuxPathSelect540, 0xFFFFFCFF'u32, 0x00000C00'u32)
    updateReg32(addr aux.rfcAuxPathGate544, 0xFFFFFFFB'u32, 0x00000000'u32)
    updateReg32(addr phy.rfcSettlingTimerA8, 0x00000000'u32, 0x000000C8'u32)
    updateReg32(addr rf.rxMode220, 0xF7FFFFFF'u32, 0x00000000'u32)
    updateReg32(addr rf.baseCtrl1, 0xFFFFFFFF'u32, 0x00000002'u32)
    updateReg32(addr rf.synthCtrl2c, 0xFFFFFFDF'u32, 0x00000000'u32)
    updateReg32(addr rf.bandwidthCtrl94, 0xFFFEFFFF'u32, 0x00010000'u32)
    updateReg32(addr rf.rbbRccalCtrl80, 0xBFFFFFFF'u32, 0x40000000'u32)
    updateReg32(addr rf.channelSequencer260, 0xFFFFFFFF'u32, 0x00000000'u32)
    updateReg32(addr rf.channelSequencer260, 0xFFFFFFFF'u32, 0x00000000'u32)
    updateReg32(addr rf.channelSequencer2c4, 0xFFFFFFFF'u32, 0x00000002'u32)
    updateReg32(addr rf.channelSequencer2c4, 0xFFFFFFFE'u32, 0x00000000'u32)
    updateReg32(addr bba.macActiveC01c, 0xFFFFFC00'u32, 0x00000050'u32)
    updateReg32(addr bba.macActiveC020, 0xFFFFFC00'u32, 0x00000050'u32)
    updateReg32(addr rf.channelTuneCtrl26c, 0xFFF003FF'u32, 0x00028000'u32)
    updateReg32(addr rf.channelTuneStrobe268, 0xC00FFFFF'u32, 0x05000000'u32)
    updateReg32(addr bba.macActiveC01c, 0xFC00FFFF'u32, 0x00010000'u32)
    updateReg32(addr bba.macActiveC020, 0xFC00FFFF'u32, 0x00010000'u32)
    updateReg32(addr bba.macActiveC02c, 0xFFFFFF00'u32, 0x00000001'u32)

  proc modemInitCoreMode(xtalfreqHz, restoreExistingCalibration: uint32;
                         mode: RadioPhyMode) =
    ## Porting boundary for librf_bl808.a:rfc.c.o modem_init_core.
    ## Recovered: xtal classification constants, rfc_xtal_cfg table load from
    ## LLVM-decoded th.addsl/th.lrw at rfc.c.o+0x9c..0xc8, RF init
    ## cold/restore flag, VCO table packing loop, and late typed modem/RF
    ## register sequence. wl_init supplies the recovered WL API mode so
    ## coexistence reclaim can reach rf_pri_init(..., WL_API_MODE_ALL) without
    ## changing the exported modem_init_core ABI.
    let rf = rfRegs()
    let xtalCfg = RfcXtalConfigTable[xtalIndex(xtalfreqHz)]
    updateReg32(addr rf.rxMode220, 0xFBFFFFFF'u32, 0'u32)
    updateReg32(addr rf.rxMode220, 0xF7FFFFFF'u32, 0x08000000'u32)
    rf_pri_input_xtalfreq(xtalfreqHz)
    rfPriLoadConfiguredDeviceInfo()
    let apiMode = apiFromRadioPhyMode(mode)
    nimFwDbgRfApiMode = apiMode.uint32
    rf_pri_init(
      if restoreExistingCalibration == 0'u32: 1'u32 else: 0'u32,
      apiMode.uint32)
    updateReg32(addr rf.xtalControlCode1c0, 0xFFFFF000'u32,
                xtalCfg.xtalControlCode and 0x00000FFF'u32)
    updateReg32(addr rf.xtalDividerConfig1c4, 0xE0000000'u32,
                xtalCfg.xtalDividerConfig and 0x1FFFFFFF'u32)
    updateReg32(addr rf.xtalCountWindowMin1c8, 0xFFF00000'u32,
                xtalCfg.xtalCountWindowMin and 0x000FFFFF'u32)
    updateReg32(addr rf.xtalCountWindowMax1cc, 0xFFF00000'u32,
                xtalCfg.xtalCountWindowMax and 0x000FFFFF'u32)
    programRfcVcoTable()
    programRfcModemLateInit()
    updateReg32(addr rf.modemPathEnable504, 0xFFFFFFFF'u32, 0x10'u32)
    updateReg32(addr rf.modemPathEnable514, 0xFFFFFFFF'u32, 0x10'u32)

  proc modem_init_core*(xtalfreqHz, restore: uint32) {.exportc, cdecl.} =
    modemInitCoreMode(xtalfreqHz, restore, wifiOnly)

  proc modem_init*(xtalfreqHz: uint32) {.exportc, cdecl.} =
    modem_init_core(xtalfreqHz, 0'u32)

  proc modem_restore*(xtalfreqHz: uint32) {.exportc, cdecl.} =
    modem_init_core(xtalfreqHz, 1'u32)

  proc rf_init*(xtalfreqHz: uint32) {.exportc, cdecl.} =
    if wifiBl808RfInited == 0'u32:
      modem_init_core(xtalfreqHz, 0'u32)
      wifiBl808RfInited = 1'u32
    else:
      modem_init_core(xtalfreqHz, 1'u32)

  proc rfc_init*(xtalfreqHz: uint32, fullInit: uint32 = 1'u32) {.exportc, cdecl.} =
    let cfg = wl_cfg_get(addr wifiBl808WlRmem)
    let wlFullCalibrationFlag =
      if fullInit != 0'u32: 1'u8 else: 0'u8
    configureWlRfConfig(
      cfg,
      xtalfreqHz,
      wifiOnly,
      wlFullCalibrationFlag)
    discard wl_init()
    phy_init(nil)
    wifiBl808RfInited = 1'u32

  template rf_calib_data: pointer = rfCalibDataGlobal

  proc snapshotWifiRfCalibData() =
    nimFwDbgRfCalPtr = pointerAddrU32(rf_calib_data)
    if rf_calib_data == nil:
      for i in 0 ..< nimFwDbgRfCalWords.len:
        nimFwDbgRfCalWords[i] = 0
      return
    let words = cast[ptr UncheckedArray[uint32]](rf_calib_data)
    for i in 0 ..< nimFwDbgRfCalWords.len:
      nimFwDbgRfCalWords[i] = words[i]

  proc mpif_clk_init*() {.exportc, cdecl.} =
    discard

  proc phy_powroffset_set*(powerOffset: ptr int8) {.exportc, cdecl.} =
    discard powerOffset
elif defined(bl808WifiAllowLegacyBl606pRfFallback):
  proc mpif_clk_init*() {.importc, cdecl.}
  proc rf_init*(xtalfreqHz: uint32) {.importc, cdecl.}
  proc rfc_init*(xtalfreqHz: uint32, fullInit: uint32) {.importc, cdecl.}

proc wifiRfCoreInitMode(xtalfreqHz: uint32, mode: RadioPhyMode) {.noinline.} =
  when defined(bl808WifiUseBl808Rf):
    let apiMode = apiFromRadioPhyMode(mode)
    nimFwDbgRfPhase = 1
    nimFwDbgRfApiMode = apiMode.uint32
    nimFwConnectTrace2U32("[WIFI-CT] bl808_rf_core ", xtalfreqHz, apiMode.uint32)
    rfPriLoadConfiguredDeviceInfo()
    let cfg = wl_cfg_get(addr wifiBl808WlRmem)
    nimFwDbgRfPhase = 2
    nimFwConnectTrace2U32("[WIFI-CT] bl808_rf_cfg ", cast[uint32](cast[uint](cfg)), sizeof(WlRfConfig).uint32)
    if cfg != nil:
      let requestFullCalibration =
        if wifiBl808RfInited == 0'u32: 1'u8 else: 0'u8
      configureWlRfConfig(cfg, xtalfreqHz, mode, requestFullCalibration)
      nimFwConnectTrace2U32("[WIFI-CT] bl808_rf_cfg2 ", cfg.status, cfg.xtalfreqHz)
    nimFwDbgRfPhase = 3
    snapshotWifiRfCalibData()
    let restoreExistingCalibration =
      if wifiBl808RfInited == 0'u32: 0'u32 else: 1'u32
    nimFwDbgRfRestore = restoreExistingCalibration
    nimFwConnectTrace2U32(
      "[WIFI-CT] bl808_rf_modem ", xtalfreqHz, restoreExistingCalibration)
    nimFwDbgRfPhase = 4
    nim_wifi_rf_latch_service_enable(1'u32)
    discard wl_init()
    nim_wifi_rf_latch_service_enable(0'u32)
    snapshotWifiRfCalibData()
    nimFwDbgRfPhase = 5
    wifiBl808RfInited = 1'u32
    nimFwConnectTrace2U32(
      "[WIFI-CT] bl808_rf_done ", xtalfreqHz, restoreExistingCalibration)
  elif defined(bl808WifiAllowLegacyBl606pRfFallback):
    rf_init(xtalfreqHz)

proc wifiRfCoreInit*(xtalfreqHz: uint32) {.exportc, cdecl, noinline.} =
  wifiRfCoreInitMode(xtalfreqHz, wifiOnly)

when defined(bl808WifiUseBl808Rf):
  proc phy_assert_rec*(fileOrCond, condOrFile: cstring, line: cint)
      {.exportc, cdecl, noinline.} =
    ## librf_bl808.a:arch.c.o phy_assert_rec is ret-only.
    discard fileOrCond
    discard condOrFile
    discard line

  proc phy_assert_warn*(fileOrCond, condOrFile: cstring, line: cint)
      {.exportc, cdecl, noinline.} =
    ## librf_bl808.a:arch.c.o phy_assert_warn is ret-only.
    discard fileOrCond
    discard condOrFile
    discard line

  proc phy_assert_err*(fileOrCond, condOrFile: cstring, line: cint)
      {.exportc, cdecl, noinline.} =
    ## arch.c.o phy_assert_err hard-spins. Keep the direct ABI symbol but route
    ## through the existing BL808 wrapper so known PHY clock diagnostics remain
    ## observable instead of blind hangs.
    wrapPhyAssertErr(fileOrCond, condOrFile, line)

  proc wrapPhyAssertErr*(fileOrCond, condOrFile: cstring,
                         line: cint)
      {.exportc: "__wrap_phy_assert_err", cdecl, noinline.} =
    ## The BL808 RF archive's phy_assert_err is a hard spin. The first
    ## phy_init assert is a clock-count diagnostic on this target; log it and
    ## continue so the smoke test can bisect the next WiFi bring-up stage.
    let mdm = wifiModemRegs()
    let versionScratch3c = volatileLoad(addr mdm.versionScratch3c)
    inc nimFwDbgRfAssertCount
    nimFwDbgRfAssertLine = line.uint32
    nimFwDbgRfAssertReg3c = versionScratch3c
    nimFwConnectTrace2U32("[WIFI-CT] phy_assert ", line.uint32, versionScratch3c)
    if line == 586.cint or line == 0x20FA.cint or line == 0x2A60.cint:
      return
    while true:
      discard fileOrCond
      discard condOrFile
proc tpc_update_tx_power*(vifIdx: uint8) {.exportc, cdecl.}
proc bl_tpc_power_table_get*(powerTable: ptr array[38, int8]) {.exportc, cdecl.}
proc bl_pwr_find*(levels: pointer, count: uint32): uint32 {.exportc, cdecl.}
proc ps_traffic_status_update*(vifIdx: uint8, status: uint32) {.exportc, cdecl.}
proc ps_dpsm_update*(enable: uint32) {.exportc, cdecl.}
proc chan_tbtt_switch_evt*() {.exportc, cdecl.}
proc chan_conn_less_delay_evt*() {.exportc, cdecl.}
proc chan_cde_evt*() {.exportc, cdecl.}
proc chan_ctxt_op_evt*() {.exportc, cdecl.}
proc chan_survey_timer_end*() {.exportc, cdecl.}
proc bam_init*() {.exportc, cdecl.}
proc bl_reset_evt*() {.exportc, cdecl.}
proc ke_task_schedule*() {.exportc, cdecl.}
proc ke_timer_schedule*() {.exportc, cdecl.}
proc ipc_emb_msg_evt*() {.exportc, cdecl.}
proc mm_hw_idle_evt*() {.exportc, cdecl.}
proc mm_tbtt_evt*() {.exportc, cdecl.}
proc rxu_swdesc_upload_evt*() {.exportc, cdecl.}
proc rxl_dma_evt*() {.exportc, cdecl.}
proc rxu_cntrl_evt*() {.exportc, cdecl.}
proc txl_cfm_evt*() {.exportc, cdecl.}
proc bl_event_handle*(evtType: uint32) {.exportc, cdecl.}
proc bl_fw_statistic_dump*() {.exportc, cdecl.}
proc me_init_rate*(staEntry: pointer) {.exportc, cdecl.}
proc me_init_bcmc_rate*(staEntry: pointer) {.exportc, cdecl.}
proc me_update_buffer_control*(sta: pointer): pointer {.exportc, cdecl.}
proc sm_assoc_done*(aid: uint16) {.exportc, cdecl.}
proc scanu_frame_handler*(frame: pointer, len: uint32) {.exportc, cdecl.}
proc scanu_find_result*(bssid: pointer, allocIfMissing: uint8 = 0): pointer {.exportc, cdecl.}
proc find_wpa_rsn_ie*(ieBuf: pointer, ieLen: uint32, wpaOut: ptr pointer, rsnOut: ptr pointer) {.exportc, cdecl.}
proc phy_channel_to_freq*(band: uint8, channel: uint8): uint16 {.weakExport, cdecl, noinline.}
proc phy_freq_to_channel*(band: uint8, freq: uint16): uint8 {.weakExport, cdecl.}
proc me_freq_to_chan_ptr*(band: uint8, freq: uint16): pointer {.exportc, cdecl.}
proc me_extract_rate_set*(ieBuf: pointer, ieLen: uint32, rateOut: pointer) {.exportc, cdecl.}
proc me_legacy_rate_bitfield_build*(rates: pointer, count: uint8): uint32 {.exportc, cdecl.}
proc me_legacy_ridx_min*(bitfield: uint32): uint8 {.exportc, cdecl.}
proc me_legacy_ridx_max*(bitfield: uint32): uint8 {.exportc, cdecl.}

const
  WifiHwPollLimit = 100_000'u32
  WifiMachwSoftResetReg = 0x24B08050'u32

var
  nimFwDbgHwWaitTimeoutCount* {.wifiCtrl, exportc: "nimfw_dbg_hw_wait_timeout_count".}: uint32
  nimFwDbgHwWaitLastReg* {.wifiCtrl, exportc: "nimfw_dbg_hw_wait_last_reg".}: uint32
  nimFwDbgHwWaitLastMask* {.wifiCtrl, exportc: "nimfw_dbg_hw_wait_last_mask".}: uint32
  nimFwDbgAssertErrCount* {.wifiCtrl, exportc: "nimfw_dbg_assert_err_count".}: uint32
  nimFwDbgAssertErrLastLine* {.wifiCtrl, exportc: "nimfw_dbg_assert_err_last_line".}: uint32
  nimFwDbgAssertErrLastFile* {.wifiCtrl, exportc: "nimfw_dbg_assert_err_last_file".}: uint32

proc noteHwWaitTimeout(reg, mask: uint32) {.inline.} =
  inc nimFwDbgHwWaitTimeoutCount
  nimFwDbgHwWaitLastReg = reg
  nimFwDbgHwWaitLastMask = mask

proc noteAssertErr(file: cstring, line: cint) {.inline.} =
  inc nimFwDbgAssertErrCount
  nimFwDbgAssertErrLastLine = cast[uint32](line)
  nimFwDbgAssertErrLastFile = cast[uint32](cast[uint](file))

proc waitRegMaskClear(reg: uint, mask: uint32,
                      limit: uint32 = WifiHwPollLimit): bool =
  result = radioWaitRegMaskClear(reg, mask, limit)
  if not result:
    noteHwWaitTimeout(reg.uint32, mask)

proc waitRegMaskSet(reg: uint, mask: uint32,
                    limit: uint32 = WifiHwPollLimit): bool =
  result = radioWaitRegMaskSet(reg, mask, limit)
  if not result:
    noteHwWaitTimeout(reg.uint32, mask)

proc waitRegLowNibbleClear(reg: uint,
                           limit: uint32 = WifiHwPollLimit): bool =
  var remaining = limit
  while (regRead(reg) and 0x3F'u32) != 0:
    if remaining == 0:
      noteHwWaitTimeout(reg.uint32, 0x3F'u32)
      return false
    dec remaining
  true

proc waitRegLowNibbleEquals(reg: uint, value: uint32,
                            limit: uint32 = WifiHwPollLimit): bool =
  let expected = value and 0x3F'u32
  var remaining = limit
  while (regRead(reg) and 0x3F'u32) != expected:
    if remaining == 0:
      noteHwWaitTimeout(reg.uint32, 0x3F'u32 or (expected shl 8))
      return false
    dec remaining
  true

proc waitMacSoftResetClear(limit: uint32 = WifiHwPollLimit): bool =
  var remaining = limit
  while blmac_soft_reset_getf() != 0:
    if remaining == 0:
      noteHwWaitTimeout(WifiMachwSoftResetReg, 0xFF'u32)
      return false
    dec remaining
  true

proc dsParamFreq(band: uint8, ds: ptr DsParamSetIeView): uint16 {.inline.} =
  phy_channel_to_freq(band, ds.currentChannel)
proc me_bw_check*(param: pointer) {.exportc, cdecl.}
proc me_rate_translate*(rateConfig: uint32): uint32 {.exportc, cdecl.}
proc rc_check*(staIdx: uint8) {.exportc, cdecl.}
proc rc_calc_tp*(entry: pointer, stats: pointer): uint32 {.exportc, cdecl.}
proc rc_update_counters*(staIdx: uint8, attemptCount: uint32, successCount: uint32) {.exportc, cdecl.}
proc rc_init*(staEntry: pointer) {.exportc, cdecl.}
proc rc_init_bcmc_rate*(staEntry: pointer, band: uint32) {.exportc, cdecl.}
proc mfp_compute_bip*(key: pointer, frame: pointer, frameLen: uint32,
    extraParam: uint32): uint64 {.exportc, cdecl.}
proc mfp_protect_mgmt_frame*(frameDesc: pointer, fc: uint32, action: uint32 = 0): uint32 {.exportc, cdecl, noinline.}
proc mfp_add_mgmt_mic*(frameDesc: pointer, bodyLen: uint32, totalLen: uint32): uint32 {.exportc, cdecl.}
proc me_extract_power_constraint*(ieBuf: pointer, ieLen: uint32, out_ptr: pointer) {.exportc, cdecl.}
proc me_extract_country_reg*(ieBuf: pointer, ieLen: uint32, out_ptr: pointer) {.exportc, cdecl.}
proc vif_mgmt_get_vif*(vifIdx: uint8): pointer {.exportc, cdecl, noinline.}
proc tpc_update_vif_tx_power*(vifEntry: pointer, txPowerElem: pointer, rateParam: pointer) {.exportc, cdecl.}
proc tpc_get_vif_tx_power_vs_rate*(vifIdx: uint8, rate: uint32): int8 {.exportc, cdecl.}
proc mac_ie_find*(buf: pointer, bufLen: uint32, ieId: uint8): pointer {.exportc, cdecl.}
proc mac_vsie_find*(buf: pointer, bufLen: uint32, oui: pointer, ouiLen: uint8): pointer {.exportc, cdecl.}
proc ke_msg_forward_and_change_id*(param: pointer, newId: uint16, destId: uint8, srcId: uint8) {.exportc, cdecl.}
proc c_memcmp(a, b: pointer, n: csize_t): cint {.importc: "memcmp", header: "<string.h>".}
proc ipc_emb_msg_handler*() {.exportc, cdecl.}

# Forward declarations for RC internal helpers
proc rc_get_mcs_index*(rateConfig: uint16): uint8 {.exportc, cdecl.}
proc rc_get_nss*(rateConfig: uint16): uint8 {.exportc, cdecl, noinline.}
proc rc_check_valid_rate*(stats: pointer, rateConfig: uint16): uint8 {.exportc, cdecl.}
proc rc_check_rate_duplicated*(stats: pointer, rateConfig: uint16): uint8 {.exportc, cdecl.}
proc rc_get_initial_rate_config*(stats: pointer): uint16 {.exportc, cdecl.}
proc rc_get_lowest_rate_config*(stats: pointer): uint16 {.exportc, cdecl.}
proc rc_new_random_rate*(stats: pointer): uint16 {.exportc, cdecl.}
proc rc_update_retry_chain*(stats: pointer, param: pointer) {.exportc, cdecl.}
proc rc_update_stats*(stats: pointer, needUpdate: uint8): uint8 {.exportc, cdecl.}
proc rc_set_previous_mcs_index*(stats: pointer, rateConfig: uint16): uint16 {.exportc, cdecl.}
proc rc_set_next_mcs_index*(stats: pointer, rateConfig: uint16): uint16 {.exportc, cdecl.}
proc rc_sort_samples_tp*(stats: pointer, tpArray: pointer) {.exportc, cdecl.}
proc rc_calc_prob_ewma*(entry: pointer) {.exportc, cdecl.}
proc rc_get_duration*(rateConfig: uint32, length: uint32): uint32 {.exportc, cdecl.}

# Vendor ke_event.o .rodata.ke_evt_hdlr table. The scheduler indexes this table
# with __clz(event_field), so index 0 handles bit 31 and index 25 handles bit 6.
# Nim stores function-pointer aggregate initializers in module init code for this
# target, so populate this explicitly before the first scheduler pass.
var keEvtHandlers* {.wifiCtrlExport.}: array[KE_EVT_MAX, KeEvtEntry]
var wifiFwRuntimeInited* {.wifiCtrl.}: uint8

proc ke_evt_handlers_init*() {.exportc, cdecl.} =
  keEvtHandlers[0] = KeEvtEntry(handler: cast[pointer](bl_reset_evt), param: nil)
  keEvtHandlers[1] = KeEvtEntry(handler: cast[pointer](mm_timer_schedule), param: nil)
  keEvtHandlers[2] = KeEvtEntry(handler: cast[pointer](ke_timer_schedule), param: nil)
  keEvtHandlers[3] = KeEvtEntry(handler: cast[pointer](ipc_emb_msg_evt), param: nil)
  keEvtHandlers[4] = KeEvtEntry(handler: cast[pointer](ke_task_schedule), param: nil)
  keEvtHandlers[5] = KeEvtEntry(handler: cast[pointer](mm_hw_idle_evt), param: nil)
  keEvtHandlers[6] = KeEvtEntry(handler: cast[pointer](mm_tbtt_evt), param: nil)
  keEvtHandlers[7] = KeEvtEntry(handler: cast[pointer](mm_tbtt_evt), param: nil)
  keEvtHandlers[8] = KeEvtEntry(handler: cast[pointer](rxu_swdesc_upload_evt), param: nil)
  keEvtHandlers[9] = KeEvtEntry(handler: cast[pointer](rxl_dma_evt), param: nil)
  keEvtHandlers[10] = KeEvtEntry(handler: cast[pointer](rxu_cntrl_evt), param: nil)
  keEvtHandlers[11] = KeEvtEntry(handler: cast[pointer](rxl_cntrl_evt), param: nil)
  keEvtHandlers[12] = KeEvtEntry(handler: cast[pointer](txl_frame_evt), param: nil)
  keEvtHandlers[13] = KeEvtEntry(handler: cast[pointer](txl_cfm_evt), param: cast[pointer](4'u))
  keEvtHandlers[14] = KeEvtEntry(handler: cast[pointer](txl_cfm_evt), param: cast[pointer](3'u))
  keEvtHandlers[15] = KeEvtEntry(handler: cast[pointer](txl_cfm_evt), param: cast[pointer](2'u))
  keEvtHandlers[16] = KeEvtEntry(handler: cast[pointer](txl_cfm_evt), param: cast[pointer](1'u))
  keEvtHandlers[17] = KeEvtEntry(handler: cast[pointer](txl_cfm_evt), param: nil)
  keEvtHandlers[18] = KeEvtEntry(handler: cast[pointer](ipc_emb_tx_evt), param: cast[pointer](4'u))
  keEvtHandlers[19] = KeEvtEntry(handler: cast[pointer](ipc_emb_tx_evt), param: cast[pointer](3'u))
  keEvtHandlers[20] = KeEvtEntry(handler: cast[pointer](ipc_emb_tx_evt), param: cast[pointer](2'u))
  keEvtHandlers[21] = KeEvtEntry(handler: cast[pointer](ipc_emb_tx_evt), param: cast[pointer](1'u))
  keEvtHandlers[22] = KeEvtEntry(handler: cast[pointer](ipc_emb_tx_evt), param: nil)
  keEvtHandlers[23] = KeEvtEntry(handler: cast[pointer](bl_event_handle), param: cast[pointer](1'u))
  keEvtHandlers[24] = KeEvtEntry(handler: cast[pointer](bl_event_handle), param: nil)
  keEvtHandlers[25] = KeEvtEntry(handler: cast[pointer](bl_fw_statistic_dump), param: nil)

proc wifi_fw_runtime_init*() {.exportc, cdecl.} =
  ## Initialize wifi_fw runtime state once.
  ##
  ## CRITICAL: do NOT call NimMain() here. `_start` jumps directly to
  ## user `main()`, so NimMain has never been called. NimMain itself
  ## ends with `jal main`, so calling it here would recursively re-enter
  ## main → infinite recursion. Instead, call PreMain — it runs all the
  ## Nim global var initializers (which is what populates dispatch
  ## tables like mm_default_handler) and returns. ke_evt_handlers_init
  ## then wires up the per-event handler table.
  if wifiFwRuntimeInited != 0:
    return
  {.emit: """
  extern void PreMain(void);
  PreMain();
  """.}
  ke_evt_handlers_init()
  wifiFwRuntimeInited = 1

