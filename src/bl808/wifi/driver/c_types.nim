type
  ErrT = int8

  Pbuf {.importc: "struct pbuf", header: "<lwip/pbuf.h>".} = object
    next*: ptr Pbuf
    payload*: pointer
    tot_len*: uint16
    len*: uint16

  Ip4Addr {.importc: "ip4_addr_t", header: "<lwip/ip4_addr.h>".} = object
    addr32* {.importc: "addr".}: uint32

  IpAddr {.importc: "ip_addr_t", header: "<lwip/ip_addr.h>".} = object
    addr32* {.importc: "addr".}: uint32

  Netif {.importc: "struct netif", header: "<lwip/netif.h>".} = object
    ip_addr* {.importc: "ip_addr".}: IpAddr
    hostname*: cstring
    mtu*: uint16
    hwaddr_len*: uint8
    flags*: uint8
    output*: NetifOutputFn
    linkoutput*: NetifLinkoutputFn
    status_callback*: NetifStatusCallbackFn

  NetifOutputFn = proc(netif: ptr Netif; p: ptr Pbuf; ipaddr: ptr Ip4Addr): ErrT {.cdecl.}
  NetifLinkoutputFn = proc(netif: ptr Netif; p: ptr Pbuf): ErrT {.cdecl.}
  NetifStatusCallbackFn = proc(netif: ptr Netif) {.cdecl.}
  BlTxCallback = proc(cbArg: pointer; txOk: bool) {.cdecl.}
  TaskGetCurrentTaskProc = proc(): pointer {.cdecl.}
  TaskNotifyProc = proc(task: pointer) {.cdecl.}

  BlTxCfm {.importc: "struct bl_tx_cfm", header: "bl_tx.h".} = object
    cb*: BlTxCallback
    cb_arg* {.importc: "cb_arg".}: pointer

  BlOpsFuncs {.importc: "bl_ops_funcs_t",
               header: "bl_os_adapter/bl_os_adapter.h".} = object

  WifiConfC {.importc: "wifi_conf_t", header: "include/wifi_mgmr_ext.h".} = object
    country_code* {.importc: "country_code".}: array[3, cchar]

  WifiMgmr {.importc: "wifi_mgmr_t", header: "wifi_mgmr.h".} = object
    country_code* {.importc: "country_code".}: array[3, cchar]
    channel_nums* {.importc: "channel_nums".}: cint
    hostname* {.importc: "hostname".}: array[32, cchar]
