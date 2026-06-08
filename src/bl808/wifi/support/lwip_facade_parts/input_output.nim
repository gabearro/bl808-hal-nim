proc tcpip_input*(p: ptr Pbuf; inp: ptr Netif): int8 {.exportc, cdecl.} =
  when defined(bl808WifiRealLwip):
    proc realEthernetInput(p: ptr Pbuf; inp: ptr Netif): int8
      {.importc: "ethernet_input", header: "<netif/ethernet.h>", cdecl.}
    realEthernetInput(p, inp)
  else:
    discard inp
    discard pbuf_free(p)
    0

when defined(bl808WifiRealLwip):
  proc etharp_output*(netif: ptr Netif; q: ptr Pbuf; ipaddr: ptr Ip4Addr): int8
    {.importc: "etharp_output", header: "<lwip/etharp.h>", cdecl.}
else:
  proc etharp_output*(netif: ptr Netif; q: ptr Pbuf; ipaddr: ptr Ip4Addr): int8 {.exportc, cdecl.} =
    discard netif; discard q; discard ipaddr; 0
