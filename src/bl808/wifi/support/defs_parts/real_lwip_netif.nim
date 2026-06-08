## C helpers for builds linked against real lwIP netif storage.

when defined(bl808WifiRealLwip):
  {.emit: """
#include <lwip/netif.h>
static struct netif bl808_real_sta_netif;
static struct netif bl808_real_ap_netif;
static uint8_t *bl808_real_netif_hwaddr(struct netif *netif) {
return netif->hwaddr;
}
static void bl808_real_netif_set_name(struct netif *netif, char a, char b) {
netif->name[0] = a;
netif->name[1] = b;
}
""".}
  var bl808_real_sta_netif {.importc, nodecl.}: Netif
  var bl808_real_ap_netif {.importc, nodecl.}: Netif
  proc realNetifHwaddr(netif: ptr Netif): ptr uint8
    {.importc: "bl808_real_netif_hwaddr", cdecl.}
  proc realNetifSetName(netif: ptr Netif; a, b: char)
    {.importc: "bl808_real_netif_set_name", cdecl.}
