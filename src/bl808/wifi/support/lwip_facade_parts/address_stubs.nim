when not defined(bl808WifiRealLwip):
  {.emit: """
#include <lwip/ip4_addr.h>
u32_t ipaddr_addr(const char *cp) { (void)cp; return 0; }
char *ip4addr_ntoa(const ip4_addr_t *addr) { (void)addr; return "0.0.0.0"; }
unsigned long inet_addr(const char *cp) { return ipaddr_addr(cp); }
""".}
