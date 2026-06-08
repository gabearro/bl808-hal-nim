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
var scanDiag: array[VendorScanDiagMax, ScanDiagItem]
var vendorRandomState = 0x6d2b_79f5'u32
