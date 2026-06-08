## Imported SDK and lwIP type anchors used by the support facade.

type
  WifiConf {.importc: "wifi_conf_t", header: "include/wifi_mgmr_ext.h".} = object
  BlOpsFuncs {.importc: "bl_ops_funcs_t", header: "bl_os_adapter.h".} = object
  WifiMgmr {.importc: "wifi_mgmr_t", header: "wifi_mgmr.h".} = object
  Netif {.importc: "struct netif", header: "<lwip/netif.h>".} = object
  Pbuf {.importc: "struct pbuf", header: "<lwip/pbuf.h>".} = object
  PbufCustom {.importc: "struct pbuf_custom", header: "<lwip/pbuf.h>".} = object
  PbufLayer {.importc: "pbuf_layer", header: "<lwip/pbuf.h>".} = enum
    pbufLayerDummy
  PbufType {.importc: "pbuf_type", header: "<lwip/pbuf.h>".} = enum
    pbufTypeDummy
  Ip4Addr {.importc: "ip4_addr_t", header: "<lwip/ip4_addr.h>".} = object
  UtilsList {.importc: "struct utils_list", header: "utils_list.h".} = object
  UtilsListHdr {.importc: "struct utils_list_hdr", header: "utils_list.h".} = object
  ConstUtilsList {.importc: "const struct utils_list", header: "utils_list.h".} = object
  ConstUtilsListHdr {.importc: "const struct utils_list_hdr", header: "utils_list.h".} = object
  MacAddr {.importc: "struct mac_addr", header: "lmac_msg.h".} = object
  MacSsid {.importc: "struct mac_ssid", header: "lmac_msg.h".} = object
  BlHw {.importc: "struct bl_hw", header: "bl_defs.h".} = object
  PmEvent {.importc: "enum PM_EVEMT", header: "bl_pm.h".} = enum
    pmEventDummy
  PmLevel {.importc: "enum PM_LEVEL", header: "bl_pm.h".} = enum
    pmLevelDummy
  PmEventAble {.importc: "enum PM_EVENT_ABLE", header: "bl_pm.h".} = enum
    pmEventAbleDummy
