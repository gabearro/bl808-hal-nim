when defined(bl808WifiRealLwip):
  proc netif_set_default*(netif: ptr Netif) {.importc: "netif_set_default", header: "<lwip/netif.h>".}
else:
  proc netif_set_default*(netif: ptr Netif) {.exportc, cdecl.} = discard netif

proc netifapi_netif_set_default*(netif: ptr Netif) {.exportc, cdecl.} = netif_set_default(netif)

when defined(bl808WifiRealLwip):
  proc netif_set_up*(netif: ptr Netif) {.importc: "netif_set_up", header: "<lwip/netif.h>".}
else:
  proc netif_set_up*(netif: ptr Netif) {.exportc, cdecl.} =
    if netif != nil: storeU8(cast[pointer](netif), NetifFlagsOff, loadU8(cast[pointer](netif), NetifFlagsOff) or NetifFlagUp)

proc netifapi_netif_set_up*(netif: ptr Netif) {.exportc, cdecl.} = netif_set_up(netif)

when defined(bl808WifiRealLwip):
  proc netif_set_link_up*(netif: ptr Netif) {.importc, header: "<lwip/netif.h>".}
  proc netif_set_link_down*(netif: ptr Netif) {.importc, header: "<lwip/netif.h>".}
else:
  proc netif_set_link_up*(netif: ptr Netif) {.exportc, cdecl.} =
    if netif != nil: storeU8(cast[pointer](netif), NetifFlagsOff, loadU8(cast[pointer](netif), NetifFlagsOff) or NetifFlagLinkUp)

  proc netif_set_link_down*(netif: ptr Netif) {.exportc, cdecl.} =
    if netif != nil: storeU8(cast[pointer](netif), NetifFlagsOff, loadU8(cast[pointer](netif), NetifFlagsOff) and not NetifFlagLinkUp)

proc netifapi_netif_set_link_up*(netif: ptr Netif) {.exportc, cdecl.} = netif_set_link_up(netif)
proc netifapi_netif_set_link_down*(netif: ptr Netif) {.exportc, cdecl.} = netif_set_link_down(netif)

when defined(bl808WifiRealLwip):
  proc netif_set_status_callback*(netif: ptr Netif; cb: NetifVoidFn)
    {.importc: "netif_set_status_callback", header: "<lwip/netif.h>".}
else:
  proc netif_set_status_callback*(netif: ptr Netif; cb: NetifVoidFn) {.exportc, cdecl.} =
    if netif != nil: storePtr(cast[pointer](netif), NetifStatusCbOff, cast[pointer](cb))
