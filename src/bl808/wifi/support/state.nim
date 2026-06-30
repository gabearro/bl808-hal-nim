{.emit: "extern struct bl_hw wifi_hw;".}
var wifi_hw {.importc, header: "bl_defs.h".}: BlHw
var ipc_shared_env {.importc, header: "ipc_shared.h".}: uint8
var ke_env {.importc.}: array[1, uint32]
var vif_info_tab {.importc.}: array[CfgVirtDevMax.int * VendorVifEntrySize.int, uint8]
var gBlOpsFuncsStorage {.exportc: "g_bl_ops_funcs".}: BlOpsFuncs
var wifiMgmr* {.exportc.}: WifiMgmr
var g_wifi_hosal_funcs* {.exportc.}: WifiHosalFuncs

var wifiStarted: bool
var hostPollEnabled: bool
var fwStarted: bool
var staEnabled: bool
var apEnabled: bool
var osMutexDepth: uint32
var osMutexSavedIrq: uint32
var connectDone = -1'i32
var disconnectDone: int32
var scanDoneCount: uint32
var scanItemCount: uint32
var macIrqCount: uint32
var macPollIrqCount: uint32
var macTrapIrqCount: uint32
var ipcTrapIrqCount: uint32
var ipcPollIrqCount: uint32
var lastStatusCode = -1'i32
var lastReasonCode = -1'i32
var sm_state {.importc.}: uint16
when defined(bl808AllcoreWasmHttp):
  {.pragma: allcoreHttpPsramBss,
    codegenDecl: "$# $# __attribute__((section(\".psrambss\"), aligned(16), used))".}
else:
  {.pragma: allcoreHttpPsramBss.}

var scanDiag {.allcoreHttpPsramBss.}: array[VendorScanDiagMax, ScanDiagItem]
var scanCache {.allcoreHttpPsramBss.}: array[VendorScanDiagMax, ScanCacheItem]
var scanCacheFailureUsed {.allcoreHttpPsramBss.}: array[VendorScanDiagMax, uint8]
var scanCacheFailureCount {.allcoreHttpPsramBss.}: array[VendorScanDiagMax, uint8]
var scanCacheFailureBssid {.allcoreHttpPsramBss.}: array[VendorScanDiagMax, array[6, uint8]]
var scanCacheSelectedSlot = -1
var nimfwDbgScanCacheFind* {.exportc: "nimfw_dbg_scan_cache_find".}: uint32
var nimfwDbgScanCacheHit* {.exportc: "nimfw_dbg_scan_cache_hit".}: uint32
var nimfwDbgScanCacheCandidates* {.exportc: "nimfw_dbg_scan_cache_candidates".}: uint32
var nimfwDbgScanCacheSelectedSlot* {.exportc: "nimfw_dbg_scan_cache_selected_slot".}: uint32
var nimfwDbgScanCacheSelectedMeta* {.exportc: "nimfw_dbg_scan_cache_selected_meta".}: uint32
var nimfwDbgScanCacheSelectedBssidLo* {.exportc: "nimfw_dbg_scan_cache_selected_bssid_lo".}: uint32
var nimfwDbgScanCacheSelectedBssidHi* {.exportc: "nimfw_dbg_scan_cache_selected_bssid_hi".}: uint32
var nimfwDbgScanCacheFailureMarks* {.exportc: "nimfw_dbg_scan_cache_failure_marks".}: uint32
var nimfwDbgScanCacheFailureCount* {.exportc: "nimfw_dbg_scan_cache_failure_count".}: uint32
var nimfwDbgStaConnectStage* {.exportc: "nimfw_dbg_sta_connect_stage".}: uint32
var nimfwDbgStaConnectResult* {.exportc: "nimfw_dbg_sta_connect_result".}: uint32
var nimfwDbgStaConnectState* {.exportc: "nimfw_dbg_sta_connect_state".}: uint32
var nimfwDbgStaConnectFreq* {.exportc: "nimfw_dbg_sta_connect_freq".}: uint32
var nimfwDbgStaConnectBssidLo* {.exportc: "nimfw_dbg_sta_connect_bssid_lo".}: uint32
var nimfwDbgStaConnectBssidHi* {.exportc: "nimfw_dbg_sta_connect_bssid_hi".}: uint32
var vendorRandomState = 0x6d2b_79f5'u32
