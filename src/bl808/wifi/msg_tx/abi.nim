type
  BlHw {.importc: "struct bl_hw", header: "bl_defs.h".} = object
  BlOpsFuncs {.importc: "bl_ops_funcs_t", header: "bl_os_adapter.h".} = object
  Cfg80211ConnectParams {.importc: "struct cfg80211_connect_params",
                          header: "cfg80211.h".} = object
  MmMonitorCfmObj {.importc: "struct mm_monitor_cfm", header: "lmac_msg.h".} = object
  MmMonitorChannelCfmObj {.importc: "struct mm_monitor_channel_cfm",
                        header: "lmac_msg.h".} = object
  MmBeaconCfmObj {.importc: "struct mm_set_beacon_int_cfm",
                header: "lmac_msg.h".} = object
  MmVersionCfmObj {.importc: "struct mm_version_cfm", header: "lmac_msg.h".} = object
  MmAddIfCfmObj {.importc: "struct mm_add_if_cfm", header: "lmac_msg.h".} = object
  SmConnectCfmObj {.importc: "struct sm_connect_cfm", header: "lmac_msg.h".} = object
  SmAbortCfmObj {.importc: "struct sm_connect_abort_cfm", header: "lmac_msg.h".} = object
  ApmStartCfmObj {.importc: "struct apm_start_cfm", header: "lmac_msg.h".} = object
  ApmStaDelCfmObj {.importc: "struct apm_sta_del_cfm", header: "lmac_msg.h".} = object
  ScanuPara = object

  MallocProc = proc(size: csize_t): pointer {.cdecl.}
  FreeProc = proc(p: pointer) {.cdecl.}
  CmdQueueProc = proc(cmdMgr, cmd: pointer): cint {.cdecl.}

var g_bl_ops_funcs {.importc, header: "bl_os_adapter.h".}: BlOpsFuncs

proc c_memset(s: pointer; c: cint; n: csize_t): pointer
  {.importc: "memset", header: "<string.h>", cdecl.}
proc c_memcpy(dest, src: pointer; n: csize_t): pointer
  {.importc: "memcpy", header: "<string.h>", cdecl.}
proc c_memcmp(a, b: pointer; n: csize_t): cint
  {.importc: "memcmp", header: "<string.h>", cdecl.}
proc c_strlen(s: cstring): csize_t
  {.importc: "strlen", header: "<string.h>", cdecl.}
proc bl_os_printf(fmt: cstring)
  {.importc, header: "bl_os_private.h", cdecl, varargs.}
proc utils_tlv_bl_pack_auto(buf: ptr uint32; bufSz: cint; typ: uint16;
                            arg1: pointer): uint32
  {.importc, header: "utils_tlv_bl.h", cdecl.}
proc bl808_wifi_backend_poll(iterations: cuint) {.importc, cdecl.}
