proc netifapi_netif_add*(netif: ptr Netif; ipaddr, netmask, gw: ptr Ip4Addr;
                         state: pointer; init: NetifInitFn; input: NetifInputFn): int8 {.exportc, cdecl.} =
  when defined(bl808WifiRealLwip):
    proc realNetifAdd(netif: ptr Netif; ipaddr, netmask, gw: ptr Ip4Addr;
                      state: pointer; init: NetifInitFn; input: NetifInputFn): ptr Netif
      {.importc: "netif_add", header: "<lwip/netif.h>".}
    if realNetifAdd(netif, ipaddr, netmask, gw, state, init, input) != nil: 0'i8 else: -1'i8
  else:
    discard ipaddr; discard netmask; discard gw
    if netif == nil: return -1
    storePtr(cast[pointer](netif), NetifStateOff, state)
    storePtr(cast[pointer](netif), NetifInputOff, cast[pointer](input))
    if init != nil: init(netif) else: 0

proc netifapi_netif_common*(netif: ptr Netif; voidfunc: NetifVoidFn; errtfunc: NetifErrFn): int8 {.exportc, cdecl.} =
  if voidfunc != nil: voidfunc(netif)
  if errtfunc != nil: errtfunc(netif) else: 0

proc netifapi_netif_set_addr*(netif: ptr Netif; ipaddr, netmask, gw: ptr Ip4Addr): int8 {.exportc, cdecl.} =
  when defined(bl808WifiRealLwip):
    proc realNetifSetAddr(netif: ptr Netif; ipaddr, netmask, gw: ptr Ip4Addr)
      {.importc: "netif_set_addr", header: "<lwip/netif.h>".}
    if netif == nil: return -1
    realNetifSetAddr(netif, ipaddr, netmask, gw)
    0
  else:
    if netif == nil: return -1
    if ipaddr != nil: storeU32(cast[pointer](netif), NetifIpOff, loadU32(cast[pointer](ipaddr), 0))
    if netmask != nil: storeU32(cast[pointer](netif), NetifNetmaskOff, loadU32(cast[pointer](netmask), 0))
    if gw != nil: storeU32(cast[pointer](netif), NetifGwOff, loadU32(cast[pointer](gw), 0))
    0
