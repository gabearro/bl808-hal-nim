type
  BlHw {.importc: "struct bl_hw", header: "bl_defs.h".} = object
  IpcSharedEnv {.importc: "struct ipc_shared_env_tag",
                 header: "ipc_shared.h".} = object
  CmdLlindProc = proc(cmdMgr, cmd: pointer): cint {.cdecl.}
  BlRxInfo {.importc: "bl_rx_info_t", header: "bl_main.h".} = object
    rssi*: int8
    legRate* {.importc: "leg_rate".}: uint8
    formatMod* {.importc: "format_mod".}: uint8
  ErrT = int8
  Pbuf {.importc: "struct pbuf", header: "<lwip/pbuf.h>".} = object
    next*: ptr Pbuf
    payload*: pointer
    tot_len*: uint16
    len*: uint16
    type_internal* {.importc: "type_internal".}: uint8
    flags*: uint8

when defined(bl808WifiRxPbufInput):
  type
    NetifInput = proc(p: ptr Pbuf; netif: ptr Netif): ErrT {.cdecl.}
    Netif {.importc: "struct netif", header: "<lwip/netif.h>".} = object
      input*: NetifInput
